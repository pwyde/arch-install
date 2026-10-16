#!/bin/bash
# desktop-install.sh
#
# Installs the niri Wayland compositor and the Noctalia desktop shell on a
# system installed by arch-install.sh, and deploys the desktop configuration
# from this repository.
#
# Features:
# - niri with PipeWire audio, XDG desktop portals and Xwayland support
# - Noctalia shell and greeter, kitty, fonts and a cursor theme
# - XDG user directories
# - Wallpapers and dotfiles copied into the user's home directory
# - Error handling and validation
#
# Usage: ./desktop-install.sh [options]
# See --help for available options

set -euo pipefail

# The Wayland compositor and the session services it relies on.
DEFAULT_COMPOSITOR_PACKAGES="niri nirimod-git pipewire pipewire-jack pipewire-pulse pipewire-alsa wireplumber wl-clipboard xdg-desktop-portal xdg-desktop-portal-gnome xdg-desktop-portal-gtk xdg-desktop-portal-kde xdg-user-dirs xdg-utils xwayland-satellite ddcutil playerctl brightnessctl"
# The desktop shell and the applications and themes it is configured for.
DEFAULT_SHELL_PACKAGES="noctalia noctalia-greeter kitty dolphin plasma-integration breeze ttf-jetbrains-mono-nerd xcursor-pro-cursor-theme"

# Terminal colors.
RED=$'\033[91m'
GREEN=$'\033[92m'
# 24-bit #1793D1, the Arch blue used by the Limine menu and the Plymouth theme.
BLUE=$'\033[38;2;23;147;209m'
YELLOW=$'\033[93m'
WHITE=$'\033[1;97m'
NO_COLOR=$'\033[0m'

trap report_failure EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

print_msg() {
  echo -e "${GREEN}==>${NO_COLOR}${WHITE}" "${@}" "${NO_COLOR}" >&1
}

print_warning() {
  echo -e "${YELLOW}==> WARNING:${NO_COLOR}${WHITE}" "${@}" "${NO_COLOR}" >&2
}

print_error() {
  echo -e "${RED}==> ERROR:${NO_COLOR}${WHITE}" "${@}" "${NO_COLOR}" >&2
}

# Reports a failed run. Nothing needs undoing: each package installation is a
# single pacman transaction, and the copies can be repeated.
report_failure() {
  local exit_code=$?

  if [ "$exit_code" -ne 0 ] && [ "${STARTED:-0}" -eq 1 ]; then
    print_error "Script exited with error code $exit_code."
    print_msg "The script can be run again once the error is resolved."
  fi
}

# Global variables
EXTRA_PACKAGES=""
NON_INTERACTIVE=0
# Set by the first step that changes the system. Earlier failures are argument
# and validation errors, which report themselves.
STARTED=0

# Repository files
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${SCRIPT_DIR}/logs"
WALLPAPERS_SRC="${SCRIPT_DIR}/assets/wallpapers"
DOTFILES_SRC="${SCRIPT_DIR}/dots/.config"
GREETER_CONF_SRC="${SCRIPT_DIR}/defaults/noctalia-greeter/greeter.toml"
GREETD_CONF_SRC="${SCRIPT_DIR}/etc/greetd/config.toml"

# Destinations
WALLPAPERS_DEST="${HOME}/Pictures/Wallpapers"
DOTFILES_DEST="${HOME}/.config"
GREETER_STATE_DIR="/var/lib/noctalia-greeter"

# Help text.
show_help() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  -h, --help                 Show this help message
  -p, --packages PACKAGES    Additional packages to install (appended to defaults)
  -y, --yes                  Non-interactive mode, no confirmation prompts

Example:
  $(basename "$0") --packages "firefox mpv"

EOF
  exit 0
}

# Every option below takes a value. Without this check, an omitted value fails
# with a bare "$2: unbound variable" from set -u, which does not name the
# option.
require_value() {
  if [ -z "${2:-}" ]; then
    print_error "Option $1 requires a value."
    print_msg "Run with --help for the available options."
    exit 1
  fi
}

# Parses the command-line options.
parse_args() {
  while [[ $# -gt 0 ]]; do
    case $1 in
    -h | --help)
      show_help
      ;;
    -p | --packages)
      require_value "$1" "${2:-}"
      EXTRA_PACKAGES="$2"
      shift 2
      ;;
    -y | --yes)
      NON_INTERACTIVE=1
      shift
      ;;
    *)
      print_error "Unknown option: $1"
      print_msg "Run with --help for the available options."
      exit 1
      ;;
    esac
  done
}

