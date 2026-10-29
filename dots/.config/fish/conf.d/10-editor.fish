# Neovim as the editor, in place of the vim that /etc/profile.d/10-defaults.sh
# sets for every user. Login shells pass it on to the niri session.
set -gx EDITOR nvim
set -gx VISUAL nvim
