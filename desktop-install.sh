#!/bin/bash
# desktop-install.sh
#
# Installs the niri Wayland compositor and the Noctalia desktop shell on an
# Arch Linux system, and deploys the desktop configuration from this
# repository.
#
# Features:
# - niri with PipeWire audio, XDG desktop portals and Xwayland support
# - Noctalia shell and greeter, with themes, fonts and a cursor theme
# - KDE applications, browsers, office, graphics and development tools
# - kitty, fish, Neovim and command-line tools
# - XDG user directories
# - Wallpapers and dotfiles copied into the user's home directory
# - Error handling and validation
#
# Usage: ./desktop-install.sh [options]
# See --help for available options

set -euo pipefail

# The Wayland compositor and the session services it relies on.
readonly DEFAULT_COMPOSITOR_PACKAGES=(
  niri
  nirimod-git
  pipewire
  pipewire-jack
  pipewire-pulse
  pipewire-alsa
  wireplumber
  wl-clipboard
  xdg-desktop-portal
  xdg-desktop-portal-gnome
  xdg-desktop-portal-gtk
  xdg-desktop-portal-kde
  xdg-user-dirs
  xdg-utils
  xwayland-satellite
  ddcutil
  playerctl
  brightnessctl
)
# The desktop shell and its greeter.
readonly DEFAULT_NOCTALIA_PACKAGES=(
  noctalia
  noctalia-greeter
)
# The terminal, the login shell and the tools shown in them. exiftool gives
# superfile its metadata, and jq reads the VSCodium extension list.
readonly DEFAULT_TERMINAL_PACKAGES=(
  kitty
  fish
  starship
  fastfetch
  jq
  btop
  superfile
  perl-image-exiftool
)
# KDE applications, and the services and integration they rely on outside
# Plasma.
readonly DEFAULT_KDE_PACKAGES=(
  dolphin
  kate
  konsole
  ark
  gwenview
  okular
  haruna
  libgsf
  kio-admin
  purpose
  kdeconnect
  kwallet-pam
  systemsettings
  plasma-integration
)
# Web browsers, and the Pywalfox host that colors Firefox from Noctalia.
readonly DEFAULT_BROWSER_PACKAGES=(
  firefox
  chromium
  zen-browser-bin
  python-pywalfox
)
# Office suite with English spelling dictionaries, and graphics editors.
readonly DEFAULT_OFFICE_PACKAGES=(
  gimp
  inkscape
  libreoffice-fresh
  hunspell-en_us
  hunspell-en_gb
)
# VSCodium, with the Visual Studio Marketplace for its extensions.
readonly DEFAULT_DEVELOPMENT_PACKAGES=(
  vscodium-bin
  vscodium-bin-marketplace
)
# Qt and GTK themes, icons and the cursor theme.
readonly DEFAULT_THEME_PACKAGES=(
  breeze
  darkly
  adw-gtk-theme
  papirus-icon-theme-git
  nwg-look
  xcursor-pro-cursor-theme
)
# Fonts for the desktop and terminal, emoji, and fallbacks for web pages.
readonly DEFAULT_FONT_PACKAGES=(
  ttf-jetbrains-mono-nerd
  inter-font
  noto-fonts
  noto-fonts-emoji
  ttf-liberation
)
# Command-line tools.
readonly DEFAULT_CLI_PACKAGES=(
  bat
  bat-extras
  duf
  dust
  eza
  fd
  fzf
  glow
  procs
  ripgrep
  zoxide
)
# Neovim with LazyVim, and the tools its plugins rely on: lazygit, Lua and
# luarocks for plugins with rocks, tree-sitter-cli for the syntax parsers and
# unzip for language servers installed by Mason.
readonly DEFAULT_NEOVIM_PACKAGES=(
  neovim
  lazygit
  lua51
  luarocks
  tree-sitter-cli
  unzip
)

# Terminal colors.
readonly RED=$'\033[91m'
readonly GREEN=$'\033[92m'
# 24-bit #1793D1, the Arch blue used by the Limine menu and the Plymouth theme.
readonly BLUE=$'\033[38;2;23;147;209m'
readonly YELLOW=$'\033[93m'
readonly WHITE=$'\033[1;97m'
readonly NO_COLOR=$'\033[0m'

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

print_msg() {
  echo "${GREEN}==>${NO_COLOR}${WHITE}" "$*${NO_COLOR}"
}

print_warning() {
  echo "${YELLOW}==> WARNING:${NO_COLOR}${WHITE}" "$*${NO_COLOR}" >&2
}

print_error() {
  echo "${RED}==> ERROR:${NO_COLOR}${WHITE}" "$*${NO_COLOR}" >&2
}

