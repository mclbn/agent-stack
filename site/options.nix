# Every site setting: its type, its default, and what it does.
#
# This file is the reference; your own site.nix sets only what differs from it.
# Three settings have no default and must be set there: exportRoot,
# dotfilesRoot and operatorSshKey. A list you set replaces the default list
# rather than adding to it.
#
# A misspelt name or a value of the wrong type fails at evaluation, naming the
# setting, rather than at boot.
{ lib, config, ... }:

let
  inherit (lib) mkOption types;

  # The service stack submodule has a config of its own.
  topConfig = config;

  # The template ships CHANGEME placeholders for the required settings, which
  # are refused here so that a forgotten edit names itself.
  edited =
    t:
    types.addCheck t (s: !lib.hasInfix "CHANGEME" s)
    // {
      description = "${t.description}, with the CHANGEME placeholder replaced";
    };
  absolutePath = types.strMatching "/.*" // {
    description = "absolute path";
  };
  sshPublicKey = types.strMatching "(ssh|ecdsa|sk)-.*" // {
    description = "ssh public key";
  };
in
{
  options = {
    # ---------------------------------------------------------------- L0 -----
    exportRoot = mkOption {
      type = edited absolutePath;
      example = "/home/alice/work";
      description = ''
        The export root: the one directory tree on L0 exported to L1. Mode
        0700, owned by uid 1000. Every project is a direct child of it, and
        the workspace for project <name> is <exportRoot>/<name>.
      '';
    };

    operatorSshKey = mkOption {
      type = edited sshPublicKey;
      example = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA... agent-stack";
      description = ''
        Public half of the stack's ssh keypair, authorized on L1 and in every
        sandbox. Generated on L0, and the private half never leaves it:

          ssh-keygen -t ed25519 -f ~/.ssh/agent-stack -C agent-stack
      '';
    };

    imageDir = mkOption {
      type = absolutePath;
      default = "/var/lib/libvirt/images/agent";
      description = "Where L1's disks live on L0. Root-owned, mode 0700.";
    };

    # ---------------------------------------------------------- libvirt ------
    domainName = mkOption {
      type = types.str;
      default = "agent-l1";
      description = "The libvirt domain name of L1.";
    };

    domainUuid = mkOption {
      type = types.strMatching "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}";
      default = "28c011be-50ad-4210-88a9-c09ded2fb50e";
      description = ''
        Fixed so that redefining the domain updates it in place instead of
        colliding with the previous definition. Regenerate per site if you
        ever run two carriers on one host: uuidgen.
      '';
    };

    networkName = mkOption {
      type = types.str;
      default = "agent-wan";
      description = "The libvirt NAT network L1 sits on.";
    };

    bridgeName = mkOption {
      type = types.addCheck types.str (s: lib.stringLength s <= 15) // {
        description = "interface name of at most 15 characters";
      };
      default = "virbr-agent";
      description = "The bridge of that network. Linux caps interface names at 15 characters.";
    };

    # ---------------------------------------------------------- L1 sizing ----
    l1 = {
      memoryMiB = mkOption {
        type = types.ints.positive;
        default = 8192;
        description = "L1's memory, which every running sandbox comes out of.";
      };
      vcpu = mkOption {
        type = types.ints.positive;
        default = 8;
        description = "L1's virtual CPUs.";
      };
      cpuQuota = mkOption {
        type = types.ints.positive;
        default = 400000;
        description = ''
          Domain-wide CPU cap: cpuQuota/cpuPeriod. 400000/100000 is four
          cores' worth for the entire nested tree.
        '';
      };
      cpuPeriod = mkOption {
        type = types.ints.positive;
        default = 100000;
        description = "See cpuQuota.";
      };
      systemDiskMiB = mkOption {
        type = types.ints.positive;
        default = 30720;
        description = "L1's system disk. Nothing that has to survive lives on it.";
      };
      dataDiskSize = mkOption {
        type = types.str;
        default = "100G";
        description = ''
          L1's data disk, a sparse raw file on L0, in truncate(1)'s units.
          Created once by install and never touched again, so growing it later
          is a manual resize.
        '';
      };
    };

    # ------------------------------------------------- wan (libvirt NAT) -----
    wan = {
      cidr = mkOption {
        type = types.str;
        default = "10.99.0.0/24";
        description = "The segment, for rules that match the whole of it.";
      };
      gateway = mkOption {
        type = types.str;
        default = "10.99.0.1";
        description = "libvirt's address on the NAT bridge.";
      };
      address = mkOption {
        type = types.str;
        default = "10.99.0.2";
        description = "L1's address.";
      };
      prefixLength = mkOption {
        type = types.ints.between 0 32;
        default = 24;
        description = "The segment's prefix length.";
      };
      netmask = mkOption {
        type = types.str;
        default = "255.255.255.0";
        description = "The same, as a netmask, for libvirt.";
      };
    };

    # ---------------------------------------------------------------- dns ----
    dns = {
      resolver = mkOption {
        type = types.either (types.enum [
          "recursive"
          "gateway"
        ]) (types.listOf types.str);
        default = "recursive";
        example = [
          "9.9.9.9@853#dns.quad9.net"
          "149.112.112.112@853#dns.quad9.net"
        ];
        description = ''
          How L1's unbound reaches the public namespace. The internal zone is
          unaffected either way: <project>.agents.<internalDomain> and
          <name>.svc.<internalDomain> are answered from local data and never
          leave L1, whatever this is set to.

          "recursive"  L1 walks from the root itself and validates every step
                       against the root trust anchor. No third party sees the
                       queries, and no resolver but this one is trusted. The
                       design's assumption, and correct wherever it works.

          "gateway"    Forward everything to wan.gateway — libvirt's dnsmasq
                       on L0 — which in turn uses whatever resolver the laptop
                       currently has. The address is on our own bridge and
                       never changes, so this one value is portable: it means
                       "whatever DNS this laptop is using", at home or
                       anywhere else.

          a list       Forward to these addresses instead. If *every* entry
                       carries @853 the stack turns on DoT, which is the
                       setting for a network you do not trust: port 853
                       cannot be intercepted by a port-53 redirect, and you
                       choose the resolver rather than inheriting whoever runs
                       the WiFi.

          *If name resolution stops working, try "gateway" first.* Recursion
          is impossible on a network that redirects outbound port 53 to its
          own resolver — a captive portal, a corporate LAN, or a router with a
          DNS capture of your own making. The symptom is specific and is
          described under "If something goes wrong" in the README: ping to an
          address works, every name fails, and `dig @127.0.0.1 . NS` on L1
          returns SERVFAIL.

          Interception is invisible to an ordinary client, which asks a
          resolver one question and does not care who answers. It is fatal to
          a resolver, which asks specific authoritative servers with recursion
          *not* desired — and an interceptor refuses exactly those. L1 is
          normally the only machine on a home network doing the second thing.

          DNSSEC is validated on L1 in every mode: forwarding moves where the
          walk happens, not who checks the signatures.
        '';
      };

      insecureDomains = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = ''
          Zones the upstream resolver is authoritative for that the public
          root says do not exist. Forwarding to a router that serves
          "home.lan." needs that name listed here or the validator will —
          correctly — refuse the answer. Empty by default: agents have no
          business reaching the LAN, and the forward rules drop it anyway.
        '';
      };
    };

    # ---------------------------------------------------------------- ntp ----
    # L1 is the only time source the sandboxes can reach, and TLS everywhere
    # downstream depends on its clock.
    ntp = {
      pools = mkOption {
        type = types.listOf types.str;
        default = [
          "0.pool.ntp.org"
          "1.pool.ntp.org"
          "2.pool.ntp.org"
          "3.pool.ntp.org"
        ];
        description = ''
          Pool names. Resolved through L1's own unbound, so they are
          unavailable for as long as DNS is.
        '';
      };
      addresses = mkOption {
        type = types.listOf types.str;
        default = [
          "162.159.200.1"
          "162.159.200.123"
        ];
        description = ''
          At least one source reachable with no DNS at all. Without this the
          stack has a deadlock it cannot leave on its own: a clock far enough
          out breaks DNSSEC, which breaks resolution, which is how chrony finds
          the servers that would fix the clock. Anycast addresses for
          time.cloudflare.com; any stable literal does the job.
        '';
      };
    };

    # --------------------------------- sandbox console (baked into the golden)
    guest = {
      locale = mkOption {
        type = types.str;
        default = "en_US.UTF-8";
        description = ''
          Passed to mkosi by golden-build. A locale other than en_US.UTF-8 or
          C.UTF-8 also means editing image/mkosi.skeleton/etc/locale.gen,
          since a glibc locale has to be generated before it can be selected.
        '';
      };
      keymap = mkOption {
        type = types.str;
        default = "us";
        description = "Console keymap, passed to mkosi by golden-build.";
      };
      timezone = mkOption {
        type = types.str;
        default = "UTC";
        example = "Europe/Paris";
        description = ''
          A tz database name. Linked by mkosi.postinst, which fails the build
          on a name the image's tzdata does not have.
        '';
      };

      profile = mkOption {
        type = types.enum [
          "full"
          "light"
        ];
        default = "light";
        description = ''
          "full" or "light". full is the image the specification describes,
          around 20-25 GB. light omits the editor, the display stack and the
          document toolchain — no Emacs, no TigerVNC, no texlive — leaving a
          sandbox that can still build, run and debug code, use databases and
          run containers. Worth having while iterating on the stack itself: it
          builds in minutes and copies to L1 in seconds. See
          image/mkosi.profiles/.
        '';
      };

      snapshot = mkOption {
        type = types.strMatching "[0-9]{4}/[0-9]{2}/[0-9]{2}" // {
          description = "date as YYYY/MM/DD";
        };
        # Keep template/site.nix in step when bumping this.
        default = "2026/09/27";
        description = ''
          The Arch Linux Archive date every repository is pinned to, so that
          two rebuilds months apart are not silently different. Bumped
          deliberately by `nix run .#golden-update`, which resolves the newest
          available date, rebuilds against it and then writes it into your
          site.nix, so that file needs a `snapshot = "…";` line for it to edit.
        '';
      };

      vnc = {
        geometry = mkOption {
          type = types.strMatching "[0-9]+x[0-9]+";
          default = "1920x1080";
          description = ''
            The VNC display, in the full profile only. No password: the only
            route in is the ssh tunnel, already authenticated by key, and Xvnc
            listens on localhost so nothing else can reach it.
          '';
        };
        depth = mkOption {
          type = types.ints.positive;
          default = 24;
          description = "The VNC display's colour depth.";
        };
      };

      aurPackages = mkOption {
        type = types.listOf types.str;
        default = [ ];
        example = [ "visual-studio-code-bin" ];
        description = ''
          AUR packages to build, in addition to yay-bin and emacs-lsp-booster,
          which the image always needs. Built on L0 with makepkg and handed to
          mkosi as a local repository. Build dependencies are installed on L0
          by `makepkg -s`, so keep this list short and prefer -bin variants
          where they exist.

          Building a package does not install it: its *package* name also has
          to be in the image's package list, and a package name is not always
          the AUR name — yay-bin provides yay.
        '';
      };

      agentInstallers = mkOption {
        type = types.listOf types.str;
        default = [
          "https://claude.ai/install.sh"
          "https://chatgpt.com/codex/install.sh"
          "https://opencode.ai/install"
        ];
        description = ''
          Agents, installed with their vendors' own installer scripts. Each is
          run on L0 with HOME pointed at a staging directory, and the result
          is copied into /home/agent in the image.

          In the agent's home rather than system-wide, because these tools
          auto-update and need write access to their own install directory:
          an update lands on the overlay, so the image sets a floor and
          `agentctl reset` returns to the baked version. Claude Code's native
          installer is built around exactly this layout, keeping a launcher at
          ~/.local/bin/claude symlinked into ~/.local/share/claude/versions/.

          npm is deliberately not used: it is deprecated for Claude Code, and
          an npm global install that cannot write its own directory disables
          auto-update.
        '';
      };
    };

    # ------------------------------------------------------ sandbox sizing --
    # Per sandbox. Fixed rather than ballooned: virtiofs needs shared memory
    # backing, which makes ballooning and free-page reporting unreliable.
    sandbox = {
      memoryMiB = mkOption {
        type = types.ints.positive;
        default = 4096;
        description = "Memory per sandbox, taken from L1's.";
      };
      vcpu = mkOption {
        type = types.ints.positive;
        default = 4;
        description = "Virtual CPUs per sandbox.";
      };
    };

    # ------------------------------------------------------ internal names --
    internalDomain = mkOption {
      type = types.str;
      default = "contained";
      description = ''
        unbound on L1 is authoritative for these. Sandboxes are
        <project>.agents.<internalDomain>; service stacks are
        <name>.svc.<internalDomain>. Your ~/.ssh/config matches the same zone
        and has to be edited alongside it.
      '';
    };

    # ------------------------------------------------------------- dotfiles --
    dotfilesRoot = mkOption {
      type = edited absolutePath;
      example = "/home/alice/agent-dotfiles";
      description = ''
        A directory on L0 holding the configuration files that belong in
        every sandbox's home. Exported to L1 by virtiofs and re-exported to
        each sandbox, where it is *copied* into /home/agent when the sandbox
        is created.

        Copied, once. A sandbox is seeded at creation and owns its copies from
        then on: an agent may edit any of them, the edits survive
        `agent stop`, nothing propagates back here, and no two sandboxes
        affect each other. Nothing is re-read on a later boot or attach, so a
        change made here reaches an existing sandbox only through
        `agent reset` — which takes a fresh copy and discards whatever the
        agent changed, since both live on the same overlay.

        Note the boundary this is *not*. The mount is read-only, but the
        copies are not: an agent can rewrite its own configuration inside the
        sandbox, and you will not see that from here. What the read-only mount
        buys is that it cannot reach back to this directory. The L0-to-L1 hop
        is writable, so a root agent that remounts the guest side could still
        write here — keep this to configuration.

        Symlinks in this directory are ignored, and named in the sandbox's
        journal rather than skipped in silence. They cannot be followed:
        virtiofs passes the link text through unchanged and the sandbox
        resolves it against its own filesystem, where L0's paths do not
        exist. Keep real files here, or point this at the tree the links lead
        to.
      '';
    };

    # ---------------------------------------------------------- credentials --
    # Secrets live on L0 and are pushed into a tmpfs in the sandbox at attach
    # time, so nothing ever lands on the overlay or on L1's disk.
    credentials = {
      source = mkOption {
        type = types.enum [
          "command"
          "authinfo"
        ];
        default = "command";
        description = ''
          "command" runs each entry's command. "authinfo" ignores them and
          reads every value from one GPG-encrypted netrc file instead, which
          is what an Emacs user already has; set authinfoFile and leave the
          commands out.
        '';
      };

      authinfoFile = mkOption {
        type = types.str;
        default = "~/.authinfo.gpg";
        description = "The netrc file read when source is \"authinfo\".";
      };

      entries = mkOption {
        type = types.attrsOf (
          types.submodule {
            options = {
              machine = mkOption {
                type = types.str;
                description = "The machine name the synthesised netrc uses, and the one looked up in authinfoFile.";
              };
              command = mkOption {
                type = types.str;
                default = "";
                description = ''
                  A command on L0 that prints the secret and nothing else. A
                  trailing newline is stripped; anything else it prints
                  becomes part of the key. Ignored when source is "authinfo".
                '';
              };
            };
          }
        );
        default = { };
        example = {
          ANTHROPIC_API_KEY = {
            machine = "api.anthropic.com";
            command = "pass show ai/anthropic";
          };
        };
        description = ''
          One entry per environment variable: the machine name it answers to,
          and a command on L0 that prints the secret. The wrapper runs the
          commands, writes /run/creds/env for the agents, and *synthesises*
          /run/creds/authinfo in netrc form for Emacs and gptel — so netrc is
          an output, never a requirement.

          This is also the need-to-know boundary: a secret with no entry here
          is never fetched, so it cannot reach a sandbox.

          Recipes for the command source, any of which can be mixed freely:

            pass show ai/anthropic                       pass, GPG-backed
            secret-tool lookup service anthropic         system keyring, no prompt
            age -d -i ~/.age/key ~/secrets/anthropic.age age, no GPG
            op read op://private/anthropic/credential    1Password CLI
            cat ~/.secrets/anthropic                     a 0600 file
            gpg -d ~/.secrets/anthropic.gpg              GPG without netrc
        '';
      };
    };

    # -------------------------------------------------------------- logging --
    # Raw text on the data disk. No shipping, no aggregation: read with
    # `ssh l1` and grep. Rotation bounds what a quiet month costs, and the
    # journal is bounded separately by systemd's own limits.
    logging = {
      rotate = mkOption {
        type = types.enum [
          "hourly"
          "daily"
          "weekly"
          "monthly"
          "yearly"
        ];
        default = "daily";
        description = "How often the logs on /data are rotated.";
      };
      keep = mkOption {
        type = types.ints.positive;
        default = 30;
        description = "Rotations retained, so roughly a month at daily.";
      };
      maxSize = mkOption {
        type = types.str;
        default = "200M";
        description = "Rotate early if a single log gets there first.";
      };
      journalMaxUse = mkOption {
        type = types.str;
        default = "2G";
        description = "journald's SystemMaxUse on L1.";
      };
      journalRetention = mkOption {
        type = types.str;
        default = "1month";
        description = "journald's MaxRetentionSec on L1.";
      };
    };

    # -------------------------------------------------------------- services --
    serviceStacks = mkOption {
      type = types.attrsOf (
        types.submodule (
          { name, config, ... }:
          {
            options = {
              enable = mkOption {
                type = types.bool;
                default = true;
                description = "Whether L1 runs this stack. Turning one off is enable = false, then deploy.";
              };
              port = mkOption {
                type = types.port;
                description = ''
                  Published on L1's agents-segment address, so sandboxes reach
                  it and nothing on the wan side can. This is also the only
                  port agents may cross to.
                '';
              };
              endpoint = mkOption {
                type = types.str;
                default = "http://${name}.svc.${topConfig.internalDomain}:${toString config.port}/mcp";
                defaultText = lib.literalExpression ''"http://<name>.svc.''${internalDomain}:<port>/mcp"'';
                description = "What agents are told, and what unbound answers for.";
              };
            };
          }
        )
      );
      default = { };
      description = ''
        Container stacks run by L1 itself, started at boot. Each name must
        match a directory under services/ holding a compose.yml.

        Not VMs: a VM per MCP server costs 768 MB and a boot to run three
        containers, and the threat it would address — an MCP server escaping
        its container — is one this design accepts. The containers sit on L1,
        reachable by agents on one published port each and by nothing else.

        searxng is defined by the stack itself, so adding a stack of your own
        keeps it; turn it off with serviceStacks.searxng.enable = false.
      '';
    };

    # ------------------------------------------------------------- segments --
    agents = {
      cidr = mkOption {
        type = types.str;
        default = "10.42.0.0/16";
        description = "The agents segment, which every sandbox's address comes from.";
      };
      gateway = mkOption {
        type = types.str;
        default = "10.42.0.1";
        description = "L1's address on it, reused on every tap.";
      };
    };
  };

  # Defined here rather than as the option's default, so that a stack added in
  # site.nix sits alongside it instead of replacing it.
  config.serviceStacks.searxng.port = lib.mkDefault 3000;
}
