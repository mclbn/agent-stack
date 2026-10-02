# L1 — sandbox lifecycle.
#
# agentctl is the only writer of /data/state, and the only thing that creates
# overlays, taps, sockets and VMs. Everything it derives comes from one
# monotonic index per project.
#
# Network policy lives in network.nix. This file owns lifecycle only: what
# exists, what is running, and who owns it.
{
  config,
  lib,
  pkgs,
  site,
  ...
}:

let
  binPath = lib.makeBinPath [
    pkgs.coreutils
    # cmp, for write_zone. Not in coreutils, and this script runs with an
    # explicit PATH — a missing binary here fails silently as a false branch.
    pkgs.diffutils
    pkgs.util-linux
    pkgs.iproute2
    pkgs.jq
    pkgs.gawk
    pkgs.gnugrep
    pkgs.gnused
    pkgs.qemu_kvm
    pkgs.virtiofsd
    pkgs.socat
    pkgs.systemd
  ];

  # Builds and execs the QEMU command line for one project. Kept out of the
  # unit file so the unit stays trivial and this stays readable.
  vmRun = pkgs.writeShellScript "agent-vm-run" ''
    set -euo pipefail
    export PATH=${binPath}

    project=$1
    rec=$(jq -c --arg p "$project" 'select(.project==$p)' /data/state/alloc.jsonl | tail -1)
    [ -n "$rec" ] || { echo "no allocation for $project" >&2; exit 1; }

    index=$(echo "$rec" | jq -r .index)
    ip=$(echo "$rec" | jq -r .ip)
    uid=$(echo "$rec" | jq -r .uid)
    tap=$(echo "$rec" | jq -r .tap)
    run=/run/agent/$project
    overlay=/data/overlays/$project.qcow2

    # Locally administered MAC derived from the index, so a capture can be
    # attributed without consulting anything.
    mac=$(printf '52:54:00:00:%02x:%02x' $((index / 256)) $((index % 256)))

    # -run-with user= drops to bare numeric IDs and needs no passwd or group
    # entry, which is exactly what these runtime-allocated IDs lack. QEMU must
    # therefore start as root: it opens the overlay and the sockets first.
    #
    # virtio-rng-pci is not decoration: pacman-key --init generates a master
    # key on the first boot after every reset and blocks on the entropy pool
    # without it. No comments inside the command below — a backslash
    # continuation would swallow the rest of the line.
    exec qemu-system-x86_64 \
      -machine q35,accel=kvm,memory-backend=mem \
      -object memory-backend-memfd,id=mem,size=${toString site.sandbox.memoryMiB}M,share=on \
      -cpu host \
      -smp ${toString site.sandbox.vcpu} \
      -m ${toString site.sandbox.memoryMiB} \
      -drive file="$overlay",if=virtio,format=qcow2,discard=unmap,cache=none,aio=native \
      -chardev socket,id=fswork,path="$run/work.sock" \
      -device vhost-user-fs-pci,chardev=fswork,tag=work \
      -chardev socket,id=fsconfig,path="$run/config.sock" \
      -device vhost-user-fs-pci,chardev=fsconfig,tag=config \
      -chardev socket,id=fsdotfiles,path="$run/dotfiles.sock" \
      -device vhost-user-fs-pci,chardev=fsdotfiles,tag=dotfiles \
      -netdev tap,id=net0,ifname="$tap",script=no,downscript=no \
      -device virtio-net-pci,netdev=net0,mac="$mac" \
      -device virtio-rng-pci \
      -serial pty \
      -qmp unix:"$run/qmp.sock",server,nowait \
      -display none \
      -vga none \
      -run-with user="$uid":"$uid"
  '';

  agentctl = pkgs.writeShellScriptBin "agentctl" ''
    set -euo pipefail
    export PATH=${binPath}

    ALLOC=/data/state/alloc.jsonl
    # Records of deleted projects, moved here rather than dropped: allocate
    # still counts their indices, so an address is never handed out twice.
    DELETED=/data/state/alloc-deleted.jsonl
    LOCK=/data/state/alloc.lock
    EXPORT_ROOT=/srv/projects
    GATEWAY=${site.agents.gateway}

    die() { echo "agentctl: $*" >&2; exit 1; }

    [ "$(id -u)" -eq 0 ] || die "must run as root"

    usage() {
      {
        echo "agentctl start <project>   create if needed, then boot"
        echo "agentctl stop <project>    graceful shutdown, overlay kept"
        echo "agentctl reset <project>   stop, then delete the overlay"
        echo "agentctl delete <project>  reset, then drop its config, captures and address"
        echo "agentctl status            what exists and what is running"
        echo "agentctl prune             delete the goldens no overlay is pinned to"
        echo "agentctl capture <p> start|stop   pcap on the project's tap"
      } >&2
      exit 1
    }

    valid_name() {
      echo "$1" | grep -Eq '^[a-z0-9][a-z0-9-]{0,62}$'
    }

    # Derivations from the index. One number drives all four.
    derive() {
      index=$1
      ip=10.42.$((index / 256)).$((index % 256))
      uid=$((1000000 + index))
      gid=$uid
      tap=tap-$index
    }

    # Allocate on first use, idempotent under flock so two concurrent first
    # invocations cannot double-allocate. Only start comes here; every other
    # verb goes through lookup, so a mistyped name cannot allocate an address.
    allocate() {
      project=$1
      mkdir -p /data/state
      touch "$ALLOC" "$DELETED"
      exec 9>"$LOCK"
      flock 9

      index=$(jq -r --arg p "$project" 'select(.project==$p) | .index' "$ALLOC" | tail -1)
      if [ -z "$index" ]; then
        # Over deleted projects too, so an address in an old log line always
        # means the one project that ever held it.
        last=$(jq -s 'map(.index) | max // 1' "$ALLOC" "$DELETED")
        index=$((last + 1))
        derive "$index"
        jq -n -c --arg p "$project" --argjson i "$index" --arg ip "$ip" \
              --arg tap "$tap" --argjson uid "$uid" --arg d "$(date -I)" \
              '{project:$p,index:$i,ip:$ip,tap:$tap,uid:$uid,created:$d}' >> "$ALLOC"
        echo "allocated $project: index $index, $ip, uid $uid, $tap" >&2
      fi
      derive "$index"
      write_zone
      flock -u 9
      exec 9>&-
    }

    # An existing project's record, never a new one.
    lookup() {
      project=$1
      [ -e "$ALLOC" ] || die "no project $project"
      index=$(jq -r --arg p "$project" 'select(.project==$p) | .index' "$ALLOC" | tail -1)
      [ -n "$index" ] || die "no project $project"
      derive "$index"
    }

    # The inverse of allocate, under the same flock. Appended to the deleted
    # list before it leaves alloc.jsonl, so an interrupted delete leaves the
    # record in both rather than in neither, and running it again finishes.
    forget() {
      project=$1
      exec 9>"$LOCK"
      flock 9
      jq -c --arg p "$project" 'select(.project==$p)' "$ALLOC" >> "$DELETED"
      jq -c --arg p "$project" 'select(.project!=$p)' "$ALLOC" > "$ALLOC.new"
      mv "$ALLOC.new" "$ALLOC"
      write_zone
      flock -u 9
      exec 9>&-
    }

    # The internal zone, regenerated from alloc.jsonl whole rather than
    # appended to, so it cannot drift from the map it is derived from. Written
    # under the same flock, which is what keeps a single writer honest.
    write_zone() {
      zone=/data/state/unbound-zones.conf
      {
        echo "local-zone: \"agents.${site.internalDomain}.\" static"
        jq -r '"local-data: \"" + .project + ".agents.${site.internalDomain}. A " + .ip + "\""' "$ALLOC"
        jq -r '"local-data-ptr: \"" + .ip + " " + .project + ".agents.${site.internalDomain}.\""' "$ALLOC"
      } > "$zone.new"
      # Only when it actually changed. allocate() runs on every start, and a
      # reload discards the whole DNS cache — so unconditionally reloading
      # meant every agent command threw away every cached answer and sent the
      # next lookup back out to the internet.
      if cmp -s "$zone.new" "$zone" 2>/dev/null; then
        rm -f "$zone.new"
      else
        mv "$zone.new" "$zone"
        systemctl reload-or-restart unbound >/dev/null 2>&1 || true
      fi
    }

    # The generated per-project configuration. Written by root on L1, mounted
    # read-only, so an agent can use it but never rewrite it.
    write_config() {
      project=$1
      dir=/data/config/$project
      install -d -m 0755 "$dir"
      printf 'ADDRESS=%s\nHOSTNAME=%s\nPROFILE=default\n' "$ip" "$project" \
        | install -m 0444 /dev/stdin "$dir/identity"
      install -m 0444 ${
        pkgs.writeText "authorized_keys" (site.operatorSshKey + "\n")
      } "$dir/authorized_keys"

      # The sandbox-local Emacs fragment, loaded from init.el in the dotfiles
      # with `(load "/etc/agent-config/local.el" t)`. Deliberately small: it
      # carries what is stack-specific and has a real failure mode behind it,
      # and nothing else. Anything that only expresses a preference belongs in
      # the dotfiles, where the operator can see it.
      install -m 0444 ${
        pkgs.writeText "local.el" ''
          ;; Generated by agentctl on L1. Read-only in the sandbox.

          ;; Where the credentials are. Without this, auth-source looks in
          ;; ~/.authinfo and ~/.netrc, finds nothing, and gptel has no key:
          ;; this path is the whole reason the file exists, and a portable
          ;; configuration has no business knowing it.
          (setq auth-sources '("/run/creds/authinfo"))

          ;; Custom must not write into init.el. It is a real writable file on
          ;; the overlay now — seeded from the dotfiles at creation — so a
          ;; `M-x customize` write would succeed and quietly append generated
          ;; forms to configuration you maintain on L0, where the change is
          ;; invisible and `agent reset` silently discards it. Keeping custom's
          ;; output in state is the point, not working around a read-only file.
          (setq custom-file "~/.local/state/emacs/custom.el")

          ;; package-user-dir and the eln cache are deliberately *not* set:
          ;; ~/.config/emacs/ is an ordinary writable directory on the overlay,
          ;; so the defaults already work. startup-redirect-eln-cache would
          ;; also have been a no-op: it only takes effect from early-init.el.
        ''
      } "$dir/local.el"

      # The MCP endpoints, in each agent's own configuration format. The
      # addresses are stable — a service keeps its name and its port — so this
      # is the same content for every project; it is written per project only
      # because the config mount is per project.
      install -m 0444 ${
        pkgs.writeText "mcp.json" (
          builtins.toJSON {
            mcpServers = lib.mapAttrs (_: svc: {
              type = "http";
              url = svc.endpoint;
            }) (lib.filterAttrs (_: svc: svc.enable) site.serviceStacks);
          }
        )
      } "$dir/mcp.json"
    }

    create_overlay() {
      project=$1
      overlay=/data/overlays/$project.qcow2
      [ -e "$overlay" ] && return 0
      golden=$(readlink -f /data/images/current)
      [ -n "$golden" ] && [ -e "$golden" ] || die "no golden image; run golden-build on L0"
      # The resolved dated path, never the symlink: an overlay recorded against
      # the symlink silently reads a different base once it is repointed.
      qemu-img create -f qcow2 -F qcow2 -b "$golden" "$overlay" >/dev/null
      chown "$uid":"$gid" "$overlay"
      chmod 0600 "$overlay"
      echo "overlay $overlay backed by $golden" >&2
    }

    # 0700 under a 0711 parent: a project uid can enter its own directory
    # without listing the others.
    create_rundir() {
      project=$1
      install -d -m 0711 /run/agent
      install -d -m 0700 -o "$uid" -g "$gid" /run/agent/$project
    }

    start_virtiofsd() {
      project=$1
      run=/run/agent/$project
      for pair in "work:$EXPORT_ROOT/$project" "config:/data/config/$project" \
                  "dotfiles:/srv/dotfiles"; do
        tag=$(echo "$pair" | cut -d: -f1)
        dir=$(echo "$pair" | cut -d: -f2)
        unit=agent-fs-$project-$tag
        systemctl is-active --quiet "$unit" && continue
        install -d -m 0755 "$dir"
        # virtiofsd runs as root: creating a file owned by uid 1000 needs
        # CAP_CHOWN, which is what makes uid 1000 end to end literally true.
        systemd-run --unit="$unit" --collect \
          ${pkgs.virtiofsd}/bin/virtiofsd \
            --socket-path="$run/$tag.sock" \
            --shared-dir="$dir" \
            --inode-file-handles=never \
            --sandbox=namespace >/dev/null
        # QEMU runs as the project uid and virtiofsd as root, so the socket has
        # to be handed over once it exists. Waiting beats an ExecStartPost that
        # can fire before the socket is created.
        for _ in $(seq 1 50); do
          [ -S "$run/$tag.sock" ] && break
          sleep 0.1
        done
        [ -S "$run/$tag.sock" ] || die "virtiofsd did not create $run/$tag.sock"
        chown "$uid":"$gid" "$run/$tag.sock"
      done
    }

    stop_virtiofsd() {
      project=$1
      for tag in work config dotfiles; do
        systemctl stop "agent-fs-$project-$tag" 2>/dev/null || true
      done
    }

    # Point to point: no bridge, so sandboxes share no layer-2 segment. L1
    # holds the same gateway address on every tap; the guest has a /32 and an
    # on-link default route.
    create_tap() {
      ip link show "$tap" >/dev/null 2>&1 && return 0
      ip tuntap add dev "$tap" mode tap user "$uid"
      ip link set "$tap" up
      ip addr add "$GATEWAY"/32 dev "$tap"
      ip route replace "$ip"/32 dev "$tap"
    }

    delete_tap() {
      ip link show "$tap" >/dev/null 2>&1 || return 0
      ip link delete "$tap"
    }

    # Without this the failure is an OOM kill, which takes a running agent
    # session and leaves a hard-cut overlay behind.
    check_memory() {
      want=${toString site.sandbox.memoryMiB}
      avail=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo)
      [ "$avail" -ge $((want + 256)) ] \
        || die "only $avail MiB available on L1, $want MiB needed"
    }

    cmd_start() {
      project=$1
      valid_name "$project" || die "invalid project name: $project"
      [ -d "$EXPORT_ROOT/$project" ] \
        || die "no workspace at $EXPORT_ROOT/$project"

      allocate "$project"
      if systemctl is-active --quiet "agent-vm@$project"; then
        echo "$project already running at $ip"
        return 0
      fi
      check_memory
      write_config "$project"
      create_overlay "$project"
      create_rundir "$project"
      start_virtiofsd "$project"
      create_tap
      systemctl start "agent-vm@$project"

      printf 'waiting for sshd'
      for _ in $(seq 1 60); do
        # socat rather than bash's /dev/tcp: this script runs with an explicit
        # PATH that has no bash in it, so `bash -c` failed silently and the
        # loop could never succeed.
        if timeout 2 socat /dev/null TCP:"$ip":22 >/dev/null 2>&1; then
          printf '\n%s is up at %s (uid %s, %s)\n' "$project" "$ip" "$uid" "$tap"
          return 0
        fi
        printf '.'
        sleep 1
      done
      printf '\n'
      die "$project booted but sshd did not answer; journalctl -u agent-vm@$project"
    }

    cmd_stop() {
      project=$1
      valid_name "$project" || die "invalid project name: $project"
      lookup "$project"
      systemctl stop "agent-vm@$project" 2>/dev/null || true
      stop_virtiofsd "$project"
      delete_tap
      echo "$project stopped"
    }

    cmd_reset() {
      project=$1
      cmd_stop "$project"
      # Deleting the backing file of a running QEMU is not a failure mode worth
      # leaving open, so refuse if the stop did not complete.
      systemctl is-active --quiet "agent-vm@$project" \
        && die "$project is still running"
      rm -f "/data/overlays/$project.qcow2"
      echo "$project reset; next start is identical to the golden"
    }

    # Everything reset discards, then what reset keeps: the generated config,
    # the runtime directory, the captures and the allocation. The workspace on
    # L0 is never touched, and the shared logs are left to rotation.
    cmd_delete() {
      project=$1
      valid_name "$project" || die "invalid project name: $project"
      lookup "$project"
      # Before the stop, which deletes the tap tcpdump is reading.
      systemctl stop "agent-capture@$project" 2>/dev/null || true
      cmd_stop "$project"
      # As in reset: never delete the backing file of a running QEMU.
      systemctl is-active --quiet "agent-vm@$project" \
        && die "$project is still running"
      rm -f "/data/overlays/$project.qcow2"
      rm -rf "/data/config/$project" "/run/agent/$project"
      # The stamp spelled out rather than $project-*, which would also take
      # the captures of foo-bar when deleting foo.
      rm -f "/data/logs/pcap/$project"-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9].pcap*
      # A failed instance outlives its project and keeps the carrier degraded
      # in `systemctl is-system-running`. The agent-fs units are --collect and
      # clean up after themselves.
      for unit in "agent-vm@$project" "agent-capture@$project"; do
        systemctl reset-failed "$unit" 2>/dev/null || true
      done
      # Last, so that a delete interrupted before this point still finds the
      # project when it is run again.
      forget "$project"
      echo "$project deleted; address $ip will not be reused, workspace left in place"
    }

        cmd_capture() {
      project=$1
      action=$2
      valid_name "$project" || die "invalid project name: $project"
      lookup "$project"
      case "$action" in
        start) systemctl start "agent-capture@$project"
               echo "capturing $tap to /data/logs/pcap/$project-*.pcap" ;;
        stop) systemctl stop "agent-capture@$project"
              echo "capture stopped" ;;
        *) die "capture takes start or stop" ;;
      esac
    }

    # The project name stays the first column: golden-update reads it.
    # An old golden is deleted only once no overlay is pinned to it: deleting
    # it would strand those projects, running ones included, since QEMU holds
    # the file open. Run by golden-build after it repoints current, and by
    # golden-update after its reset.
    cmd_prune() {
      current=$(readlink -f /data/images/current || true)
      [ -n "$current" ] && [ -e "$current" ] || die "no current golden; nothing to keep"
      declare -A users=()
      for o in /data/overlays/*.qcow2; do
        [ -e "$o" ] || continue
        # -U: a running QEMU holds the lock on its overlay. A failure here
        # aborts the prune: an unreadable overlay must not free its golden.
        b=$(qemu-img info -U --output=json "$o" | jq -r '."backing-filename" // empty')
        [ -n "$b" ] && users[$b]+=" $(basename "$o" .qcow2)"
      done
      for g in /data/images/golden/arch-*.qcow2; do
        [ -e "$g" ] && [ "$g" != "$current" ] || continue
        if [ -n "''${users[$g]:-}" ]; then
          echo "kept $(basename "$g") (''${users[$g]# })"
        else
          rm -f "$g"
          echo "pruned $(basename "$g")"
        fi
      done
    }

    cmd_status() {
      # A missing workspace is only reported when the export is mounted. The
      # mount is nofail, and without it every project would look abandoned.
      mounted=
      mountpoint -q "$EXPORT_ROOT" && mounted=1
      current=$(readlink -f /data/images/current || true)
      printf '%-20s %-12s %-10s %-8s %-22s %s\n' \
        PROJECT ADDRESS STATE OVERLAY IMAGE WORKSPACE
      jq -r '.project + " " + .ip' "$ALLOC" 2>/dev/null | while read -r p a; do
        if systemctl is-active --quiet "agent-vm@$p"; then state=running
        elif [ -e "/data/overlays/$p.qcow2" ]; then state=stopped
        else state=reset
        fi
        size=$(du -h "/data/overlays/$p.qcow2" 2>/dev/null | cut -f1 || echo -)
        # The golden the overlay is pinned to, read from the overlay itself as
        # golden-build's prune does; -U because a running QEMU holds the lock.
        image=-
        if [ -e "/data/overlays/$p.qcow2" ]; then
          base=$(qemu-img info -U --output=json "/data/overlays/$p.qcow2" 2>/dev/null \
                 | jq -r '."backing-filename" // empty' || true)
          image=$(basename "$base" .qcow2)
          image=''${image#arch-}
          if [ -z "$base" ] || [ ! -e "$base" ]; then image=missing
          elif [ "$base" != "$current" ]; then image="$image (old)"
          fi
        fi
        if [ -z "$mounted" ]; then workspace="?"
        elif [ -d "$EXPORT_ROOT/$p" ]; then workspace=
        else workspace=missing
        fi
        printf '%-20s %-12s %-10s %-8s %-22s %s\n' \
          "$p" "$a" "$state" "$size" "$image" "$workspace"
      done
    }

    [ $# -ge 1 ] || usage
    verb=$1
    shift
    case "$verb" in
      start) [ $# -eq 1 ] || usage; cmd_start "$1" ;;
      capture) [ $# -eq 2 ] || usage; cmd_capture "$1" "$2" ;;
      stop) [ $# -eq 1 ] || usage; cmd_stop "$1" ;;
      reset) [ $# -eq 1 ] || usage; cmd_reset "$1" ;;
      delete) [ $# -eq 1 ] || usage; cmd_delete "$1" ;;
      status) cmd_status ;;
      prune) [ $# -eq 0 ] || usage; cmd_prune ;;
      *) usage ;;
    esac
  '';
in
{
  environment.systemPackages = [
    agentctl
    pkgs.virtiofsd
    pkgs.socat
  ];

  # Capture is its own template unit so `agent capture` is a thin wrapper over
  # systemctl with no state to keep in step. A size-capped ring, because an
  # unbounded capture on a busy tap fills the data disk.
  systemd.services."agent-capture@" = {
    description = "Packet capture on %i's tap";
    after = [ "data.mount" ];
    requires = [ "data.mount" ];
    serviceConfig = {
      Type = "simple";
      ExecStart = pkgs.writeShellScript "agent-capture" ''
        set -euo pipefail
        export PATH=${binPath}
        project=$1
        tap=$(jq -r --arg p "$project" 'select(.project==$p) | .tap' \
              /data/state/alloc.jsonl | tail -1)
        [ -n "$tap" ] || { echo "no allocation for $project" >&2; exit 1; }
        # The timestamp is expanded here, not by tcpdump: it only honours
        # strftime escapes in -w when -G is given, and with -C/-W it writes the
        # format string literally. tcpdump appends the ring number itself, so
        # the files come out as <project>-<stamp>.pcap0 .. .pcap4.
        stamp=$(date +%Y%m%d-%H%M%S)
        exec ${pkgs.tcpdump}/bin/tcpdump -i "$tap" -n -s 0 \
          -C 100 -W 5 -w "/data/logs/pcap/$project-$stamp.pcap" -z gzip
      '' + " %i";
    };
  };

  systemd.services."agent-vm@" = {
    description = "Agent sandbox %i";
    after = [ "data.mount" ];
    requires = [ "data.mount" ];
    serviceConfig = {
      Type = "simple";
      ExecStart = "${vmRun} %i";
      # An ACPI power button press rather than SIGTERM. The overlay survives
      # stop and carries installed packages, Docker images and build
      # artefacts; cutting power to it as a routine operation is how that
      # layer quietly rots.
      ExecStop = pkgs.writeShellScript "agent-vm-stop" ''
        printf '%s\n%s\n' '{"execute":"qmp_capabilities"}' '{"execute":"system_powerdown"}' \
          | ${pkgs.socat}/bin/socat - UNIX-CONNECT:/run/agent/$1/qmp.sock,connect-timeout=5 \
          >/dev/null || true
      '' + " %i";
      TimeoutStopSec = 30;
    };
  };

}
