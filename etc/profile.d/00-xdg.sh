# XDG Base Directory locations for every login shell, installed as
# /etc/profile.d/00-xdg.sh.
#
# The values are the specification's defaults, set explicitly: some programs
# only use an XDG location when its variable is set. A value that is already
# set is kept. The niri session inherits them through niri-session, which
# starts in a login shell and passes its environment on to systemd. The 00
# prefix makes this file run before the other profile.d files, which can read
# these variables.

: "${XDG_CONFIG_HOME:=$HOME/.config}"
: "${XDG_DATA_HOME:=$HOME/.local/share}"
: "${XDG_STATE_HOME:=$HOME/.local/state}"
: "${XDG_CACHE_HOME:=$HOME/.cache}"
export XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME XDG_CACHE_HOME

# Programs that keep their files directly in the home directory otherwise. less
# needs no variable: with XDG_STATE_HOME set, its history goes there.
export PYTHON_HISTORY="$XDG_STATE_HOME/python_history"
export CARGO_HOME="$XDG_DATA_HOME/cargo"
export RUSTUP_HOME="$XDG_DATA_HOME/rustup"
# readline, which bash uses. Without the file, readline reads /etc/inputrc.
export INPUTRC="$XDG_CONFIG_HOME/readline/inputrc"
