# Your agent-stack settings.
#
# Only what differs from the defaults belongs here. Every setting, with its
# default and what it does, is in site/options.nix:
#   https://github.com/mclbn/agent-stack/blob/main/site/options.nix
# A misspelt name or a wrong value fails with an error naming it.
{
  # ---- Required: replace the three CHANGEME values ------------------------

  # The folder holding your projects, one sub-folder each.
  exportRoot = "/home/CHANGEME/work";

  # Configuration files copied into the home of every new sandbox.
  dotfilesRoot = "/home/CHANGEME/agent-dotfiles";

  # The stack's public ssh key, the whole line: cat ~/.ssh/agent-stack.pub
  operatorSshKey = "ssh-ed25519 CHANGEME agent-stack";

  # ---- The sandbox image ---------------------------------------------------

  guest = {
    # "light" builds in minutes: no Emacs, no VNC desktop, no TeX.
    # "full" has all of them and takes around 20 GB. Choose before the first
    # build: switching later means building the image again.
    profile = "light";

    # The Arch Linux Archive date the image is built from.
    # `nix run .#golden-update` moves it forward; leave this line in.
    snapshot = "2026/09/27";

  };

  # For L1 and the sandboxes alike; set it to L0's own.
  # timezone = "Europe/Paris";

  # ---- Credentials, for the agents that need an API key --------------------
  # One entry per key: the variable the agent reads, and a command on this
  # machine that prints the key. `agent shell` needs none of them.

  # credentials.entries = {
  #   ANTHROPIC_API_KEY = { machine = "api.anthropic.com"; command = "pass show ai/anthropic"; };
  #   OPENAI_API_KEY    = { machine = "api.openai.com";    command = "pass show ai/openai"; };
  #   OPENCODE_API_KEY  = { machine = "opencode.ai";       command = "pass show ai/opencode"; };
  # };
}