# Validates the environment and the repository files.
validate_inputs() {
  # makepkg refuses to run as root, and the copies belong to the user.
  if [ "$EUID" -eq 0 ]; then
    print_error "This script must be run as the regular user, not as root."
    exit 1
  fi

  # Tools required on the installed system.
  local cmd
  for cmd in paru sudo cp; do
    if ! command -v "$cmd" &>/dev/null; then
      print_error "Required command not found: $cmd"
      exit 1
    fi
  done

  # Everything the script copies out of this repository.
  local src
  for src in "$WALLPAPERS_SRC" "$DOTFILES_SRC"; do
    if [ ! -d "$src" ]; then
      print_error "Missing repository directory: $src"
      print_error "Run the script from a full checkout of the repository."
      exit 1
    fi
  done
  for src in "$GREETER_CONF_SRC" "$GREETD_CONF_SRC"; do
    if [ ! -f "$src" ]; then
      print_error "Missing repository file: $src"
      print_error "Run the script from a full checkout of the repository."
      exit 1
    fi
  done
}

# Asks for confirmation before anything is installed or overwritten.
confirm_operation() {
  if [ "$NON_INTERACTIVE" -eq 0 ]; then
    echo "The following will be installed and configured:"
    echo "  - The niri compositor and its session services"
    echo "  - The Noctalia shell and greeter, kitty, Dolphin, KDE theming, a font and a cursor theme"
    if [ -n "$EXTRA_PACKAGES" ]; then
      echo "  - Additional packages: $EXTRA_PACKAGES"
    fi
    echo "  - The greetd login manager with the Noctalia greeter, from the next boot"
    echo "  - Appearance sync to the greeter without a password prompt"
    echo "  - Wallpapers and configuration files copied to the home directory"
    echo
    echo "WARNING: Existing files with the same names in $DOTFILES_DEST will be overwritten."
    read -r -p "Are you sure you want to continue? (y/N) " REPLY
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
      echo "Installation cancelled."
      exit 1
    fi
  fi
}

# Installs packages with paru, which resolves both the official repositories
# and the AUR.
paru_install() {
  local -a flags=(--needed)
  if [ "$NON_INTERACTIVE" -eq 1 ]; then
    flags+=(--noconfirm --skipreview)
  fi

  # shellcheck disable=SC2086
  paru -S "${flags[@]}" $1
}

# Upgrades the system first. Installing from a stale package database risks a
# partial upgrade, which Arch does not support.
update_system() {
  STARTED=1
  print_msg "Upgrading the system"

  local -a flags=()
  if [ "$NON_INTERACTIVE" -eq 1 ]; then
    flags+=(--noconfirm)
  fi

  paru -Syu "${flags[@]}"
}

install_compositor() {
  print_msg "Installing the niri compositor"
  paru_install "$DEFAULT_COMPOSITOR_PACKAGES"
}

install_desktop_shell() {
  print_msg "Installing the Noctalia desktop shell"
  paru_install "$DEFAULT_SHELL_PACKAGES"
}

# The package's install hook creates the state directory, mode 0750 and owned
# by the greetd user, which appearance sync requires. greeter.toml takes the
# same owner with mode 0644, as upstream sets it. The hook rewrites the file on
# every upgrade but keeps its settings.
install_greeter_config() {
  print_msg "Installing the greeter configuration"

  local owner group
  if ! owner=$(stat -c '%U' "$GREETER_STATE_DIR" 2>/dev/null); then
    print_error "$GREETER_STATE_DIR does not exist; the noctalia-greeter install hook did not run."
    exit 1
  fi
  if [ "$owner" = "root" ]; then
    print_error "$GREETER_STATE_DIR is owned by root instead of the greetd user."
    print_error "Repair it with: sudo /usr/share/noctalia-greeter/setup_greeter_system.sh"
    exit 1
  fi
  group=$(stat -c '%G' "$GREETER_STATE_DIR")

  sudo install -m 0644 -o "$owner" -g "$group" "$GREETER_CONF_SRC" "${GREETER_STATE_DIR}/greeter.toml"
}

# Only enabled: starting greetd now would stop getty@tty1, and with it a login
# session on the first virtual terminal.
#
# In a virtual machine, wlroots draws the greeter's cursor upside down on the
# virtio-gpu hardware cursor plane (wlroots issue 3921). The greeter's
# compositor then draws the cursor itself instead.
configure_greetd() {
  print_msg "Configuring greetd to start the Noctalia greeter"
  sudo install -D -m 0644 "$GREETD_CONF_SRC" /etc/greetd/config.toml

  if systemd-detect-virt --vm --quiet; then
    print_msg "Virtual machine detected; disabling hardware cursors in the greeter"
    sudo sed -i 's|^command = "/usr/bin/noctalia-greeter-session"$|command = "env WLR_NO_HARDWARE_CURSORS=1 /usr/bin/noctalia-greeter-session"|' /etc/greetd/config.toml
    if ! sudo grep -q 'WLR_NO_HARDWARE_CURSORS=1' /etc/greetd/config.toml; then
      print_warning "Could not disable hardware cursors; the greeter cursor may appear upside down."
    fi
  fi

  sudo systemctl enable greetd.service
}

