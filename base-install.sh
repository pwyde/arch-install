#!/bin/bash
# base-install.sh
#
# A comprehensive Arch Linux installation script with LUKS encryption,
# Btrfs subvolumes, the Limine bootloader and Unified Kernel Image (UKI).
#
# Features:
# - Full disk encryption with LUKS2, unlocked by passphrase
# - Snapper snapshots with a Limine boot entry for each
# - Btrfs filesystem with customizable subvolumes
# - Unified Kernel Image booted by Limine
# - Customizable installation parameters
# - Error handling and validation
#
# Usage: ./base-install.sh [options]
# See --help for available options

set -euo pipefail

# Defaults, overridden by the command-line options.
# The first disk that is neither removable nor USB-attached, which excludes
# the installation medium.
DEFAULT_DISK=$(lsblk -dpnro NAME,RM,TRAN | awk '
  !found && $1 !~ "^/dev/(loop|zram|sr|ram)" && $2 == 0 && $3 != "usb" {
    print $1
    found = 1
  }')
readonly DEFAULT_DISK
readonly DEFAULT_HOSTNAME="arch-linux"
readonly DEFAULT_USERNAME="admin"
readonly DEFAULT_TIMEZONE="Europe/London"
readonly DEFAULT_KEYMAP="uk"
readonly DEFAULT_LOCALE="en_GB.UTF-8"
# No snapshots subvolume is listed: 'snapper create-config' creates its own
# /.snapshots and refuses to run when the path already exists.
readonly DEFAULT_SUBVOLUMES="@ @home @cache @log @root"
# base-devel and git clone and build paru in install_aur_helper, and paru needs
# base-devel for every AUR package it builds afterwards.
# mkinitcpio and iptables are named explicitly. They provide the virtual
# packages 'initramfs' and 'libxtables.so', which have several providers each.
# pacstrap runs with --noconfirm, which would otherwise leave the choice to
# whichever provider pacman lists first.
readonly DEFAULT_PACKAGES=(
  base
  base-devel
  bash-completion
  btrfs-progs
  cryptsetup
  dosfstools
  efibootmgr
  git
  iptables
  limine
  linux
  linux-firmware
  man-db
  man-pages
  mkinitcpio
  nano
  networkmanager
  openssh
  plocate
  plymouth
  snap-pac
  snapper
  sudo
  unzip
  util-linux
  vim
  wpa_supplicant
  zram-generator
)

# Terminal colors.
readonly RED=$'\033[91m'
readonly GREEN=$'\033[92m'
# 24-bit #1793D1, the Arch blue used by the Limine menu and the Plymouth theme.
# The plain console has 16 colors and approximates it; a truecolor terminal
# shows it exactly.
readonly BLUE=$'\033[38;2;23;147;209m'
readonly YELLOW=$'\033[93m'
readonly WHITE=$'\033[1;97m'
readonly NO_COLOR=$'\033[0m'

# ESP mount options. FAT has no permission bits; the mount supplies them: files
# 0600, directories 0700, all owned by root. This matches what mkinitcpio would
# set on a normal filesystem, where it builds initramfs images and UKIs under
# `umask 077` because an initramfs can carry secrets such as a LUKS keyfile.
# Without these options, the kernel and the UKIs on /boot are world-readable.
readonly ESP_MOUNT_OPTS="fmask=0177,dmask=0077"

# Btrfs mount options applied to every subvolume.
#   compress=zstd:3 - btrfs's own default level, a better ratio than level 1
#     for a modest CPU cost. It applies only to newly written data, which makes
#     install time the right moment to set it.
#   noatime - every atime update on a CoW filesystem is a metadata write that
#     also makes snapshots diverge from their parent without any change in
#     content.
#   nodiscard - the LUKS container is opened with --allow-discards, which
#     makes the device support TRIM, and btrfs would otherwise enable
#     continuous discard=async by default (kernel 6.2+). Arch, Debian and Red
#     Hat all recommend periodic TRIM instead, which fstrim.timer provides.
readonly BTRFS_MOUNT_OPTS="compress=zstd:3,noatime,nodiscard"

# Repository files
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
# Inside the repository, which is copied to the new user's home on success.
readonly LOG_DIR="${SCRIPT_DIR}/logs"
readonly PLYMOUTH_THEME_SRC="${SCRIPT_DIR}/defaults/plymouth/arch-linux"
readonly PLYMOUTHD_CONF_SRC="${SCRIPT_DIR}/etc/plymouth/plymouthd.conf"
readonly LIMINE_CONF_SRC="${SCRIPT_DIR}/defaults/limine/limine.conf"
readonly VCONSOLE_LATIN_HOOK_SRC="${SCRIPT_DIR}/etc/initcpio/install/vconsole-latin"
readonly MKINITCPIO_HOOKS_CONF_SRC="${SCRIPT_DIR}/etc/mkinitcpio.conf.d/hooks.conf"
readonly CMDLINE_SRC="${SCRIPT_DIR}/etc/cmdline.d"
readonly CMDLINE_FILES=(
  10-root.conf
  20-rtc-alarm.conf
  80-initramfs-async.conf
  85-console.conf
  90-splash.conf
)
readonly LOCALE_CONF_SRC="${SCRIPT_DIR}/etc/locale.conf"
readonly HOSTS_SRC="${SCRIPT_DIR}/etc/hosts"
readonly ZRAM_CONF_SRC="${SCRIPT_DIR}/etc/systemd/zram-generator.conf.d/90-zram.conf"
readonly SYSCTL_SRC="${SCRIPT_DIR}/etc/sysctl.d"
readonly SYSCTL_FILES=(
  40-net.conf
  41-ipv4.conf
  45-bbr.conf
  50-vm.conf
  60-net-hardening.conf
  61-kernel-hardening.conf
)
readonly MODULES_LOAD_SRC="${SCRIPT_DIR}/etc/modules-load.d/bbr.conf"
readonly NM_CONF_SRC="${SCRIPT_DIR}/etc/NetworkManager/conf.d"
readonly NM_CONF_FILES=(10-ipv6-privacy.conf 20-wifi-powersave.conf)
readonly COREDUMP_CONF_SRC="${SCRIPT_DIR}/etc/systemd/coredump.conf.d/10-disable-coredumps.conf"
readonly JOURNALD_CONF_SRC="${SCRIPT_DIR}/etc/systemd/journald.conf.d/10-journal-size.conf"
readonly SSHD_CONF_SRC="${SCRIPT_DIR}/etc/ssh/sshd_config.d/10-hardening.conf"
readonly MANDB_TIMER_SRC="${SCRIPT_DIR}/etc/systemd/system/man-db.timer.d/override.conf"
readonly UPDATEDB_TIMER_SRC="${SCRIPT_DIR}/etc/systemd/system/plocate-updatedb.timer.d/override.conf"
readonly UPDATEDB_SERVICE_SRC="${SCRIPT_DIR}/etc/systemd/system/plocate-updatedb.service.d/override.conf"
readonly SHUTDOWN_CONF_SRC="${SCRIPT_DIR}/etc/systemd"
readonly SHUTDOWN_CONF_FILES=(
  system.conf.d/10-faster-shutdown.conf
  user.conf.d/10-faster-shutdown.conf
  system/user@.service.d/10-faster-shutdown.conf
)
readonly SUDOERS_SRC="${SCRIPT_DIR}/etc/sudoers.d"
readonly XDG_PROFILE_SRC="${SCRIPT_DIR}/etc/profile.d/00-xdg.sh"
readonly DEFAULTS_PROFILE_SRC="${SCRIPT_DIR}/etc/profile.d/10-defaults.sh"
readonly XDG_BASH_PROFILE_SRC="${SCRIPT_DIR}/etc/profile.d/zz-xdg-bash.sh"
readonly VIM_XDG_SRC="${SCRIPT_DIR}/etc/vim/xdg.vim"
readonly USER_BASHRC_SRC="${SCRIPT_DIR}/defaults/bash/bashrc"
readonly SUDOERS_FILES=(00-wheel 01-timeout 02-passwd-tries)
readonly SLEEP_HOOK_SRC="${SCRIPT_DIR}/defaults/systemd/system-sleep/keyboard-backlight"
readonly SNAPPER_CONFIG_SRC="${SCRIPT_DIR}/defaults/snapper/root"
readonly SNAPPER_CONFD_SRC="${SCRIPT_DIR}/etc/conf.d/snapper"
readonly LIMINE_TOOL_CONF_SRC="${SCRIPT_DIR}/etc/limine-entry-tool.d/50-arch.conf"
# Prebuilt AUR packages. They are compiled with GraalVM native-image, which is
# too heavy to run during an install; ARCHITECTURE.md describes how to rebuild
# them.
readonly LIMINE_PKG_SRC="${SCRIPT_DIR}/packages"
readonly LIMINE_PKGS=(limine-mkinitcpio-hook limine-snapper-sync)

# Global variables
DISK=""
EFI_PART=""
ROOT_PART=""
HOSTNAME=""
USERNAME=""
TIMEZONE=""
KEYMAP=""
LOCALE=""
SUBVOLUMES=""
EXTRA_PACKAGES=""
# Temporary sync databases of validate_packages, removed by cleanup on failure.
PKG_DB_DIR=""
NON_INTERACTIVE=0
MICROCODE=""
# Set by the first step that writes to the disk. A failure before it leaves
# nothing behind and reports itself; after it, cleanup asks for a reboot.
DISK_MODIFIED=0
# Set by verify_installation when the installed system may not boot. The run
# then fails, but the target stays mounted for the repairs the errors suggest.
VERIFY_FAILED=0

# Password variables
USER_PASSWORD=""
ROOT_PASSWORD=""
# Names the accounts that fell back to 'changeme'. print_summary repeats this at
# the end, where a warning from the password prompt has long scrolled off.
PASSWORD_FALLBACK=""

print_msg() {
  echo "${GREEN}==>${NO_COLOR}${WHITE}" "$*${NO_COLOR}"
}

print_warning() {
  echo "${YELLOW}==> WARNING:${NO_COLOR}${WHITE}" "$*${NO_COLOR}" >&2
}

print_error() {
  echo "${RED}==> ERROR:${NO_COLOR}${WHITE}" "$*${NO_COLOR}" >&2
}

# Reports a failed run. Once the disk has been written to, nothing is undone:
# the target stays mounted and the LUKS container open. A reboot gives the next
# run a clean live system, and that run erases the disk again.
cleanup() {
  local exit_code=$? failed_command="${BASH_COMMAND}"

  # Left only if package validation failed.
  [[ -z "${PKG_DB_DIR:-}" ]] || rm -rf "${PKG_DB_DIR}"

  # Failures before the first write report themselves, and the summary explains
  # a failed verification.
  if [[ "${exit_code}" -eq 0 ]] || [[ "${DISK_MODIFIED:-0}" -eq 0 ]] \
    || [[ "${VERIFY_FAILED:-0}" -eq 1 ]]; then
    return
  fi

  case "${exit_code}" in
    130 | 143) print_error "The installation was interrupted." ;;
    *)
      print_error "The installation failed with exit code ${exit_code}."
      # An explicit exit follows an error message of its own. Of a command
      # with a heredoc, only the first line is shown.
      if [[ "${failed_command}" != exit* ]]; then
        print_error "Failed command: ${failed_command%%$'\n'*}"
      fi
      ;;
  esac
  print_error "Reboot the installation medium and run the installer again;" \
    "the disk stays in use until then."
}

