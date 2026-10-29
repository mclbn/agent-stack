# Restricted sandboxes: a module for your site folder, listed in
# carrier.extraModules. See "Restricting a sandbox" in the README.
#
# A restricted sandbox reaches, on L1, DNS for internal names only, time, ping
# and the services listed below; elsewhere, only the destinations listed below.
# Nothing else: no internet, no LAN, no other sandbox, 80 and 443 included.
# With no sandbox listed, this module changes nothing.
{ lib, site, ... }:

let
  # Each restricted sandbox, by project name and index. Every project's index:
  #   ssh l1 'jq -r "[.project, .index] | @tsv" /data/state/alloc.jsonl'
  # A project gets its index on its first start, and a new one if it is deleted
  # and re-created: update this list then, or the rules no longer apply to it.
  restricted = {
    # pentest = 5;
  };

  # L1 services they may use, by name in site.nix's serviceStacks. Ports are
  # read from there, and a misspelt name fails the build.
  allowedServices = [
    # "searxng"
  ];

  # Destinations outside L1 they may reach, over TCP.
  allowedElsewhere = [
    # { address = "10.51.37.17"; port = 8080; }
  ];

  # The tap and address agentctl derives from the index (carrier/sandbox.nix).
  # Should that ever change, the source-address rule below cuts the sandbox off
  # rather than leaving it open.
  sandboxes = lib.mapAttrsToList (_: index: {
    tap = "tap-${toString index}";
    ip = "10.42.${toString (builtins.div index 256)}.${toString (lib.mod index 256)}";
  }) restricted;

  l1 = site.agents.gateway;
  taps = lib.concatMapStringsSep ", " (s: "\"${s.tap}\"") sandboxes;
  bindings = lib.concatMapStringsSep ", " (s: "\"${s.tap}\" . ${s.ip}") sandboxes;
  servicePorts = lib.concatMapStringsSep ", " (
    n: toString site.serviceStacks.${n}.port
  ) allowedServices;
in
{
  config = lib.mkIf (restricted != { }) {
    # DNS: answer only what L1 holds locally (sandbox and service names, reverse
    # records) and refuse the rest, so no lookup leaves L1 on their behalf.
    # Added to the stack's list; the more specific address wins over its /16.
    services.unbound.settings.server.access-control = map (
      s: "${s.ip}/32 refuse_non_local"
    ) sandboxes;

    networking.nftables.tables.agent-restricted = {
      family = "ip";
      content = ''
        set taps {
          type ifname
          elements = { ${taps} }
        }

        set bindings {
          type ifname . ipv4_addr
          elements = { ${bindings} }
        }

        chain prerouting {
          # Ahead of the stack's redirect to Squid, so 80 and 443 are filtered
          # here like every other port. A drop here is final; an accept only
          # ends this chain, so nothing here can widen the stack's rules.
          type filter hook prerouting priority mangle; policy accept;

          # The DNS rule trusts the source address: hold each tap to its own.
          iifname @taps iifname . ip saddr != @bindings counter drop

          # Replies to connections L1 opens: ssh, agent attach.
          iifname @taps ct state established,related accept

          # L1: DNS, time, ping, and the allowed services.
          iifname @taps ip daddr ${l1} udp dport { 53, 123 } accept
          iifname @taps ip daddr ${l1} tcp dport 53 accept
          iifname @taps ip daddr ${l1} icmp type echo-request accept
          ${lib.optionalString (allowedServices != [ ]) ''
            iifname @taps ip daddr ${l1} tcp dport { ${servicePorts} } accept
          ''}
          # Elsewhere: the allowed destinations.
          ${lib.concatMapStrings (d: ''
            iifname @taps ip daddr ${d.address} tcp dport ${toString d.port} accept
          '') allowedElsewhere}
          iifname @taps counter log prefix "segment-deny " level info drop
        }
      '';
    };
  };
}
