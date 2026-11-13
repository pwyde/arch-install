# Claude Code's environment for shells outside the niri session, such as SSH
# logins, which ~/.config/environment.d/10-claude.conf does not reach. That
# file explains the values.
set -l config_home $HOME/.config
set -q XDG_CONFIG_HOME[1] && set config_home $XDG_CONFIG_HOME
set -q CLAUDE_CONFIG_DIR || set -gx CLAUDE_CONFIG_DIR $config_home/claude
set -q DISABLE_TELEMETRY || set -gx DISABLE_TELEMETRY 1
set -q DO_NOT_TRACK || set -gx DO_NOT_TRACK 1
set -q DISABLE_ERROR_REPORTING || set -gx DISABLE_ERROR_REPORTING 1
set -q DISABLE_FEEDBACK_COMMAND || set -gx DISABLE_FEEDBACK_COMMAND 1
set -q CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY || set -gx CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY 1
