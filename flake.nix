{
  description = "Sandboxed LLM agent stack — L1 carrier";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs =
    { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      lib = nixpkgs.lib;

      # The image itself needs these, whatever guest.aurPackages adds:
      # mkosi.conf installs yay, and the full profile emacs-lsp-booster.
      baseAurPackages = [
        "yay-bin"
        "emacs-lsp-booster"
      ];

      # Everything this repository builds, for one site. A site is the
      # defaults in site/options.nix plus the modules a site flake passes in,
      # normally just its own site.nix; template/ is that flake. This flake has
      # no apps of its own, so nothing here can run on placeholder values.
      mkStack =
        { modules }:
        let
          site = (lib.evalModules { modules = [ ./site/options.nix ] ++ modules; }).config;

          carrier = nixpkgs.lib.nixosSystem {
            inherit system;
            specialArgs = { inherit site; };
            modules = [ ./carrier/configuration.nix ] ++ site.carrier.extraModules;
          };

          # $out/carrier.qcow2
          image = carrier.config.system.build.image;

          # libvirt starts L1's virtiofsd itself and has no setting for
          # --inode-file-handles, so the domain names this wrapper as its binary:
          # the same pinned virtiofsd the sandboxes get on L1, with the same flag.
          # Why both hops need it: see pin_virtiofsd_wrapper in the preamble.
          virtiofsdWrapper = pkgs.writeShellScript "virtiofsd-no-file-handles" ''
            exec ${pkgs.virtiofsd}/bin/virtiofsd --inode-file-handles=never "$@"
          '';
          # The same, refusing every write, for the dotfiles: libvirt has no
          # read-only setting for a virtiofs share either.
          virtiofsdReadonlyWrapper = pkgs.writeShellScript "virtiofsd-no-file-handles-readonly" ''
            exec ${pkgs.virtiofsd}/bin/virtiofsd --inode-file-handles=never --readonly "$@"
          '';
          domainXml = pkgs.writeText "${site.domainName}.xml" (
            import ./host/domain-xml.nix { inherit site virtiofsdWrapper virtiofsdReadonlyWrapper; }
          );
          networkXml = pkgs.writeText "${site.networkName}.xml" (import ./host/network-xml.nix { inherit site; });

          # The ssh stanzas for L1 and the sandboxes, printed by
          # `nix run .#ssh-config` for ~/.ssh/config. Generated rather than kept
          # as a file, so that the address and the zone always match site.nix.
          sshConfig = pkgs.writeText "agent-stack-ssh_config" ''

            # --- agent-stack: printed by `nix run .#ssh-config` ---------------
            # All connections are initiated from L0 inwards; nothing downstream
            # may initiate outwards. No forced command and no restrict on the
            # key: both would break ProxyJump, the credential push and
            # vncviewer -via.

            Host l1
                HostName ${site.wan.address}
                User root
                IdentityFile ${site.sshIdentityFile}
                IdentitiesOnly yes

            # Sandboxes, by internal name only, never by address: a pattern like
            # 10.42.* would match hosts on any network you ever reach. Nothing
            # on L0 resolves these names: with ProxyJump, L1 does.
            #
            # Host key checking is off here, and only here. A sandbox regenerates
            # its host keys on every reset, which is the point of a reset, and a
            # habit of dismissing warnings costs more than this check is worth.
            # The check that matters is on l1 above: reaching a sandbox means
            # authenticating to L1 first.
            Host *.agents.${site.internalDomain}
                ProxyJump l1
                User agent
                IdentityFile ${site.sshIdentityFile}
                IdentitiesOnly yes
                UserKnownHostsFile /dev/null
                StrictHostKeyChecking no
                LogLevel ERROR
            # --- end of agent-stack -------------------------------------------
          '';
          sshConfigScript = pkgs.writeShellScriptBin "agent-stack-ssh-config" "cat ${sshConfig}";

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
            VIRTIOFSD_WRAPPER=${virtiofsdWrapper}
            VIRTIOFSD_READONLY_WRAPPER=${virtiofsdReadonlyWrapper}
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
              # One system image retained: the one just
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

            # L0's virtiofsd must keep an fd on every inode L1 references, not a
            # file handle, which current virtiofsd prefers by default. L1's
            # virtiofsd tells inodes apart by inode number, which is only safe
            # while each one is pinned: with handles here, ext4 frees a deleted
            # inode at once and reuses its number, and L1 then hands a sandbox
            # the wrong inode (EBADF, ESTALE). Hence the wrapper the domain names.
            #
            # The domain XML refers to the wrappers by store path, and nothing
            # else keeps them alive: without a GC root, nix-collect-garbage on
            # L0 would delete the binaries libvirt starts for L1. One root per
            # wrapper, replaced on every install and deploy.
            pin_virtiofsd_wrapper() {
              ln -sfn "$VIRTIOFSD_WRAPPER" /nix/var/nix/gcroots/agent-stack-virtiofsd
              ln -sfn "$VIRTIOFSD_READONLY_WRAPPER" /nix/var/nix/gcroots/agent-stack-virtiofsd-readonly
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

            # The archive date comes from site.nix, unless golden-update passes
            # the one it has just resolved: it records that date only once this
            # build has succeeded.
            SNAPSHOT=${site.guest.snapshot}
            if [ "''${1:-}" = --snapshot ] && [ -n "''${2:-}" ]; then
              SNAPSHOT=$2
            fi

            # guest.extraPackages, on top of image/mkosi.conf and the profile.
            EXTRA_PACKAGES=(${lib.escapeShellArgs site.guest.extraPackages})
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
            for aur in ${nixpkgs.lib.concatStringsSep " " (lib.unique (baseAurPackages ++ site.guest.aurPackages))}; do
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
              --environment GUEST_TIMEZONE=${site.timezone} \
              --snapshot "$SNAPSHOT" \
              --locale ${site.guest.locale} \
              --keymap ${site.guest.keymap} \
              "''${EXTRA_PACKAGES[@]/#/--package=}" \
              --force \
              build

            raw=$(sudo find "$BUILD/out" -maxdepth 1 -name '*.raw' -print -quit)
            [ -n "$raw" ] || { echo "mkosi produced no .raw image" >&2; exit 1; }

            # Down to the second: a second build the same day must not take the
            # name, and so the place, of a golden that overlays are pinned to.
            stamp=$(date +%Y%m%d-%H%M%S)
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
            # never rebase an existing overlay. The prune runs after the repoint,
            # so an overlay created meanwhile is on the new golden; it keeps any
            # old golden an overlay is still pinned to.
            ssh root@l1 "
              set -eo pipefail
              ln -sfn /data/images/golden/arch-$stamp.qcow2 /data/images/current
              agentctl prune | sed 's/^/    /'
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
            # snapshot, rebuild against it, record it in site.nix, reset every
            # project onto the new golden, prune the old one, and say how to
            # start them again. Nothing is recorded or reset until the build has
            # succeeded: a failed build costs no overlay and leaves site.nix as
            # it was. The build's own prune has kept the old golden, which the
            # projects were still pinned to, hence the second prune.
            [ "$(id -u)" -ne 0 ] || { echo "run as your normal user" >&2; exit 1; }

            # The pin is a line in your site.nix, so this runs where that is.
            [ -f site.nix ] && [ -f flake.nix ] \
              || { echo "run this from your site folder, the one holding site.nix" >&2; exit 1; }
            current=${site.guest.snapshot}
            grep -q "snapshot = \"$current\";" site.nix || {
              echo "site.nix has no line  snapshot = \"$current\";  to update." >&2
              echo "Add  guest.snapshot = \"$current\";  to it, then run this again." >&2
              exit 1
            }

            echo "==> resolving the newest snapshot"
            latest=$(cd ${./image} && ${pkgs.mkosi}/bin/mkosi latest-snapshot)
            echo "    current $current, latest $latest"
            if [ "$current" = "$latest" ]; then
              echo "    already current; nothing to do"
              exit 0
            fi

            echo "==> rebuilding against $latest"
            ${goldenScript}/bin/agent-stack-golden-build --snapshot "$latest"

            echo "==> recording it in site.nix"
            ${pkgs.gnused}/bin/sed -i \
              "s|snapshot = \"$current\";|snapshot = \"$latest\";|" site.nix
            grep -n "snapshot = " site.nix | sed 's/^/    /'

            echo "==> resetting projects onto the new golden"
            projects=$(ssh l1 agentctl status | tail -n +2 | ${pkgs.gawk}/bin/awk '{print $1}')
            for p in $projects; do
              echo "    $p"
              ssh l1 "agentctl reset $p"
            done

            echo "==> pruning the old golden"
            ssh l1 agentctl prune | sed 's/^/    /'

            echo
            echo "Done. Start them again with:"
            for p in $projects; do echo "  ssh l1 agentctl start $p"; done
            echo
            echo "site.nix now pins $latest. The agents and AUR packages are always"
            echo "built from current sources and are not covered by the pin."
          '';

          # Just prints the newest snapshot date, for deciding whether a bump is
          # worth making. mkosi comes from the flake, so this is the only way to
          # ask the question without installing it on the host; `golden-update`
          # resolves the same date and then acts on it.
          snapshotScript = pkgs.writeShellScriptBin "agent-stack-latest-snapshot" ''
            set -euo pipefail
            export LC_ALL=C LANG=C
            cd ${./image}
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
                echo "agent delete <project>        reset, then free its config, captures and address"
                echo "agent list                    every project: address, state, overlay, image"
                echo "agent prune                   delete the goldens no overlay is pinned to"
                echo "agent capture <project> start|stop|delete"
                echo "agent capture list            every capture, and whether it runs"
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

            # Continue the latest conversation in /work, else start a new one.
            # claude --continue exits 1 at once when there is nothing to continue
            # (a first run, or the first run after a reset). The elapsed-time test
            # confines the fallback to that case: a continued session that ends
            # with an error after real work closes the pane as before, instead of
            # dropping into a fresh conversation. No single quotes in here: it is
            # spliced into a single-quoted remote command.
            continue_or_new='t=$(date +%s); claude --continue || { [ $(( $(date +%s) - t )) -lt 10 ] && exec claude; }'

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
              stop|reset|delete)
                [ $# -eq 1 ] || usage
                ssh l1 "agentctl $verb $1"
                ;;
              list)
                [ $# -eq 0 ] || usage
                ssh l1 agentctl status
                ;;
              # The prune golden-build already runs, for the goldens it had to keep:
              # once the projects pinned to one are reset or deleted, this frees it.
              prune)
                [ $# -eq 0 ] || usage
                ssh l1 agentctl prune
                ;;
              capture)
                case $# in
                  1) [ "$1" = list ] || usage; ssh l1 agentctl capture list ;;
                  2) ssh l1 "agentctl capture $1 $2" ;;
                  *) usage ;;
                esac
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
                    export CLAUDE_CONFIG_DIR=\$HOME/.config/claude-api; \
                    $continue_or_new'"
                ;;
              claude-pro)
                [ $# -eq 1 ] || usage
                ensure_running "$1"; push_creds "$1"
                # Pro tokens land in the config directory on the overlay and
                # survive stop, but not reset: log in once per reset.
                attach "$1" claude-pro \
                  "'export CLAUDE_CONFIG_DIR=\$HOME/.config/claude-pro; \
                    $continue_or_new'"
                ;;
              codex)
                [ $# -eq 1 ] || usage
                ensure_running "$1"; push_creds "$1"
                require_var "$1" OPENAI_API_KEY
                # CODEX_HOME on the overlay, alongside the other agents' config
                # directories, so it survives stop and is discarded by reset.
                # Codex requires the directory to exist before it will start.
                # resume --last reopens the latest session started in /work, and
                # starts a new one by itself when there is none, so it needs no
                # fallback of its own.
                attach "$1" codex \
                  "'set -a; . /run/creds/env; set +a; \
                    export CODEX_HOME=\$HOME/.config/codex; \
                    mkdir -p \$CODEX_HOME; codex resume --last'"
                ;;
              opencode)
                [ $# -eq 1 ] || usage
                ensure_running "$1"; push_creds "$1"
                # *Every* configured key, not one: opencode offers the models from
                # its own subscription through OPENCODE_API_KEY and direct
                # Anthropic access through ANTHROPIC_API_KEY, and lists both at
                # once. Through the environment rather than `opencode auth login`,
                # which writes to auth.json on the overlay where it survives stop.
                # --continue only when there is a session to continue: with none,
                # opencode still starts, but shows a server error before falling
                # back to its start screen. `session list` prints nothing when the
                # project has no session; if it fails, the plain start is taken.
                attach "$1" opencode \
                  "'set -a; . /run/creds/env; set +a; \
                    if [ -n \"\$(opencode session list -n 1 2>/dev/null)\" ]; \
                    then exec opencode --continue; else exec opencode; fi'"
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

            pin_virtiofsd_wrapper
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
            pin_virtiofsd_wrapper
            echo "==> redefining domain $DOMAIN"
            virsh define "$DOMAIN_XML" >/dev/null
            virsh start "$DOMAIN" >/dev/null
            echo "==> $DOMAIN started on a fresh system image; /data untouched"
          '';
        in
        {
          # The settings as evaluated, defaults included:
          #   nix eval .#site.timezone
          inherit site;


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
            ssh-config = sshConfigScript;
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
            ssh-config = {
              type = "app";
              program = "${sshConfigScript}/bin/agent-stack-ssh-config";
            };
          };
        };
    in
    {
      lib = { inherit mkStack; };

      # nix flake init -t github:mclbn/agent-stack
      templates.default = {
        path = ./template;
        description = "A site folder for agent-stack: flake.nix, and your site.nix";
        welcomeText = ''
          Created flake.nix (leave it as it is) and site.nix (yours).

          Next: replace the three CHANGEME values in site.nix, as the README's
          Quickstart describes.
        '';
      };

      checks.${system} = {
        # Evaluates everything and builds nothing, with placeholder values that
        # pass the checks: `nix flake check` catches a broken option or script
        # without a site of its own.
        eval =
          let
            stack = mkStack {
              modules = [
                {
                  exportRoot = "/home/check/agent-work";
                  dotfilesRoot = "/home/check/agent-dotfiles";
                  operatorSshKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIcheck check";
                }
              ];
            };
            drvs = [
              stack.nixosConfigurations.agentvm.config.system.build.toplevel
            ]
            ++ builtins.attrValues stack.packages.${system};
          in
          pkgs.writeText "agent-stack-eval" (
            lib.concatMapStringsSep "\n" (d: builtins.unsafeDiscardStringContext d.drvPath) drvs
          );

        # template/site.nix lists every setting, commented out at its default.
        # Uncommenting all of them must define every setting and change none:
        # a setting added to site/options.nix without its line in the template,
        # or a line whose value has drifted from the default, fails here.
        template =
          let
            text = builtins.replaceStrings [ "CHANGEME" ] [ "check" ] (
              builtins.readFile ./template/site.nix
            );
            # A commented-out setting is `# name = value`, a quoted list element
            # or a closing bracket; the template's prose never takes those forms.
            uncomment =
              line:
              let
                m = builtins.match "( *)# ( *([a-zA-Z][a-zA-Z0-9_.]* = .*|\".*\"|[]}];?))" line;
              in
              if m == null then line else builtins.elemAt m 0 + builtins.elemAt m 1;
            everything = lib.concatMapStringsSep "\n" uncomment (lib.splitString "\n" text);
            eval =
              t:
              lib.evalModules {
                modules = [
                  ./site/options.nix
                  (import (builtins.toFile "site.nix" t))
                ];
              };
            asIs = eval text;
            full = eval everything;
            # The credential entries in the template are an example, not a
            # default: there are none by default.
            comparable =
              c:
              builtins.unsafeDiscardStringContext (
                builtins.toJSON (
                  removeAttrs c [ "_module" ]
                  // {
                    credentials = removeAttrs c.credentials [ "entries" ];
                    guest = removeAttrs c.guest [ "timezone" ];
                  }
                )
              );
            missing = builtins.filter (
              o: (o.visible or true) != false && lib.head o.loc != "_module" && o.highestPrio >= 1500
            ) (lib.collect lib.isOption full.options);
          in
          assert lib.assertMsg (missing == [ ])
            "template/site.nix has no line for: ${lib.concatMapStringsSep ", " (o: lib.showOption o.loc) missing}";
          assert lib.assertMsg (comparable full.config == comparable asIs.config)
            "template/site.nix: a commented-out value differs from its default in site/options.nix";
          pkgs.writeText "agent-stack-template-check" "ok";
      };

      formatter.${system} = pkgs.nixfmt-tree;
    };
}