# Help text.
show_help() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  -d, --disk DISK            Specify disk (default: ${DEFAULT_DISK})
  -k, --keymap KEYMAP        Set keymap (default: ${DEFAULT_KEYMAP})
  -l, --locale LOCALE        Set locale (default: ${DEFAULT_LOCALE})
  -n, --hostname HOSTNAME    Set hostname (default: ${DEFAULT_HOSTNAME})
  -p, --packages PACKAGES    Additional packages to install, space-separated
                             (appended to defaults)
  -s, --subvolumes SUBVOLS   Btrfs subvolumes, space-separated
                             (default: ${DEFAULT_SUBVOLUMES})
  -t, --timezone TIMEZONE    Set timezone (default: ${DEFAULT_TIMEZONE})
  -u, --username USERNAME    Set username (default: ${DEFAULT_USERNAME})
  -y, --yes                  Non-interactive mode, use defaults for prompts
                             (requires --disk)
  -h, --help                 Show this help message

Example:
  $(basename "$0") --disk /dev/sda --hostname mymachine --username myuser

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
  # No default for DISK here: validate_disk applies it, except under --yes.
  HOSTNAME="${DEFAULT_HOSTNAME}"
  USERNAME="${DEFAULT_USERNAME}"
  TIMEZONE="${DEFAULT_TIMEZONE}"
  KEYMAP="${DEFAULT_KEYMAP}"
  LOCALE="${DEFAULT_LOCALE}"
  SUBVOLUMES="${DEFAULT_SUBVOLUMES}"

  while [[ $# -gt 0 ]]; do
    case $1 in
      -h | --help)
        show_help
        ;;
      -d | --disk)
        require_value "$1" "${2:-}"
        DISK="$2"
        shift 2
        ;;
      -n | --hostname)
        require_value "$1" "${2:-}"
        HOSTNAME="$2"
        shift 2
        ;;
      -u | --username)
        require_value "$1" "${2:-}"
        USERNAME="$2"
        shift 2
        ;;
      -t | --timezone)
        require_value "$1" "${2:-}"
        TIMEZONE="$2"
        shift 2
        ;;
      -k | --keymap)
        require_value "$1" "${2:-}"
        KEYMAP="$2"
        shift 2
        ;;
      -l | --locale)
        require_value "$1" "${2:-}"
        LOCALE="$2"
        shift 2
        ;;
      -s | --subvolumes)
        require_value "$1" "${2:-}"
        SUBVOLUMES="$2"
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

# Exits when Secure Boot is on, since nothing written to the ESP is signed.
validate_secure_boot() {
  local sb_var state=""

  sb_var="/sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c"

  if [[ -r "${sb_var}" ]]; then
    # Four bytes of EFI variable attributes, then the state byte.
    state=$(od -An -t u1 -j 4 -N 1 "${sb_var}" 2>/dev/null | tr -d '[:space:]')
  elif command -v bootctl >/dev/null 2>&1; then
    local sb_line
    sb_line=$(bootctl status 2>/dev/null | grep -m1 "Secure Boot:" || true)
    case "${sb_line}" in
      *enabled*) state=1 ;;
      *disabled*) state=0 ;;
    esac
  fi

  case "${state}" in
    1)
      print_error "Secure Boot is enabled. Disable it in the firmware setup" \
        "before installing."
      print_error "Nothing installed here is signed, so the system would not" \
        "boot."
      print_error "This installation does not sign its boot files; leave" \
        "Secure Boot off."
      exit 1
      ;;
    0)
      print_msg "Secure Boot is disabled"
      ;;
    *)
      # No SecureBoot variable: the firmware does not implement Secure Boot.
      print_warning "Could not determine the Secure Boot state; assuming it" \
        "is disabled."
      ;;
  esac
}

# --yes skips the only prompt that names the disk, so an unattended run needs
# --disk. Links such as /dev/disk/by-id/... are resolved to the kernel name,
# from which setup_partitions derives the partition names.
validate_disk() {
  local type

  if [[ -z "${DISK}" ]]; then
    if [[ "${NON_INTERACTIVE}" -eq 1 ]]; then
      print_error "Option --yes requires --disk, which names the disk to" \
        "erase."
      exit 1
    fi
    DISK="${DEFAULT_DISK}"
  fi
  if [[ -z "${DISK}" ]]; then
    print_error "No disk found to install to. Name one with --disk."
    exit 1
  fi

  if [[ ! -b "${DISK}" ]]; then
    print_error "Disk ${DISK} does not exist or is not a block device."
    exit 1
  fi
  type=$(lsblk -dno TYPE "${DISK}")
  if [[ "${type}" != "disk" ]]; then
    print_error "${DISK} is not a whole disk; lsblk reports its type as" \
      "'${type}'."
    exit 1
  fi
  DISK=$(readlink -f -- "${DISK}")
}

# sgdisk would erase a partition table the kernel still uses, and partprobe
# would then fail with the disk half wiped. /mnt and the name cryptroot are
# the installer's own.
validate_disk_unused() {
  local busy line

  # Every device on the disk that is mounted or used as swap, and every one
  # other than a partition, such as an open LUKS container.
  busy=$(lsblk -lnpo NAME,TYPE,MOUNTPOINT "${DISK}" \
    | awk '($2 != "disk" && $2 != "part") || $3 != ""')
  if [[ -n "${busy}" ]]; then
    print_error "${DISK} is in use. Release these first, for example with" \
      "umount, swapoff or cryptsetup close:"
    while IFS= read -r line; do
      print_error "  ${line}"
    done <<<"${busy}"
  elif mountpoint -q /mnt; then
    print_error "/mnt is already in use. Unmount it first: umount -R /mnt"
  elif [[ -e /dev/mapper/cryptroot ]]; then
    print_error "/dev/mapper/cryptroot is already open. Close it first:" \
      "cryptsetup close cryptroot"
  else
    return 0
  fi
  # A failed run leaves the disk in use on purpose; see cleanup.
  print_error "After a failed installation, reboot the installation medium" \
    "instead."
  exit 1
}

# systemd-firstboot --root only checks that the keymap name is well-formed,
# not that the keymap exists.
validate_keymap() {
  local pattern='^[A-Za-z0-9_.-]+$'

  if [[ ! "${KEYMAP}" =~ ${pattern} \
    || -z "$(find /usr/share/kbd/keymaps -name "${KEYMAP}.map*" -print -quit \
      2>/dev/null)" ]]; then
    print_error "Keymap '${KEYMAP}' is not installed."
    exit 1
  fi
}

