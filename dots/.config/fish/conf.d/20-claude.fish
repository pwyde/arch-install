# Claude Code's configuration directory, for shells outside the niri session,
# such as SSH logins, which ~/.config/environment.d/10-claude.conf does not
# reach.
set -l config_home $HOME/.config
set -q XDG_CONFIG_HOME[1] && set config_home $XDG_CONFIG_HOME
set -q CLAUDE_CONFIG_DIR || set -gx CLAUDE_CONFIG_DIR $config_home/claude
