# Default programs and options for every login shell, installed as
# /etc/profile.d/10-defaults.sh. Like 00-xdg.sh, it also reaches the niri
# session. A value that is already set is kept, which leaves each user free to
# choose another program.

: "${EDITOR:=vim}"
: "${VISUAL:=vim}"
: "${PAGER:=less}"
export EDITOR VISUAL PAGER

# less shows the color codes from git, grep and similar tools as colors.
: "${LESS:=-R}"
# Colored man pages: bold text in red, underlined text in blue.
: "${MANPAGER:=less -R --use-color -Dd+r -Du+b}"
export LESS MANPAGER