# Removes the temporary file and reports a failed run. Nothing needs undoing:
# each package installation is a single pacman transaction, and the copies can
# be repeated.
cleanup() {
  local exit_code=$?

  # Left only if a step failed while it was in use.
  [[ -z "${TEMP_FILE:-}" ]] || rm -f "${TEMP_FILE}"

  if [[ "${exit_code}" -ne 0 ]] && [[ "${STARTED:-0}" -eq 1 ]]; then
    print_error "Script exited with error code ${exit_code}."
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
readonly DEFAULT_XKB_LAYOUT="us"
# Address from --address, which Noctalia geocodes for weather, night light and
# automatic dark mode. Empty leaves Noctalia without a location, its default.
LOCATION_ADDRESS=""
# Raw --display, --scale and --position entries, and the validated settings
# written to niri for each connector, in the order the connectors first appear.
DISPLAYS=()
SCALES=()
POSITIONS=()
declare -A OUTPUT_MODE=() OUTPUT_RATE=() OUTPUT_SCALE=() OUTPUT_POSITION=()
OUTPUT_ORDER=()
# Refresh rate for a --display entry without one.
readonly DEFAULT_REFRESH_RATE="60.000"
# Set by the first step that changes the system. Earlier failures are argument
# and validation errors, which report themselves.
STARTED=0
# Temporary file of configure_swedish_binds, removed by cleanup on failure.
TEMP_FILE=""

# Repository files
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly LOG_DIR="${SCRIPT_DIR}/logs"
readonly WALLPAPERS_SRC="${SCRIPT_DIR}/assets/wallpapers"
readonly DOTFILES_SRC="${SCRIPT_DIR}/dots"
readonly GREETER_CONF_SRC="${SCRIPT_DIR}/defaults/noctalia-greeter/greeter.toml"
readonly GREETD_CONF_SRC="${SCRIPT_DIR}/etc/greetd/config.toml"
readonly GREETD_PAM_SRC="${SCRIPT_DIR}/etc/pam.d/greetd"
readonly FONTCONFIG_SRC="${SCRIPT_DIR}/etc/fonts/conf.d/50-generic-families.conf"
readonly NIRI_SESSION_SRC="${SCRIPT_DIR}/defaults/wayland-sessions/niri.desktop"

# Destinations
readonly WALLPAPERS_DEST="${HOME}/Pictures/Wallpapers"
readonly DOTFILES_DEST="${HOME}"
readonly GREETER_STATE_DIR="/var/lib/noctalia-greeter"
readonly FISH_SHELL="/usr/bin/fish"
readonly NIRI_USER_EXTRA="${DOTFILES_DEST}/.config/niri/config.d/90-user-extra.kdl"
readonly NIRI_BINDS="${DOTFILES_DEST}/.config/niri/config.d/70-binds.kdl"
readonly NOCTALIA_CONFIG="${DOTFILES_DEST}/.config/noctalia/10-default.toml"
readonly NOCTALIA_LOCKSCREEN="${DOTFILES_DEST}/.config/noctalia/20-lockscreen-widgets.toml"
readonly GTK3_SETTINGS="${DOTFILES_DEST}/.config/gtk-3.0/settings.ini"
# VSCodium's portable data, as ~/.config/environment.d/60-vscodium.conf sets it.
readonly VSCODIUM_DATA="${XDG_DATA_HOME:-${HOME}/.local/share}/vscodium"
# The extensions to install, under "recommendations", from copy_dotfiles. Not
# extensions/extensions.json, which is VSCodium's own record of what it has
# installed.
readonly VSCODIUM_EXTENSIONS="${VSCODIUM_DATA}/extensions.json"
# systemd's table of keyboard layouts, and the XKB rules listing every layout's
# variants, from xkeyboard-config.
readonly KBD_MODEL_MAP="/usr/share/systemd/kbd-model-map"
readonly XKB_RULES="/usr/share/X11/xkb/rules/evdev.lst"
# The kernel's connectors, named as niri names them, with their modes.
readonly DRM_SYSFS="/sys/class/drm"

# Help text.
show_help() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  -a, --address ADDRESS      Location for Noctalia, e.g.
                             "London, United Kingdom" (default: no location)
  -d, --display CONNECTOR:WIDTHxHEIGHT[@RATE]
                             Display mode for niri, e.g. DP-1:1920x1080@164.999;
                             repeatable. The refresh rate defaults to 60 Hz and
                             must match a mode in 'niri msg outputs' exactly
  -l, --xkb-layout LAYOUT    XKB keyboard layout for niri, e.g. gb
                             (default: the layout in the niri configuration)
  -o, --position CONNECTOR:X,Y
                             Display position in logical pixels, e.g.
                             DP-2:1920,0; repeatable (default: niri's
                             automatic placement)
  -p, --packages PACKAGES    Additional packages to install, space-separated
                             (appended to defaults)
  -s, --scale CONNECTOR:SCALE
                             Display scale for niri, e.g. DP-1:1.5; repeatable
                             (default: niri's guess from the monitor size)
  -x, --xkb-variant VARIANT  Variant of the --xkb-layout layout, e.g.
                             nodeadkeys
  -y, --yes                  Non-interactive mode, no confirmation prompts
  -h, --help                 Show this help message

Example:
  $(basename "$0") --xkb-layout gb --display DP-1:1920x1080 \\
    --packages "vlc spotify"

EOF
  exit 0
}

# Every option below takes a value. Without this check, an omitted value fails
# with a bare "$2: unbound variable" from set -u, which does not name the
# option.
require_value() {
  if [[ -z "${2:-}" ]]; then
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
  if [[ -z "${XKB_LAYOUT}" ]]; then
    if [[ -n "${XKB_VARIANT}" ]]; then
      print_error "Option --xkb-variant requires --xkb-layout."
      exit 1
    fi
    return 0
  fi

  if ! awk -v layout="${XKB_LAYOUT}" '
      !/^#/ && NF {
        n = split($2, l, ",")
        for (i = 1; i <= n; i++) if (l[i] == layout) found = 1
      }
      END { exit !found }
    ' "${KBD_MODEL_MAP}" 2>/dev/null; then
    print_error "Keyboard layout '${XKB_LAYOUT}' is not in ${KBD_MODEL_MAP}."
    exit 1
  fi

  [[ -n "${XKB_VARIANT}" ]] || return 0

  if [[ ! -f "${XKB_RULES}" ]]; then
    print_error "${XKB_RULES} is missing; install xkeyboard-config to" \
      "validate the variant."
    exit 1
  fi
  if ! awk -v layout="${XKB_LAYOUT}" -v variant="${XKB_VARIANT}" '
      /^! / { section = $2; next }
      section == "variant" && $1 == variant && $2 == layout ":" { found = 1 }
      END { exit !found }
    ' "${XKB_RULES}"; then
    print_error "Keyboard layout '${XKB_LAYOUT}' has no variant" \
      "'${XKB_VARIANT}'."
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
  local display_re='^([A-Za-z0-9-]+):([0-9]+x[0-9]+)'
  display_re+='(@([0-9]+(\.[0-9]{1,3})?))?$'
  local scale_re='^([A-Za-z0-9-]+):([0-9]+(\.[0-9]+)?)$'
  local position_re='^([A-Za-z0-9-]+):(-?[0-9]{1,9}),(-?[0-9]{1,9})$'
  for entry in "${DISPLAYS[@]}"; do
    if [[ ! "${entry}" =~ ${display_re} ]]; then
      print_error "Invalid --display value '${entry}'; expected" \
        "CONNECTOR:WIDTHxHEIGHT[@RATE]."
      exit 1
    fi
    connector="${BASH_REMATCH[1]}"
    resolution="${BASH_REMATCH[2]}"
    rate="${BASH_REMATCH[4]}"

    if [[ -n "${OUTPUT_MODE[${connector}]:-}" ]]; then
      print_error "--display is given more than once for ${connector}."
      exit 1
    fi
    status_file=$(require_connected "${connector}") || exit 1
    if ! grep -qx "${resolution}" "$(dirname "${status_file}")/modes"; then
      print_error "The monitor on ${connector} does not support" \
        "${resolution}. Supported:" \
        "$(sort -u -V -r "$(dirname "${status_file}")/modes" | paste -sd ' ')"
      exit 1
    fi

    OUTPUT_MODE[${connector}]="${resolution}@${rate:-${DEFAULT_REFRESH_RATE}}"
    OUTPUT_RATE[${connector}]="${rate}"
    add_output "${connector}"
  done

  for entry in "${SCALES[@]}"; do
    if [[ ! "${entry}" =~ ${scale_re} ]] \
      || ! awk -v scale="${BASH_REMATCH[2]}" \
        'BEGIN { exit !(scale > 0 && scale <= 10) }'; then
      print_error "Invalid --scale value '${entry}'; expected" \
        "CONNECTOR:SCALE, with a scale above 0 and at most 10."
      exit 1
    fi
    connector="${BASH_REMATCH[1]}"

    if [[ -n "${OUTPUT_SCALE[${connector}]:-}" ]]; then
      print_error "--scale is given more than once for ${connector}."
      exit 1
    fi
    require_connected "${connector}" >/dev/null

    OUTPUT_SCALE[${connector}]="${BASH_REMATCH[2]}"
    add_output "${connector}"
  done

  for entry in "${POSITIONS[@]}"; do
    if [[ ! "${entry}" =~ ${position_re} ]]; then
      print_error "Invalid --position value '${entry}'; expected" \
        "CONNECTOR:X,Y with integer coordinates."
      exit 1
    fi
    connector="${BASH_REMATCH[1]}"

    if [[ -n "${OUTPUT_POSITION[${connector}]:-}" ]]; then
      print_error "--position is given more than once for ${connector}."
      exit 1
    fi
    require_connected "${connector}" >/dev/null

    OUTPUT_POSITION[${connector}]="x=${BASH_REMATCH[2]} y=${BASH_REMATCH[3]}"
    add_output "${connector}"
  done
}