# The values reach sed expressions, configuration files and commands run in
# the chroot. Strict patterns make escaping unnecessary, and the live system
# ships the same time zone and locale data as the target.
validate_options() {
  local pattern subvol listed="" has_root=0
  local -a subvols

  # A single label, since /etc/hosts appends .localdomain to it.
  pattern='^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$'
  if [[ ! "${HOSTNAME}" =~ ${pattern} ]]; then
    print_error "Invalid hostname '${HOSTNAME}': letters, digits and inner" \
      "hyphens only, at most 63 characters."
    exit 1
  fi

  # The pattern useradd accepts, without the '$' of machine accounts.
  pattern='^[a-z_][a-z0-9_-]{0,31}$'
  if [[ ! "${USERNAME}" =~ ${pattern} ]]; then
    print_error "Invalid username '${USERNAME}': lowercase letters, digits," \
      "'_' and '-' only, at most 32 characters, not starting with a digit" \
      "or '-'."
    exit 1
  fi
  # An existing account would gain a password and SSH access. The live system
  # has the target's base accounts; configure_users catches those that
  # packages add.
  if getent passwd "${USERNAME}" >/dev/null; then
    print_error "Username '${USERNAME}' is reserved for a system account."
    exit 1
  fi

  # The pattern excludes '.', which keeps the path below zoneinfo.
  pattern='^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)*$'
  if [[ ! "${TIMEZONE}" =~ ${pattern} \
    || ! -f "/usr/share/zoneinfo/${TIMEZONE}" ]]; then
    print_error "Unknown time zone '${TIMEZONE}'."
    exit 1
  fi

  # locale-gen generates only the locales listed in locale.gen. The locale sets
  # LC_CTYPE, so a legacy character set would replace UTF-8 for every program.
  pattern='^[A-Za-z0-9_.@-]+$'
  if [[ ! "${LOCALE}" =~ ${pattern} ]] \
    || ! awk -v locale="${LOCALE}" '
      { sub(/^#/, "") }
      $1 == locale && $2 == "UTF-8" { found = 1 }
      END { exit !found }' /etc/locale.gen; then
    print_error "Unknown or non-UTF-8 locale '${LOCALE}'. Use a UTF-8 locale" \
      "from /etc/locale.gen, such as sv_SE.UTF-8."
    exit 1
  fi

  # Each name becomes a path and a mount point, and @ holds the root
  # filesystem.
  pattern='^@[A-Za-z0-9_-]*$'
  read -ra subvols <<<"${SUBVOLUMES}"
  for subvol in "${subvols[@]}"; do
    if [[ ! "${subvol}" =~ ${pattern} ]]; then
      print_error "Invalid subvolume '${subvol}': '@' followed by letters," \
        "digits, '_' or '-'."
      exit 1
    fi
    if [[ " ${listed} " == *" ${subvol} "* ]]; then
      print_error "Subvolume '${subvol}' is listed more than once."
      exit 1
    fi
    listed="${listed} ${subvol}"
    [[ "${subvol}" != "@" ]] || has_root=1
  done
  if ((has_root == 0)); then
    print_error "The subvolumes must include '@' for the root filesystem."
    exit 1
  fi
}

# Resolves the additional packages against a temporary copy of the sync
# databases, which leaves the live system's own databases untouched. A name
# that pacstrap cannot find would otherwise fail after the disk is wiped.
validate_packages() {
  local pattern pkg
  local -a pkgs

  read -ra pkgs <<<"${EXTRA_PACKAGES}"
  ((${#pkgs[@]} > 0)) || return 0

  # Package names as pacman defines them, optionally prefixed with a
  # repository. A leading '-' would turn an entry into an option.
  pattern='^([a-z0-9_-]+/)?[a-z0-9@_+][a-z0-9@._+-]*$'
  for pkg in "${pkgs[@]}"; do
    if [[ ! "${pkg}" =~ ${pattern} ]]; then
      print_error "Invalid package name '${pkg}'."
      exit 1
    fi
  done

  print_msg "Checking the additional packages"
  PKG_DB_DIR=$(mktemp -d)
  # pacman downloads as its unprivileged sandbox user, which must be able to
  # reach the directory. The databases are public.
  chmod 0755 "${PKG_DB_DIR}"
  if ! pacman -Sy --dbpath "${PKG_DB_DIR}" --logfile /dev/null >/dev/null; then
    print_error "Could not download the package databases. Check the" \
      "network connection."
    exit 1
  fi
  if ! pacman -Sp --dbpath "${PKG_DB_DIR}" --logfile /dev/null --noconfirm \
    --print-format '%n' -- "${pkgs[@]}" >/dev/null; then
    print_error "Unknown package in --packages: ${EXTRA_PACKAGES}"
    exit 1
  fi
  rm -rf "${PKG_DB_DIR}"
  PKG_DB_DIR=""
}

# Validates the options and the live environment.
validate_inputs() {
  validate_disk
  validate_disk_unused

  if [[ "$(id -u)" -ne 0 ]]; then
    print_error "This script must be run as root."
    exit 1
  fi

  if [[ ! -d /sys/firmware/efi/efivars ]]; then
    print_error "System not booted in UEFI mode. This script requires UEFI" \
      "boot."
    exit 1
  fi

  validate_keymap
  validate_options
  validate_packages

  # Everything the installer copies out of this repository. Checked now, before
  # the disk is wiped, rather than failing halfway through the install.
  local repo_file
  local -a repo_files=(
    # Stands in for the whole theme directory, which is copied with cp -rT.
    "${PLYMOUTH_THEME_SRC}/arch-linux.plymouth"
    "${PLYMOUTHD_CONF_SRC}"
    "${LIMINE_CONF_SRC}"
    "${VCONSOLE_LATIN_HOOK_SRC}"
    "${MKINITCPIO_HOOKS_CONF_SRC}"
    "${LOCALE_CONF_SRC}"
    "${HOSTS_SRC}"
    "${ZRAM_CONF_SRC}"
    "${SLEEP_HOOK_SRC}"
    "${SNAPPER_CONFIG_SRC}"
    "${SNAPPER_CONFD_SRC}"
    "${LIMINE_TOOL_CONF_SRC}"
    "${MODULES_LOAD_SRC}"
    "${COREDUMP_CONF_SRC}"
    "${JOURNALD_CONF_SRC}"
    "${SSHD_CONF_SRC}"
    "${MANDB_TIMER_SRC}"
    "${UPDATEDB_TIMER_SRC}"
    "${UPDATEDB_SERVICE_SRC}"
    "${XDG_PROFILE_SRC}"
    "${DEFAULTS_PROFILE_SRC}"
    "${XDG_BASH_PROFILE_SRC}"
    "${VIM_XDG_SRC}"
    "${USER_BASHRC_SRC}"
  )
  for repo_file in "${CMDLINE_FILES[@]}"; do
    repo_files+=("${CMDLINE_SRC}/${repo_file}")
  done
  for repo_file in "${SUDOERS_FILES[@]}"; do
    repo_files+=("${SUDOERS_SRC}/${repo_file}")
  done
  for repo_file in "${SYSCTL_FILES[@]}"; do
    repo_files+=("${SYSCTL_SRC}/${repo_file}")
  done
  for repo_file in "${SHUTDOWN_CONF_FILES[@]}"; do
    repo_files+=("${SHUTDOWN_CONF_SRC}/${repo_file}")
  done
  for repo_file in "${NM_CONF_FILES[@]}"; do
    repo_files+=("${NM_CONF_SRC}/${repo_file}")
  done

  for repo_file in "${repo_files[@]}"; do
    [[ -f "${repo_file}" ]] && continue
    print_error "Missing repository file: ${repo_file}"
    print_error "Run the script from a full checkout of the repository."
    exit 1
  done

  # Exactly one file per package: pacman -U installs every file that matches,
  # and two versions of a package in one transaction fail after the disk is
  # wiped.
  local pkg_name
  local -a pkg_files
  for pkg_name in "${LIMINE_PKGS[@]}"; do
    pkg_files=("${LIMINE_PKG_SRC}/${pkg_name}"-*.pkg.tar.zst)
    if [[ ! -f "${pkg_files[0]}" ]]; then
      print_error "Missing prebuilt package:" \
        "${LIMINE_PKG_SRC}/${pkg_name}-*.pkg.tar.zst"
      print_error "See ARCHITECTURE.md for how to build it."
      exit 1
    fi
    if ((${#pkg_files[@]} > 1)); then
      print_error "More than one prebuilt package for ${pkg_name}:"
      print_error "  ${pkg_files[*]##*/}"
      print_error "Keep only the current version in ${LIMINE_PKG_SRC}."
      exit 1
    fi
  done

  # Tools required on the live system.
  local tool
  for tool in sgdisk cryptsetup mkfs.fat mkfs.btrfs; do
    if ! command -v "${tool}" &>/dev/null; then
      print_error "Required tool '${tool}' not found. Please install it first."
      exit 1
    fi
  done
}

# Derives the partition names and the microcode package.
setup_partitions() {
  # The kernel puts a 'p' between the disk name and the partition number when
  # the name ends in a digit, as with NVMe and eMMC devices.
  if [[ "${DISK}" =~ [0-9]$ ]]; then
    EFI_PART="${DISK}p1"
    ROOT_PART="${DISK}p2"
  else
    EFI_PART="${DISK}1"
    ROOT_PART="${DISK}2"
  fi

  # Microcode package for the CPU vendor.
  if grep -q GenuineIntel /proc/cpuinfo; then
    MICROCODE="intel-ucode"
  elif grep -q AuthenticAMD /proc/cpuinfo; then
    MICROCODE="amd-ucode"
  else
    print_warning "Could not detect CPU type. Microcode will not be installed."
    MICROCODE=""
  fi
}

# Asks for confirmation before the disk is erased.
confirm_operation() {
  if [[ "${NON_INTERACTIVE}" -eq 0 ]]; then
    echo "WARNING: This will erase ALL data on ${DISK}"
    echo "The following partitions will be created:"
    echo "  ${EFI_PART}: 2048MB (EFI System Partition)"
    echo "  ${ROOT_PART}: Rest of disk (Linux LUKS)"
    read -r -p "Are you sure you want to continue? (y/N) " REPLY
    echo
    if [[ ! ${REPLY} =~ ^[Yy]$ ]]; then
      echo "Installation cancelled."
      exit 1
    fi
  fi
}

# Partitions the disk: a 2 GiB ESP and a LUKS partition.
create_partitions() {
  DISK_MODIFIED=1
  print_msg "Creating partitions on ${DISK}"

  print_msg "Creating new GPT partition table on ${DISK}"
  sgdisk --zap-all "${DISK}" # Removes the existing GPT and MBR
  sgdisk --clear "${DISK}"   # Writes a new, empty GPT
  udevadm settle             # Lets udev finish with the removed partitions

  print_msg "Creating EFI System Partition"
  sgdisk --new=1:0:+2048M --typecode=1:ef00 --change-name=1:"EFI System" \
    "${DISK}"

  print_msg "Creating root partition"
  sgdisk --new=2:0:0 --typecode=2:8309 --change-name=2:"Linux LUKS" "${DISK}"

  # Makes the kernel reread the new partition table, then waits until udev has
  # handled the new partitions; its probes would otherwise race mkfs and
  # cryptsetup for the devices.
  print_msg "Informing kernel of partition table change"
  partprobe "${DISK}"
  udevadm settle

  print_msg "Checking new partition table"
  sgdisk --print "${DISK}"

  if [[ ! -b "${EFI_PART}" ]] || [[ ! -b "${ROOT_PART}" ]]; then
    print_error "Partitions did not appear after creation."
    print_msg "EFI partition (${EFI_PART}) exists:" \
      "$(test -b "${EFI_PART}" && echo "Yes" || echo "No")"
    print_msg "Root partition (${ROOT_PART}) exists:" \
      "$(test -b "${ROOT_PART}" && echo "Yes" || echo "No")"
    exit 1
  fi
}

# Formats the ESP and creates the LUKS container.
format_partitions() {
  print_msg "Format EFI partition with FAT32"
  mkfs.fat -F32 -n "EFI" "${EFI_PART}"

  if cryptsetup isLuks "${ROOT_PART}" 2>/dev/null; then
    print_msg "Partition ${ROOT_PART} already has a LUKS header, removing it..."
    # Overwrites the first 10 MiB, where the LUKS header is stored.
    dd if=/dev/zero of="${ROOT_PART}" bs=1M count=10 status=progress
    sync
  fi

  print_msg "Creating new LUKS container on ${ROOT_PART}..."
  cryptsetup luksFormat --type luks2 -v "${ROOT_PART}"

  print_msg "Opening LUKS container..."
  if ! cryptsetup --allow-discards --persistent open "${ROOT_PART}" \
    cryptroot; then
    print_error "Failed to open LUKS container."
    print_msg "This might be due to a previous LUKS header still being" \
      "detected."
    exit 1
  fi
}

# Creates the Btrfs filesystem and its subvolumes.
setup_btrfs() {
  local subvol
  local -a subvols

  print_msg "Format and layout Btrfs"
  mkfs.btrfs -L "ArchRoot" /dev/mapper/cryptroot

  print_msg "Mounting Btrfs root for subvolume creation"
  mount /dev/mapper/cryptroot /mnt

  print_msg "Creating Btrfs subvolumes"
  read -ra subvols <<<"${SUBVOLUMES}"
  for subvol in "${subvols[@]}"; do
    print_msg "Creating subvolume ${subvol}"
    btrfs subvolume create "/mnt/${subvol}"
  done

  print_msg "Unmounting temporary Btrfs mount"
  umount /mnt
}

# Mounts the subvolumes and the ESP under /mnt.
mount_filesystems() {
  local subvol mountpoint
  local -a subvols

  print_msg "Mount subvolumes"

  # The root subvolume first.
  print_msg "Mounting root subvolume"
  mount -o "subvol=@,${BTRFS_MOUNT_OPTS}" /dev/mapper/cryptroot /mnt

  mkdir -p "/mnt/boot"
  print_msg "Mounting EFI partition to /mnt/boot"
  mount -o "${ESP_MOUNT_OPTS}" "${EFI_PART}" "/mnt/boot"

  # The remaining subvolumes, each on its own mount point.
  print_msg "Mounting other subvolumes"
  read -ra subvols <<<"${SUBVOLUMES}"
  for subvol in "${subvols[@]}"; do
    if [[ "${subvol}" != "@" ]]; then
      # @cache and @log mount below /var; the others at /<name>.
      case "${subvol}" in
        @home) mountpoint="/home" ;;
        @cache) mountpoint="/var/cache" ;;
        @log) mountpoint="/var/log" ;;
        *)
          mountpoint="${subvol#@}"
          mountpoint="/${mountpoint}"
          ;;
      esac

      print_msg "Mounting subvolume ${subvol} to /mnt${mountpoint}"
      mkdir -p "/mnt${mountpoint}"
      mount -o "subvol=${subvol},${BTRFS_MOUNT_OPTS}" /dev/mapper/cryptroot \
        "/mnt${mountpoint}"
    fi
  done

  # A fresh subvolume is 0755, but root's home should be 0750; pacman warns
  # about the difference when it installs the filesystem package.
  if mountpoint -q /mnt/root; then
    chmod 0750 /mnt/root
  fi

  print_msg "Mounted filesystems:"
  mount | grep "/mnt"
}

# Installs the base system with pacstrap.
install_base_system() {
  print_msg "Install base system"
  local -a packages=("${DEFAULT_PACKAGES[@]}") extra_packages
  [[ -z "${MICROCODE}" ]] || packages+=("${MICROCODE}")
  read -ra extra_packages <<<"${EXTRA_PACKAGES}"
  packages+=("${extra_packages[@]}")
  print_msg "Installing packages: ${packages[*]}"

  # Initializes the live system's pacman keyring.
  pacman-key --init
  pacman-key --populate archlinux

  # The ESP is /boot, and pacstrap writes the kernel straight onto it. If the
  # ESP is not mounted yet, the kernel lands on the Btrfs root and is shadowed
  # the moment the ESP is mounted over it, leaving an unbootable system.
  if ! mountpoint -q "/mnt/boot"; then
    print_error "EFI partition is not mounted at /mnt/boot."
    print_error "It must be mounted before pacstrap, or the kernel will be" \
      "installed to the wrong filesystem."
    mount | grep /mnt
    exit 1
  fi

  print_msg "Running pacstrap to install packages (this may take a while)"

  # pacstrap passes --noconfirm unless -i is given and runs unattended without
  # a flag of its own. SNAP_PAC_SKIP reaches the alpm hooks through pacman's
  # environment: snapper has no configuration yet, and its post-transaction
  # hook would only fail noisily in the target.
  SNAP_PAC_SKIP=y pacstrap -K /mnt "${packages[@]}" || {
    print_error "pacstrap failed. Check internet connection and package names."
    exit 1
  }

  print_msg "Generate fstab"
  genfstab -U /mnt >>/mnt/etc/fstab

  # The filesystem package ships an fstab of comments only, so an entry for /
  # is what shows that genfstab wrote anything.
  if ! findmnt --tab-file /mnt/etc/fstab --mountpoint / >/dev/null; then
    print_error "genfstab wrote no entry for the root filesystem to" \
      "/mnt/etc/fstab."
    exit 1
  fi

  # genfstab copies the options the kernel reports, which never include
  # nodiscard. Without it, btrfs turns on discard=async at every boot; see
  # BTRFS_MOUNT_OPTS.
  sed -i -E 's/^([^#[:space:]]\S*\s+\S+\s+btrfs\s+)(\S+)/\1\2,nodiscard/' \
    /mnt/etc/fstab

  print_msg "Installed fstab:"
  cat /mnt/etc/fstab
}

# Configures the installed system, one function per area. Each arch-chroot call
# mounts /proc, /sys, /dev and /run itself, so no step mounts them here.
configure_system() {
  print_msg "Starting system configuration"

  configure_basic_system

  # Users: root and the regular user in the wheel group. Passwords are prompted
  # for outside the chroot.
  prompt_for_passwords
  configure_users

  # Hibernation swapfile. Must run before configure_boot: it writes resume=
  # into /etc/cmdline.d/, which mkinitcpio embeds in the UKI.
  configure_hibernation

  # Plymouth boot splash. Must run before configure_boot: the plymouth hook
  # reads the default theme, and the kernel parameters are embedded in the UKI.
  configure_plymouth

  # Boot setup: installs every file the Limine packages read, and writes
  # /etc/cmdline.d/10-root.conf, which configure_limine_tool mirrors.
  configure_boot
  configure_limine_tool

  # Last: installing limine-mkinitcpio-hook fires its pacman hook, which builds
  # the UKIs straight away from the configuration written above.
  install_limine_hooks

  configure_snapshots

  enable_services

  # Last, and not fatal: an unreachable AUR should not fail an install that is
  # otherwise complete.
  install_aur_helper
}

# Configures the time zone, locale, hostname and system tuning.
configure_basic_system() {
  print_msg "Configuring basic system settings"

  # Outside the chroot: with --root, systemd-firstboot skips reloading the
  # console over D-Bus.
  print_msg "Setting keymap to ${KEYMAP}"
  systemd-firstboot --root=/mnt --keymap="${KEYMAP}"

  print_msg "Setting locale to ${LOCALE}"
  sed "s|@LOCALE@|${LOCALE}|g" "${LOCALE_CONF_SRC}" \
    | install -D -m 0644 /dev/stdin /mnt/etc/locale.conf

  print_msg "Setting hostname to ${HOSTNAME}"
  echo "${HOSTNAME}" >/mnt/etc/hostname
  sed "s|@HOSTNAME@|${HOSTNAME}|g" "${HOSTS_SRC}" \
    | install -D -m 0644 /dev/stdin /mnt/etc/hosts

  print_msg "Configuring ZRAM"
  install -D -m 0644 "${ZRAM_CONF_SRC}" \
    /mnt/etc/systemd/zram-generator.conf.d/90-zram.conf

  # Reclaim tuning for swap on zram, network buffers, BBR, and the kernel and
  # TCP/IP hardening. tcp_bbr has to be registered before sysctl can select it.
  print_msg "Applying sysctl tuning"
  local sysctl_file
  for sysctl_file in "${SYSCTL_FILES[@]}"; do
    install -D -m 0644 "${SYSCTL_SRC}/${sysctl_file}" \
      "/mnt/etc/sysctl.d/${sysctl_file}"
  done
  install -D -m 0644 "${MODULES_LOAD_SRC}" /mnt/etc/modules-load.d/bbr.conf

  # A crashed process's memory image never reaches the disk.
  print_msg "Disabling core dumps"
  install -D -m 0644 "${COREDUMP_CONF_SRC}" \
    /mnt/etc/systemd/coredump.conf.d/10-disable-coredumps.conf

  print_msg "Capping the journal size"
  install -D -m 0644 "${JOURNALD_CONF_SRC}" \
    /mnt/etc/systemd/journald.conf.d/10-journal-size.conf

  # Both packages ship their own timers.target.wants symlink: the timers are
  # already active, and only their schedules change.
  print_msg "Rescheduling the index rebuilds"
  install -D -m 0644 "${MANDB_TIMER_SRC}" \
    /mnt/etc/systemd/system/man-db.timer.d/override.conf
  install -D -m 0644 "${UPDATEDB_TIMER_SRC}" \
    /mnt/etc/systemd/system/plocate-updatedb.timer.d/override.conf

  # Three files: system services, the session's services and user@.service
  # itself, which carries its own 120s timeout the default cannot reach.
  print_msg "Shortening the shutdown timeouts"
  local shutdown_file
  for shutdown_file in "${SHUTDOWN_CONF_FILES[@]}"; do
    install -D -m 0644 "${SHUTDOWN_CONF_SRC}/${shutdown_file}" \
      "/mnt/etc/systemd/${shutdown_file}"
  done

  # Without this, the index would skip every Btrfs subvolume and include every
  # snapshot: the wrong half of the filesystem in both directions.
  print_msg "Scoping the locate index"
  install -D -m 0644 "${UPDATEDB_SERVICE_SRC}" \
    /mnt/etc/systemd/system/plocate-updatedb.service.d/override.conf

  # XDG Base Directory variables for every login, including the niri session.
  print_msg "Setting the XDG Base Directories"
  install -D -m 0644 "${XDG_PROFILE_SRC}" /mnt/etc/profile.d/00-xdg.sh
  install -D -m 0644 "${XDG_BASH_PROFILE_SRC}" /mnt/etc/profile.d/zz-xdg-bash.sh
  # /etc/vimrc is where Arch expects system-wide additions; pacman keeps the
  # edited file on upgrades.
  cat "${VIM_XDG_SRC}" >>/mnt/etc/vimrc

  # Editor, pager and colored man pages for every login.
  print_msg "Setting the default programs"
  install -D -m 0644 "${DEFAULTS_PROFILE_SRC}" /mnt/etc/profile.d/10-defaults.sh

  # A drop-in, leaving /etc/ssh/sshd_config as the package ships it. Keys only,
  # and only this account: remote login needs a key placed from the console.
  print_msg "Hardening sshd"
  sed "s|@USERNAME@|${USERNAME}|g" "${SSHD_CONF_SRC}" \
    | install -D -m 0644 /dev/stdin /mnt/etc/ssh/sshd_config.d/10-hardening.conf

  # Rotating IPv6 addresses, and no Wi-Fi power save.
  print_msg "Configuring NetworkManager"
  local nm_file
  for nm_file in "${NM_CONF_FILES[@]}"; do
    install -D -m 0644 "${NM_CONF_SRC}/${nm_file}" \
      "/mnt/etc/NetworkManager/conf.d/${nm_file}"
  done

  arch-chroot /mnt env TIMEZONE="${TIMEZONE}" LOCALE="${LOCALE}" \
    /bin/bash -e <<'EOF'
echo "==> Setting timezone to ${TIMEZONE}"
ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
hwclock --systohc

# Anchored with the trailing space, so that en_GB does not also enable
# en_GB.UTF-8.
echo "==> Generating locales"
sed -i 's/^#\(en_US.UTF-8 \)/\1/' /etc/locale.gen
sed -i 's/^#\(en_GB.UTF-8 \)/\1/' /etc/locale.gen
sed -i "s/^#\(${LOCALE} \)/\1/" /etc/locale.gen
locale-gen

echo "==> Configuring pacman"
sed -i "/Color/s/^#//" /etc/pacman.conf
sed -i '/^Color/a ILoveCandy' /etc/pacman.conf
sed -i "/VerbosePkgLists/s/^#//" /etc/pacman.conf
# Whether the package ships the line commented out or set, as pacman 7 does.
sed -i 's/^#\?ParallelDownloads = .*/ParallelDownloads = 16/' /etc/pacman.conf
sed -i '/\[multilib\]/,/Include/s/^#//' /etc/pacman.conf
pacman -Sy
EOF
}

# Prompts for the password of an account into the variable named by $2. An
# empty or mismatched entry falls back to 'changeme' and adds the account to
# PASSWORD_FALLBACK; $3 is the command that changes the password later.
prompt_password() {
  local account=$1 change_command=$3 confirm
  local -n password=$2

  # read trims leading and trailing whitespace on purpose, so an entry of only
  # spaces counts as empty.
  print_msg "Setting password for ${account}"
  echo "Please enter password for ${account}:"
  read -rs password
  echo
  echo "Please confirm password for ${account}:"
  read -rs confirm
  echo

  if [[ -n "${password}" && "${password}" == "${confirm}" ]]; then
    print_msg "Password for ${account} set successfully"
    return
  fi
  if [[ -z "${password}" ]]; then
    print_msg "Password is empty. Setting temporary password 'changeme'"
  else
    print_msg "Passwords do not match. Setting temporary password 'changeme'"
  fi
  password="changeme"
  PASSWORD_FALLBACK+="${account} "
  print_warning "Change the password for ${account} after the first login" \
    "with: ${change_command}"
}

# Prompts for both passwords, outside the chroot.
prompt_for_passwords() {
  # Non-interactive mode sets temporary passwords instead of prompting.
  if [[ "${NON_INTERACTIVE}" -eq 1 ]]; then
    print_msg "Non-interactive mode: Setting default temporary passwords"
    USER_PASSWORD="changeme"
    ROOT_PASSWORD="changeme"
    PASSWORD_FALLBACK="${USERNAME} root "
    return
  fi

  prompt_password "${USERNAME}" USER_PASSWORD "passwd"
  prompt_password root ROOT_PASSWORD "sudo passwd root"
}

# Creates the user and sets both passwords, prompted for outside the chroot.
configure_users() {
  print_msg "Configuring users"

  # The target is freshly installed, so an account of that name comes from a
  # package, such as a service user from --packages, and would gain a password
  # and SSH access.
  if arch-chroot /mnt id "${USERNAME}" &>/dev/null; then
    print_error "Username '${USERNAME}' is taken by a system account that a" \
      "package created. Rerun with another --username."
    exit 1
  fi
  print_msg "Creating user ${USERNAME}"
  arch-chroot /mnt useradd -m -G wheel -s /bin/bash "${USERNAME}"

  # less and Python write their history into the XDG state directory, which
  # neither creates. Created as the user, which gives it the right owner.
  arch-chroot /mnt runuser -u "${USERNAME}" -- mkdir -p -m 0700 \
    "/home/${USERNAME}/.local/state"

  # Bash reads the user's configuration from XDG directories instead of the
  # skeleton files useradd copied, which are removed while still unchanged.
  print_msg "Moving the bash configuration to XDG directories"
  local skel_file
  for skel_file in .bashrc .bash_profile .bash_logout; do
    if cmp -s "/mnt/home/${USERNAME}/${skel_file}" \
      "/mnt/etc/skel/${skel_file}"; then
      rm -f "/mnt/home/${USERNAME}/${skel_file}"
    fi
  done
  install -D -m 0644 "${USER_BASHRC_SRC}" \
    "/mnt/home/${USERNAME}/.config/bash/bashrc"
  arch-chroot /mnt chown -R "${USERNAME}:" "/home/${USERNAME}/.config"

  # Both passwords reach chpasswd on stdin. Interpolated into a command string
  # they break on any quote character the passphrase happens to contain.
  printf '%s:%s\n' "${USERNAME}" "${USER_PASSWORD}" | arch-chroot /mnt chpasswd
  printf '%s:%s\n' root "${ROOT_PASSWORD}" | arch-chroot /mnt chpasswd

  # 0440 and root-owned, or sudo refuses to read them.
  print_msg "Configuring sudo"
  local sudoers_file
  for sudoers_file in "${SUDOERS_FILES[@]}"; do
    install -D -m 0440 "${SUDOERS_SRC}/${sudoers_file}" \
      "/mnt/etc/sudoers.d/${sudoers_file}"
  done
}

# Configures hibernation.
#
# A swapfile the size of RAM in its own Btrfs subvolume, an fstab entry at
# pri=0 and resume= parameters for the initramfs.
#
# Notes on this setup:
#   - No 'resume' mkinitcpio hook. That hook is only required by a busybox
#     initramfs. The 'systemd' hook used here already ships
#     systemd-hibernate-resume, which reads the same resume= parameters.
#   - resume= goes into /etc/cmdline.d/, which mkinitcpio embeds in the UKI,
#     instead of a limine-entry-tool drop-in. It must therefore be written
#     before configure_boot runs mkinitcpio.
#   - No swapon. In the installer that would activate swap on the live ISO's
#     kernel and pin /mnt, blocking the unmount. map-swapfile does not need an
#     active swapfile, and the fstab entry activates it on first boot.
configure_hibernation() {
  print_msg "Configuring hibernation"

  # Turns the keyboard backlight off before hibernating; the hook itself
  # explains why.
  if [[ -f /sys/power/image_size ]]; then
    print_msg "Installing keyboard-backlight system-sleep hook"
    install -D -m 0755 "${SLEEP_HOOK_SRC}" \
      /mnt/usr/lib/systemd/system-sleep/keyboard-backlight
  fi

  arch-chroot /mnt /bin/bash -e <<'EOF'
if [[ ! -f /sys/power/image_size ]]; then
  echo "Hibernation is not supported on this system, skipping swapfile setup."
  exit 0
fi

SWAP_SUBVOLUME="/swap"
SWAP_FILE="/swap/swapfile"

# A Btrfs subvolume cannot be snapshotted while it holds an active swapfile,
# which is why the swapfile gets a subvolume of its own. Nested under @, it is
# also left out of snapshots of the root subvolume. +C (NODATACOW) is required:
# Btrfs swapfiles cannot be copy-on-write, checksummed or compressed.
if ! btrfs subvolume show "${SWAP_SUBVOLUME}" &>/dev/null; then
  echo "==> Creating Btrfs subvolume ${SWAP_SUBVOLUME}"
  btrfs subvolume create "${SWAP_SUBVOLUME}"
  chattr +C "${SWAP_SUBVOLUME}"
fi

# Sized to total RAM, large enough for a full memory image.
if ! swaplabel "${SWAP_FILE}" &>/dev/null; then
  echo "==> Creating swapfile in Btrfs subvolume"
  MEM_TOTAL_KB="$(awk '/MemTotal/ {print $2}' /proc/meminfo)k"
  btrfs filesystem mkswapfile -s "${MEM_TOTAL_KB}" "${SWAP_FILE}"
fi

# pri=0 sits below zram (priority 100): everyday swapping goes to compressed
# RAM, and this file is effectively reserved for hibernation images.
if ! grep -Fq "${SWAP_FILE}" /etc/fstab; then
  echo "==> Adding swapfile to /etc/fstab"
  {
    printf "\n# Btrfs swapfile for system hibernation\n"
    printf "%s none swap defaults,pri=0 0 0\n" "${SWAP_FILE}"
  } >>/etc/fstab
fi

# Tells the initramfs where the hibernation image is. Without these, resume only
# happens late (after the GPU drivers load) and fails. The offset is physical,
# relative to the unlocked LUKS device -- which is why it comes from
# map-swapfile and not filefrag.
echo "==> Adding resume kernel parameters"
RESUME_DEVICE=$(findmnt -no SOURCE --first-only -T "${SWAP_FILE}" \
  | sed 's/\[.*\]//')
RESUME_OFFSET=$(btrfs inspect-internal map-swapfile -r "${SWAP_FILE}")
if [[ -n "${RESUME_OFFSET}" ]]; then
  mkdir -p /etc/cmdline.d
  echo "resume=${RESUME_DEVICE}" \
    "resume_offset=${RESUME_OFFSET}" >/etc/cmdline.d/30-resume.conf
  echo "Resume device: ${RESUME_DEVICE}, offset: ${RESUME_OFFSET}"
else
  echo "WARNING: Could not determine resume offset for ${SWAP_FILE};" \
    "hibernation will not resume." >&2
fi
EOF

  # The live ISO runs on the target hardware, and /sys/power/mem_sleep reports
  # the same suspend modes the installed system will see.
  if grep -q "\[s2idle\]" /sys/power/mem_sleep 2>/dev/null; then
    print_msg "Enabling ACPI RTC alarm for s2idle suspend"
    install -D -m 0644 "${CMDLINE_SRC}/20-rtc-alarm.conf" \
      /mnt/etc/cmdline.d/20-rtc-alarm.conf
  fi
}

# Configures Plymouth.
#
# The theme in /usr/share/plymouth/themes/, Theme= in
# /etc/plymouth/plymouthd.conf, the plymouth mkinitcpio hook and the quiet-boot
# kernel command line.
#
# Notes on this setup:
#   - No FILES+=(/etc/vconsole.conf) drop-in. The sd-vconsole hook already
#     copies vconsole.conf in; vconsole-latin only rewrites its layout.
#   - The kernel parameters go into /etc/cmdline.d/, which is mirrored to
#     /etc/default/limine for limine-entry-tool.
#
# Must run before configure_boot: the plymouth hook reads the default theme when
# mkinitcpio builds the UKI, and the command line is embedded at the same time.
configure_plymouth() {
  print_msg "Configuring Plymouth"

  local theme_dir="/mnt/usr/share/plymouth/themes/arch-linux"

  # The whole theme directory is copied; files added to it need no script
  # change. --no-preserve gives root-owned files 0644 and directories 0755.
  print_msg "Installing Plymouth theme"
  install -d -m 0755 "${theme_dir}"
  cp -rT --no-preserve=mode,ownership "${PLYMOUTH_THEME_SRC}" "${theme_dir}"
  install -D -m 0644 "${PLYMOUTHD_CONF_SRC}" /mnt/etc/plymouth/plymouthd.conf

  print_msg "Installing Plymouth kernel parameters"
  install -D -m 0644 "${CMDLINE_SRC}/80-initramfs-async.conf" \
    /mnt/etc/cmdline.d/80-initramfs-async.conf
  install -D -m 0644 "${CMDLINE_SRC}/85-console.conf" \
    /mnt/etc/cmdline.d/85-console.conf
  install -D -m 0644 "${CMDLINE_SRC}/90-splash.conf" \
    /mnt/etc/cmdline.d/90-splash.conf

  arch-chroot /mnt /bin/bash -e <<'EOF'
echo "==> Setting default Plymouth theme"
# Fails if the theme or its plugin is missing, which would otherwise only show
# up as an error from the plymouth hook during mkinitcpio.
plymouth-set-default-theme arch-linux
echo "Default theme: $(plymouth-set-default-theme)"
EOF
}

# Installs the Limine configuration, the initramfs hooks and the command line.
configure_boot() {
  print_msg "Configuring boot"

  # The boot files belong on the ESP, which mount_filesystems mounted as FAT.
  # Empty output means nothing is mounted there.
  if [[ "$(findmnt -n -o FSTYPE --mountpoint /mnt/boot)" != "vfat" ]]; then
    print_error "/mnt/boot is not the FAT-formatted EFI partition."
    exit 1
  fi

  # Limine reads it from the root of the boot volume. It carries only global
  # options; limine-entry-tool adds the boot entries once its package is
  # installed.
  print_msg "Installing Limine configuration"
  install -D -m 0644 "${LIMINE_CONF_SRC}" /mnt/boot/limine.conf

  # Local install hooks go in /etc/initcpio/install/, which mkinitcpio searches
  # before /usr/lib/initcpio/install/. Hook files are sourced, not executed.
  print_msg "Installing mkinitcpio hook vconsole-latin"
  install -D -m 0644 "${VCONSOLE_LATIN_HOOK_SRC}" \
    /mnt/etc/initcpio/install/vconsole-latin

  # HOOKS comes from a drop-in rather than an edit to /etc/mkinitcpio.conf,
  # which stays as the package ships it. Drop-ins are read after the main file.
  print_msg "Installing mkinitcpio drop-in hooks.conf"
  install -D -m 0644 "${MKINITCPIO_HOOKS_CONF_SRC}" \
    /mnt/etc/mkinitcpio.conf.d/hooks.conf

  # blkid prints nothing and still succeeds when it cannot read a UUID. An
  # empty one would pass the later checks for rd.luks.name and leave a system
  # that cannot unlock its root.
  local root_uuid pattern
  pattern='^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$'
  root_uuid=$(blkid -s UUID -o value "${ROOT_PART}")
  if [[ ! "${root_uuid}" =~ ${pattern} ]]; then
    print_error "Could not read the UUID of the LUKS container on" \
      "${ROOT_PART}."
    exit 1
  fi
  print_msg "Installing kernel command line for root UUID ${root_uuid}"
  sed "s|@ROOT_UUID@|${root_uuid}|g" "${CMDLINE_SRC}/10-root.conf" \
    | install -D -m 0644 /dev/stdin /mnt/etc/cmdline.d/10-root.conf

  arch-chroot /mnt /bin/bash -e <<'EOF'
if [[ ! -f /boot/vmlinuz-linux ]]; then
  echo "ERROR: /boot/vmlinuz-linux not found inside chroot. Kernel install" \
    "may have failed!" >&2
  echo "Contents of /boot:" >&2
  ls -ltr /boot >&2
  echo "Installed packages:" >&2
  pacman -Q | grep ^linux >&2
  exit 1
fi

# The EFI binaries and the removable-media fallback are not copied here.
# limine-install deploys them when limine-mkinitcpio-hook is installed; copying
# them first would only give it a limine_x64.bak to create on a fresh ESP.

echo "==> Removing stale Limine UEFI boot entries"
# The disk was just repartitioned: any entry with this label points at a
# partition that no longer exists. Registering the new one is left to
# limine-install, which runs when limine-mkinitcpio-hook is installed; creating
# one here as well would leave the firmware with two entries of the same name.
while read -r bootnum; do
  echo "Removing stale entry Boot${bootnum}"
  efibootmgr --bootnum "${bootnum}" --delete-bootnum >/dev/null \
    || echo "WARNING: could not remove Boot${bootnum}" >&2
done < <(efibootmgr 2>/dev/null \
  | awk '$1 ~ /^Boot[0-9A-Fa-f]{4}\*?$/ && $2 == "Limine" {
      print substr($1, 5, 4)
    }')

echo "==> UEFI boot entries:"
efibootmgr || echo "WARNING: efibootmgr failed"
EOF
}

# Assembles the kernel command line the way mkinitcpio does when it embeds it in
# the UKI: every *.conf in /etc/cmdline.d/ in version-sort order, comments
# stripped, joined with spaces.
assemble_cmdline() {
  local -a files=()

  mapfile -t files < <(find /mnt/etc/cmdline.d -maxdepth 1 -type f \
    -name '*.conf' 2>/dev/null \
    | LC_ALL=C.UTF-8 sort -V)

  if [[ "${#files[@]}" -eq 0 ]]; then
    echo ""
    return 0
  fi

  grep -ha -- '^[^#]' "${files[@]}" | tr -s '\n' ' ' | sed 's/[[:space:]]*$//'
}

# limine-entry-tool reads a command line only from /etc/kernel/cmdline or
# /proc/cmdline, never from /etc/cmdline.d/. Inside the installer /proc/cmdline
# belongs to the live ISO, which is why the real one is written where the tool
# looks.
configure_limine_tool() {
  local cmdline

  print_msg "Configuring limine-entry-tool"

  cmdline=$(assemble_cmdline)

  if ! grep -q 'rd\.luks\.name=' <<<"${cmdline}" \
    || ! grep -q '\broot=' <<<"${cmdline}"; then
    print_error "The assembled command line has no rd.luks.name= or root=" \
      "parameter:"
    print_error "  ${cmdline}"
    exit 1
  fi

  install -D -m 0644 "${LIMINE_TOOL_CONF_SRC}" \
    /mnt/etc/limine-entry-tool.d/50-arch.conf

  install -D -m 0644 /dev/stdin /mnt/etc/default/limine <<EOF
# Written by base-install.sh from /etc/cmdline.d/, which stays the source of
# truth for the kernel command line. After changing anything there, mirror it
# here and run 'limine-mkinitcpio'.
KERNEL_CMDLINE[default]+=${cmdline}
EOF
}

# The Limine snapshot packages are prebuilt and shipped in this repository:
# building them needs a GraalVM toolchain and several GB of RAM, which does not
# belong in an installer. pacman pulls their runtime dependencies from the
# official repositories.
install_limine_hooks() {
  print_msg "Installing the Limine snapshot packages"

  install -d -m 0755 /mnt/var/cache/pacman/pkg
  cp "${LIMINE_PKG_SRC}"/*.pkg.tar.zst /mnt/var/cache/pacman/pkg/

  # SNAP_PAC_SKIP stops snap-pac from taking pre/post snapshots of this
  # transaction. Snapper has no configuration yet, and its hooks would only fail
  # noisily in the chroot with 'fatal library error, lookup self'.
  arch-chroot /mnt env SNAP_PAC_SKIP=y bash -c \
    'pacman -U --noconfirm \
      /var/cache/pacman/pkg/limine-mkinitcpio-hook-*.pkg.tar.zst \
      /var/cache/pacman/pkg/limine-snapper-sync-*.pkg.tar.zst'

  # Installing the package fires its own pacman hook, which builds the UKIs
  # immediately -- which is why every piece of configuration it reads has to be
  # in place before this runs.
  arch-chroot /mnt /bin/bash -e <<'EOF'
# The hook overrides mkinitcpio's pacman hook and builds the UKIs by calling
# mkinitcpio directly; the preset pacstrap generated is never read again.
# Leaving it behind invites a manual 'mkinitcpio -P' to write UKIs that
# disagree with the entries in limine.conf.
rm -f /etc/mkinitcpio.d/linux.preset

if [[ ! -f /boot/EFI/Linux/arch_linux.efi ]]; then
  echo "==> Generating UKIs"
  limine-mkinitcpio
fi

# pacstrap ran mkinitcpio with the stock preset, which wrote plain initramfs
# images. Now that /boot is the ESP those sit on the FAT partition costing a few
# hundred MiB, and nothing boots them -- the UKIs replaced them.
rm -f /boot/initramfs-linux.img /boot/initramfs-linux-fallback.img

if [[ ! -f /boot/EFI/Linux/arch_linux.efi ]]; then
  echo "ERROR: /boot/EFI/Linux/arch_linux.efi not found. UKI generation" \
    "failed!" >&2
  find /boot/EFI -ls >&2
  exit 1
fi
EOF
}

# Snapshots of the root subvolume, and a Limine entry for each one.
configure_snapshots() {
  print_msg "Configuring Snapper"

  if ! arch-chroot /mnt test -x /usr/bin/limine-snapper-sync; then
    print_warning "limine-snapper-sync is missing; skipping snapshot" \
      "configuration."
    return 0
  fi

  # create-config makes its own /.snapshots subvolume and refuses to run when
  # the path already exists, which is why no such subvolume is created earlier,
  # and why this only runs when there is no config yet.
  if [[ ! -f /mnt/etc/snapper/configs/root ]]; then
    arch-chroot /mnt snapper --no-dbus -c root create-config /
  fi

  install -D -m 0644 "${SNAPPER_CONFIG_SRC}" /mnt/etc/snapper/configs/root
  install -D -m 0644 "${SNAPPER_CONFD_SRC}" /mnt/etc/conf.d/snapper

  arch-chroot /mnt systemctl enable snapper-cleanup.timer \
    limine-snapper-sync.service
}

# makepkg refuses to run as root, and the user has no password-free sudo. Only
# the build therefore runs as the user. Everything that needs root -- the build
# dependency, the install, removing the dependency again -- runs as root around
# it, which avoids granting a temporary NOPASSWD rule that could outlive a
# failed build.
install_aur_helper() {
  print_msg "Installing the paru AUR helper"

  if ! arch-chroot /mnt env SNAP_PAC_SKIP=y AUR_USER="${USERNAME}" \
    /bin/bash -e <<'EOF'; then
# /var/tmp rather than /tmp: arch-chroot mounts /tmp as tmpfs, and a Rust build
# is large enough to matter in RAM.
build_dir=$(mktemp -d -p /var/tmp paru-build.XXXXXX)
installed_rust=0

cleanup() {
  rm -rf "${build_dir}"
  # rust is removed only if this build installed it; --packages may have
  # requested it.
  if [[ "${installed_rust}" -eq 1 ]]; then
    pacman -Rns --noconfirm rust >/dev/null || true
  fi
}
trap cleanup EXIT

# paru's makedepends is cargo, which rust and rustup both provide. rust is named
# explicitly to keep --noconfirm from choosing a provider.
if ! pacman -Q rust &>/dev/null; then
  pacman -S --needed --noconfirm --asdeps rust
  installed_rust=1
fi

chown "${AUR_USER}": "${build_dir}"

# HOME and CARGO_HOME point inside the build directory, leaving neither the
# cargo registry nor anything else behind in the user's home.
as_user() {
  runuser -u "${AUR_USER}" -- env HOME="${build_dir}" \
    CARGO_HOME="${build_dir}/cargo" "$@"
}

as_user git clone --depth 1 https://aur.archlinux.org/paru.git \
  "${build_dir}/paru"
cd "${build_dir}/paru"
as_user makepkg --noconfirm

# makepkg.conf enables debug, and the build also produces paru-debug.
mapfile -t packages < <(as_user makepkg --packagelist | grep -v -- '-debug-')
pacman -U --noconfirm "${packages[@]}"
EOF
    print_warning "paru could not be installed. The system is otherwise" \
      "complete;"
    print_warning "build it after first boot from" \
      "https://aur.archlinux.org/paru.git"
  fi
}

# Enables the system services.
enable_services() {
  print_msg "Enabling services"
  arch-chroot /mnt /bin/bash -e <<'EOF'
systemctl enable systemd-resolved systemd-timesyncd \
  systemd-zram-setup@zram0.service sshd NetworkManager
systemctl mask systemd-networkd

# Periodic TRIM. The filesystems are mounted 'nodiscard': freed blocks are
# discarded once a week in one batch instead of on every delete, as Arch,
# Debian and Red Hat all recommend. TRIM reaches the SSD because the LUKS
# container is opened with --allow-discards.
systemctl enable fstrim.timer
EOF
}

# Checks that the installed system has everything it needs to boot.
verify_installation() {
  print_msg "Verifying critical components"

  if [[ ! -d "/mnt/boot/EFI" ]]; then
    print_error "EFI directory not found at /boot/EFI. The system will not" \
      "boot."
    print_error "Check that the EFI partition is mounted at /mnt/boot."
    VERIFY_FAILED=1
  fi

  print_msg "Checking boot files"
  if [[ ! -f "/mnt/boot/EFI/Linux/arch_linux.efi" ]]; then
    print_error "UKI not found at /boot/EFI/Linux/arch_linux.efi. The system" \
      "will not boot."
    print_error "Rebuild it with: arch-chroot /mnt limine-mkinitcpio"
    VERIFY_FAILED=1
  fi

  if [[ ! -f "/mnt/boot/EFI/limine/limine_x64.efi" ]] \
    && [[ ! -f "/mnt/boot/EFI/BOOT/BOOTX64.EFI" ]]; then
    print_error "Limine not found. The system will not boot."
    print_error "Reinstall it with: arch-chroot /mnt limine-install"
    VERIFY_FAILED=1
  fi

  if [[ ! -f "/mnt/boot/limine.conf" ]]; then
    print_error "Limine configuration not found at /boot/limine.conf."
    print_error "Rebuild it with: arch-chroot /mnt limine-mkinitcpio"
    VERIFY_FAILED=1
  fi

  # The UKI embeds the command line assembled from /etc/cmdline.d/. This checks
  # that the root and LUKS parameters are in the source file.
  print_msg "Checking kernel command line"
  if ! grep -q "rd.luks.name" /mnt/etc/cmdline.d/10-root.conf 2>/dev/null; then
    print_warning "No rd.luks.name in /etc/cmdline.d/10-root.conf; the UKI" \
      "may not unlock the disk."
  fi

  # A swapfile without resume parameters swaps fine but can never resume from
  # hibernation, and nothing else would point that out.
  if grep -q "/swap/swapfile" /mnt/etc/fstab 2>/dev/null; then
    print_msg "Checking hibernation setup"
    if ! grep -q "resume_offset=[0-9]" /mnt/etc/cmdline.d/30-resume.conf \
      2>/dev/null; then
      print_warning "Swapfile configured but /etc/cmdline.d/30-resume.conf" \
        "has no resume_offset; hibernation will not resume."
    fi
  fi

  # Plymouth shows only the theme plymouthd.conf names, and only if the hook is
  # in the UKI; with either missing, the system still boots, to a plain-text
  # passphrase prompt.
  print_msg "Checking Plymouth setup"
  if ! grep -qx "Theme=arch-linux" /mnt/etc/plymouth/plymouthd.conf \
    2>/dev/null; then
    print_warning "Plymouth theme is not set to 'arch-linux' in" \
      "/etc/plymouth/plymouthd.conf."
  fi
  if ! grep -Eq '^HOOKS=\(.*\bplymouth\b' \
    /mnt/etc/mkinitcpio.conf.d/hooks.conf 2>/dev/null; then
    print_warning "plymouth is missing from HOOKS in" \
      "/etc/mkinitcpio.conf.d/hooks.conf; there will be no boot splash."
  fi

  print_msg "Checking user setup"
  if ! arch-chroot /mnt id "${USERNAME}" &>/dev/null; then
    print_warning "User ${USERNAME} not properly created."
  fi

  # ESP details, recorded in the log.
  if mountpoint -q "/mnt/boot"; then
    print_msg "EFI partition information:"
    file -sL "$(findmnt -n -o SOURCE --first-only "/mnt/boot")"
    print_msg "EFI partition contents:"
    find "/mnt/boot" -type f \( -name "*.efi" -o -name "*.EFI" \) | sort
  else
    print_warning "EFI partition not mounted, cannot check its contents."
  fi
}

# The Arch Linux installation image uses zsh as its default shell. Any parent
# other than zsh or a program that starts a login session marks a nested shell.
check_shell_nesting() {
  local arg parent_cmd
  for arg in "$@"; do
    case "${arg}" in -h | --help) return 0 ;; esac
  done

  parent_cmd="$(ps -o comm= -p "${PPID}")"

  case "${parent_cmd}" in
    login | agetty | systemd | zsh)
      print_msg "Top-level shell detected (parent: ${parent_cmd})"
      echo
      ;;
    *)
      print_error "This script must be started from a top-level shell, not" \
        "from ${parent_cmd}."
      exit 1
      ;;
  esac
}

# Re-runs the installer under script(1), which records everything printed on
# the terminal to the log. A pipe through tee would also capture it, but pacman,
# cryptsetup and makepkg change behavior when output is not a terminal, losing
# progress bars and color. Typed passwords are never logged: input is not
# recorded, and password prompts do not echo.
#
# The timestamp in the file name is the first run's. A later run in the same
# checkout appends to that file: one log covers an install that needed several
# attempts, and script(1) marks where each run starts and ends.
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
  log_file=$(find "${LOG_DIR}" -maxdepth 1 -name 'base-install-*.log' \
    | sort \
    | tail -n 1)
  if [[ -z "${log_file}" ]]; then
    log_file="${LOG_DIR}/base-install-$(date +%Y%m%d-%H%M%S).log"
  fi
  print_msg "Logging to ${log_file}"

  # script(1) runs the command through $SHELL; bash, to match the quoting.
  local command
  command=$(printf '%q ' env ARCH_INSTALL_LOG="${log_file}" \
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
  print_heading "ARCH LiNUX iNSTALLATiON SCRiPT"
  echo
}

# Copies the repository, including the log up to this point, to the new user's
# home. It runs last; a failure only warns, since it does not undo a finished
# install.
copy_installer_to_home() {
  local name target
  name=$(basename "${SCRIPT_DIR}")
  target="/home/${USERNAME}/${name}"

  print_msg "Copying the installer and its log to ${target}"
  if mkdir -p "/mnt${target}" && cp -a "${SCRIPT_DIR}/." "/mnt${target}/"; then
    arch-chroot /mnt chown -R "${USERNAME}:" "${target}" \
      || print_warning "Copied, but ownership of ${target} could not be set."
  else
    print_warning "Could not copy the installer to ${target}."
  fi
}

# Prints the installation summary.
print_summary() {
  echo
  print_heading "iNSTALLATiON SUMMARY"
  echo "${WHITE}Disk:${NO_COLOR} ${DISK}"
  echo "${WHITE}EFI Partition:${NO_COLOR} ${EFI_PART}"
  echo "${WHITE}Root Partition:${NO_COLOR} ${ROOT_PART} (encrypted)"
  echo "${WHITE}Hostname:${NO_COLOR} ${HOSTNAME}"
  echo "${WHITE}Username:${NO_COLOR} ${USERNAME}"
  echo "${WHITE}Timezone:${NO_COLOR} ${TIMEZONE}"
  echo "${WHITE}Microcode:${NO_COLOR} ${MICROCODE}"
  echo "${WHITE}Btrfs Subvolumes:${NO_COLOR} ${SUBVOLUMES}"
  echo

  echo "${WHITE}Boot Setup Status:${NO_COLOR}"
  if [[ -f "/mnt/boot/EFI/Linux/arch_linux.efi" ]]; then
    echo " ${WHITE}- UKI present:${NO_COLOR} Yes" \
      "(/boot/EFI/Linux/arch_linux.efi)"
  else
    echo " ${WHITE}- UKI present:${NO_COLOR} No (missing)"
  fi

  if [[ -f "/mnt/boot/EFI/Linux/arch_linux-fallback.efi" ]]; then
    echo " ${WHITE}- Fallback UKI:${NO_COLOR} Yes" \
      "(/boot/EFI/Linux/arch_linux-fallback.efi)"
  else
    echo " ${WHITE}- Fallback UKI:${NO_COLOR} No (missing)"
  fi

  if [[ -f "/mnt/boot/EFI/limine/limine_x64.efi" ]]; then
    echo " ${WHITE}- Limine:${NO_COLOR} Yes (/boot/EFI/limine/limine_x64.efi)"
  else
    echo " ${WHITE}- Limine:${NO_COLOR} No (missing)"
  fi

  if [[ -f "/mnt/boot/EFI/BOOT/BOOTX64.EFI" ]]; then
    echo " ${WHITE}- Removable fallback:${NO_COLOR} Yes" \
      "(/boot/EFI/BOOT/BOOTX64.EFI)"
  else
    echo " ${WHITE}- Removable fallback:${NO_COLOR} No (missing)"
  fi

  if [[ -f "/mnt/boot/limine.conf" ]]; then
    echo " ${WHITE}- Limine config:${NO_COLOR} Yes (/boot/limine.conf)"
  else
    echo " ${WHITE}- Limine config:${NO_COLOR} No (missing)"
  fi

  echo
  echo "${WHITE}The disk is unlocked with the LUKS passphrase. There is no" \
    "second"
  echo "credential: losing the passphrase means losing the data.${NO_COLOR}"

  if [[ -n "${PASSWORD_FALLBACK}" ]]; then
    echo
    echo "${YELLOW}The temporary password 'changeme' was set for:" \
      "${PASSWORD_FALLBACK% }"
    echo "Log in with it and change it immediately:"
    if [[ " ${PASSWORD_FALLBACK}" == *" ${USERNAME} "* ]]; then
      echo "  ${USERNAME}: passwd"
    fi
    if [[ " ${PASSWORD_FALLBACK}" == *" root "* ]]; then
      echo "  root: sudo passwd root"
    fi
    printf '%s' "${NO_COLOR}"
  fi

  echo
  if [[ "${VERIFY_FAILED}" -eq 1 ]]; then
    echo "${RED}==>${WHITE} Finished with errors, and the system may not" \
      "boot.${NO_COLOR}"
    echo "    ${WHITE}Fix the errors above before rebooting; /mnt stays" \
      "mounted for arch-chroot.${NO_COLOR}"
  else
    echo "${BLUE}==>${WHITE} Done. Ready to reboot!${NO_COLOR}"
  fi
  echo "${BLUE}==>${WHITE} Secure Boot is not configured by this script:" \
    "leave it disabled${NO_COLOR}"
  echo "    ${WHITE}in the BIOS for now.${NO_COLOR}"
  echo "${BLUE}==>${WHITE} After reboot, log in as ${USERNAME}${NO_COLOR}"

  # Troubleshooting tips when verification failed or a boot file is missing.
  if [[ "${VERIFY_FAILED}" -eq 1 ]] \
    || [[ ! -f "/mnt/boot/EFI/Linux/arch_linux.efi" ]] \
    || [[ ! -f "/mnt/boot/EFI/BOOT/BOOTX64.EFI" ]]; then
    echo
    print_heading "BOOT TROUBLESHOOTiNG"
    echo "If the system does not boot, try these steps:"
    echo "1. From the UEFI/BIOS setup, make sure Secure Boot is disabled"
    echo "2. Make sure the EFI partition is set as the primary boot device"
    echo "3. If it still does not boot, try rebuilding the boot setup:"
    echo "  - Boot from the Arch Linux installation media"
    echo "  - Open the encrypted root: cryptsetup open ${ROOT_PART} cryptroot"
    echo "  - Mount the filesystems: mount -o subvol=@ /dev/mapper/cryptroot" \
      "/mnt"
    echo "  - Mount the ESP: mount ${EFI_PART} /mnt/boot"
    echo "  - Chroot: arch-chroot /mnt"
    echo "  - Rerun: limine-install && limine-mkinitcpio"
    echo "  - Exit chroot and reboot"
  fi
}

# Runs every installation step in order.
main() {
  # Only EXIT runs cleanup: a signal handler would see the status of whatever
  # command the signal interrupted, which is 0 more often than not. Converting
  # the signals to an exit gives cleanup the real code, and only one trap fires.
  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  # Runs before the re-run under script(1), whose process would fail the
  # parent check.
  if [[ -z "${ARCH_INSTALL_LOG:-}" ]]; then
    check_shell_nesting "$@"
    start_logging "$@"
  fi

  print_logo

  parse_args "$@"

  validate_secure_boot

  validate_inputs
  setup_partitions
  confirm_operation

  create_partitions
  format_partitions
  setup_btrfs
  mount_filesystems

  install_base_system
  configure_system

  verify_installation
  print_summary
  copy_installer_to_home

  if [[ "${VERIFY_FAILED}" -eq 1 ]]; then
    exit 1
  fi
}

# Entry point.
main "$@"
