{
  description = "Sandboxed LLM agent stack — L1 carrier";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs =
    { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      site = import ./site.nix;

      carrier = nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = { inherit site; };
        modules = [ ./carrier/configuration.nix ];
      };

      # $out/carrier.qcow2
      image = carrier.config.system.build.image;

      domainXml = pkgs.writeText "${site.domainName}.xml" (import ./host/domain-xml.nix { inherit site; });
      networkXml = pkgs.writeText "${site.networkName}.xml" (import ./host/network-xml.nix { inherit site; });

      # Shared preamble for the host-side scripts. They deliberately use the
      # host's own virsh and qemu-img rather than pinned ones, so they talk to
      # the libvirt that is actually running on L0.
      preamble = ''
        set -euo pipefail

        # virsh output is translated, and these scripts match on it.
        export LC_ALL=C LANG=C

        IMAGE_DIR=${site.imageDir}
        DOMAIN=${site.domainName}
        NETWORK=${site.networkName}
        IMAGE_STORE=${image}
        DOMAIN_XML=${domainXml}
        NETWORK_XML=${networkXml}
        SYSTEM_LINK="$IMAGE_DIR/l1-system-current.qcow2"
        DATA_DISK="$IMAGE_DIR/l1-data.raw"

        if [ "$(id -u)" -ne 0 ]; then
          echo "==> re-executing under sudo"
          exec sudo -- "$0" "$@"
        fi

        for tool in virsh qemu-img; do
          command -v "$tool" >/dev/null || { echo "missing on this host: $tool" >&2; exit 1; }
        done

        install_image() {
          local stamp target
          stamp=$(date +%Y%m%d-%H%M%S)
          target="$IMAGE_DIR/l1-system-$stamp.qcow2"
          echo "==> installing $IMAGE_STORE/carrier.qcow2 as $target"
          install -m 0600 "$IMAGE_STORE/carrier.qcow2" "$target"
          ln -sfn "$target" "$SYSTEM_LINK"
          # One system image retained, as with the golden on L1: the one just
          # installed, which the symlink now points at. Nothing that has to
          # survive lives on the system disk — that is what /data is for — so
          # recovery from a bad image is to deploy a good one, not to keep
          # older copies around.
          #
          # Matched on the stamp rather than by resolving the symlink: the two
          # agree, and a direct match cannot be fooled by a symlink that is
          # missing or dangling.
          find "$IMAGE_DIR" -maxdepth 1 -type f -name 'l1-system-*.qcow2' \
            ! -name "l1-system-$stamp.qcow2" -print -delete | sed 's/^/    pruned /'
        }

        domain_running() {
          virsh list --name --state-running 2>/dev/null | grep -qx "$DOMAIN"
        }

        stop_domain() {
          if domain_running; then
            echo "==> shutting $DOMAIN down"
            virsh shutdown "$DOMAIN" >/dev/null
            for _ in $(seq 1 60); do
              domain_running || break
              sleep 1
            done
            if domain_running; then
              echo "==> graceful shutdown timed out, destroying"
              virsh destroy "$DOMAIN" >/dev/null
            fi
          fi
        }
      '';

      goldenScript = pkgs.writeShellScriptBin "agent-stack-golden-build" ''
        set -euo pipefail
        export LC_ALL=C LANG=C

        # Runs on L0, which is Arch: mkosi gets the FHS host it expects, its
        # sandbox is not nested inside another one, and pacman's
        # post-transaction hooks execute normally. The result is copied to L1.
        #
        # mkosi, qemu-img and rsync come from the flake so they are pinned with
        # everything else and L0 needs nothing installed for them. What must
        # come from the host is pacman: mkosi sets PATH to /usr/bin:/usr/sbin
        # inside its own sandbox and looks for it there, which is exactly the
        # assumption that fails on NixOS and holds on Arch.
        BUILD=/var/tmp/agent-stack-golden
        SRC=${./image}
        MKOSI=${pkgs.mkosi}/bin/mkosi
        QEMU_IMG=${pkgs.qemu-utils}/bin/qemu-img
        RSYNC=${pkgs.rsync}/bin/rsync

        if [ ! -x /usr/bin/pacman ]; then
          echo "/usr/bin/pacman not found: this must run on an Arch host" >&2
          exit 1
        fi
        # makepkg builds the AUR helper, npm stages the agents. Both run here
        # rather than inside the image, which would need mkosi-chroot.
        for tool in ssh makepkg git curl; do
          command -v "$tool" >/dev/null \
            || { echo "missing on this host: $tool (pacman -S base-devel git curl)" >&2; exit 1; }
        done
        if [ "$(id -u)" -eq 0 ]; then true; fi

        # Built as root, transferred as you: root has no ssh key for L1, and
        # the stack's private key never leaves your account.
        if [ "$(id -u)" -eq 0 ]; then
          echo "run as your normal user, not root; it will sudo where needed" >&2
          exit 1
        fi

        sudo rm -rf "$BUILD/config" "$BUILD/workspace"
        sudo mkdir -p "$BUILD/config" "$BUILD/out" "$BUILD/cache" "$BUILD/workspace"
        # mkosi creates this subdirectory only after a successful metadata
        # sync, but binds it into the sandbox only if it already exists, while
        # passing --cachedir for it unconditionally. A fresh cache directory
        # therefore cannot complete its first sync unless we create it here.
        sudo mkdir -p "$BUILD/pkgcache/cache/pacman/pkg" "$BUILD/pkgcache/lib/pacman/sync"
        sudo cp -rT "$SRC" "$BUILD/config"
        sudo chmod -R u+w "$BUILD/config"
        # makepkg and npm run as you, and both write into the staged config.
        sudo chown -R "$(id -u):$(id -g)" "$BUILD/config" "$BUILD/aur" 2>/dev/null || true
        sudo chown "$(id -u):$(id -g)" "$BUILD"

        # Both of these are silent failures otherwise. A missing mkosi.conf
        # makes mkosi fall back to Distribution=custom; a missing profile is
        # ignored, and the build quietly produces the light image — which is
        # exactly what happened once.
        [ -f "$BUILD/config/mkosi.conf" ] \
          || { echo "no mkosi.conf under $BUILD/config; is image/ tracked by git?" >&2; exit 1; }
        if [ ! -f "$BUILD/config/mkosi.profiles/${site.guest.profile}.conf" ]; then
          echo "no mkosi.profiles/${site.guest.profile}.conf under $BUILD/config" >&2
          echo "the profile would be ignored and you would get the light image" >&2
          echo "on L0: git add -A" >&2
          exit 1
        fi

        # --- AUR packages ----------------------------------------------------
        # Not in the official repositories, so they are built here and handed
        # to mkosi through mkosi.packages/, which it turns into a local
        # repository. makepkg refuses to run as root, which is why this script
        # is not; -s lets it install its own build dependencies on L0.
        mkdir -p "$BUILD/config/mkosi.packages"
        rm -rf "$BUILD/aur"
        mkdir -p "$BUILD/aur"
        for aur in ${nixpkgs.lib.concatStringsSep " " site.guest.aurPackages}; do
          echo "==> building $aur from the AUR"
          git clone --depth 1 "https://aur.archlinux.org/$aur.git" "$BUILD/aur/$aur"
          ( cd "$BUILD/aur/$aur" && makepkg --syncdeps --noconfirm --clean )
          cp "$BUILD/aur/$aur"/*.pkg.tar.* "$BUILD/config/mkosi.packages/"
        done
        ls "$BUILD/config/mkosi.packages/"*.pkg.tar.* >/dev/null \
          || { echo "no AUR packages staged; mkosi would fail with 'target not found'" >&2; exit 1; }

        # --- the agents ------------------------------------------------------
        # Each vendor's own installer, run with HOME pointed at a staging
        # directory so everything lands where it would in a real home. The
        # result is copied into /home/agent by mkosi.postinst, which keeps
        # self-update working: it writes to the overlay rather than to a
        # system path it cannot touch.
        #
        # Run here rather than in the image for the usual reason — executing
        # inside the image needs mkosi-chroot — and as the invoking user, so
        # nothing installs as root.
        echo "==> staging the agents"
        rm -rf "$BUILD/config/agent-home"
        mkdir -p "$BUILD/config/agent-home"
        for installer in ${nixpkgs.lib.concatStringsSep " " site.guest.agentInstallers}; do
          echo "    $installer"
          script=$(mktemp)
          curl -fsSL "$installer" -o "$script"
          # setsid with stdin from /dev/null, not just a pipe: these installers
          # ask questions on /dev/tty, which a pipe does not intercept — the
          # Codex one ends with "Start Codex now? [y/N]" and waits forever.
          # Without a controlling terminal the prompt falls back to its default
          # and the script exits. CI is the conventional hint for the same
          # thing, set here as well because some installers honour it and
          # skip the prompt outright.
          setsid --wait env CI=1 \
            HOME="$BUILD/config/agent-home" \
            PREFIX="$BUILD/config/agent-home/.local" \
            bash "$script" </dev/null || true
          rm -f "$script"
        done
        # The installers are allowed to fail past their prompt, so check the
        # result rather than the exit status.
        echo "==> staged into the agent home:"
        ls "$BUILD/config/agent-home/.local/bin" 2>/dev/null | sed 's/^/    /' \
          || { echo "no agent landed in .local/bin" >&2; exit 1; }

        echo "==> building (long: full package set)"
        # Run *from* the config directory rather than pointing at it with
        # --directory alone: mkosi resolves profiles as
        # Path.cwd()/mkosi.profiles/<name>, so from anywhere else the profile
        # is not found — and a profile that is not found is silently ignored,
        # which produces a complete, working, wrong image.
        cd "$BUILD/config"
        sudo "$MKOSI" \
          --directory "$BUILD/config" \
          --output-directory "$BUILD/out" \
          --cache-directory "$BUILD/cache" \
          --package-cache-directory "$BUILD/pkgcache" \
          --workspace-directory "$BUILD/workspace" \
          --package-directory "$BUILD/config/mkosi.packages" \
          --profile ${site.guest.profile} \
          --environment VNC_GEOMETRY=${site.guest.vnc.geometry} \
          --environment VNC_DEPTH=${toString site.guest.vnc.depth} \
          --snapshot ${site.guest.snapshot} \
          --locale ${site.guest.locale} \
          --keymap ${site.guest.keymap} \
          --timezone ${site.guest.timezone} \
          --force \
          build

        raw=$(sudo find "$BUILD/out" -maxdepth 1 -name '*.raw' -print -quit)
        [ -n "$raw" ] || { echo "mkosi produced no .raw image" >&2; exit 1; }

        stamp=$(date +%Y%m%d)
        local_qcow=$BUILD/arch-$stamp.qcow2
        echo "==> converting to qcow2"
        sudo "$QEMU_IMG" convert -O qcow2 "$raw" "$local_qcow"
        sudo chown "$(id -u):$(id -g)" "$local_qcow"
        sudo rm -f "$raw"
        "$QEMU_IMG" info "$local_qcow" | sed 's/^/    /'

        echo "==> copying to L1 (sparse; this is the cost of building here)"
        "$RSYNC" --sparse --info=progress2 "$local_qcow" root@l1:/data/images/golden/

        # The symlink is repointed only after the copy lands. Overlays record
        # the resolved dated path, never this symlink, so repointing it can
        # never rebase an existing overlay. One golden is retained, so a
        # forgotten overlay fails loudly instead of reading a base that is gone.
        ssh root@l1 "
          set -e
          ln -sfn /data/images/golden/arch-$stamp.qcow2 /data/images/current
          find /data/images/golden -maxdepth 1 -type f -name 'arch-*.qcow2' \
            ! -name 'arch-$stamp.qcow2' -print -delete | sed 's/^/    pruned /'
          echo '    current -> '\$(readlink /data/images/current)
          df -h /data | tail -1 | sed 's/^/    /'
        "

        sudo rm -f "$local_qcow"
        # The workspace is scratch, but the staged config is kept: it is what
        # `mkosi --directory ... cat-config` needs to explain what was built.
        sudo rm -rf "$BUILD/workspace"
        echo "==> done; package cache kept in $BUILD/pkgcache"
      '';

      updateScript = pkgs.writeShellScriptBin "agent-stack-golden-update" ''
        set -euo pipefail
        export LC_ALL=C LANG=C

        # Routine maintenance in one command: find the newest archive
        # snapshot, record it, reset every project, rebuild, and say how to
        # start them again. Resetting *before* the rebuild matters — a golden
        # is pruned once its replacement lands, and an overlay pinned to a
        # deleted one refuses to start.
        [ "$(id -u)" -ne 0 ] || { echo "run as your normal user" >&2; exit 1; }
        repo=$(${pkgs.git}/bin/git rev-parse --show-toplevel)
        cd "$repo"

        current=${site.guest.snapshot}
        echo "==> resolving the newest snapshot"
        latest=$(cd image && ${pkgs.mkosi}/bin/mkosi latest-snapshot)
        echo "    current $current, latest $latest"
        if [ "$current" = "$latest" ]; then
          echo "    already current; nothing to do"
          exit 0
        fi

        echo "==> recording it in site.nix"
        ${pkgs.gnused}/bin/sed -i \
          "s|snapshot = \"$current\";|snapshot = \"$latest\";|" site.nix
        ${pkgs.git}/bin/git -C "$repo" add -A
        ${pkgs.git}/bin/git -C "$repo" --no-pager diff --cached -- site.nix | tail -4

        echo "==> resetting projects, so none is left pinned to the old golden"
        projects=$(ssh l1 agentctl status | tail -n +2 | ${pkgs.gawk}/bin/awk '{print $1}')
        for p in $projects; do
          echo "    $p"
          ssh l1 "agentctl reset $p"
        done

        echo "==> rebuilding against $latest"
        nix run "$repo#golden-build"

        echo
        echo "Done. Start them again with:"
        for p in $projects; do echo "  ssh l1 agentctl start $p"; done
        echo
        echo "Commit site.nix to keep the pin; the agents and AUR packages are"
        echo "always built from current sources and are not covered by it."
      '';

      # Just prints the newest snapshot date, for deciding whether a bump is
      # worth making. mkosi comes from the flake, so this is the only way to
      # ask the question without installing it on the host; `golden-update`
      # resolves the same date and then acts on it.
      snapshotScript = pkgs.writeShellScriptBin "agent-stack-latest-snapshot" ''
        set -euo pipefail
        export LC_ALL=C LANG=C
        cd "$(${pkgs.git}/bin/git rev-parse --show-toplevel)/image"
        exec ${pkgs.mkosi}/bin/mkosi latest-snapshot
      '';

      agentScript = pkgs.writeShellScriptBin "agent" ''
        set -euo pipefail

        # Runs on L0. Each invocation resolves the project by name, syncs the
        # dotfiles unless told not to, ensures the sandbox exists and is
        # running, pushes credentials into tmpfs, and attaches.
        #
        # Authority stays on L1: everything privileged is done by agentctl
        # there, over ssh. This wrapper never touches L1's state directly.

        CRED_SOURCE=${site.credentials.source}
        AUTHINFO=${site.credentials.authinfoFile}

        # One line per credential: variable, machine name, command. The machine
        # name is what the synthesised netrc uses; the command is ignored when
        # the source is authinfo.
        cred_entries() {
          cat <<'ENTRIES'
${
  nixpkgs.lib.concatStringsSep "\n" (
    nixpkgs.lib.mapAttrsToList (
      var: e: "${var}|${e.machine}|${e.command}"
    ) site.credentials.entries
  )
}
ENTRIES
        }

        die() { echo "agent: $*" >&2; exit 1; }

        usage() {
          {
            echo "agent claude-pro <project>    Claude Code, Pro auth"
            echo "agent claude-api <project>    Claude Code, API key auth"
            echo "agent codex <project>         Codex CLI, API key auth"
            echo "agent opencode <project>      opencode"
            echo "agent emacs <project>         emacsclient on the VNC display"
            echo "agent vnc <project>           just the VNC viewer"
            echo "agent shell <project>         a plain shell"
            echo "agent start <project>         bring it up, do not attach"
            echo "agent stop <project>          power off; overlay intact"
            echo "agent reset <project>         stop, then delete the overlay"
            echo "agent capture <project> start|stop"
            echo "agent service list"
            echo "agent service start|stop|restart|status|logs <name>"
          } >&2
          exit 1
        }

        host() { echo "$1.agents.${site.internalDomain}"; }

        # There is deliberately no dotfiles command here. A sandbox is seeded
        # with dotfilesRoot when it is created and owns its copies from then
        # on; pushing a later change into a running one is `agent reset`.
        ensure_running() {
          ssh l1 "agentctl start $1" >&2
        }

        # Fetch one secret. Whether that means running a command or pulling a
        # line out of a netrc file is the only difference between the two
        # sources; everything downstream is identical.
        cred_value() {
          local var=$1 machine=$2 command=$3
          if [ "$CRED_SOURCE" = authinfo ]; then
            gpg --quiet --batch --decrypt "''${AUTHINFO/#\~/$HOME}" 2>/dev/null \
              | awk -v m="$machine" '$0 ~ ("machine " m " ") {
                    for (i = 1; i < NF; i++) if ($i == "password") { print $(i+1); exit } }'
          else
            # eval, because a recipe is a command line with its own quoting:
            # `pass show ai/anthropic`, `op read op://...`, `age -d -i key f`.
            eval "$command" 2>/dev/null | head -1
          fi
        }

        # Both credential files, from one pass over the table.
        #
        # /run/creds/env is what the agents are started with. /run/creds/authinfo
        # is synthesised in netrc form for Emacs and gptel — so a netrc file is
        # an *output* of this, never a requirement of it. Both are written
        # straight into tmpfs in the sandbox: nothing touches disk on L0 or L1.
        push_creds() {
          local project=$1 target env_lines netrc_lines var machine command value found=0
          target=$(host "$project")
          env_lines=""
          netrc_lines=""

          while IFS='|' read -r var machine command; do
            [ -n "$var" ] || continue
            value=$(cred_value "$var" "$machine" "$command")
            if [ -z "$value" ]; then
              echo "agent: no value for $var" >&2
              continue
            fi
            found=1
            env_lines="$env_lines$var=$value"$'\n'
            # login apikey is what auth-source and gptel look up; the field is
            # required by the netrc format even where it means nothing.
            netrc_lines="$netrc_lines""machine $machine login apikey password $value"$'\n'
          done < <(cred_entries)

          [ "$found" = 1 ] || {
            echo "agent: no credentials resolved; see credentials in site.nix" >&2
            return 0
          }

          printf '%s' "$env_lines" \
            | ssh "$target" 'install -m600 /dev/stdin /run/creds/env'
          printf '%s' "$netrc_lines" \
            | ssh "$target" 'install -m600 /dev/stdin /run/creds/authinfo'
        }

        # Fail by name here rather than leaving the agent to report a missing
        # key from inside its own interface, where it reads as a login problem.
        require_var() {
          ssh "$(host "$1")" "grep -q '^$2=' /run/creds/env" \
            || die "no $2 in /run/creds/env: check its entry under credentials in site.nix"
        }

        # The display stack exists only in the full profile, and a binary being
        # installed is not the same as a display running: test the port.
        require_display() {
          ssh "$(host "$1")" 'command -v Xvnc >/dev/null' \
            || die "this golden has no display stack: set guest.profile = \"full\" in site.nix, then nix run '.#golden-build'"
          # Match on the port, not on 127.0.0.1: Xvnc binds loopback on both
          # families and may offer only [::1], which an address match misses
          # while the display is perfectly healthy.
          ssh "$(host "$1")" 'ss -lnt | awk "{print \$4}" | grep -q ":5900$"' \
            || die "nothing is listening on :0 in $1: ssh $(host "$1") systemctl status xvnc"
        }

        # -via the *sandbox*, not l1. Xvnc binds the sandbox's loopback only,
        # so a tunnel terminating on L1 would then have to reach 5900 across
        # the network, which is precisely what -localhost forbids. ssh reaches
        # the sandbox through L1 anyway, by the ProxyJump in ~/.ssh/config, so
        # this is one hop in appearance and two in fact.
        view() {
          command -v vncviewer >/dev/null \
            || die "vncviewer not found on this host (pacman -S tigervnc)"
          vncviewer -via "$(host "$1")" localhost:0
        }

        # tmux in the sandbox, so a long agent run survives a dropped
        # connection and can be reattached.
        attach() {
          local project=$1 session=$2 cmd=$3
          # LANG explicitly: tmux decides whether the terminal is UTF-8 once,
          # when its server starts, from LANG or LC_CTYPE. An ssh command gets
          # neither a login nor an interactive shell, so without this it starts
          # in POSIX and draws an underscore for every character it will not
          # render. The image sets this too, through /etc/environment; this
          # line also covers a sandbox built before that.
          #
          # -c /work: the session starts in the project directory, which is
          # what the agent is here to work on. Only applies when the session is
          # created; reattaching leaves you wherever you were, which is the
          # behaviour you want from a session you left running.
          ssh -t "$(host "$project")" \
            "LANG=${site.guest.locale} tmux new-session -A -s $session -c /work $cmd"
        }

        # ---------------------------------------------------------------------
        [ $# -ge 1 ] || usage
        verb=$1
        shift

        case "$verb" in
          service)
            # Service stacks are systemd units on L1, started at boot. This is
            # for restarting one after changing its compose file, or looking at
            # why it is unhappy — turning one off for good is enable = false in
            # site.nix, not a command.
            [ $# -ge 1 ] || usage
            case "$1" in
              list) ssh l1 'systemctl list-units "svc-*" --no-pager' ;;
              start|stop|restart)
                [ $# -eq 2 ] || usage
                ssh l1 "systemctl $1 svc-$2" ;;
              status|logs)
                [ $# -eq 2 ] || usage
                if [ "$1" = logs ]; then
                  ssh l1 "journalctl -u svc-$2 -n 50 --no-pager"
                else
                  ssh l1 "systemctl status svc-$2 --no-pager"
                fi ;;
              *) usage ;;
            esac
            ;;
          start)
            # Everything an attaching verb does except the attach: useful to
            # warm a sandbox before you need it, or to push credentials for
            # something that will connect by other means.
            [ $# -eq 1 ] || usage
            ensure_running "$1"; push_creds "$1"
            echo "$1 is up at $(host "$1")"
            ;;
          stop|reset)
            [ $# -eq 1 ] || usage
            ssh l1 "agentctl $verb $1"
            ;;
          capture)
            [ $# -eq 2 ] || usage
            ssh l1 "agentctl capture $1 $2"
            ;;
          shell)
            [ $# -eq 1 ] || usage
            ensure_running "$1"; push_creds "$1"
            attach "$1" shell "'exec \$SHELL -l'"
            ;;
          claude-api)
            [ $# -eq 1 ] || usage
            ensure_running "$1"; push_creds "$1"
            require_var "$1" ANTHROPIC_API_KEY
            # set -a exports everything the file defines, so one mechanism
            # serves every provider. A separate CLAUDE_CONFIG_DIR from Pro
            # mode, so the two cannot collide.
            attach "$1" claude-api \
              "'set -a; . /run/creds/env; set +a; \
                CLAUDE_CONFIG_DIR=\$HOME/.config/claude-api claude'"
            ;;
          claude-pro)
            [ $# -eq 1 ] || usage
            ensure_running "$1"; push_creds "$1"
            # Pro tokens land in the config directory on the overlay and
            # survive stop, but not reset: log in once per reset.
            attach "$1" claude-pro \
              "'CLAUDE_CONFIG_DIR=\$HOME/.config/claude-pro claude'"
            ;;
          codex)
            [ $# -eq 1 ] || usage
            ensure_running "$1"; push_creds "$1"
            require_var "$1" OPENAI_API_KEY
            # CODEX_HOME on the overlay, alongside the other agents' config
            # directories, so it survives stop and is discarded by reset.
            # Codex requires the directory to exist before it will start.
            attach "$1" codex \
              "'set -a; . /run/creds/env; set +a; \
                export CODEX_HOME=\$HOME/.config/codex; \
                mkdir -p \$CODEX_HOME; codex'"
            ;;
          opencode)
            [ $# -eq 1 ] || usage
            ensure_running "$1"; push_creds "$1"
            # *Every* configured key, not one: opencode offers the models from
            # its own subscription through OPENCODE_API_KEY and direct
            # Anthropic access through ANTHROPIC_API_KEY, and lists both at
            # once. Through the environment rather than `opencode auth login`,
            # which writes to auth.json on the overlay where it survives stop.
            attach "$1" opencode "'set -a; . /run/creds/env; set +a; opencode'"
            ;;
          vnc)
            [ $# -eq 1 ] || usage
            ensure_running "$1"; push_creds "$1"
            require_display "$1"
            view "$1"
            ;;
          emacs)
            [ $# -eq 1 ] || usage
            # Credentials first, and before the daemon starts: auth-source
            # caches a miss, so a daemon that reads authinfo before it exists
            # keeps believing there is no key until it is restarted.
            ensure_running "$1"; push_creds "$1"
            require_display "$1"
            # Idempotent: attaches to the frame that is already there, and
            # creates one only if there is none, so reconnecting after closing
            # the viewer does not stack frames. Also points *scratch* at the
            # project, which the daemon would otherwise inherit from whatever
            # started it.
            ssh "$(host "$1")" 'agent-emacs-frame /work' >/dev/null
            view "$1"
            ;;
          *) usage ;;
        esac
      '';

      cleanScript = pkgs.writeShellScriptBin "agent-stack-clean" ''
        set -euo pipefail
        export LC_ALL=C LANG=C
        BUILD=/var/tmp/agent-stack-golden

        echo "==> before"
        sudo du -shc "$BUILD"/* 2>/dev/null | tail -1 | sed 's/^/    /' || true
        df -h /var/tmp | tail -1 | sed 's/^/    /'

        # Scratch from the last build. The raw image is the big one: 41 GiB
        # nominal, several GiB real, and a *failed* build leaves it behind
        # because the conversion that normally deletes it never ran.
        echo "==> removing build scratch"
        sudo rm -rf "$BUILD/out" "$BUILD/workspace" "$BUILD/aur" "$BUILD/config"

        if [ "''${1:-}" = "--all" ]; then
          # The package cache is what makes a rebuild cheap: dropping it means
          # the next build redownloads every package. Worth it only when the
          # disk is actually short.
          echo "==> removing the package and image caches as well"
          sudo rm -rf "$BUILD/cache" "$BUILD/pkgcache"
        fi

        echo "==> after"
        sudo du -shc "$BUILD"/* 2>/dev/null | tail -1 | sed 's/^/    /' || true
        df -h /var/tmp | tail -1 | sed 's/^/    /'
        echo
        echo "Nix store paths from past builds are separate; to reclaim those:"
        echo "  nix store gc"
      '';

      installScript = pkgs.writeShellScriptBin "agent-stack-install" ''
        ${preamble}

        echo "==> preflight"
        for m in kvm_intel kvm_amd; do
          f=/sys/module/$m/parameters/nested
          [ -r "$f" ] && echo "    nested ($m): $(cat "$f")"
        done
        [ -e /dev/kvm ] || { echo "/dev/kvm missing: enable virtualization in firmware" >&2; exit 1; }
        if [ ! -d ${site.exportRoot} ]; then
          echo "export root ${site.exportRoot} does not exist" >&2; exit 1
        fi
        mode=$(stat -c %a ${site.exportRoot})
        [ "$mode" = "700" ] || echo "    warning: ${site.exportRoot} is mode $mode, expected 700"

        install -d -m 0700 -o root -g root "$IMAGE_DIR"

        if [ ! -e "$DATA_DISK" ]; then
          echo "==> creating sparse data disk $DATA_DISK (${site.l1.dataDiskSize})"
          truncate -s ${site.l1.dataDiskSize} "$DATA_DISK"
          chmod 0600 "$DATA_DISK"
        else
          echo "==> data disk already present, left untouched"
        fi

        install_image

        if ! virsh net-info "$NETWORK" >/dev/null 2>&1; then
          echo "==> defining network $NETWORK"
          virsh net-define "$NETWORK_XML" >/dev/null
        fi
        virsh net-autostart "$NETWORK" >/dev/null
        if ! virsh net-list --name 2>/dev/null | grep -qx "$NETWORK"; then
          virsh net-start "$NETWORK"
        fi

        echo "==> defining domain $DOMAIN"
        virsh define "$DOMAIN_XML" >/dev/null
        if domain_running; then
          echo "    already running"
        else
          virsh start "$DOMAIN"
        fi

        echo
        echo "L1 is starting. Next:"
        echo "  sudo virsh console $DOMAIN     # serial console, ctrl-] to leave"
        echo "  ssh l1                         # once ~/.ssh/config is in place"
      '';

      deployScript = pkgs.writeShellScriptBin "agent-stack-deploy" ''
        ${preamble}

        stop_domain
        install_image
        echo "==> redefining domain $DOMAIN"
        virsh define "$DOMAIN_XML" >/dev/null
        virsh start "$DOMAIN" >/dev/null
        echo "==> $DOMAIN started on a fresh system image; /data untouched"
      '';
    in
    {
      nixosConfigurations.agentvm = carrier;

      packages.${system} = {
        default = image;
        image = image;
        domain-xml = domainXml;
        network-xml = networkXml;
        install = installScript;
        deploy = deployScript;
        golden-build = goldenScript;
        clean = cleanScript;
        golden-update = updateScript;
        latest-snapshot = snapshotScript;
        agent = agentScript;
      };

      apps.${system} = {
        install = {
          type = "app";
          program = "${installScript}/bin/agent-stack-install";
        };
        deploy = {
          type = "app";
          program = "${deployScript}/bin/agent-stack-deploy";
        };
        golden-build = {
          type = "app";
          program = "${goldenScript}/bin/agent-stack-golden-build";
        };
        clean = {
          type = "app";
          program = "${cleanScript}/bin/agent-stack-clean";
        };
        golden-update = {
          type = "app";
          program = "${updateScript}/bin/agent-stack-golden-update";
        };
        latest-snapshot = {
          type = "app";
          program = "${snapshotScript}/bin/agent-stack-latest-snapshot";
        };
        agent = {
          type = "app";
          program = "${agentScript}/bin/agent";
        };
      };

      formatter.${system} = pkgs.nixfmt-tree;
    };
}