# Prints the connector's status file, or exits when the connector does not
# exist or has no monitor attached.
require_connected() {
  local status_file
  status_file=$(find_connector_status "$1")
  if [[ -z "${status_file}" ]]; then
    print_error "Unknown connector '${1}'. Connected:" \
      "$(list_connected_displays)"
    exit 1
  fi
  if [[ "$(<"${status_file}")" != "connected" ]]; then
    print_error "No monitor is connected to ${1}. Connected:" \
      "$(list_connected_displays)"
    exit 1
  fi
  echo "${status_file}"
}

add_output() {
  local connector
  for connector in "${OUTPUT_ORDER[@]}"; do
    [[ "${connector}" != "$1" ]] || return 0
  done
  OUTPUT_ORDER+=("$1")
}

# One line per connector, for the confirmation prompt and the summary.
describe_outputs() {
  local connector mode scale position line
  for connector in "${OUTPUT_ORDER[@]}"; do
    mode="${OUTPUT_MODE[${connector}]:-}"
    scale="${OUTPUT_SCALE[${connector}]:-}"
    position="${OUTPUT_POSITION[${connector}]:-}"
    line="${connector}${mode:+ ${mode}}${scale:+, scale ${scale}}"
    line+="${position:+, position ${position}}"
    echo "${line}"
  done
}

# Connector entries are symbolic links named card<N>-<connector>. The exact
# name is compared, which keeps A-1 from matching HDMI-A-1.
find_connector_status() {
  local entry name
  for entry in "${DRM_SYSFS}"/card*-*; do
    name="${entry##*/}"
    if [[ "${name#card*-}" == "$1" ]] && [[ -f "${entry}/status" ]]; then
      echo "${entry}/status"
      return 0
    fi
  done
}

