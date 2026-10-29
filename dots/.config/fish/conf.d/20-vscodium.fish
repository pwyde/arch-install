# VSCodium's portable mode and the data directory of its command-line part,
# for shells outside the niri session, such as SSH logins, which
# ~/.config/environment.d/60-vscodium.conf does not reach.
set -l data_home $HOME/.local/share
set -q XDG_DATA_HOME[1] && set data_home $XDG_DATA_HOME
set -q VSCODE_PORTABLE || set -gx VSCODE_PORTABLE $data_home/vscodium
set -q VSCODE_CLI_DATA_DIR || set -gx VSCODE_CLI_DATA_DIR $data_home/vscodium/cli
