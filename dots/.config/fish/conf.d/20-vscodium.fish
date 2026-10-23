# VSCodium's portable mode for shells outside the niri session, such as SSH
# logins, which ~/.config/environment.d/60-vscodium.conf does not reach.
if not set -q VSCODE_PORTABLE
    set -l data_home $HOME/.local/share
    set -q XDG_DATA_HOME[1]; and set data_home $XDG_DATA_HOME
    set -gx VSCODE_PORTABLE $data_home/vscodium
end
