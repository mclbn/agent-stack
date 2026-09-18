# The agents live in the agent's home so that their self-updates land on the
# overlay. /usr/local/bin carries symlinks to their launchers, so they work in
# any shell without this file; these entries are for everything *else* an agent
# installs into its home — npm -g with a user prefix, pipx, cargo install, go
# install — which would otherwise need a full path.
case ":$PATH:" in
    *":$HOME/.local/bin:"*) ;;
    *) export PATH="$HOME/.local/bin:$PATH" ;;
esac
