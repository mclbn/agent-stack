# L1 — the carrier VM.
#
# Slice 1: the carrier boots, is reachable over ssh from L0, has its data disk
# and sees the export root. The gateway services (unbound, squid, nftables
# policy), the image builder and agentctl arrive in later slices.
#
# Rules that hold from here on:
#   1. Nothing that would be missed is ever stored on the system disk.
#   2. The carrier is never fixed by hand-editing files over ssh.
#   3. Paths that must stay writable are on /data.
{
  config,
  lib,
  pkgs,
  modulesPath,
  site,
  ...
}:

{
  imports = [
    "${modulesPath}/profiles/qemu-guest.nix"
    "${modulesPath}/virtualisation/disk-image.nix"
    ./sandbox.nix
    ./network.nix
    ./logging.nix
    ./services.nix
  ];

  assertions = [
    {
      assertion = !(lib.hasInfix "CHANGEME" site.exportRoot);
      message = "site.nix: exportRoot still contains CHANGEME";
    }
    {
      assertion = !(lib.hasInfix "CHANGEME" site.operatorSshKey);
      message = "site.nix: operatorSshKey still contains CHANGEME";
    }
    {
      assertion = !(lib.hasInfix "CHANGEME" site.dotfilesRoot);
      message = "site.nix: dotfilesRoot still contains CHANGEME";
    }
  ];

  # ------------------------------------------------------------- image ----
  # BIOS/MBR rather than UEFI: no per-VM firmware state, nothing to orphan.
  # Produces $out/carrier.qcow2 via config.system.build.image.
  image = {
    efiSupport = false;
    format = "qcow2";
    baseName = "carrier";
  };
  virtualisation.diskSize = site.l1.systemDiskMiB;

  # -------------------------------------------------------------- boot ----
  boot.loader.timeout = 1;
  boot.kernelParams = [
    "console=tty0"
    "console=ttyS0,115200"
  ];
  boot.kernelModules = [ "virtiofs" ];
  # Nothing here needs to survive; the system disk is replaceable by design.
  boot.tmp.cleanOnBoot = true;

  # --------------------------------------------------------- filesystems --
  # /data — the persistent tier. btrfs, created on first boot if the raw disk
  # is empty. Never reformatted once a filesystem is present.
  fileSystems."/data" = {
    device = "/dev/disk/by-label/agentdata";
    fsType = "btrfs";
    options = [
      "compress=zstd"
      "noatime"
      "nofail"
      "x-systemd.device-timeout=15s"
    ];
  };

  systemd.services.data-disk-init = {
    description = "Create the btrfs filesystem on the L1 data disk if absent";
    # Runs in early boot, before the mount, so default dependencies (which
    # order services after local-fs.target) would deadlock.
    unitConfig.DefaultDependencies = false;
    after = [ "local-fs-pre.target" ];
    before = [
      "data.mount"
      "local-fs.target"
      "shutdown.target"
    ];
    conflicts = [ "shutdown.target" ];
    requiredBy = [ "data.mount" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    path = [
      pkgs.util-linux
      pkgs.btrfs-progs
    ];
    script = ''
      for _ in $(seq 1 30); do
        [ -b /dev/vdb ] && break
        sleep 0.5
      done
      if [ ! -b /dev/vdb ]; then
        echo "no /dev/vdb: no data disk attached, skipping" >&2
        exit 0
      fi
      existing=$(blkid -o value -s TYPE /dev/vdb || true)
      if [ -z "$existing" ]; then
        echo "formatting /dev/vdb as btrfs, label agentdata"
        mkfs.btrfs -L agentdata /dev/vdb
      else
        echo "/dev/vdb already holds a '$existing' filesystem, leaving it alone"
      fi
    '';
  };

  systemd.services.data-layout = {
    description = "Create the /data directory layout";
    after = [ "data.mount" ];
    requires = [ "data.mount" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    path = [ pkgs.e2fsprogs ]; # chattr
    script = ''
      install -d -m 0755 /data/images /data/images/golden /data/state \
                         /data/config /data/logs /data/logs/pcap
      install -d -m 0700 /data/state/ssh
      # Overlays are per-project and mode 0600; 0711 lets a project uid open
      # its own file by name without listing the others.
      install -d -m 0711 /data/overlays
      # qcow2 random writes on btrfs: nodatacow, inherited by new files.
      chattr +C /data/images /data/images/golden /data/overlays 2>/dev/null || true
    '';
  };

  # The dotfiles directory from L0, re-exported read-only into every sandbox.
  fileSystems."/srv/dotfiles" = {
    device = "dotfiles"; # virtiofs tag, set in the domain XML
    fsType = "virtiofs";
    options = [ "nofail" ];
  };

  # The export root, re-exported per project into sandboxes in a later slice.
  # nofail: a missing virtiofs tag must not stop the carrier from booting.
  fileSystems."/srv/projects" = {
    device = "projects"; # virtiofs tag, set in the domain XML
    fsType = "virtiofs";
    options = [ "nofail" ];
  };

  # ----------------------------------------------------------- network ----
  networking.hostName = "agent-l1";
  networking.useDHCP = false;
  networking.useNetworkd = true;

  systemd.network.networks."10-wan" = {
    matchConfig.Name = "en*";
    address = [ "${site.wan.address}/${toString site.wan.prefixLength}" ];
    routes = [ { Gateway = site.wan.gateway; } ];
    networkConfig = {
      IPv6AcceptRA = false;
      LinkLocalAddressing = "no";
    };
    linkConfig.RequiredForOnline = "routable";
  };

  # unbound owns the resolver; see network.nix.
  services.resolved.enable = false;
  networking.resolvconf.enable = true;
  networking.nftables.enable = true;

  # ------------------------------------------------------------- access ---
  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "prohibit-password";
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
    };
    # On /data, not the system disk: the system disk is replaced on every image
    # swap, and regenerated host keys would make L0 reject the carrier as an
    # impostor after each one. This is L1's own identity rather than a
    # credential for reaching anything, and rule 3 is where it belongs.
    hostKeys = [
      {
        path = "/data/state/ssh/ssh_host_ed25519_key";
        type = "ed25519";
      }
    ];
  };

  # Both the generator and the daemon must wait for the key store to exist.
  systemd.services.sshd-keygen = {
    after = [ "data.mount" ];
    requires = [ "data.mount" ];
  };
  systemd.services.sshd = {
    after = [ "data.mount" ];
    requires = [ "data.mount" ];
  };
  # One keypair, held only on L0. No forced command and no restrict: that would
  # break ProxyJump, the credential push and vncviewer -via.
  users.users.root.openssh.authorizedKeys.keys = [ site.operatorSshKey ];

  # Clean `virsh shutdown`.
  services.qemuGuest.enable = true;

  # `virsh console agent-l1` works through systemd-getty-generator, which
  # instantiates serial-getty@ttyS0 from the console= kernel parameter above.
  # Defining that unit here would shadow systemd's own template, so it isn't.

  # --------------------------------------------------------------- time ---
  # L1 takes the laptop's suspend jump itself and serves time downstream from
  # slice 4, so it steps large offsets rather than slewing them.
  time.timeZone = "UTC";
  services.chrony = {
    enable = true;
    servers = [
      "0.pool.ntp.org"
      "1.pool.ntp.org"
      "2.pool.ntp.org"
      "3.pool.ntp.org"
    ];
    # The RTC is handled by the module (rtcfile, rtcautotrim), so only the
    # stepping policy belongs here: laptop suspend produces jumps large enough
    # to break TLS, and they must be stepped rather than slewed.
    extraConfig = ''
      makestep 1.0 -1
    '';
  };

  # ----------------------------------------------------------- packages ---
  # The golden image is built on L0, not here: mkosi needs an FHS host, and
  # nesting its sandbox inside one on NixOS made every pacman post-transaction
  # hook segfault. L1 keeps only what is needed to boot and inspect a golden.
  environment.systemPackages = with pkgs; [
    btrfs-progs
    dnsutils
    file
    git
    htop
    jq
    qemu_kvm
    rsync
    tcpdump
    tmux
    tree

    (writeShellScriptBin "golden-boot" ''
      set -euo pipefail
      # Boot the golden on a throwaway overlay, serial on this terminal.
      # Bring-up only: agentctl replaces this in slice 3.
      golden=$(readlink -f /data/images/current)
      [ -n "$golden" ] || { echo "no golden image" >&2; exit 1; }
      tmp=$(mktemp -u /tmp/golden-test-XXXX.qcow2)
      ${pkgs.qemu_kvm}/bin/qemu-img create -f qcow2 -F qcow2 -b "$golden" "$tmp" >/dev/null
      trap 'rm -f "$tmp"' EXIT
      echo "==> booting $golden (ctrl-a x to quit)"
      ${pkgs.qemu_kvm}/bin/qemu-system-x86_64 \
        -machine q35,accel=kvm -cpu host -m 2048 -smp 2 \
        -drive file="$tmp",if=virtio,format=qcow2 \
        -nographic -serial mon:stdio -display none \
        -net none
    '')
  ];

  documentation.enable = false;
  documentation.nixos.enable = false;

  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  system.stateVersion = "26.05";
}
