# L1 — network policy (phase 1).
#
# Egress is allow-by-default and everything is logged: the purpose of phase 1
# is to accumulate a real inventory of what the agents contact, from which
# allow-lists are written later. What is enforced from the start is the shape
# of the topology and the visibility of what passes through it.
#
# Default-deny describes traffic *between segments* — agents to services, to
# L1, to L0, to each other — not outbound traffic to the internet, which is
# forwarded and logged.
{
  config,
  lib,
  pkgs,
  site,
  ...
}:

let
  squidHttp = 3129;
  squidHttps = 3130;
  squidCert = "/data/state/squid/squid.pem";

  # How unbound reaches the public namespace; the choice and the reasoning
  # both live under dns.resolver in site.nix. Empty means recurse.
  forwarders =
    if builtins.isList site.dns.resolver then
      site.dns.resolver
    else if site.dns.resolver == "gateway" then
      [ site.wan.gateway ]
    else
      [ ];

  # All, not any: a mixed list would silently send some queries in clear, and
  # a forwarder that can be intercepted defeats the reason for choosing one.
  forwardOverTls = forwarders != [ ] && lib.all (a: lib.hasInfix "@853" a) forwarders;
in
{
  # ------------------------------------------------------------- unbound ---
  # DNSSEC-validating, and by default recursive rather than forwarding: at the
  # primary site the host has direct internet access, so nothing but the root
  # anchor has to be trusted. Where that is not true — any network that
  # redirects outbound port 53 to its own resolver — dns.resolver in site.nix
  # switches this to forwarding without touching anything here. Validation
  # stays on L1 in both modes.
  #
  # Also the authority for internal names, through a zone file that agentctl
  # writes under the same flock as alloc.jsonl, so the two cannot drift.
  assertions = [
    {
      assertion =
        builtins.isList site.dns.resolver || builtins.elem site.dns.resolver [ "recursive" "gateway" ];
      message = ''site.nix: dns.resolver must be "recursive", "gateway", or a list of forward addresses'';
    }
  ];

  # A forward-zone for "." replaces the iterator's starting point, nothing
  # else: local-zone and local-data are still consulted first, so the internal
  # names never leave L1.
  services.unbound.settings.forward-zone = lib.mkIf (forwarders != [ ]) [
    (
      {
        name = ".";
        forward-addr = forwarders;
      }
      # tls-cert-bundle is set by the module, so the upstream is authenticated
      # rather than merely encrypted to.
      // lib.optionalAttrs forwardOverTls { forward-tls-upstream = true; }
    )
  ];

  services.unbound = {
    enable = true;
    resolveLocalQueries = true;
    settings.server = {
      interface = [
        "127.0.0.1"
        site.agents.gateway
      ];
      access-control = [
        "127.0.0.0/8 allow"
        "${site.agents.cidr} allow"
        "0.0.0.0/0 refuse"
      ];
      do-ip6 = "no";
      # Forcing port 53 here is a visibility measure, not a containment one:
      # DoT on 853 and DoH on 443 are ordinary permitted egress in phase 1, so
      # this log is a floor rather than a census.
      # The query log itself is configured in logging.nix, which sends it to
      # a file on /data rather than the journal.
      log-queries = true;
      verbosity = 1;
      include = "/data/state/unbound-zones.conf";
      # Names an upstream forwarder is authoritative for that the public root
      # says do not exist. Empty unless site.nix says otherwise.
      domain-insecure = site.dns.insecureDomains;
    };
  };

  # L1 resolves through its own unbound rather than the libvirt resolver.
  networking.nameservers = lib.mkForce [ "127.0.0.1" ];

  systemd.services.unbound = {
    after = [ "data.mount" ];
    requires = [ "data.mount" ];
    # The include is a hard error if absent, and it is absent until the first
    # project is allocated.
    preStart = ''
      ${pkgs.coreutils}/bin/install -d -m 0755 /data/state
      [ -e /data/state/unbound-zones.conf ] \
        || ${pkgs.coreutils}/bin/install -m 0644 /dev/null /data/state/unbound-zones.conf
    '';
  };

  # --------------------------------------------------------------- squid ---
  # Intercept mode, recovering the original destination through
  # SO_ORIGINAL_DST. Nothing is configured in the sandbox: no proxy variables,
  # no CA, no client changes.
  systemd.services.squid-cert = {
    description = "Self-signed keypair for Squid's https_port";
    before = [ "squid.service" ];
    requiredBy = [ "squid.service" ];
    after = [ "data.mount" ];
    requires = [ "data.mount" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      # https_port refuses to start without cert= even though every connection
      # is spliced. Because nothing is ever bumped, this certificate is never
      # presented to any client and nothing validates it: its compromise means
      # nothing.
      install -d -m 0750 -o squid -g squid /data/state/squid
      [ -s ${squidCert} ] && exit 0
      ${pkgs.openssl}/bin/openssl req -x509 -newkey rsa:2048 -nodes \
        -days 3650 -subj "/CN=agent-l1-squid" \
        -keyout /tmp/squid.key -out /tmp/squid.crt 2>/dev/null
      cat /tmp/squid.key /tmp/squid.crt > ${squidCert}
      rm -f /tmp/squid.key /tmp/squid.crt
      chown squid:squid ${squidCert}
      chmod 0400 ${squidCert}
    '';
    path = [ pkgs.coreutils ];
  };

  services.squid = {
    enable = true;
    # The certificate does not exist at build time, so squid -k parse cannot
    # run then.
    validateConfig = false;
    configText = ''
      # configText replaces the module's generated configuration entirely, so
      # anything it would have set has to be set here. Without pid_filename,
      # squid falls back to a compiled-in path inside its own read-only store
      # directory and dies with "failed to open .../var/run/squid.pid".
      pid_filename /run/squid.pid
      cache_effective_user squid
      cache_effective_group squid

      # peek at step 1 to read the SNI hostname, then splice: the connection is
      # forwarded without decryption. No CA is trusted anywhere, certificate
      # pinning is unaffected, and agent-pulled container images work normally.
      # URL paths are not visible; hostnames, byte counts and durations are.
      http_port ${toString squidHttp} intercept
      https_port ${toString squidHttps} intercept ssl-bump generate-host-certificates=off cert=${squidCert}

      acl step1 at_step SslBump1
      ssl_bump peek step1
      ssl_bump splice all

      acl agents src ${site.agents.cidr}
      http_access allow agents
      http_access deny all

      # The client name rather than its address, resolved through unbound's
      # reverse records, so `grep demo` on this log yields that project's
      # traffic. The time is local, as on L0, with the offset that tells apart
      # the hour daylight saving time repeats; flow.log writes the same form.
      logformat agents %{%Y-%m-%dT%H:%M:%S%z}tl %6tr %>A %Ss/%03>Hs %<st %rm %ru %mt
      # /var/log/squid is a symlink to /data/logs/squid; see logging.nix.
      access_log /var/log/squid/access.log agents
      cache_log /var/log/squid/cache.log

      # No prompts or completions ever appear in any log; nothing is cached.
      cache deny all
      httpd_suppress_version_string on
      forwarded_for delete
    '';
  };

  systemd.services.squid = {
    after = [
      "data.mount"
      "unbound.service"
    ];
    requires = [ "data.mount" ];
  };

  # ------------------------------------------------------------ filtering --
  networking.firewall = {
    enable = true;
    allowedTCPPorts = [ 22 ];
    # Default-deny forward, with the exceptions below. Without this the kernel
    # forwards everything and the topology is only a convention.
    filterForward = true;

    # Services L1 offers downstream. ssh is deliberately not among them: the
    # requirement is directional, and nothing downstream may reach upstream.
    extraInputRules = ''
      iifname "tap-*" meta nfproto ipv6 drop
      iifname "tap-*" udp dport 53 accept comment "unbound"
      iifname "tap-*" tcp dport 53 accept comment "unbound"
      iifname "tap-*" udp dport 123 accept comment "chrony"
      iifname "tap-*" tcp dport ${toString squidHttp} accept comment "squid http"
      iifname "tap-*" tcp dport ${toString squidHttps} accept comment "squid https"
      iifname "tap-*" icmp type echo-request accept

      # The service stacks, published by L1 on its agents-segment address.
      # These are input rules, not forward ones: the containers run here, and
      # an agent connecting to one is connecting to L1.
      ${
        lib.concatStringsSep "\n      " (
          lib.mapAttrsToList (
            name: svc:
            "iifname \"tap-*\" tcp dport ${toString svc.port} counter accept comment \"${name}\""
          ) (lib.filterAttrs (_: svc: svc.enable) site.serviceStacks)
        )
      }
    '';

    extraForwardRules = ''
      # `counter` on each rule: `nft list ruleset` then shows packets and bytes
      # per rule, which is how you tell a rule that is doing work from one that
      # has never matched. Cheap, and the only way to see a drop that is not
      # also logged.

      # An unfiltered v6 path is the classic bypass.
      iifname "tap-*" counter meta nfproto ipv6 drop

      # Between segments, default-deny: agents reach L0 not at all, the
      # services segment only on its listed port, and each other not at all.
      # These are dropped and logged rather than failing silently on the guest.
      # Between segments, default-deny. 172.16/12 is in the set because that
      # is where the container bridges live: an agent reaches a service on the
      # published port through L1, never by talking to a container directly.
      iifname "tap-*" ip daddr { ${site.agents.cidr}, ${site.wan.cidr}, 172.16.0.0/12 } counter log prefix "segment-deny " level info drop

      # Without this, QUIC/HTTP3 bypasses Squid entirely and nothing is logged.
      # Clients fall back to TCP.
      iifname "tap-*" counter udp dport 443 drop comment "no QUIC"

      # Outbound DNS to the internet is deliberately not blocked, overruling
      # the specification's "DNS to L1 only". The sandbox is pointed at unbound
      # and nearly all traffic uses it, so the query log stays worth reading;
      # an agent that wants to query a public resolver directly may, and that
      # attempt shows up in the flow log below. What it may not do is reach a
      # resolver on the LAN — the services segment, another sandbox, L0 — and
      # the segment-deny rule above already covers that at every port rather
      # than only 53. Blocking 53 outbound would have bought little anyway:
      # DoT on 853 and DoH on 443 remain ordinary permitted egress in phase 1.

      # NTP to chrony on L1. Correctness rather than visibility: L1 absorbs the
      # laptop's suspend jump and the guests must follow it, or TLS starts
      # failing on a clock that drifted.
      iifname "tap-*" counter udp dport 123 drop comment "chrony only"

      # The containers' own egress. Docker manages its NAT, but the forward
      # chain here is default-deny, so its bridges need saying out loud.
      # Named svcbr* by the compose files, so one pair of rules covers every
      # service rather than one per generated bridge name.
      #
      # The first rule is container-to-container on the same bridge. Docker
      # loads br_netfilter, so even traffic that is switched rather than routed
      # passes through this hook — without it, a stack's containers cannot
      # reach each other at all, which looks like DNS working and every
      # connection timing out.
      iifname "svcbr*" oifname "svcbr*" counter accept
      iifname "svcbr*" oifname "en*" counter accept
      iifname "en*" oifname "svcbr*" ct state established,related counter accept

      # Everything else outbound is forwarded and recorded. 80 and 443 never
      # reach here: they are redirected to Squid in prerouting and appear in
      # its access log instead. What is left is the flow log.
      iifname "tap-*" oifname "en*" ct state new counter log prefix "flow " level info
      iifname "tap-*" oifname "en*" counter accept
    '';
  };

  # L1's address on the agents segment, held permanently on a dummy interface.
  #
  # agentctl also puts it on every tap, which is what answers ARP for each
  # point-to-point link. But taps exist only while a sandbox runs, so at boot
  # the address belonged to nothing and anything trying to bind it — a service
  # stack publishing a port, for one — failed with "cannot assign requested
  # address". A dummy interface makes the gateway a property of L1 rather than
  # of whichever sandboxes happen to be up.
  systemd.network.netdevs."10-agents0" = {
    netdevConfig = {
      Name = "agents0";
      Kind = "dummy";
    };
  };

  systemd.network.networks."10-agents0" = {
    matchConfig.Name = "agents0";
    address = [ "${site.agents.gateway}/32" ];
    networkConfig = {
      IPv6AcceptRA = false;
      LinkLocalAddressing = "no";
    };
    linkConfig.RequiredForOnline = false;
  };

  networking.nftables.tables = {
    # Transparent interception and source NAT.
    agent-nat = {
      family = "ip";
      content = ''
        chain prerouting {
          type nat hook prerouting priority dstnat; policy accept;
          # Only the agents segment is intercepted. A service VM's egress is
          # its own business and goes out directly: putting SearXNG's scraping
          # through Squid would double the log volume of the whole stack for
          # no visibility that matters.
          iifname "tap-*" tcp dport 80 redirect to :${toString squidHttp}
          iifname "tap-*" tcp dport 443 redirect to :${toString squidHttps}
        }
        chain postrouting {
          type nat hook postrouting priority srcnat; policy accept;
          ip saddr ${site.agents.cidr} oifname "en*" masquerade
        }
      '';
    };

    # In case the host sits behind a reduced-MTU link.
    agent-mangle = {
      family = "ip";
      content = ''
        chain forward {
          type filter hook forward priority mangle; policy accept;
          oifname "en*" tcp flags syn tcp option maxseg size set rt mtu
        }
      '';
    };
  };

  # nft `log` statements reach the kernel ring buffer through netfilter's
  # syslog backend, and without this module they are silently no-ops: the rules
  # match and drop exactly as written, but nothing is ever recorded. The flow
  # log and segment-deny are the whole visibility half of phase 1, so this is
  # load-bearing rather than diagnostic.
  boot.kernelModules = [ "nf_log_syslog" ];

  boot.kernel.sysctl = {
    "net.ipv4.ip_forward" = 1;
    # L1 holds the same gateway address on every tap, so return paths are not
    # symmetric in the way strict mode expects.
    "net.ipv4.conf.all.rp_filter" = 2;
    "net.ipv4.conf.default.rp_filter" = 2;
    # Interception needs the kernel to accept packets addressed elsewhere.
    "net.ipv4.conf.all.route_localnet" = 1;
  };

  # The sandboxes' only reachable time source. L1 takes the laptop's suspend
  # jump itself and they follow it.
  services.chrony.extraConfig = lib.mkAfter ''
    allow ${site.agents.cidr}
  '';
}
