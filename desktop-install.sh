#!/bin/bash
# desktop-install.sh
#
# Installs the niri Wayland compositor and the Noctalia desktop shell on an
# Arch Linux system, and deploys the desktop configuration from this
# repository.
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
DEFAULT_SHELL_PACKAGES="noctalia noctalia-greeter kitty fish starship fastfetch jq btop dolphin kate konsole ark gwenview libgsf kio-admin purpose kdeconnect kwallet-pam systemsettings plasma-integration breeze darkly adw-gtk-theme papirus-icon-theme-git nwg-look ttf-jetbrains-mono-nerd inter-font xcursor-pro-cursor-theme"

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
# XKB layout and variant from --xkb-layout and --xkb-variant.
XKB_LAYOUT=""
XKB_VARIANT=""
# The layout without --xkb-layout, matching niri's 10-input-and-cursor.kdl.
DEFAULT_XKB_LAYOUT="us"
# Address from --address, which Noctalia geocodes for weather, night light and
# automatic dark mode. Empty leaves Noctalia without a location, its default.
LOCATION_ADDRESS=""
# Raw --display, --scale and --position entries, and the validated settings
# written to niri for each connector, in the order the connectors first appear.
DISPLAYS=()
SCALES=()
POSITIONS=()
declare -A OUTPUT_MODE=() OUTPUT_SCALE=() OUTPUT_POSITION=()
OUTPUT_ORDER=()
# Refresh rate for a --display entry without one.
DEFAULT_REFRESH_RATE="60.000"
# Set by the first step that changes the system. Earlier failures are argument
# and validation errors, which report themselves.
STARTED=0

# Repository files
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${SCRIPT_DIR}/logs"
WALLPAPERS_SRC="${SCRIPT_DIR}/assets/wallpapers"
DOTFILES_SRC="${SCRIPT_DIR}/dots"
GREETER_CONF_SRC="${SCRIPT_DIR}/defaults/noctalia-greeter/greeter.toml"
GREETD_CONF_SRC="${SCRIPT_DIR}/etc/greetd/config.toml"
GREETD_PAM_SRC="${SCRIPT_DIR}/etc/pam.d/greetd"

# Destinations
WALLPAPERS_DEST="${HOME}/Pictures/Wallpapers"
DOTFILES_DEST="${HOME}"
GREETER_STATE_DIR="/var/lib/noctalia-greeter"
NIRI_USER_EXTRA="${DOTFILES_DEST}/.config/niri/config.d/90-user-extra.kdl"
NOCTALIA_CONFIG="${DOTFILES_DEST}/.config/noctalia/10-default.toml"
# systemd's table of keyboard layouts, and the XKB rules listing every layout's
# variants, from xkeyboard-config.
KBD_MODEL_MAP="/usr/share/systemd/kbd-model-map"
XKB_RULES="/usr/share/X11/xkb/rules/evdev.lst"
# The kernel's connectors, named as niri names them, with their modes.
DRM_SYSFS="/sys/class/drm"

# Help text.
show_help() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  -h, --help                 Show this help message
  -l, --xkb-layout LAYOUT    XKB keyboard layout for niri, e.g. se
                             (default: the layout in the niri configuration)
  -x, --xkb-variant VARIANT  Variant of that layout, e.g. nodeadkeys
  -d, --display CONNECTOR:WIDTHxHEIGHT[@RATE]
                             Display mode for niri, e.g. DP-1:2560x1440@143.912;
                             repeatable. The refresh rate defaults to 60 Hz and
                             must match a mode in 'niri msg outputs' exactly
  -s, --scale CONNECTOR:SCALE
                             Display scale for niri, e.g. DP-1:1.5; repeatable
                             (default: niri's guess from the monitor size)
  -o, --position CONNECTOR:X,Y
                             Display position in logical pixels, e.g.
                             DP-4:2560,0; repeatable (default: niri's
                             automatic placement)
  -a, --address ADDRESS      Location for Noctalia, e.g. "Stockholm, Sweden"
                             (default: no location)
  -p, --packages PACKAGES    Additional packages to install (appended to defaults)
  -y, --yes                  Non-interactive mode, no confirmation prompts

Example:
  $(basename "$0") --xkb-layout se --display DP-1:3840x2160 --packages "firefox mpv"

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
    -l | --xkb-layout)
      require_value "$1" "${2:-}"
      XKB_LAYOUT="$2"
      shift 2
      ;;
    -x | --xkb-variant)
      require_value "$1" "${2:-}"
      XKB_VARIANT="$2"
      shift 2
      ;;
    -d | --display)
      require_value "$1" "${2:-}"
      DISPLAYS+=("$2")
      shift 2
      ;;
    -s | --scale)
      require_value "$1" "${2:-}"
      SCALES+=("$2")
      shift 2
      ;;
    -o | --position)
      require_value "$1" "${2:-}"
      POSITIONS+=("$2")
      shift 2
      ;;
    -a | --address)
      require_value "$1" "${2:-}"
      LOCATION_ADDRESS="$2"
      shift 2
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

