# XDG Base Directory support for bash, installed as
# /etc/profile.d/zz-xdg-bash.sh.
#
# Bash has no XDG Base Directory support and reads ~/.bashrc otherwise. For
# bash login shells, this loads the user's bashrc from the XDG config directory.
# The history and the bash-completion user file are exported, which also
# applies to a bash started later from another program.
#
# /etc/profile reads every POSIX login shell's profile.d files in name order;
# this one only acts in bash, and like /etc/profile itself, not in bash running
# as sh or in POSIX mode. The zz prefix makes it run last, after 00-xdg.sh and
# the other files whose environment the bashrc can rely on.

if [ -n "${BASH_VERSION:-}" ] && [ "${0#-}" != sh ] \
  && [ -z "${POSIXLY_CORRECT:-}" ]; then
  HISTFILE="${XDG_STATE_HOME:-${HOME}/.local/state}/bash/history"
  BASH_COMPLETION_USER_FILE="${XDG_CONFIG_HOME:-${HOME}/.config}/bash-completion/bash_completion"
  export HISTFILE BASH_COMPLETION_USER_FILE

  case $- in
    *i*)
      mkdir -p "${HISTFILE%/*}"
      if [ -r "${XDG_CONFIG_HOME:-${HOME}/.config}/bash/bashrc" ]; then
        . "${XDG_CONFIG_HOME:-${HOME}/.config}/bash/bashrc"
      fi
      ;;
  esac
fi
