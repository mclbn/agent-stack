# Your site folder's flake. Nothing to edit here: your settings go in site.nix.
#
# The stack's version is pinned in flake.lock, written on first use. To move to
# the newest one: nix flake update agent-stack
{
  description = "My agent-stack site";

  inputs.agent-stack.url = "github:mclbn/agent-stack";

  outputs = { agent-stack, ... }: agent-stack.lib.mkStack { modules = [ ./site.nix ]; };
}
