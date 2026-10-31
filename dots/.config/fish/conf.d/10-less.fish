# less options, in place of the -R that /etc/profile.d/10-defaults.sh sets for
# every user. Login shells pass them on to the niri session.
set -gx LESS '-g -i -M -R -S -w -z-4'
