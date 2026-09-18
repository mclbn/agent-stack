# L1 — service stacks.
#
# Containers, not VMs. A VM per MCP server costs 768 MB and a boot to run three
# containers, and the threat that would address — an MCP server escaping its
# container — is one this design accepts: these are services the operator chose
# and runs, not agent-authored code.
#
# One systemd unit per stack, started at boot, defined by a compose file under
# services/<name>/. Adding a service is a directory and a line in site.nix;
# nothing here knows about any particular one.
{
  config,
  lib,
  pkgs,
  site,
  ...
}:

let
  enabled = lib.filterAttrs (_: svc: svc.enable) site.serviceStacks;
in
{
  # The daemon L1 did not have until now. Deliberately plain docker rather than
  # rootless podman: the compose files are meant to be the same ones an
  # operator would run anywhere, and rootless changes port binding and volume
  # ownership in ways that would make them stack-specific.
  virtualisation.docker = {
    enable = true;
    # Containers are restarted by their units, not by the daemon, so that
    # `systemctl stop svc-searxng` means what it says.
    autoPrune.enable = true;
    autoPrune.dates = "weekly";
  };

  environment.systemPackages = [ pkgs.docker-compose ];

  systemd.services = lib.mapAttrs' (
    name: svc:
    lib.nameValuePair "svc-${name}" {
      description = "Service stack: ${name}";
      after = [
        "docker.service"
        "data.mount"
        "network-online.target"
        # The published port binds L1's agents-segment address, which lives on
        # a dummy interface brought up by networkd.
        "systemd-networkd.service"
      ];
      requires = [ "docker.service" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];

      environment = {
        # The compose files publish on this rather than on 0.0.0.0: a service
        # is for sandboxes, and binding the wan side would put it in front of
        # whatever network the laptop is on.
        SVC_BIND = site.agents.gateway;
        # Persistent state, for the services that want any. SearXNG does not.
        SVC_DATA = "/data/services/${name}";
      };

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        # A bind source that does not exist makes Docker try to create it and
        # fail on the read-only store, which reads as a mount problem rather
        # than the missing file it is. Usually means something under
        # services/<name>/ is untracked, so the flake never copied it.
        ExecStartPre = pkgs.writeShellScript "svc-${name}-check" ''
          dir=${../services}/${name}
          for want in compose.yml; do
            [ -e "$dir/$want" ] \
              || { echo "missing $dir/$want — is services/${name} fully tracked by git?" >&2; exit 1; }
          done
          ${pkgs.docker-compose}/bin/docker-compose -f "$dir/compose.yml" -p ${name} config -q \
            || { echo "compose file for ${name} is not valid" >&2; exit 1; }
        '';
        # --wait: the unit fails if a container does not come up healthy,
        # rather than reporting success over a stack that is not running.
        ExecStart = "${pkgs.docker-compose}/bin/docker-compose -f ${../services}/${name}/compose.yml -p ${name} up -d --wait";
        ExecStop = "${pkgs.docker-compose}/bin/docker-compose -f ${../services}/${name}/compose.yml -p ${name} down";
        # A cold first start pulls images.
        TimeoutStartSec = "600";
      };
    }
  ) enabled;

  systemd.tmpfiles.rules = lib.mapAttrsToList (
    name: _: "d /data/services/${name} 0755 root root -"
  ) enabled;

  # Names for the agents. These resolve to L1's own address on the agents
  # segment, because that is where the ports are published — the containers
  # themselves are never addressed directly.
  services.unbound.settings.server.local-data = lib.mapAttrsToList (
    name: _: "\"${name}.svc.${site.internalDomain}. A ${site.agents.gateway}\""
  ) enabled;
}
