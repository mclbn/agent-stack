# L1 — logging and retention.
#
# Raw text files on the persistent data disk. No reporting tools, no shipping,
# no aggregation: read with `ssh l1` and grep. This is the visibility half of
# phase 1, and it is only worth anything if it survives — which means /data,
# not the system disk that every deploy replaces.
{
  config,
  lib,
  pkgs,
  site,
  ...
}:

{
  # ------------------------------------------------------------ journald ---
  # Per-sandbox unit events, QEMU, agentctl. Moved off the system disk: rule 1
  # says nothing that would be missed is stored there, and until now the
  # journal contradicted it on every deploy.
  #
  # The directory has to exist before journald starts, and tmpfiles runs too
  # late, so the bind mount carries it. journald then finds a real directory on
  # /data and switches to persistent storage on its own.
  fileSystems."/var/log/journal" = {
    device = "/data/logs/journal";
    # "none" is how a bind mount is spelled here: there is no filesystem to
    # name, but the option is not optional.
    fsType = "none";
    options = [
      "bind"
      "nofail"
      "x-systemd.requires-mounts-for=/data"
    ];
    # Orders this mount after /data, which is what actually carries it.
    depends = [ "/data" ];
  };

  systemd.services.systemd-journald = {
    after = [ "data.mount" ];
    requires = [ "data.mount" ];
  };

  services.journald.extraConfig = lib.mkForce ''
    Storage=persistent
    SystemMaxUse=${site.logging.journalMaxUse}
    MaxRetentionSec=${site.logging.journalRetention}
  '';

  # --------------------------------------------------------------- squid ---
  # Squid's own logs, not the journal: they are the per-request record the
  # phase-2 allow-lists will be written from, and grep over a month of text is
  # the tool for that.
  systemd.tmpfiles.rules = [
    "d /data/logs 0755 root root -"
    "d /data/logs/journal 0755 root root -"
    "d /data/logs/squid 0750 squid squid -"
    "d /data/logs/pcap 0755 root root -"
    # unbound runs unprivileged and /data/logs is root-owned, so it cannot
    # create its own log file. Pre-create it with the right owner.
    "f /data/logs/unbound.log 0640 unbound unbound -"
    # squid's preStart does mkdir -p then chown, both of which follow this
    # symlink without complaint.
    "L+ /var/log/squid - - - - /data/logs/squid"
  ];

  # ------------------------------------------------------------- unbound ---
  # Who resolved what. Port 53 only, so it is a floor rather than a census:
  # DoT and DoH are ordinary permitted egress and appear as a flow or a Squid
  # entry instead.
  services.unbound.settings.server = {
    logfile = "/data/logs/unbound.log";
    log-time-ascii = true;
    use-syslog = false;
  };

  # ProtectSystem=strict in the unbound unit means the log path has to be
  # allowed explicitly. systemd list options concatenate across modules, so
  # this appends to the module's own entry rather than replacing it.
  systemd.services.unbound.serviceConfig.ReadWritePaths = [ "/data/logs" ];

  # ---------------------------------------------------------- flow log -----
  # The kernel's nftables log statements — `flow ` for permitted connections,
  # `segment-deny ` for refused ones — pulled out of the journal into their own
  # file. Reading the inventory should not mean wading through kernel messages
  # about XSAVE features.
  systemd.services.agent-flowlog = {
    description = "Flow and segment-deny lines to their own file";
    after = [
      "data.mount"
      "systemd-journald.service"
    ];
    requires = [ "data.mount" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "simple";
      Restart = "always";
      RestartSec = 5;
      ExecStart = pkgs.writeShellScript "agent-flowlog" ''
        set -euo pipefail
        install -d -m 0755 /data/logs
        # --follow from the current boot, so a restart does not rewrite
        # history; logrotate owns the file's size.
        exec ${pkgs.systemd}/bin/journalctl --dmesg --follow --no-pager \
             --output=short-iso \
          | ${pkgs.gnugrep}/bin/grep --line-buffered -E 'flow |segment-deny ' \
          >> /data/logs/flow.log
      '';
    };
  };

  # ------------------------------------------------------------ rotation ---
  # Size *and* age: age keeps a quiet month readable, size stops a busy day
  # from filling the disk before the daily rotation comes round.
  # The timer, not just the frequency. `maxsize` is only evaluated when
  # logrotate runs, so with the stock daily timer a busy day could reach far
  # past it before anything trimmed. Hourly checks keep the size cap
  # meaningful; `frequency = daily` still governs how often a quiet log turns
  # over, so this does not multiply the number of rotations.
  systemd.timers.logrotate.timerConfig.OnCalendar = lib.mkForce "hourly";

  services.logrotate = {
    enable = true;
    settings = {
      header = {
        # Two different directives with confusingly similar names: frequency
        # is how often, rotate is how many are kept.
        frequency = site.logging.rotate;
        rotate = site.logging.keep;
        maxsize = site.logging.maxSize;
        compress = true;
        delaycompress = true;
        notifempty = true;
        missingok = true;
        copytruncate = true;
      };

      # copytruncate throughout: squid, unbound and the flow reader all hold
      # their file open, and none of them reopens on a signal we could send
      # from here without restarting the service and dropping traffic.
      "/data/logs/squid/*.log" = {
        su = "squid squid";
        create = "0640 squid squid";
      };

      "/data/logs/unbound.log" = {
        su = "unbound unbound";
        create = "0640 unbound unbound";
      };

      "/data/logs/flow.log" = {
        create = "0640 root root";
      };
    };
  };
}