# The layout must be one in systemd's keyboard table, and the variant one that
# xkeyboard-config defines for that layout.
validate_xkb_layout() {
  if [ -z "$XKB_LAYOUT" ]; then
    if [ -n "$XKB_VARIANT" ]; then
      print_error "Option --xkb-variant requires --xkb-layout."
      exit 1
    fi
    return 0
  fi

  if ! awk -v layout="$XKB_LAYOUT" '!/^#/ && NF { n = split($2, l, ","); for (i = 1; i <= n; i++) if (l[i] == layout) found = 1 } END { exit !found }' "$KBD_MODEL_MAP" 2>/dev/null; then
    print_error "Keyboard layout '${XKB_LAYOUT}' is not in ${KBD_MODEL_MAP}."
    exit 1
  fi

  [ -n "$XKB_VARIANT" ] || return 0

  if [ ! -f "$XKB_RULES" ]; then
    print_error "${XKB_RULES} is missing; install xkeyboard-config to validate the variant."
    exit 1
  fi
  if ! awk -v layout="$XKB_LAYOUT" -v variant="$XKB_VARIANT" '/^! /{ section = $2; next } section == "variant" && $1 == variant && $2 == layout ":" { found = 1 } END { exit !found }' "$XKB_RULES"; then
    print_error "Keyboard layout '${XKB_LAYOUT}' has no variant '${XKB_VARIANT}'."
    exit 1
  fi
}

# Every connector must exist and have a monitor attached, and a resolution
# must be one that monitor reports. The kernel lists no refresh rates, which
# leaves the rate unchecked; niri picks a mode itself when it does not match.
# niri rejects a scale outside 0 to 10, and stores positions as 32-bit
# integers.
validate_displays() {
  local entry connector resolution rate status_file
  for entry in "${DISPLAYS[@]}"; do
    if [[ ! "$entry" =~ ^([A-Za-z0-9-]+):([0-9]+x[0-9]+)(@([0-9]+(\.[0-9]{1,3})?))?$ ]]; then
      print_error "Invalid --display value '${entry}'; expected CONNECTOR:WIDTHxHEIGHT[@RATE]."
      exit 1
    fi
    connector="${BASH_REMATCH[1]}"
    resolution="${BASH_REMATCH[2]}"
    rate="${BASH_REMATCH[4]}"

    if [ -n "${OUTPUT_MODE[$connector]:-}" ]; then
      print_error "--display is given more than once for ${connector}."
      exit 1
    fi
    status_file=$(require_connected "$connector") || exit 1
    if ! grep -qx "$resolution" "$(dirname "$status_file")/modes"; then
      print_error "The monitor on ${connector} does not support ${resolution}. Supported: $(sort -u -V -r "$(dirname "$status_file")/modes" | tr '
' ' ')"
      exit 1
    fi

    OUTPUT_MODE[$connector]="${resolution}@${rate:-$DEFAULT_REFRESH_RATE}"
    add_output "$connector"
  done

  for entry in "${SCALES[@]}"; do
    if [[ ! "$entry" =~ ^([A-Za-z0-9-]+):([0-9]+(\.[0-9]+)?)$ ]] ||
      ! awk -v scale="${BASH_REMATCH[2]}" 'BEGIN { exit !(scale > 0 && scale <= 10) }'; then
      print_error "Invalid --scale value '${entry}'; expected CONNECTOR:SCALE, with a scale above 0 and at most 10."
      exit 1
    fi
    connector="${BASH_REMATCH[1]}"

    if [ -n "${OUTPUT_SCALE[$connector]:-}" ]; then
      print_error "--scale is given more than once for ${connector}."
      exit 1
    fi
    require_connected "$connector" >/dev/null

    OUTPUT_SCALE[$connector]="${BASH_REMATCH[2]}"
    add_output "$connector"
  done

  for entry in "${POSITIONS[@]}"; do
    if [[ ! "$entry" =~ ^([A-Za-z0-9-]+):(-?[0-9]{1,9}),(-?[0-9]{1,9})$ ]]; then
      print_error "Invalid --position value '${entry}'; expected CONNECTOR:X,Y with integer coordinates."
      exit 1
    fi
    connector="${BASH_REMATCH[1]}"

    if [ -n "${OUTPUT_POSITION[$connector]:-}" ]; then
      print_error "--position is given more than once for ${connector}."
      exit 1
    fi
    require_connected "$connector" >/dev/null

    OUTPUT_POSITION[$connector]="x=${BASH_REMATCH[2]} y=${BASH_REMATCH[3]}"
    add_output "$connector"
  done
}