# Adds a Polkit rule that lets this account sync its appearance to the greeter
# without an administrator prompt. The rule covers only the constrained sync
# action. Not fatal: without it, each sync asks for the password instead.
enable_passwordless_sync() {
  local user
  user=$(id -un)

  print_msg "Enabling passwordless appearance sync for ${user}"
  if ! sudo noctalia-greeter passwordless-sync enable "$user"; then
    print_warning "Passwordless sync could not be enabled; each sync will ask for the password."
  fi
}

install_extra_packages() {
  if [ -n "$EXTRA_PACKAGES" ]; then
    print_msg "Installing additional packages"
    paru_install "$EXTRA_PACKAGES"
  fi
}

# Creates ~/Pictures and the other XDG user directories, and records them in
# ~/.config/user-dirs.dirs.
create_user_dirs() {
  print_msg "Creating the XDG user directories"
  xdg-user-dirs-update
}

copy_wallpapers() {
  print_msg "Copying the wallpapers to $WALLPAPERS_DEST"
  mkdir -p "$WALLPAPERS_DEST"
  cp -rT "$WALLPAPERS_SRC" "$WALLPAPERS_DEST"
}

# Merges into ~/.config: files from the repository replace files of the same
# name, and every other file is left in place.
copy_dotfiles() {
  print_msg "Copying the configuration files to $DOTFILES_DEST"
  mkdir -p "$DOTFILES_DEST"
  cp -rT "$DOTFILES_SRC" "$DOTFILES_DEST"
}

# Re-runs the script under script(1), which records everything printed on the
# terminal to the log. Typed passwords are never logged: input is not
# recorded, and password prompts do not echo.
#
# The timestamp in the file name is the first run's. A later run in the same
# checkout appends to that file, and script(1) marks where each run starts and
# ends.
start_logging() {
  local arg
  for arg in "$@"; do
    case "$arg" in -h | --help) return 0 ;; esac
  done

  if ! command -v script &>/dev/null; then
    print_warning "script(1) is not available; continuing without a log file."
    return 0
  fi

  mkdir -p "$LOG_DIR"
  local log_file
  log_file=$(find "$LOG_DIR" -maxdepth 1 -name 'desktop-install-*.log' | sort | tail -n 1)
  if [ -z "$log_file" ]; then
    log_file="${LOG_DIR}/desktop-install-$(date +%Y%m%d-%H%M%S).log"
  fi
  print_msg "Logging to ${log_file}"

  # script(1) runs the command through $SHELL; bash, to match the quoting.
  local command
  command=$(printf '%q ' env DESKTOP_INSTALL_LOG="$log_file" "${SCRIPT_DIR}/$(basename "$0")" "$@")
  exec env SHELL=/bin/bash script --quiet --append --flush --return --command "$command" "$log_file"
}

print_logo() {
  # Colour is set around the heredoc rather than inside it: the heredoc stays
  # quoted, and the art is never subject to expansion.
  printf '%s' "$BLUE"
  cat <<'EOF'
                    ▄
                   ▟█▙
                  ▟███▙
                 ▟█████▙
                ▟███████▙
               ▂▔▀▜██████▙
              ▟██▅▂▝▜█████▙
             ▟█████████████▙
            ▟███████████████▙
           ▟█████████████████▙
          ▟███████████████████▙
         ▟█████████▛▀▀▜████████▙
        ▟████████▛      ▜███████▙
       ▟█████████        ████████▙
      ▟██████████        █████▆▅▄▃▂
     ▟██████████▛        ▜█████████▙
    ▟██████▀▀▀              ▀▀██████▙
   ▟███▀▘                       ▝▀███▙
  ▟▛▀                               ▀▜▙

EOF
  printf '%s' "$NO_COLOR"
  echo "${WHITE}===${BLUE} DESKTOP iNSTALLATiON SCRiPT ${WHITE}===${NO_COLOR}"
  echo
}

# Prints the installation summary.
print_summary() {
  echo
  echo "${WHITE}===${BLUE} iNSTALLATiON SUMMARY ${WHITE}===${NO_COLOR}"
  echo "${WHITE}Compositor:${NO_COLOR} niri"
  echo "${WHITE}Desktop shell:${NO_COLOR} Noctalia"
  if [ -n "$EXTRA_PACKAGES" ]; then
    echo "${WHITE}Additional packages:${NO_COLOR} ${EXTRA_PACKAGES}"
  fi
  echo
  echo "${BLUE}==>${WHITE} Done. Reboot to start the greeter.${NO_COLOR}"
}

# Runs every installation step in order.
main() {
  if [ -z "${DESKTOP_INSTALL_LOG:-}" ]; then
    start_logging "$@"
  fi

  print_logo

  parse_args "$@"

  validate_inputs
  confirm_operation

  update_system
  install_compositor
  install_desktop_shell
  install_extra_packages

  install_greeter_config
  configure_greetd
  enable_passwordless_sync

  create_user_dirs
  copy_wallpapers
  copy_dotfiles

  print_summary
}

# Entry point.
main "$@"