list_connected_displays() {
  local entry name names=""
  for entry in "${DRM_SYSFS}"/card*-*; do
    [[ -f "${entry}/status" ]] || continue
    [[ "$(<"${entry}/status")" == "connected" ]] || continue
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
  if [[ "${LOCATION_ADDRESS}" == *[\"\\]* \
    || "${LOCATION_ADDRESS}" =~ [[:cntrl:]] ]]; then
    print_error "The address must not contain double quotes, backslashes or" \
      "control characters."
    exit 1
  fi
}

# Package names as pacman defines them, optionally prefixed with a repository;
# a leading '-' would turn an entry into an option to paru. paru -Si knows the
# sync databases and the AUR, but not groups. The databases are those before
# the upgrade, so a package added to the repositories since the last sync is
# not found.
validate_packages() {
  local pattern='^([a-z0-9_-]+/)?[a-z0-9@_+][a-z0-9@._+-]*$' pkg
  local -a pkgs

  read -ra pkgs <<<"${EXTRA_PACKAGES}"
  for pkg in "${pkgs[@]}"; do
    if [[ ! "${pkg}" =~ ${pattern} ]]; then
      print_error "Invalid package name '${pkg}'."
      exit 1
    fi
    if ! paru -Si -- "${pkg}" &>/dev/null \
      && ! pacman -Sg -- "${pkg}" &>/dev/null; then
      print_error "Package '${pkg}' was found neither in the sync databases" \
        "nor in the AUR."
      print_error "A package added recently is found after a system" \
        "upgrade with 'paru -Syu'."
      exit 1
    fi
  done
}

# Validates the environment and the repository files.
validate_inputs() {
  # makepkg refuses to run as root, and the copies belong to the user.
  if [[ "${EUID}" -eq 0 ]]; then
    print_error "This script must be run as the regular user, not as root."
    exit 1
  fi

  # Tools required on the installed system.
  local cmd
  for cmd in paru sudo cp; do
    if ! command -v "${cmd}" &>/dev/null; then
      print_error "Required command not found: ${cmd}"
      exit 1
    fi
  done

  # greetd is enabled as display-manager.service, an alias that systemctl
  # enable does not take over from another display manager.
  local dm_link="/etc/systemd/system/display-manager.service" display_manager
  if [[ -L "${dm_link}" ]]; then
    display_manager=$(readlink "${dm_link}")
    display_manager="${display_manager##*/}"
    if [[ "${display_manager}" != "greetd.service" ]]; then
      print_error "${display_manager} is enabled as the display manager," \
        "which greetd would replace."
      if [[ -e "${dm_link}" ]]; then
        print_error "Disable it first: sudo systemctl disable" \
          "${display_manager}"
      else
        # pacman removes a package without disabling its services.
        print_error "Its unit no longer exists. Remove the leftover link" \
          "first: sudo rm ${dm_link}"
      fi
      exit 1
    fi
  fi

  # Everything the script copies out of this repository.
  local src
  for src in "${WALLPAPERS_SRC}" "${DOTFILES_SRC}"; do
    if [[ ! -d "${src}" ]]; then
      print_error "Missing repository directory: ${src}"
      print_error "Run the script from a full checkout of the repository."
      exit 1
    fi
  done
  local -a repo_files=(
    "${GREETER_CONF_SRC}"
    "${GREETD_CONF_SRC}"
    "${GREETD_PAM_SRC}"
    "${FONTCONFIG_SRC}"
    "${NIRI_SESSION_SRC}"
  )
  for src in "${repo_files[@]}"; do
    if [[ ! -f "${src}" ]]; then
      print_error "Missing repository file: ${src}"
      print_error "Run the script from a full checkout of the repository."
      exit 1
    fi
  done
}

# Asks for confirmation before anything is installed or overwritten.
confirm_operation() {
  if [[ "${NON_INTERACTIVE}" -eq 0 ]]; then
    echo "The following will be installed and configured:"
    echo "  - The niri compositor, the Noctalia shell and its greeter"
    echo "  - KDE applications, browsers, LibreOffice, GIMP, Inkscape and" \
      "VSCodium"
    echo "  - kitty, fish, Neovim with LazyVim and command-line tools"
    echo "  - Qt and GTK themes, icons, fonts and a cursor theme"
    if [[ -n "${EXTRA_PACKAGES}" ]]; then
      echo "  - Additional packages: ${EXTRA_PACKAGES}"
    fi
    echo "  - The greetd login manager with the Noctalia greeter, from the" \
      "next boot"
    echo "  - Appearance sync to the greeter without a password prompt"
    echo "  - Fish as the login shell"
    echo "  - Wallpapers and configuration files copied to the home directory"
    if [[ -n "${XKB_LAYOUT}" ]]; then
      echo "  - Keyboard layout in niri:" \
        "${XKB_LAYOUT}${XKB_VARIANT:+ (${XKB_VARIANT})}"
    fi
    local output
    while IFS= read -r output; do
      [[ -n "${output}" ]] && echo "  - Display in niri: ${output}"
    done < <(describe_outputs)
    if [[ -n "${LOCATION_ADDRESS}" ]]; then
      echo "  - Location in Noctalia: ${LOCATION_ADDRESS}"
    fi
    echo
    echo "WARNING: Existing files with the same names in ~/.config" \
      "and ~/.local/share"
    echo "         will be overwritten."
    read -r -p "Are you sure you want to continue? (y/N) " REPLY
    echo
    if [[ ! ${REPLY} =~ ^[Yy]$ ]]; then
      echo "Installation cancelled."
      exit 1
    fi
  fi
}

# Installs the packages given as arguments with paru, which resolves both the
# official repositories and the AUR.
paru_install() {
  local -a flags=(--needed)
  if [[ "${NON_INTERACTIVE}" -eq 1 ]]; then
    flags+=(--noconfirm --skipreview)
  fi

  paru -S "${flags[@]}" -- "$@"
}

# Upgrades the system first. Installing from a stale package database risks a
# partial upgrade, which Arch does not support.
update_system() {
  STARTED=1
  print_msg "Upgrading the system"

  # -Syu also upgrades AUR packages, whose review would otherwise stop an
  # unattended run.
  local -a flags=()
  if [[ "${NON_INTERACTIVE}" -eq 1 ]]; then
    flags+=(--noconfirm --skipreview)
  fi

  paru -Syu "${flags[@]}"
}

install_compositor() {
  print_msg "Installing the niri compositor"
  paru_install "${DEFAULT_COMPOSITOR_PACKAGES[@]}"
}

# One paru run for all the desktop packages: a single confirmation and AUR
# review, and one transaction that resolves their dependencies together.
install_desktop_shell() {
  print_msg "Installing the Noctalia desktop shell and its applications"
  paru_install \
    "${DEFAULT_NOCTALIA_PACKAGES[@]}" \
    "${DEFAULT_TERMINAL_PACKAGES[@]}" \
    "${DEFAULT_KDE_PACKAGES[@]}" \
    "${DEFAULT_BROWSER_PACKAGES[@]}" \
    "${DEFAULT_OFFICE_PACKAGES[@]}" \
    "${DEFAULT_DEVELOPMENT_PACKAGES[@]}" \
    "${DEFAULT_THEME_PACKAGES[@]}" \
    "${DEFAULT_FONT_PACKAGES[@]}"
}

install_cli_tools() {
  print_msg "Installing the command-line tools"
  paru_install "${DEFAULT_CLI_PACKAGES[@]}"
}

install_neovim() {
  print_msg "Installing Neovim"
  paru_install "${DEFAULT_NEOVIM_PACKAGES[@]}"
}

# Adds a sed expression to the caller's edits array: the placeholder takes the
# value, or its line is deleted when the value is empty.
set_or_delete() {
  if [[ -n "$2" ]]; then
    edits+=(-e "s/${1}/${2}/")
  else
    edits+=(-e "/${1}/d")
  fi
}

# The package's install hook creates the state directory, mode 0750 and owned
# by the greetd user, which appearance sync requires. greeter.toml takes the
# same owner with mode 0644, as upstream sets it. The hook rewrites the file on
# every upgrade but keeps its settings.
install_greeter_config() {
  print_msg "Installing the greeter configuration"

  local owner group
  if ! owner=$(stat -c '%U' "${GREETER_STATE_DIR}" 2>/dev/null); then
    print_error "${GREETER_STATE_DIR} does not exist; the noctalia-greeter" \
      "install hook did not run."
    exit 1
  fi
  if [[ "${owner}" == "root" ]]; then
    print_error "${GREETER_STATE_DIR} is owned by root instead of the greetd" \
      "user."
    print_error "Repair it with: sudo" \
      "/usr/share/noctalia-greeter/setup_greeter_system.sh"
    exit 1
  fi
  group=$(stat -c '%G' "${GREETER_STATE_DIR}")

  # The login screen uses the same keyboard layout as the niri session, and the
  # first connector given with --display, --scale or --position. A setting not
  # given loses its line, which leaves the greeter's own default: the preferred
  # mode's refresh rate and an automatic scale. Without any of the options, the
  # whole [output] section goes, and the greeter shows on every monitor.
  local connector="${OUTPUT_ORDER[0]:-}" mode resolution
  local -a edits=(-e "s/@XKB_LAYOUT@/${XKB_LAYOUT:-${DEFAULT_XKB_LAYOUT}}/")
  if [[ -z "${connector}" ]]; then
    edits+=(-e '/^\[output\]$/,/^$/d')
  else
    mode="${OUTPUT_MODE[${connector}]:-}"
    resolution="${mode%@*}"
    edits+=(-e "s/@OUTPUT_NAME@/${connector}/")
    set_or_delete "@OUTPUT_WIDTH@" "${resolution:+${resolution%x*}}"
    set_or_delete "@OUTPUT_HEIGHT@" "${resolution:+${resolution#*x}}"
    set_or_delete "@OUTPUT_REFRESH_RATE@" "${OUTPUT_RATE[${connector}]:-}"
    set_or_delete "@OUTPUT_SCALE@" "${OUTPUT_SCALE[${connector}]:-}"
  fi
  sed "${edits[@]}" "${GREETER_CONF_SRC}" \
    | sudo install -m 0644 -o "${owner}" -g "${group}" /dev/stdin \
      "${GREETER_STATE_DIR}/greeter.toml"
}

# Only enabled: starting greetd now would stop getty@tty1, and with it a login
# session on the first virtual terminal.
#
# In a virtual machine, wlroots draws the greeter's cursor upside down on the
# virtio-gpu hardware cursor plane (wlroots issue 3921). The greeter's
# compositor then draws the cursor itself instead.
configure_greetd() {
  print_msg "Configuring greetd to start the Noctalia greeter"
  sudo install -D -m 0644 "${GREETD_CONF_SRC}" /etc/greetd/config.toml

  if systemd-detect-virt --vm --quiet; then
    print_msg "Virtual machine detected; disabling hardware cursors in the" \
      "greeter"
    local session="/usr/bin/noctalia-greeter-session" expression
    expression="s|^command = \"${session}\"\$|"
    expression+="command = \"env WLR_NO_HARDWARE_CURSORS=1 ${session}\"|"
    sudo sed -i "${expression}" /etc/greetd/config.toml
    if ! sudo grep -q 'WLR_NO_HARDWARE_CURSORS=1' /etc/greetd/config.toml; then
      print_warning "Could not disable hardware cursors; the greeter cursor" \
        "may appear upside down."
    fi
  fi

  # Replaces the package's PAM file, which noctalia-greeter's install hook has
  # already patched; the repository's version includes that change.
  print_msg "Unlocking KWallet at login through PAM"
  sudo install -m 0644 "${GREETD_PAM_SRC}" /etc/pam.d/greetd

  print_msg "Keeping the niri session output off the screen"
  sudo install -D -m 0644 "${NIRI_SESSION_SRC}" \
    /usr/local/share/wayland-sessions/niri.desktop

  sudo systemctl enable greetd.service
}

# fish's package lists /usr/bin/fish in /etc/shells, which chsh requires. The
# environment /etc/profile sets up for login shells comes from
# ~/.config/fish/conf.d/00-profile.fish, as fish does not read that file.
set_login_shell() {
  local user current
  user=$(id -un)
  current=$(getent passwd "${user}" | cut -d: -f7)
  [[ "${current}" != "${FISH_SHELL}" ]] || return 0

  if ! grep -qx "${FISH_SHELL}" /etc/shells; then
    print_error "${FISH_SHELL} is not listed in /etc/shells."
    exit 1
  fi
  print_msg "Setting fish as the login shell for ${user}"
  sudo chsh -s "${FISH_SHELL}" "${user}"
}

# Chooses the fonts for sans-serif, serif, monospace and the system-ui names,
# which web pages mostly rely on. Applies to every user of the system.
configure_fonts() {
  print_msg "Setting the fonts for the generic font families"
  sudo install -D -m 0644 "${FONTCONFIG_SRC}" \
    /etc/fonts/conf.d/50-generic-families.conf
}

# Adds a Polkit rule that lets this account sync its appearance to the greeter
# without an administrator prompt. The rule covers only the constrained sync
# action. Not fatal: without it, each sync asks for the password instead.
enable_passwordless_sync() {
  local user
  user=$(id -un)

  print_msg "Enabling passwordless appearance sync for ${user}"
  if ! sudo noctalia-greeter passwordless-sync enable "${user}"; then
    print_warning "Passwordless sync could not be enabled; each sync will ask" \
      "for the password."
  fi
}

install_extra_packages() {
  if [[ -n "${EXTRA_PACKAGES}" ]]; then
    print_msg "Installing additional packages"
    local -a packages
    read -ra packages <<<"${EXTRA_PACKAGES}"
    paru_install "${packages[@]}"
  fi
}

# Creates ~/Pictures and the other XDG user directories, and records them in
# ~/.config/user-dirs.dirs.
create_user_dirs() {
  print_msg "Creating the XDG user directories"
  xdg-user-dirs-update
}

copy_wallpapers() {
  print_msg "Copying the wallpapers to ${WALLPAPERS_DEST}"
  mkdir -p "${WALLPAPERS_DEST}"
  cp -rT "${WALLPAPERS_SRC}" "${WALLPAPERS_DEST}"
}

# Merges dots/ into the home directory, which covers ~/.config and
# ~/.local/share. Files from the repository replace files of the same name, and
# every other file is left in place. The AGENTS.md files describe the
# repository to coding agents and are not configuration, so they stay behind.
copy_dotfiles() {
  print_msg "Copying the configuration files to the home directory"
  mkdir -p "${DOTFILES_DEST}"
  (
    cd "${DOTFILES_SRC}"
    find . ! -type d ! -name AGENTS.md \
      -exec cp -P --parents -t "${DOTFILES_DEST}" -- {} +
  )
}

# Swaps the five bindings 70-binds.kdl marks "Swedish:" for their alternatives:
# with the se layout, the US bindings use symbols that need Shift or AltGr,
# which niri cannot match. Each line is matched whole; a missing one is reported
# and its pair left as it is.
configure_swedish_binds() {
  [[ "${XKB_LAYOUT}" == "se" ]] || return 0

  print_msg "Switching the niri key bindings to the Swedish layout"
  # Each US binding, followed by its Swedish alternative.
  local -a pairs=(
    'Mod+Shift+Slash { show-hotkey-overlay; }'
    'Mod+Shift+7 { show-hotkey-overlay; }'
    'Mod+BracketLeft  { consume-or-expel-window-left; }'
    'Mod+aring          { consume-or-expel-window-left; }'
    'Mod+BracketRight { consume-or-expel-window-right; }'
    'Mod+dead_diaeresis { consume-or-expel-window-right; }'
    'Mod+Equal { set-column-width "+10%"; }'
    'Mod+plus       { set-column-width "+10%"; }'
    'Mod+Shift+Equal { set-window-height "+10%"; }'
    'Mod+Shift+plus { set-window-height "+10%"; }'
  )
  local i us se
  TEMP_FILE=$(mktemp)
  for ((i = 0; i < ${#pairs[@]}; i += 2)); do
    us="    ${pairs[i]}"
    se="    ${pairs[i + 1]}"
    if ! grep -qxF -- "${us}" "${NIRI_BINDS}" \
      || ! grep -qxF -- "    // ${pairs[i + 1]}" "${NIRI_BINDS}"; then
      print_warning "Binding not found in ${NIRI_BINDS}, left unchanged:" \
        "${pairs[i]}"
      continue
    fi
    awk -v us="${us}" -v se="${se}" '
      $0 == us { print "    // " substr(us, 5); next }
      $0 == "    // " substr(se, 5) { print se; next }
      { print }
    ' "${NIRI_BINDS}" >"${TEMP_FILE}"
    cat "${TEMP_FILE}" >"${NIRI_BINDS}"
  done
  rm -f "${TEMP_FILE}"
  TEMP_FILE=""
}

# On Wayland, GTK 3 takes the theme, icons, cursor and fonts from GSettings,
# and its values replace those in settings.ini, which only X11 applications
# then follow. The keys are filled from settings.ini and stored by dconf in
# ~/.config/dconf/user. Runs after copy_dotfiles, which installs the file.
configure_gtk_settings() {
  print_msg "Applying the GTK settings to GSettings"
  local -A keys=(
    [gtk-theme-name]=gtk-theme
    [gtk-icon-theme-name]=icon-theme
    [gtk-cursor-theme-name]=cursor-theme
    [gtk-cursor-theme-size]=cursor-size
    [gtk-font-name]=font-name
  )
  local setting value
  for setting in "${!keys[@]}"; do
    value=$(awk -F= -v key="${setting}" '$1 == key { print $2; exit }' \
      "${GTK3_SETTINGS}")
    [[ -n "${value}" ]] || continue
    gsettings set org.gnome.desktop.interface "${keys[${setting}]}" "${value}"
  done

  # Dark variant and grayscale antialiasing, as in settings.ini.
  gsettings set org.gnome.desktop.interface color-scheme prefer-dark
  gsettings set org.gnome.desktop.interface font-antialiasing grayscale
  gsettings set org.gnome.desktop.interface font-hinting slight

  # Without a session bus, gsettings stores nothing and only warns.
  if [[ "$(gsettings get org.gnome.desktop.interface color-scheme)" \
    != "'prefer-dark'" ]]; then
    print_warning "The GTK settings could not be stored; GTK applications may" \
      "use the default theme."
  fi
}

# Installs the LazyVim plugins from ~/.config/nvim ahead of the first start,
# into ~/.local/share/nvim, along with the syntax parsers LazyVim lists.
# nvim-treesitter compiles the parsers in the background, and wait() keeps
# Neovim from quitting before they are done, for up to ten minutes. Runs after
# copy_dotfiles. Not fatal: Neovim installs whatever is missing when it starts.
install_neovim_plugins() {
  print_msg "Installing the Neovim plugins"
  local parsers="require('nvim-treesitter')"
  parsers+=".install(LazyVim.opts('nvim-treesitter').ensure_installed or {})"
  parsers+=":wait(600000)"
  if ! nvim --headless "+Lazy! sync" "+lua ${parsers}" +qa; then
    print_warning "The Neovim plugins could not be installed; Neovim installs" \
      "them on its first start."
  fi
  # Neovim's progress messages leave the last line open.
  echo
}

# Installs the VSCodium extensions that extensions.json lists: the Noctalia
# theme extension, whose colors Noctalia renders, and Catppuccin Icons. The
# settings.json from copy_dotfiles selects both. The install runs outside the
# niri session, which leaves VSCODE_PORTABLE and VSCODE_CLI_DATA_DIR to be set
# here. Not fatal: VSCodium then starts with its default themes.
configure_vscodium() {
  print_msg "Installing the VSCodium extensions"
  local extension
  local -a args=()
  while IFS= read -r extension; do
    args+=(--install-extension "${extension}")
  done < <(jq -r '.recommendations[]' "${VSCODIUM_EXTENSIONS}")
  [[ "${#args[@]}" -gt 0 ]] || return 0

  # VSCodium only uses VSCODE_PORTABLE when the directory exists, and falls
  # back to ~/.vscode-oss and ~/.config/VSCodium otherwise.
  mkdir -p "${VSCODIUM_DATA}"
  # The extension install prints Node.js deprecation warnings about VSCodium's
  # own code, which are filtered out of the error output.
  if ! VSCODE_PORTABLE="${VSCODIUM_DATA}" \
    VSCODE_CLI_DATA_DIR="${VSCODIUM_DATA}/cli" \
    codium "${args[@]}" >/dev/null \
    2> >(grep -v -e 'DeprecationWarning' -e '--trace-deprecation' >&2); then
    print_warning "Not every VSCodium extension could be installed."
  fi
}

# Runs after copy_dotfiles, which restores the repository's version of the file
# and keeps a rerun from adding the block twice. niri reads 90-user-extra.kdl
# last, and its xkb section replaces the one in 10-input-and-cursor.kdl.
configure_keyboard_layout() {
  [[ -n "${XKB_LAYOUT}" ]] || return 0

  print_msg "Setting the niri keyboard layout to" \
    "${XKB_LAYOUT}${XKB_VARIANT:+ (${XKB_VARIANT})}"
  {
    echo
    echo "// Keyboard layout set by desktop-install.sh."
    echo "input {"
    echo "    keyboard {"
    echo "        xkb {"
    echo "            layout \"${XKB_LAYOUT}\""
    if [[ -n "${XKB_VARIANT}" ]]; then
      echo "            variant \"${XKB_VARIANT}\""
    fi
    echo "        }"
    echo "    }"
    echo "}"
  } >>"${NIRI_USER_EXTRA}"
}

# Appended like the keyboard layout, after copy_dotfiles. Each connector gets
# one output section with the settings given for it; niri keeps its defaults
# for the rest.
configure_displays() {
  local connector mode scale position
  for connector in "${OUTPUT_ORDER[@]}"; do
    mode="${OUTPUT_MODE[${connector}]:-}"
    scale="${OUTPUT_SCALE[${connector}]:-}"
    position="${OUTPUT_POSITION[${connector}]:-}"
    print_msg "Configuring ${connector}"
    {
      echo
      echo "// Display settings set by desktop-install.sh."
      echo "output \"${connector}\" {"
      [[ -z "${mode}" ]] || echo "    mode \"${mode}\""
      [[ -z "${scale}" ]] || echo "    scale ${scale}"
      [[ -z "${position}" ]] || echo "    position ${position}"
      echo "}"
    } >>"${NIRI_USER_EXTRA}"
  done
}

# Ties the lock screen widgets to the first display given with --display,
# --scale or --position, or else to the first connected one. Without a display,
# the file is removed and Noctalia uses its default lock screen.
configure_lockscreen() {
  local connector="${OUTPUT_ORDER[0]:-}"
  if [[ -z "${connector}" ]]; then
    connector=$(list_connected_displays)
    connector="${connector%% *}"
  fi

  if [[ "${connector}" == "none" ]]; then
    print_warning "No connected display found; the lock screen keeps" \
      "Noctalia's default layout."
    rm -f "${NOCTALIA_LOCKSCREEN}"
    return 0
  fi
  print_msg "Placing the lock screen widgets on ${connector}"
  sed -i "s|@LOCKSCREEN_OUTPUT@|${connector}|g" "${NOCTALIA_LOCKSCREEN}"
}

# Runs after copy_dotfiles, and also without --address, which leaves the
# address empty instead of the placeholder. The sed replacement escapes the
# characters sed treats specially: the delimiter and the ampersand.
configure_location() {
  local address="${LOCATION_ADDRESS//|/\\|}"
  address="${address//&/\\&}"

  if [[ -n "${LOCATION_ADDRESS}" ]]; then
    print_msg "Setting the Noctalia location to ${LOCATION_ADDRESS}"
  fi
  sed -i "s|@LOCATION_ADDRESS@|${address}|" "${NOCTALIA_CONFIG}"
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
    case "${arg}" in -h | --help) return 0 ;; esac
  done

  if ! command -v script &>/dev/null; then
    print_warning "script(1) is not available; continuing without a log file."
    return 0
  fi

  mkdir -p "${LOG_DIR}"
  local log_file
  log_file=$(find "${LOG_DIR}" -maxdepth 1 -name 'desktop-install-*.log' \
    | sort \
    | tail -n 1)
  if [[ -z "${log_file}" ]]; then
    log_file="${LOG_DIR}/desktop-install-$(date +%Y%m%d-%H%M%S).log"
  fi
  print_msg "Logging to ${log_file}"

  # script(1) runs the command through $SHELL; bash, to match the quoting.
  local command
  command=$(printf '%q ' env DESKTOP_INSTALL_LOG="${log_file}" \
    "${SCRIPT_DIR}/$(basename "$0")" "$@")
  exec env SHELL=/bin/bash script --quiet --append --flush --return \
    --command "${command}" "${log_file}"
}

# Prints the title centered in an 80-column line of equals signs.
print_heading() {
  local title=" $1 " left right
  local -i width=$(((80 - ${#title}) / 2))
  printf -v left '%*s' "${width}" ''
  printf -v right '%*s' "$((80 - ${#title} - width))" ''
  echo "${WHITE}${left// /=}${BLUE}${title}${WHITE}${right// /=}${NO_COLOR}"
}

print_logo() {
  # Color is set around the heredoc rather than inside it: the heredoc stays
  # quoted, and the art is never subject to expansion.
  printf '%s' "${BLUE}"
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
  printf '%s' "${NO_COLOR}"
  print_heading "DESKTOP iNSTALLATiON SCRiPT"
  echo
}

# Prints the installation summary.
print_summary() {
  echo
  print_heading "iNSTALLATiON SUMMARY"
  echo "${WHITE}Compositor:${NO_COLOR} niri"
  echo "${WHITE}Desktop shell:${NO_COLOR} Noctalia"
  if [[ -n "${EXTRA_PACKAGES}" ]]; then
    echo "${WHITE}Additional packages:${NO_COLOR} ${EXTRA_PACKAGES}"
  fi
  local output
  while IFS= read -r output; do
    [[ -n "${output}" ]] && echo "${WHITE}Display:${NO_COLOR} ${output}"
  done < <(describe_outputs)
  if [[ -n "${LOCATION_ADDRESS}" ]]; then
    echo "${WHITE}Location:${NO_COLOR} ${LOCATION_ADDRESS}"
  fi
  if [[ -n "${XKB_LAYOUT}" ]]; then
    echo "${WHITE}Keyboard layout:${NO_COLOR}" \
      "${XKB_LAYOUT}${XKB_VARIANT:+ (${XKB_VARIANT})}"
  fi
  echo
  echo "${BLUE}==>${WHITE} Done. Reboot to start the greeter.${NO_COLOR}"
}

# Runs every installation step in order.
main() {
  if [[ -z "${DESKTOP_INSTALL_LOG:-}" ]]; then
    start_logging "$@"
  fi

  print_logo

  parse_args "$@"

  validate_inputs
  validate_xkb_layout
  validate_displays
  validate_address
  validate_packages
  confirm_operation

  update_system
  install_compositor
  install_desktop_shell
  install_cli_tools
  install_neovim
  install_extra_packages

  install_greeter_config
  configure_greetd
  configure_fonts
  enable_passwordless_sync
  set_login_shell

  create_user_dirs
  copy_wallpapers
  copy_dotfiles
  configure_gtk_settings
  install_neovim_plugins
  configure_vscodium
  configure_keyboard_layout
  configure_swedish_binds
  configure_displays
  configure_location
  configure_lockscreen

  print_summary
}

# Entry point.
main "$@"