# Prints the connector's status file, or exits when the connector does not
# exist or has no monitor attached.
require_connected() {
  local status_file
  status_file=$(find_connector_status "$1")
  if [ -z "$status_file" ]; then
    print_error "Unknown connector '${1}'. Connected: $(list_connected_displays)"
    exit 1
  fi
  if [ "$(cat "$status_file")" != "connected" ]; then
    print_error "No monitor is connected to ${1}. Connected: $(list_connected_displays)"
    exit 1
  fi
  echo "$status_file"
}

add_output() {
  local connector
  for connector in "${OUTPUT_ORDER[@]}"; do
    [ "$connector" != "$1" ] || return 0
  done
  OUTPUT_ORDER+=("$1")
}

# One line per connector, for the confirmation prompt and the summary.
describe_outputs() {
  local connector
  for connector in "${OUTPUT_ORDER[@]}"; do
    echo "${connector}${OUTPUT_MODE[$connector]:+ ${OUTPUT_MODE[$connector]}}${OUTPUT_SCALE[$connector]:+, scale ${OUTPUT_SCALE[$connector]}}${OUTPUT_POSITION[$connector]:+, position ${OUTPUT_POSITION[$connector]}}"
  done
}

# Connector entries are symbolic links named card<N>-<connector>. The exact
# name is compared, which keeps A-1 from matching HDMI-A-1.
find_connector_status() {
  local entry name
  for entry in "$DRM_SYSFS"/card*-*; do
    name="${entry##*/}"
    if [ "${name#card*-}" = "$1" ] && [ -f "$entry/status" ]; then
      echo "$entry/status"
      return 0
    fi
  done
}

list_connected_displays() {
  local entry name names=""
  for entry in "$DRM_SYSFS"/card*-*; do
    [ -f "$entry/status" ] || continue
    [ "$(cat "$entry/status")" = "connected" ] || continue
    name="${entry##*/}"
    names+="${name#card*-} "
  done
  names="${names% }"
  echo "${names:-none}"
}

