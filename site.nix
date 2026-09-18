# Site-local parameters.
#
# This is the only file that differs between installations. Everything marked
# CHANGEME must be edited before the first build; the carrier config asserts on
# them, so a forgotten edit fails at eval time rather than at boot.
{
  # ---------------------------------------------------------------- L0 -----

  # The export root: the one directory tree on L0 exported to L1. Mode 0700,
  # owned by uid 1000. Every project is a direct child of it, and the workspace
  # for project <name> is <exportRoot>/<name>.
  exportRoot = "/home/CHANGEME/work";

  # Public half of the stack's ssh keypair. Generated on L0, never leaves it.
  #   ssh-keygen -t ed25519 -f ~/.ssh/agent-stack -C agent-stack
  operatorSshKey = "ssh-rsa CHANGEME...";

  # Where L1's disks live on L0. Root-owned, mode 0700.
  imageDir = "/var/lib/libvirt/images/agent";

  # ---------------------------------------------------------- libvirt ------
  domainName = "agent-l1";
  # Fixed so that redefining the domain updates it in place instead of
  # colliding with the previous definition. Regenerate per site if you ever run
  # two carriers on one host: uuidgen.
  domainUuid = "28c011be-50ad-4210-88a9-c09ded2fb50e";
  networkName = "agent-wan";
  bridgeName = "virbr-agent"; # must stay under 15 characters

  # ---------------------------------------------------------- L1 sizing ----
  l1 = {
    memoryMiB = 8192;
    vcpu = 8;
    # Domain-wide CPU cap: <global_quota>/<global_period>. 400000/100000 is
    # four cores' worth for the entire nested tree.
    cpuQuota = 400000;
    cpuPeriod = 100000;
    systemDiskMiB = 30720; # 30 GiB
    dataDiskSize = "100G"; # sparse raw file on L0
  };

  # ------------------------------------------------- wan (libvirt NAT) -----
  wan = {
    cidr = "10.99.0.0/24"; # the segment, for rules that match the whole of it
    gateway = "10.99.0.1"; # libvirt's address on the NAT bridge
    address = "10.99.0.2"; # L1
    prefixLength = 24;
    netmask = "255.255.255.0";
  };

  # --------------------------------- sandbox console (baked into the golden)
  # Passed to mkosi by golden-build, overriding the defaults in
  # image/mkosi.conf. Changing the locale to something other than en_US.UTF-8
  # or C.UTF-8 also means editing image/mkosi.extra/etc/locale.gen, since a
  # glibc locale has to be generated before it can be selected.
  guest = {
    locale = "en_US.UTF-8";
    keymap = "us";
    timezone = "UTC";

    # "full" or "light". full is the image the specification describes, around
    # 20-25 GB. light omits the editor, the display stack and the document
    # toolchain — no Emacs, no TigerVNC, no texlive — leaving a sandbox that
    # can still build, run and debug code, use databases and run containers.
    # Worth having while iterating on the stack itself: it builds in minutes
    # and copies to L1 in seconds. See image/mkosi.profiles/.
    profile = "light";

    # The Arch Linux Archive date every repository is pinned to, so that two
    # rebuilds months apart are not silently different. Bumped deliberately by
    # `nix run '.#golden-update'`, which resolves the newest available date,
    # writes it here, resets every project and rebuilds.
    snapshot = "2026/09/01";

    # The VNC display, in the full profile only. No password: the only route
    # in is the ssh tunnel, already authenticated by key, and Xvnc listens on
    # localhost so nothing else can reach it.
    vnc = {
      geometry = "1920x1080";
      depth = 24;
    };

    # AUR packages, built on L0 with makepkg and handed to mkosi as a local
    # repository. Build dependencies are installed on L0 by `makepkg -s`, so
    # keep this list short and prefer -bin variants where they exist.
    #
    # The *package* names still have to appear in image/mkosi.conf or
    # image/mkosi.profiles/*.conf for them to be installed, and a package name
    # is not always the AUR name: yay-bin provides yay.
    aurPackages = [
      "yay-bin"
      "emacs-lsp-booster"
    ];

    # Agents, installed with their vendors' own installer scripts. Each is
    # run on L0 with HOME pointed at a staging directory, and the result is
    # copied into /home/agent in the image.
    #
    # In the agent's home rather than system-wide, because these tools
    # auto-update and need write access to their own install directory: an
    # update lands on the overlay, so the image sets a floor and
    # `agentctl reset` returns to the baked version. Claude Code's native
    # installer is built around exactly this layout, keeping a launcher at
    # ~/.local/bin/claude symlinked into ~/.local/share/claude/versions/.
    #
    # npm is deliberately not used: it is deprecated for Claude Code, and an
    # npm global install that cannot write its own directory disables
    # auto-update.
    agentInstallers = [
      "https://claude.ai/install.sh"
      "https://chatgpt.com/codex/install.sh"
      "https://opencode.ai/install"
    ];
  };

  # ------------------------------------------------------ sandbox sizing --
  # Per sandbox. Fixed rather than ballooned: virtiofs needs shared memory
  # backing, which makes ballooning and free-page reporting unreliable.
  sandbox = {
    memoryMiB = 4096;
    vcpu = 2;
  };

  # ------------------------------------------------------ internal names --
  # unbound on L1 is authoritative for these. Sandboxes are
  # <project>.agents.<internalDomain>; service VMs will be svc.<internalDomain>.
  # host/ssh_config matches the same zone and has to be edited alongside it.
  internalDomain = "contained";

  # ------------------------------------------------------------- dotfiles --
  # A directory on L0 holding the configuration files that belong in every
  # sandbox's home. Exported to L1 by virtiofs and re-exported to each sandbox
  # exactly as the workspace is, so an edit here is visible inside every
  # running sandbox at once: no pull, no copy on L1, nothing to drift.
  #
  # Mounted read-only in the sandbox. Note the boundary this is *not*: the
  # L0-to-L1 hop is writable, so a root agent that remounts the guest side
  # could write back to this directory. Keep it to configuration.
  dotfilesRoot = "/home/CHANGEME/agent-dotfiles";

  # ---------------------------------------------------------- credentials --
  # Secrets live on L0 and are pushed into a tmpfs in the sandbox at attach
  # time, so nothing ever lands on the overlay or on L1's disk.
  #
  # Each entry names an environment variable, the machine name it answers to,
  # and a command on L0 that prints the secret. The wrapper runs the commands,
  # writes /run/creds/env for the agents, and *synthesises* /run/creds/authinfo
  # in netrc form for Emacs and gptel — so netrc is an output, never a
  # requirement.
  #
  # This map is also the need-to-know boundary: a secret with no entry here is
  # never fetched, so it cannot reach a sandbox.
  credentials = {
    # "command" runs each entry's command. "authinfo" ignores them and reads
    # every value from one GPG-encrypted netrc file instead, which is what an
    # Emacs user already has; set authinfoFile below and leave the commands as
    # documentation.
    source = "command";
    authinfoFile = "~/.authinfo.gpg";

    # Recipes for the command source, any of which can be mixed freely:
    #
    #   pass show ai/anthropic                       pass, GPG-backed
    #   secret-tool lookup service anthropic         system keyring, no prompt
    #   age -d -i ~/.age/key ~/secrets/anthropic.age age, no GPG
    #   op read op://private/anthropic/credential    1Password CLI
    #   cat ~/.secrets/anthropic                     a 0600 file
    #   gpg -d ~/.secrets/anthropic.gpg              GPG without netrc
    #
    # The command must print the secret and nothing else. A trailing newline is
    # stripped; anything else it prints becomes part of the key.
    entries = {
      ANTHROPIC_API_KEY = {
        machine = "api.anthropic.com";
        command = "pass show ai/anthropic";
      };
      OPENCODE_API_KEY = {
        machine = "opencode.ai";
        command = "pass show ai/opencode";
      };
      OPENAI_API_KEY = {
        machine = "api.openai.com";
        command = "pass show ai/openai";
      };
    };
  };

  # -------------------------------------------------------------- logging --
  # Raw text on the data disk. No shipping, no aggregation: read with `ssh l1`
  # and grep. Rotation bounds what a quiet month costs, and the journal is
  # bounded separately by systemd's own limits.
  logging = {
    rotate = "daily";
    keep = 30; # rotations retained, so roughly a month at daily
    maxSize = "200M"; # rotate early if a single log gets there first
    journalMaxUse = "2G";
    journalRetention = "1month";
  };

  # -------------------------------------------------------------- services --
  # Container stacks run by L1 itself, started at boot. Each name must match a
  # directory under services/ holding a compose.yml.
  #
  # Not VMs: a VM per MCP server costs 768 MB and a boot to run three
  # containers, and the threat it would address — an MCP server escaping its
  # container — is one this design accepts. The containers sit on L1, reachable
  # by agents on one published port each and by nothing else.
  #
  # To add one: copy services/searxng, change the compose file, add a line
  # here. To turn one off: enable = false, then deploy.
  serviceStacks = {
    searxng = {
      enable = true;
      # Published on L1's agents-segment address, so sandboxes reach it and
      # nothing on the wan side can. This is also the only port agents may
      # cross to.
      port = 3000;
      # What agents are told, and what unbound answers for.
      endpoint = "http://searxng.svc.contained:3000/mcp";
    };
  };

  # ------------------------------------------------------------- segments --
  agents = {
    cidr = "10.42.0.0/16";
    gateway = "10.42.0.1"; # L1, reused on every tap
  };
}
