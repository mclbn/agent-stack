# Your agent-stack settings.
#
# Every setting is listed below. The ones commented out (# at the start of the
# line) show their default value and change nothing: to change one, remove its
# # and edit the value. A setting left commented follows the stack's default,
# including when a later version of the stack changes it.
#
# What each setting does, in full: site/options.nix
#   https://github.com/mclbn/agent-stack/blob/main/site/options.nix
# A misspelt name or a wrong value fails with an error naming it.
{
  # ---- Required: replace the three CHANGEME values ---------------------------

  # The folder holding your projects, one sub-folder each. Mode 0700.
  exportRoot = "/home/CHANGEME/work";

  # Configuration files copied into the home of every new sandbox.
  dotfilesRoot = "/home/CHANGEME/agent-dotfiles";

  # The stack's public ssh key, the whole line: cat ~/.ssh/agent-stack.pub
  operatorSshKey = "ssh-ed25519 CHANGEME agent-stack";

  # Its private half, as `nix run .#ssh-config` writes it into ~/.ssh/config.
  # sshIdentityFile = "~/.ssh/agent-stack";

  # Timezone of L1 and of the sandboxes. Set it to the one this machine uses,
  # then deploy, golden-build, and agent reset each project.
  # timezone = "UTC";

  # ---- The sandbox image: golden-build, then agent reset, after a change -----

  guest = {
    # "light" builds in minutes: no Emacs, no VNC desktop, no TeX.
    # "full" has all of them and takes around 20 GB. Choose before the first
    # build: switching later means building the image again.
    profile = "light";

    # The Arch Linux Archive date the image is built from.
    # `nix run .#golden-update` moves it forward; leave this line in.
    snapshot = "2026/09/27";

    # Console locale and keymap. Another locale also needs a line in
    # image/mkosi.skeleton/etc/locale.gen in the stack.
    # locale = "en_US.UTF-8";
    # keymap = "us";

    # Arch packages added to the image, e.g. [ "htop" ].
    # extraPackages = [ ];

    # AUR packages to build, besides yay-bin and emacs-lsp-booster. Building
    # does not install: put the package's name in extraPackages too.
    # aurPackages = [ ];

    # The agents, each installed by its vendor's own script.
    # agentInstallers = [
    #   "https://claude.ai/install.sh"
    #   "https://chatgpt.com/codex/install.sh"
    #   "https://opencode.ai/install"
    # ];

    # The VNC desktop, full profile only.
    # vnc.geometry = "1920x1080";
    # vnc.depth = 24;
  };

  # ---- Credentials: nix profile upgrade agent after a change -----------------

  # "command" runs each entry's command; "authinfo" reads every key from one
  # GPG-encrypted netrc file instead, and ignores the commands.
  # credentials.source = "command";
  # credentials.authinfoFile = "~/.authinfo.gpg";

  # One entry per API key: the variable the agent reads, the machine name it is
  # filed under, and a command that prints the key. None by default;
  # `agent shell` needs none.
  # credentials.entries = {
  #   ANTHROPIC_API_KEY = { machine = "api.anthropic.com"; command = "pass show ai/anthropic"; };
  #   OPENAI_API_KEY = { machine = "api.openai.com"; command = "pass show ai/openai"; };
  #   OPENCODE_API_KEY = { machine = "opencode.ai"; command = "pass show ai/opencode"; };
  # };

  # ---- Sandboxes: deploy, then agent stop and start, after a change ----------

  # sandbox.memoryMiB = 4096;
  # sandbox.vcpu = 4;

  # ---- L1, the carrier VM: nix run .#deploy after a change -------------------

  # L1's own size. Every running sandbox's memory comes out of l1.memoryMiB.
  # l1.memoryMiB = 8192;
  # l1.vcpu = 8;

  # A CPU cap for L1 and everything in it: cpuQuota / cpuPeriod cores.
  # l1.cpuQuota = 400000;
  # l1.cpuPeriod = 100000;

  # L1's system disk, which holds nothing that has to survive.
  # l1.systemDiskMiB = 30720;

  # L1's data disk, created once by install and never resized after.
  # l1.dataDiskSize = "100G";

  # NixOS modules of your own, added to L1's configuration.
  # carrier.extraModules = [ ];

  # ---- DNS and time on L1: nixos-rebuild switch, or deploy -------------------

  # "recursive", "gateway" (whatever DNS this machine uses), or a list of
  # resolvers. Try "gateway" first if names stop resolving.
  # dns.resolver = "recursive";

  # Zones the upstream resolver serves that the public DNS does not.
  # dns.insecureDomains = [ ];

  # ntp.pools = [
  #   "0.pool.ntp.org"
  #   "1.pool.ntp.org"
  #   "2.pool.ntp.org"
  #   "3.pool.ntp.org"
  # ];

  # Reachable without DNS, so a wrong clock can always be put right.
  # ntp.addresses = [
  #   "162.159.200.1"
  #   "162.159.200.123"
  # ];

  # ---- Logs on L1: nix run .#deploy after a change ---------------------------

  # logging.rotate = "daily";
  # logging.keep = 30;
  # logging.maxSize = "200M";
  # logging.journalMaxUse = "2G";
  # logging.journalRetention = "1month";

  # ---- Service stacks on L1: nix run .#deploy after a change -----------------

  # searxng ships with the stack. A stack of your own goes beside it, with
  # its compose file in this folder:
  #   e.g. serviceStacks.mine = { port = 3001; directory = ./services/mine; };
  # serviceStacks.searxng = {
  #   enable = true;
  #   port = 3000;
  #   endpoint = "http://searxng.svc.contained:3000/mcp";
  # };

  # ---- Names and networks: change before the first install -------------------

  # Sandboxes are <project>.agents.<internalDomain>. After a change: deploy,
  # nix profile upgrade agent, and print nix run .#ssh-config into
  # ~/.ssh/config again in place of the old lines.
  # internalDomain = "contained";

  # The libvirt NAT network between this machine and L1. install only creates
  # it when it does not exist yet, and wan.address is also in ~/.ssh/config:
  # see "Everything else, and what to re-run" in the README first.
  # wan.cidr = "10.99.0.0/24";
  # wan.gateway = "10.99.0.1";
  # wan.address = "10.99.0.2";
  # wan.prefixLength = 24;
  # wan.netmask = "255.255.255.0";

  # ---- libvirt on this machine: nix run .#install after a change -------------

  # imageDir = "/var/lib/libvirt/images/agent";
  # domainName = "agent-l1";
  # domainUuid = "28c011be-50ad-4210-88a9-c09ded2fb50e";
  # networkName = "agent-wan";
  # bridgeName = "virbr-agent";
}