# The address ends up in a TOML string, which double quotes, backslashes and
# control characters would break. Whether the address resolves is only known
# once Noctalia geocodes it.
validate_address() {
  if [[ "$LOCATION_ADDRESS" == *[\"\\]* || "$LOCATION_ADDRESS" =~ [[:cntrl:]] ]]; then
    print_error "The address must not contain double quotes, backslashes or control characters."
    exit 1
  fi
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
  for src in "$GREETER_CONF_SRC" "$GREETD_CONF_SRC" "$GREETD_PAM_SRC"; do
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
    echo "  - The Noctalia shell and greeter"
    echo "  - KDE and GTK theming, fonts and a cursor theme"
    echo "  - Applications: kitty, Dolphin, Kate, Konsole, Ark, Gwenview and KDE Connect"
    if [ -n "$EXTRA_PACKAGES" ]; then
      echo "  - Additional packages: $EXTRA_PACKAGES"
    fi
    echo "  - The greetd login manager with the Noctalia greeter, from the next boot"
    echo "  - Appearance sync to the greeter without a password prompt"
    echo "  - Wallpapers and configuration files copied to the home directory"
    if [ -n "$XKB_LAYOUT" ]; then
      echo "  - Keyboard layout in niri: ${XKB_LAYOUT}${XKB_VARIANT:+ ($XKB_VARIANT)}"
    fi
    local output
    while IFS= read -r output; do
      [ -n "$output" ] && echo "  - Display in niri: ${output}"
    done < <(describe_outputs)
    if [ -n "$LOCATION_ADDRESS" ]; then
      echo "  - Location in Noctalia: $LOCATION_ADDRESS"
    fi
    echo
    echo "WARNING: Existing files with the same names in ~/.config and ~/.local/share"
    echo "         will be overwritten."
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

  # The login screen uses the same keyboard layout as the niri session.
  local rendered
  rendered=$(mktemp)
  sed "s/@XKB_LAYOUT@/${XKB_LAYOUT:-$DEFAULT_XKB_LAYOUT}/" "$GREETER_CONF_SRC" >"$rendered"
  sudo install -m 0644 -o "$owner" -g "$group" "$rendered" "${GREETER_STATE_DIR}/greeter.toml"
  rm -f "$rendered"
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

  # Replaces the package's PAM file, which noctalia-greeter's install hook has
  # already patched; the repository's version includes that change.
  print_msg "Unlocking KWallet at login through PAM"
  sudo install -m 0644 "$GREETD_PAM_SRC" /etc/pam.d/greetd

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

# Merges dots/ into the home directory, which covers ~/.config and
# ~/.local/share. Files from the repository replace files of the same name, and
# every other file is left in place.
copy_dotfiles() {
  print_msg "Copying the configuration files to the home directory"
  mkdir -p "$DOTFILES_DEST"
  cp -rT "$DOTFILES_SRC" "$DOTFILES_DEST"
}

# Runs after copy_dotfiles, which restores the repository's version of the file
# and keeps a rerun from adding the block twice. niri reads 90-user-extra.kdl
# last, and its xkb section replaces the one in 10-input-and-cursor.kdl.
configure_keyboard_layout() {
  [ -n "$XKB_LAYOUT" ] || return 0

  print_msg "Setting the niri keyboard layout to ${XKB_LAYOUT}${XKB_VARIANT:+ ($XKB_VARIANT)}"
  {
    echo
    echo "// Keyboard layout set by desktop-install.sh."
    echo "input {"
    echo "    keyboard {"
    echo "        xkb {"
    echo "            layout \"${XKB_LAYOUT}\""
    if [ -n "$XKB_VARIANT" ]; then
      echo "            variant \"${XKB_VARIANT}\""
    fi
    echo "        }"
    echo "    }"
    echo "}"
  } >>"$NIRI_USER_EXTRA"
}

# Appended like the keyboard layout, after copy_dotfiles. Each connector gets
# one output section with the settings given for it; niri keeps its defaults
# for the rest.
configure_displays() {
  local connector
  for connector in "${OUTPUT_ORDER[@]}"; do
    print_msg "Configuring ${connector}"
    {
      echo
      echo "// Display settings set by desktop-install.sh."
      echo "output \"${connector}\" {"
      [ -z "${OUTPUT_MODE[$connector]:-}" ] || echo "    mode \"${OUTPUT_MODE[$connector]}\""
      [ -z "${OUTPUT_SCALE[$connector]:-}" ] || echo "    scale ${OUTPUT_SCALE[$connector]}"
      [ -z "${OUTPUT_POSITION[$connector]:-}" ] || echo "    position ${OUTPUT_POSITION[$connector]}"
      echo "}"
    } >>"$NIRI_USER_EXTRA"
  done
}

# Runs after copy_dotfiles, and also without --address, which leaves the
# address empty instead of the placeholder. The sed replacement escapes the
# characters sed treats specially: the delimiter and the ampersand.
configure_location() {
  local address="${LOCATION_ADDRESS//|/\\|}"
  address="${address//&/\\&}"

  [ -z "$LOCATION_ADDRESS" ] || print_msg "Setting the Noctalia location to ${LOCATION_ADDRESS}"
  sed -i "s|@LOCATION_ADDRESS@|${address}|" "$NOCTALIA_CONFIG"
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
  local output
  while IFS= read -r output; do
    [ -n "$output" ] && echo "${WHITE}Display:${NO_COLOR} ${output}"
  done < <(describe_outputs)
  if [ -n "$LOCATION_ADDRESS" ]; then
    echo "${WHITE}Location:${NO_COLOR} ${LOCATION_ADDRESS}"
  fi
  if [ -n "$XKB_LAYOUT" ]; then
    echo "${WHITE}Keyboard layout:${NO_COLOR} ${XKB_LAYOUT}${XKB_VARIANT:+ ($XKB_VARIANT)}"
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
  validate_xkb_layout
  validate_displays
  validate_address
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
  configure_keyboard_layout
  configure_displays
  configure_location

  print_summary
}

# Entry point.
main "$@"
