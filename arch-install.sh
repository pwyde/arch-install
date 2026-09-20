#!/bin/bash
# arch-install.sh v1.0
#
# A comprehensive Arch Linux installation script with LUKS encryption, TPM2 unlocking,
# Btrfs subvolumes, the Limine bootloader and Unified Kernel Image (UKI).
#
# Features:
# - Full disk encryption with LUKS2
# - TPM2 integration
# - Btrfs filesystem with customizable subvolumes
# - Unified Kernel Image booted by Limine
# - Customizable installation parameters
# - Error handling and validation
#
# Usage: ./arch-install.sh [options]
# See --help for available options

set -euo pipefail

# Define default variables
DEFAULT_DISK=$(lsblk -dpno NAME | grep -vE '/dev/(loop|zram|sr|ram)' | head -n1)
DEFAULT_HOSTNAME="arch-linux"
DEFAULT_USERNAME="admin"
DEFAULT_TIMEZONE="Europe/Stockholm"
DEFAULT_KEYMAP="sv-latin1"
DEFAULT_LOCALE="sv_SE.UTF-8"
# No snapshots subvolume here on purpose: 'snapper create-config' creates its
# own /.snapshots and refuses to run when the path already exists.
DEFAULT_SUBVOLUMES="@ @home @cache @log @root"
# mkinitcpio and iptables are named explicitly. They provide the virtual
# packages 'initramfs' and 'libxtables.so', which have several providers each,
# and pacstrap runs with --noconfirm, so the choice would otherwise come from
# whichever provider pacman happens to list first.
DEFAULT_PACKAGES="base base-devel bash-completion btrfs-progs cryptsetup dosfstools efibootmgr git iptables limine linux linux-firmware man-db man-pages mkinitcpio nano networkmanager openssh plymouth snap-pac snapper sudo terminus-font unzip util-linux vim zram-generator"

# Color variables
RED=$'\033[91m'
GREEN=$'\033[92m'
BLUE=$'\033[94m'
YELLOW=$'\033[93m'
WHITE=$'\033[1;97m'
NO_COLOR=$'\033[0m'

# Set once this script opens the LUKS container, so cleanup only closes one it
# opened itself and never an unrelated cryptroot that was already mapped.
CRYPTROOT_OPENED=0

# Only EXIT runs cleanup: a signal handler would see the status of whatever
# command the signal interrupted, which is 0 more often than not. Converting the
# signals to an exit gives cleanup the real code, and only one trap fires.
trap cleanup EXIT
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

# Cleanup function for unexpected exits
cleanup() {
  local exit_code=$?

  # Only run cleanup if the script errors out
  if [ $exit_code -ne 0 ]; then
    print_error "Script exited with error code $exit_code. Performing cleanup..."

    # Clean up chroot special mounts first
    if mountpoint -q /mnt/proc 2>/dev/null ||
      mountpoint -q /mnt/sys 2>/dev/null ||
      mountpoint -q /mnt/dev 2>/dev/null ||
      mountpoint -q /mnt/run 2>/dev/null; then
      print_msg "Cleaning up chroot mounts"
      cleanup_chroot
    fi

    # Unmount all filesystems if they exist
    if mountpoint -q /mnt 2>/dev/null; then
      print_msg "Unmounting filesystems"
      umount -Rf /mnt 2>/dev/null || true
    fi

    # Only the container this script opened; an already-mapped cryptroot
    # belongs to the running system.
    if [ "${CRYPTROOT_OPENED:-0}" -eq 1 ] && [ -e "/dev/mapper/cryptroot" ]; then
      print_msg "Closing LUKS container"
      cryptsetup close cryptroot 2>/dev/null || true
    fi

    print_msg "Cleanup complete. Please check the logs for errors."
  fi
}

# Global variables
DISK=""
EFI_PART=""
ROOT_PART=""
HOSTNAME=""
USERNAME=""
TIMEZONE=""
SUBVOLUMES=""
EXTRA_PACKAGES=""
NON_INTERACTIVE=0
MICROCODE=""

# ESP mount options. FAT has no permission bits, so they come from the mount:
# files 0600, directories 0700, all owned by root. This matches what mkinitcpio
# would have given them on a normal filesystem -- it builds initramfs images and
# UKIs under `umask 077` precisely because an initramfs can carry secrets such as
# a LUKS keyfile. Without this the kernel and the UKIs on /boot are
# world-readable.
ESP_MOUNT_OPTS="fmask=0177,dmask=0077"

# Btrfs mount options applied to every subvolume.
#   compress=zstd:3 - btrfs's own default level, a better ratio than level 1 for
#     a modest CPU cost. It only affects newly written data, so it is worth
#     setting correctly at install time rather than later.
#   noatime - every atime update on a CoW filesystem is a metadata write that
#     also makes snapshots diverge from their parent for no content change.
#   nodiscard - the LUKS container is opened with --allow-discards, so the
#     device supports TRIM and btrfs would otherwise turn on continuous
#     discard=async by default (kernel 6.2+). Arch, Debian and Red Hat all
#     recommend periodic TRIM instead, so fstrim.timer is enabled rather than
#     trimming on every delete.
BTRFS_MOUNT_OPTS="compress=zstd:3,noatime,nodiscard"

# Repository files
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLYMOUTH_THEME_SRC="${SCRIPT_DIR}/default/plymouth/arch-linux"
PLYMOUTHD_CONF_SRC="${SCRIPT_DIR}/etc/plymouth/plymouthd.conf"
LIMINE_CONF_SRC="${SCRIPT_DIR}/default/limine/limine.conf"
VCONSOLE_LATIN_HOOK_SRC="${SCRIPT_DIR}/etc/initcpio/install/vconsole-latin"
MKINITCPIO_HOOKS_CONF_SRC="${SCRIPT_DIR}/etc/mkinitcpio.conf.d/hooks.conf"
CMDLINE_SRC="${SCRIPT_DIR}/etc/cmdline.d"
CMDLINE_FILES="20-rtc-alarm.conf 80-initramfs-async.conf 90-splash.conf"
LOCALE_CONF_SRC="${SCRIPT_DIR}/etc/locale.conf"
ZRAM_CONF_SRC="${SCRIPT_DIR}/etc/systemd/zram-generator.conf.d/90-zram.conf"
SUDOERS_SRC="${SCRIPT_DIR}/etc/sudoers.d"
SUDOERS_FILES="00-wheel 01-timeout 02-passwd-tries"
SLEEP_HOOK_SRC="${SCRIPT_DIR}/default/systemd/system-sleep/keyboard-backlight"
SNAPPER_CONFIG_SRC="${SCRIPT_DIR}/default/snapper/root"
SNAPPER_CONFD_SRC="${SCRIPT_DIR}/etc/conf.d/snapper"
LIMINE_TOOL_CONF_SRC="${SCRIPT_DIR}/etc/limine-entry-tool.d/50-arch.conf"
# Prebuilt AUR packages. They are compiled with GraalVM native-image, which is
# far too heavy to run during an install; see README.md for how to rebuild them.
LIMINE_PKG_SRC="${SCRIPT_DIR}/packages"
LIMINE_PKGS="limine-mkinitcpio-hook limine-snapper-sync"

# Default start at beginning
START_STAGE="partitions"

# Password variables
USER_PASSWORD=""
ROOT_PASSWORD=""
USER_PASSWORD_VALID=0
ROOT_PASSWORD_VALID=0

# Help function
show_help() {
  cat <<EOF
Arch Linux Installation Script

Usage: $(basename "$0") [options]

Options:
  -h, --help                 Show this help message
  -d, --disk DISK            Specify disk (default: $DEFAULT_DISK)
  -n, --hostname HOSTNAME    Set hostname (default: $DEFAULT_HOSTNAME)
  -u, --username USERNAME    Set username (default: $DEFAULT_USERNAME)
  -t, --timezone TIMEZONE    Set timezone (default: $DEFAULT_TIMEZONE)
  -k, --keymap KEYMAP        Set keymap (default: $DEFAULT_KEYMAP)
  -l, --locale LOCALE        Set locale (default: $DEFAULT_LOCALE)
  -s, --subvolumes SUBVOLS   Btrfs subvolumes, space-separated (default: $DEFAULT_SUBVOLUMES)
  -p, --packages PACKAGES    Additional packages to install (appended to defaults)
  -y, --yes                  Non-interactive mode, use defaults for prompts
  --stage STAGE              Start from specific installation stage:
                             'partitions', 'format', 'btrfs', 'mount',
                             'base', 'configure', 'users', 'boot', 'verify'

Example:
  $(basename "$0") --disk /dev/sda --hostname mymachine --username myuser
  $(basename "$0") --stage users --hostname mymachine --username myuser

EOF
  exit 0
}

# Process command line arguments
parse_args() {
  DISK="$DEFAULT_DISK"
  HOSTNAME="$DEFAULT_HOSTNAME"
  USERNAME="$DEFAULT_USERNAME"
  TIMEZONE="$DEFAULT_TIMEZONE"
  KEYMAP="$DEFAULT_KEYMAP"
  LOCALE="$DEFAULT_LOCALE"
  SUBVOLUMES="$DEFAULT_SUBVOLUMES"
  START_STAGE="partitions" # Default start at beginning

  while [[ $# -gt 0 ]]; do
    case $1 in
    -h | --help)
      show_help
      ;;
    -d | --disk)
      DISK="$2"
      shift 2
      ;;
    -n | --hostname)
      HOSTNAME="$2"
      shift 2
      ;;
    -u | --username)
      USERNAME="$2"
      shift 2
      ;;
    -t | --timezone)
      TIMEZONE="$2"
      shift 2
      ;;
    -k | --kaymap)
      KEYMAP="$2"
      shift 2
      ;;
    -l | --locale)
      LOCALE="$2"
      shift 2
      ;;
    -s | --subvolumes)
      SUBVOLUMES="$2"
      shift 2
      ;;
    -p | --packages)
      EXTRA_PACKAGES="$2"
      shift 2
      ;;
    -y | --yes)
      NON_INTERACTIVE=1
      shift
      ;;
    --stage)
      START_STAGE="$2"
      shift 2
      ;;
    *)
      echo "Unknown option: $1"
      show_help
      ;;
    esac
  done
}

# Exits when Secure Boot is on, since nothing written to the ESP is signed.
validate_secure_boot() {
  local sb_var state=""

  sb_var="/sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c"

  if [ -r "$sb_var" ]; then
    # Four bytes of EFI variable attributes, then the state byte.
    state=$(od -An -t u1 -j 4 -N 1 "$sb_var" 2>/dev/null | tr -d '[:space:]')
  elif command -v bootctl >/dev/null 2>&1; then
    local sb_line
    sb_line=$(bootctl status 2>/dev/null | grep -m1 "Secure Boot:" || true)
    case "$sb_line" in
      *enabled*) state=1 ;;
      *disabled*) state=0 ;;
    esac
  fi

  case "$state" in
    1)
      print_error "Secure Boot is enabled. Disable it in the firmware setup before installing."
      print_error "Nothing installed here is signed, so the system would not boot."
      print_error "This installation does not sign its boot files; leave Secure Boot off."
      exit 1
      ;;
    0)
      print_msg "Secure Boot is disabled"
      ;;
    *)
      # No SecureBoot variable means the firmware does not implement Secure Boot.
      print_warning "Could not determine the Secure Boot state; assuming it is disabled."
      ;;
  esac
}

# systemd-firstboot --root only checks the keymap name is well-formed, not that it exists.
validate_keymap() {
  if [ -z "$(find /usr/share/kbd/keymaps -name "${KEYMAP}.map*" -print -quit 2>/dev/null)" ]; then
    print_error "Keymap '${KEYMAP}' is not installed."
    exit 1
  fi
}

# Validate inputs
validate_inputs() {
  # Check if disk exists
  if [ ! -b "$DISK" ]; then
    print_error "Disk $DISK does not exist or is not a block device."
    exit 1
  fi

  # Check if we're running as root
  if [ "$(id -u)" -ne 0 ]; then
    print_error "This script must be run as root."
    exit 1
  fi

  # Check if we're booted in UEFI mode
  if [ ! -d /sys/firmware/efi/efivars ]; then
    print_error "System not booted in UEFI mode. This script requires UEFI boot."
    exit 1
  fi

  validate_keymap

  # Everything the installer copies out of this repository. Checked now, before
  # the disk is wiped, rather than failing halfway through the install.
  local repo_file
  local -a repo_files=(
    # Stands in for the whole theme directory, which is copied with cp -rT.
    "${PLYMOUTH_THEME_SRC}/arch-linux.plymouth"
    "$PLYMOUTHD_CONF_SRC"
    "$LIMINE_CONF_SRC"
    "$VCONSOLE_LATIN_HOOK_SRC"
    "$MKINITCPIO_HOOKS_CONF_SRC"
    "$LOCALE_CONF_SRC"
    "$ZRAM_CONF_SRC"
    "$SLEEP_HOOK_SRC"
    "$SNAPPER_CONFIG_SRC"
    "$SNAPPER_CONFD_SRC"
    "$LIMINE_TOOL_CONF_SRC"
  )
  for repo_file in $CMDLINE_FILES; do
    repo_files+=("${CMDLINE_SRC}/${repo_file}")
  done
  for repo_file in $SUDOERS_FILES; do
    repo_files+=("${SUDOERS_SRC}/${repo_file}")
  done

  for repo_file in "${repo_files[@]}"; do
    [ -f "$repo_file" ] && continue
    print_error "Missing repository file: $repo_file"
    print_error "Run the script from a full checkout of the repository."
    exit 1
  done

  local pkg_name
  local -a pkg_files
  for pkg_name in $LIMINE_PKGS; do
    pkg_files=("${LIMINE_PKG_SRC}/${pkg_name}"-*.pkg.tar.zst)
    if [ ! -f "${pkg_files[0]}" ]; then
      print_error "Missing prebuilt package: ${LIMINE_PKG_SRC}/${pkg_name}-*.pkg.tar.zst"
      print_error "See README.md for how to build it."
      exit 1
    fi
  done

  # Check for required tools
  for tool in sgdisk cryptsetup mkfs.fat mkfs.btrfs; do
    if ! command -v "$tool" &>/dev/null; then
      print_error "Required tool '$tool' not found. Please install it first."
      exit 1
    fi
  done
}

setup_luks() {
  # Prompt for LUKS passphrase if not already set
  if [ -z "${LUKS_PASSPHRASE:-}" ]; then
    read -rs -p "Enter LUKS passphrase: " LUKS_PASSPHRASE
    echo # ensure a newline after prompt
  fi

  # Attempt to open the LUKS container non-interactively
  if ! echo "$LUKS_PASSPHRASE" | cryptsetup open "$ROOT_PART" cryptroot --key-file=-; then
    print_error "Failed to open LUKS container."
    print_msg "This might be due to a previous LUKS header still being detected."
    exit 1
  fi
  CRYPTROOT_OPENED=1
}

# Setup partitions based on disk
setup_partitions() {
  # Derive partition names based on disk
  if [[ "$DISK" =~ nvme || "$DISK" =~ mmcblk ]]; then
    EFI_PART="${DISK}p1"
    ROOT_PART="${DISK}p2"
  else
    EFI_PART="${DISK}1"
    ROOT_PART="${DISK}2"
  fi

  # Auto-detect CPU type for microcode
  if grep -q GenuineIntel /proc/cpuinfo; then
    MICROCODE="intel-ucode"
  elif grep -q AuthenticAMD /proc/cpuinfo; then
    MICROCODE="amd-ucode"
  else
    print_warning "Could not detect CPU type. Microcode will not be installed."
    MICROCODE=""
  fi
}

# Confirm before proceeding
confirm_operation() {
  if [ "$NON_INTERACTIVE" -eq 0 ]; then
    echo "WARNING: This will erase ALL data on $DISK"
    echo "The following partitions will be created:"
    echo "  $EFI_PART: 2048MB (EFI System Partition)"
    echo "  $ROOT_PART: Rest of disk (Linux LUKS)"
    read -r -p "Are you sure you want to continue? (y/N) " REPLY
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
      echo "Installation cancelled."
      exit 1
    fi
  fi
}

# Create disk partitions
create_partitions() {
  print_msg "Creating partitions on $DISK"

  # Make sure the disk is not in use
  for part in $(lsblk -npo NAME "$DISK" | tail -n +2); do
    umount "$part" 2>/dev/null || true
  done
  swapoff -a || true

  # Close any existing LUKS containers
  for mapper in /dev/mapper/*; do
    [ -e "$mapper" ] || continue
    if [ "$mapper" != "/dev/mapper/control" ]; then
      cryptsetup close "$mapper" 2>/dev/null || true
    fi
  done

  # Create new partition table - FIXED PARTITIONING
  print_msg "Creating new GPT partition table on $DISK"
  sgdisk --zap-all "$DISK" # Zap existing partitions
  sgdisk --clear "$DISK"   # Create fresh GPT
  sleep 1

  # Create EFI System Partition - 2GB
  print_msg "Creating EFI System Partition"
  sgdisk --new=1:0:+2048M --typecode=1:ef00 --change-name=1:"EFI System" "$DISK"

  # Create root partition (rest of disk)
  print_msg "Creating root partition"
  sgdisk --new=2:0:0 --typecode=2:8309 --change-name=2:"Linux LUKS" "$DISK"

  # Make sure the kernel knows about the new partition table
  print_msg "Informing kernel of partition table change"
  partprobe "$DISK"
  sleep 3

  print_msg "Checking new partition table"
  sgdisk --print "$DISK"

  # Ensure partitions exist before proceeding
  for _ in $(seq 1 10); do
    if [ -b "$EFI_PART" ] && [ -b "$ROOT_PART" ]; then
      break
    fi
    print_msg "Waiting for partitions to appear..."
    sleep 1
  done

  if [ ! -b "$EFI_PART" ] || [ ! -b "$ROOT_PART" ]; then
    print_error "Partitions did not appear after creation!"
    print_msg "EFI partition ($EFI_PART) exists: $(test -b "$EFI_PART" && echo "Yes" || echo "No")"
    print_msg "Root partition ($ROOT_PART) exists: $(test -b "$ROOT_PART" && echo "Yes" || echo "No")"
    exit 1
  fi
}

# Format partitions
format_partitions() {
  print_msg "Format EFI partition with FAT32"
  mkfs.fat -F32 -n "EFI" "$EFI_PART"

  # Check if cryptroot is already open and close it
  if [ -e "/dev/mapper/cryptroot" ]; then
    print_msg "Found existing cryptroot mapping, attempting to close it..."
    umount -R /mnt 2>/dev/null || true
    cryptsetup close cryptroot || {
      print_error "Could not close existing cryptroot mapping."
      print_msg "Please manually unmount and close with: umount -R /mnt; cryptsetup close cryptroot"
      exit 1
    }
  fi

  # Check if the partition is already a LUKS container
  if cryptsetup isLuks "$ROOT_PART" 2>/dev/null; then
    print_msg "Partition $ROOT_PART already has a LUKS header, removing it..."
    # Force wipe the first few MB where LUKS header exists
    dd if=/dev/zero of="$ROOT_PART" bs=1M count=10 status=progress
    sync
  fi

  # Create LUKS container
  print_msg "Creating new LUKS container on $ROOT_PART..."
  cryptsetup luksFormat --type luks2 -v "$ROOT_PART"

  # Open the container
  print_msg "Opening LUKS container..."
  if ! cryptsetup --allow-discards --persistent open "$ROOT_PART" cryptroot; then
    print_error "Failed to open LUKS container."
    print_msg "This might be due to a previous LUKS header still being detected."
    exit 1
  fi
  CRYPTROOT_OPENED=1
}

# Resuming mid-install needs the container open. A failed run closes it, so any
# stage after 'format' has to be able to reopen it.
ensure_cryptroot_open() {
  [ -e /dev/mapper/cryptroot ] && return 0

  if [ ! -b "$ROOT_PART" ]; then
    print_error "Root partition $ROOT_PART not found."
    exit 1
  fi

  if ! cryptsetup isLuks "$ROOT_PART"; then
    print_error "$ROOT_PART is not a LUKS container."
    exit 1
  fi

  # Discards are persistent in the header from luksFormat, so a plain open
  # keeps them without rewriting it.
  print_msg "Opening LUKS container on $ROOT_PART"
  if ! cryptsetup open "$ROOT_PART" cryptroot; then
    print_error "Failed to open LUKS container."
    exit 1
  fi
  CRYPTROOT_OPENED=1
}

# Stages from 'base' onwards expect the subvolumes and the ESP in place. A
# failed run leaves them unmounted, so resuming has to mount them again.
ensure_mounted() {
  ensure_cryptroot_open

  if ! mountpoint -q /mnt; then
    print_msg "Filesystems are not mounted; mounting them for this stage"
    mount_filesystems
    return 0
  fi

  # Root can be mounted while the ESP is not, and everything from the base
  # install onwards writes to it.
  if ! mountpoint -q /mnt/boot && [ -b "$EFI_PART" ]; then
    print_msg "Mounting EFI partition to /mnt/boot"
    mkdir -p /mnt/boot
    mount -o "$ESP_MOUNT_OPTS" "$EFI_PART" /mnt/boot ||
      print_warning "Could not mount the EFI partition. Boot setup might fail!"
  fi
}

# Setup Btrfs filesystem with subvolumes
setup_btrfs() {
  print_msg "Format and layout Btrfs"
  mkfs.btrfs -L "ArchRoot" /dev/mapper/cryptroot

  print_msg "Mounting Btrfs root for subvolume creation"
  mount /dev/mapper/cryptroot /mnt

  print_msg "Creating Btrfs subvolumes"
  for subvol in $SUBVOLUMES; do
    print_msg "Creating subvolume $subvol"
    btrfs subvolume create "/mnt/$subvol"
  done

  print_msg "Unmounting temporary Btrfs mount"
  umount /mnt
}

# Mount all filesystems
mount_filesystems() {
  print_msg "Mount subvolumes"

  # Mount root subvolume first
  print_msg "Mounting root subvolume"
  mount -o "subvol=@,$BTRFS_MOUNT_OPTS" /dev/mapper/cryptroot /mnt || {
    print_error "Failed to mount root subvolume"
    print_msg "Debug info:"
    mount /dev/mapper/cryptroot /mnt
    ls -la /mnt/
    btrfs subvolume list /mnt
    umount /mnt
    exit 1
  }

  mkdir -p "/mnt/boot"
  print_msg "Mounting EFI partition to /mnt/boot"
  mount -o "$ESP_MOUNT_OPTS" "$EFI_PART" "/mnt/boot"

  # Create directories and mount other subvolumes if they exist
  print_msg "Mounting other subvolumes"
  for subvol in $SUBVOLUMES; do
    if [[ "$subvol" != "@" ]]; then
      # Convert '@subvol' format to '/subvol' path format
      local mountpoint

      # For special cases
      case "$subvol" in
      @home) mountpoint="/home" ;;
      @cache) mountpoint="/var/cache" ;;
      @log) mountpoint="/var/log" ;;
      *)
        mountpoint="${subvol#@}"
        mountpoint="/$mountpoint"
        ;;
      esac

      print_msg "Mounting subvolume $subvol to /mnt$mountpoint"
      mkdir -p "/mnt$mountpoint"
      mount -o "subvol=$subvol,$BTRFS_MOUNT_OPTS" /dev/mapper/cryptroot "/mnt$mountpoint" || {
        print_warning "Failed to mount subvolume $subvol to /mnt$mountpoint"
        continue
      }
    fi
  done

  # A fresh subvolume is 0755, but root's home is meant to be 0750, and pacman
  # warns about the difference when it installs the filesystem package.
  if mountpoint -q /mnt/root; then
    chmod 0750 /mnt/root
  fi

  print_msg "Mounted filesystems:"
  mount | grep "/mnt"
}

# Install base system
install_base_system() {
  print_msg "Install base system"
  local PACKAGES="$DEFAULT_PACKAGES $MICROCODE $EXTRA_PACKAGES"
  print_msg "Installing packages: $PACKAGES"

  # Ensure pacman keyring is initialized
  pacman-key --init
  pacman-key --populate archlinux

  # The ESP is /boot, so pacstrap writes the kernel straight onto it. If it is
  # not mounted yet the kernel lands on the Btrfs root and is then shadowed the
  # moment the ESP is mounted over it, leaving an unbootable system.
  if ! mountpoint -q "/mnt/boot"; then
    print_error "EFI partition is not mounted at /mnt/boot."
    print_error "It must be mounted before pacstrap, or the kernel will be installed to the wrong filesystem."
    mount | grep /mnt
    exit 1
  fi

  # Install base packages
  print_msg "Running pacstrap to install packages (this may take a while)"

  # pacstrap passes --noconfirm unless -i is given, so this needs no flag of its
  # own to run unattended. SNAP_PAC_SKIP reaches the alpm hooks through pacman's
  # environment: snapper has no configuration yet, so its post-transaction hook
  # would only fail noisily in the target.
  # shellcheck disable=SC2086
  SNAP_PAC_SKIP=y pacstrap -K /mnt $PACKAGES || {
    print_error "pacstrap failed. Check internet connection and package names."
    exit 1
  }

  print_msg "Generate fstab"
  genfstab -U /mnt >>/mnt/etc/fstab

  # Verify fstab was created properly
  if [ ! -s /mnt/etc/fstab ]; then
    print_error "fstab generation failed or produced empty file"
    exit 1
  fi

  print_msg "Installed fstab:"
  cat /mnt/etc/fstab
}

# Configure the system - split into smaller functions for better error handling
configure_system() {
  print_msg "Starting system configuration"

  # Prepare chroot environment once for all chroot operations
  prepare_chroot

  # Basic system configuration (timezone, locale, hostname)
  configure_basic_system

  # User setup (root, normal user, wheel group) - now with password prompting outside chroot
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

  # Enable services
  enable_services

  # Clean up chroot mounts
  cleanup_chroot
}

# Configure basic system settings
configure_basic_system() {
  print_msg "Configuring basic system settings"

  # Outside the chroot: --root makes systemd-firstboot skip reloading the console over D-Bus.
  print_msg "Setting keymap to ${KEYMAP}"
  validate_keymap
  systemd-firstboot --root=/mnt --keymap="${KEYMAP}"

  print_msg "Setting locale to ${LOCALE}"
  sed "s|@LOCALE@|${LOCALE}|g" "$LOCALE_CONF_SRC" |
    install -D -m 0644 /dev/stdin /mnt/etc/locale.conf

  print_msg "Configuring ZRAM"
  install -D -m 0644 "$ZRAM_CONF_SRC" /mnt/etc/systemd/zram-generator.conf.d/90-zram.conf

  arch-chroot /mnt /bin/bash -e <<EOF
echo "==> Setting timezone to ${TIMEZONE}"
ln -sf /usr/share/zoneinfo/${TIMEZONE} /etc/localtime
hwclock --systohc

echo "==> Setting hostname to ${HOSTNAME}"
echo "${HOSTNAME}" > /etc/hostname
cat > /etc/hosts <<EOL
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${HOSTNAME}.localdomain ${HOSTNAME}
EOL

echo "==> Generating locales"
sed -i 's/#\(en_US.UTF-8\)/\1/' /etc/locale.gen
sed -i 's/#\(en_GB.UTF-8\)/\1/' /etc/locale.gen
sed -i 's/#\(${LOCALE}\)/\1/' /etc/locale.gen
locale-gen

echo "==> Configuring pacman"
sed -i "/Color/s/^#//" /etc/pacman.conf
sed -i '/^Color/a ILoveCandy' /etc/pacman.conf
sed -i "/VerbosePkgLists/s/^#//" /etc/pacman.conf
sed -i 's/#ParallelDownloads = 5/ParallelDownloads = 16/' /etc/pacman.conf
sed -i '/\[multilib\]/,/Include/s/^#//' /etc/pacman.conf
pacman -Sy
EOF
}

# Prompt for passwords outside of chroot
prompt_for_passwords() {
  # Initialize password variables
  USER_PASSWORD=""
  USER_PASSWORD_CONFIRM=""
  ROOT_PASSWORD=""
  ROOT_PASSWORD_CONFIRM=""
  USER_PASSWORD_VALID=0
  ROOT_PASSWORD_VALID=0

  # Skip prompts in non-interactive mode
  if [ "$NON_INTERACTIVE" -eq 1 ]; then
    print_msg "Non-interactive mode: Setting default temporary passwords"
    USER_PASSWORD="changeme"
    ROOT_PASSWORD="changeme"
    return
  fi

  print_msg "Setting password for ${USERNAME}"
  echo "Please enter password for ${USERNAME}:"
  read -rs USER_PASSWORD
  echo
  echo "Please confirm password for ${USERNAME}:"
  read -rs USER_PASSWORD_CONFIRM
  echo

  if [ "$USER_PASSWORD" = "$USER_PASSWORD_CONFIRM" ]; then
    print_msg "Password for ${USERNAME} set successfully"
    USER_PASSWORD_VALID=1
  else
    print_msg "Passwords do not match. Setting temporary password 'changeme'"
    USER_PASSWORD="changeme"
    print_warning "You must change the password after first login with: passwd"
  fi

  print_msg "Setting root password"
  echo "Please enter password for root:"
  read -rs ROOT_PASSWORD
  echo
  echo "Please confirm password for root:"
  read -rs ROOT_PASSWORD_CONFIRM
  echo

  if [ "$ROOT_PASSWORD" = "$ROOT_PASSWORD_CONFIRM" ]; then
    print_msg "Root password set successfully"
    ROOT_PASSWORD_VALID=1
  else
    print_msg "Passwords do not match. Setting temporary password 'changeme'"
    ROOT_PASSWORD="changeme"
    print_warning "You must change the root password after installation with: sudo passwd root"
  fi
}

# Prepare chroot environment by mounting necessary filesystems
prepare_chroot() {
  print_msg "Preparing chroot environment"

  # Check if /mnt is mounted
  if ! mountpoint -q /mnt; then
    print_error "/mnt is not mounted. Please mount the root filesystem first."
    exit 1
  fi

  # Create necessary mount points if they do not exist
  mkdir -p /mnt/{proc,sys,dev,run}

  # Mount virtual filesystems if not already mounted
  if ! mountpoint -q /mnt/proc; then
    mount -t proc proc /mnt/proc
  fi
  if ! mountpoint -q /mnt/sys; then
    mount -t sysfs sys /mnt/sys
  fi
  if ! mountpoint -q /mnt/dev; then
    mount --rbind /dev /mnt/dev
    mount --make-rslave /mnt/dev
  fi
  if ! mountpoint -q /mnt/run; then
    mount --rbind /run /mnt/run
    mount --make-rslave /mnt/run
  fi

  print_msg "Chroot environment prepared"
}

# Clean up chroot mounts when done
cleanup_chroot() {
  print_msg "Cleaning up chroot mounts"

  # Only unmount if they exist and are mounted
  if mountpoint -q /mnt/run 2>/dev/null; then
    umount -l /mnt/run
  fi
  if mountpoint -q /mnt/dev 2>/dev/null; then
    umount -l /mnt/dev
  fi
  if mountpoint -q /mnt/sys 2>/dev/null; then
    umount /mnt/sys
  fi
  if mountpoint -q /mnt/proc 2>/dev/null; then
    umount /mnt/proc
  fi
}

# Configure users with passwords provided from outside chroot
configure_users() {
  print_msg "Configuring users"

  # Ensure chroot environment is prepared
  prepare_chroot

  # Pass the password variables explicitly to the chroot environment
  arch-chroot /mnt /bin/bash -c "
    # Create user (skip if already exists)
    echo '==> Creating user ${USERNAME}'
    if id '${USERNAME}' &>/dev/null; then
        echo 'User ${USERNAME} already exists, skipping creation'
    else
        useradd -m -G wheel -s /bin/bash '${USERNAME}'
        echo '${USERNAME}:${USER_PASSWORD}' | chpasswd
        if [ ${USER_PASSWORD_VALID} -eq 0 ]; then
            echo 'WARNING: You must change the password after first login with: passwd'
        fi
    fi

    # Set root password
    echo 'root:${ROOT_PASSWORD}' | chpasswd
    if [ ${ROOT_PASSWORD_VALID} -eq 0 ]; then
        echo 'WARNING: You must change the root password after installation with: sudo passwd root'
    fi
    "

  # 0440 and root-owned, or sudo refuses to read them.
  print_msg "Configuring sudo"
  local sudoers_file
  for sudoers_file in $SUDOERS_FILES; do
    install -D -m 0440 "${SUDOERS_SRC}/${sudoers_file}" "/mnt/etc/sudoers.d/${sudoers_file}"
  done

  # Clean up chroot mounts when done with this step
  cleanup_chroot
}

# Configure hibernation
#
# A swapfile the size of RAM in its own Btrfs subvolume, an fstab entry at
# pri=0, and resume= parameters for the initramfs.
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

  # Turns the keyboard backlight off before hibernating. See script file.
  if [ -f /sys/power/image_size ]; then
    print_msg "Installing keyboard-backlight system-sleep hook"
    install -D -m 0755 "$SLEEP_HOOK_SRC" /mnt/usr/lib/systemd/system-sleep/keyboard-backlight
  fi

  arch-chroot /mnt /bin/bash -e <<'EOF'
if [ ! -f /sys/power/image_size ]; then
  echo "Hibernation is not supported on this system, skipping swapfile setup."
  exit 0
fi

SWAP_SUBVOLUME="/swap"
SWAP_FILE="/swap/swapfile"

# A Btrfs subvolume cannot be snapshotted while it holds an active swapfile,
# so the swapfile gets a subvolume of its own. Nested under @, it is also left
# out of snapshots of the root subvolume. +C (NODATACOW) is required: Btrfs
# swapfiles cannot be copy-on-write, checksummed or compressed.
if ! btrfs subvolume show "$SWAP_SUBVOLUME" &>/dev/null; then
  echo "==> Creating Btrfs subvolume $SWAP_SUBVOLUME"
  btrfs subvolume create "$SWAP_SUBVOLUME"
  chattr +C "$SWAP_SUBVOLUME"
fi

# Sized to total RAM so a full memory image fits.
if ! swaplabel "$SWAP_FILE" &>/dev/null; then
  echo "==> Creating swapfile in Btrfs subvolume"
  MEM_TOTAL_KB="$(awk '/MemTotal/ {print $2}' /proc/meminfo)k"
  btrfs filesystem mkswapfile -s "$MEM_TOTAL_KB" "$SWAP_FILE"
fi

# pri=0 sits below zram (priority 100), so everyday swapping goes to compressed
# RAM and this file is effectively reserved for hibernation images.
if ! grep -Fq "$SWAP_FILE" /etc/fstab; then
  echo "==> Adding swapfile to /etc/fstab"
  printf "\n# Btrfs swapfile for system hibernation\n%s none swap defaults,pri=0 0 0\n" "$SWAP_FILE" >>/etc/fstab
fi

# Tell the initramfs where the hibernation image is. Without these, resume only
# happens late (after the GPU drivers load) and fails. The offset is physical,
# relative to the unlocked LUKS device -- which is why it comes from
# map-swapfile and not filefrag.
echo "==> Adding resume kernel parameters"
RESUME_DEVICE=$(findmnt -no SOURCE -T "$SWAP_FILE" | sed 's/\[.*\]//')
RESUME_OFFSET=$(btrfs inspect-internal map-swapfile -r "$SWAP_FILE")
if [ -n "$RESUME_OFFSET" ]; then
  mkdir -p /etc/cmdline.d
  echo "resume=$RESUME_DEVICE resume_offset=$RESUME_OFFSET" >/etc/cmdline.d/30-resume.conf
  echo "Resume device: $RESUME_DEVICE, offset: $RESUME_OFFSET"
else
  echo "WARNING: Could not determine resume offset for $SWAP_FILE; hibernation will not resume." >&2
fi
EOF

  # The live ISO runs on the target hardware, so /sys/power/mem_sleep reports
  # the same suspend modes the installed system will see.
  if grep -q "\[s2idle\]" /sys/power/mem_sleep 2>/dev/null; then
    print_msg "Enabling ACPI RTC alarm for s2idle suspend"
    install -D -m 0644 "${CMDLINE_SRC}/20-rtc-alarm.conf" /mnt/etc/cmdline.d/20-rtc-alarm.conf
  fi
}

# Configure Plymouth
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

  # The whole theme directory is copied, so files added to it need no script
  # change. --no-preserve gives root-owned files 0644 and directories 0755.
  print_msg "Installing Plymouth theme"
  install -d -m 0755 "$theme_dir"
  cp -rT --no-preserve=mode,ownership "$PLYMOUTH_THEME_SRC" "$theme_dir"
  install -D -m 0644 "$PLYMOUTHD_CONF_SRC" /mnt/etc/plymouth/plymouthd.conf

  print_msg "Installing Plymouth kernel parameters"
  install -D -m 0644 "${CMDLINE_SRC}/80-initramfs-async.conf" /mnt/etc/cmdline.d/80-initramfs-async.conf
  install -D -m 0644 "${CMDLINE_SRC}/90-splash.conf" /mnt/etc/cmdline.d/90-splash.conf

  arch-chroot /mnt /bin/bash -e <<'EOF'
echo "==> Setting default Plymouth theme"
# Fails if the theme or its plugin is missing, which would otherwise only show
# up as an error from the plymouth hook during mkinitcpio.
plymouth-set-default-theme arch-linux
echo "Default theme: $(plymouth-set-default-theme)"
EOF
}

# Configure boot
configure_boot() {
  print_msg "Configuring boot"

  # Ensure the EFI partition is mounted
  if ! mountpoint -q "/mnt/boot"; then
    print_warning "EFI partition not mounted at /mnt/boot. Attempting to mount."
    mkdir -p "/mnt/boot"
    if [ -b "$EFI_PART" ]; then
      if mount -o "$ESP_MOUNT_OPTS" "$EFI_PART" "/mnt/boot"; then
        print_msg "EFI partition mounted."
      else
        print_error "Failed to mount EFI partition. Boot setup will likely fail."
        if [ "$NON_INTERACTIVE" -eq 0 ]; then
          read -r -p "Continue anyway? (y/N) " REPLY
          echo
          if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            print_msg "Boot setup aborted."
            return 1
          fi
        else
          print_msg "Continuing anyway in non-interactive mode."
        fi
      fi
    else
      print_error "EFI partition $EFI_PART not found. Boot setup will likely fail."
      if [ "$NON_INTERACTIVE" -eq 0 ]; then
        read -r -p "Continue anyway? (y/N) " REPLY
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
          print_msg "Boot setup aborted."
          return 1
        fi
      else
        print_msg "Continuing anyway in non-interactive mode."
      fi
    fi
  fi

  # Check that the ESP partition is formatted as FAT
  if ! file -sL "$(findmnt -n -o SOURCE "/mnt/boot")" | grep -q "FAT"; then
    print_warning "WARNING: EFI System Partition is not formatted as FAT filesystem."
    print_msg "Current filesystem type: $(file -sL "$(findmnt -n -o SOURCE "/mnt/boot")")"
    if [ "$NON_INTERACTIVE" -eq 0 ]; then
      read -r -p "Format the EFI partition with FAT32? This will erase all data on it. (y/N) " REPLY
      echo
      if [[ $REPLY =~ ^[Yy]$ ]]; then
        umount "/mnt/boot"
        mkfs.fat -F32 -n "EFI" "$EFI_PART"
        mount -o "$ESP_MOUNT_OPTS" "$EFI_PART" "/mnt/boot"
        print_msg "EFI partition reformatted and remounted."
      else
        print_msg "Continuing without reformatting. Boot might fail."
      fi
    else
      print_msg "Continuing without reformatting in non-interactive mode."
    fi
  fi

  # Limine reads it from the root of the boot volume. 'boot():' in the entries
  # resolves to the partition holding this file.
  print_msg "Installing Limine configuration"
  install -D -m 0644 "$LIMINE_CONF_SRC" /mnt/boot/limine.conf

  # Local install hooks go in /etc/initcpio/install/, which mkinitcpio searches
  # before /usr/lib/initcpio/install/. Hook files are sourced, not executed.
  print_msg "Installing mkinitcpio hook vconsole-latin"
  install -D -m 0644 "$VCONSOLE_LATIN_HOOK_SRC" /mnt/etc/initcpio/install/vconsole-latin

  # HOOKS comes from a drop-in rather than an edit to /etc/mkinitcpio.conf,
  # which stays as the package ships it. Drop-ins are read after the main file.
  print_msg "Installing mkinitcpio drop-in hooks.conf"
  install -D -m 0644 "$MKINITCPIO_HOOKS_CONF_SRC" /mnt/etc/mkinitcpio.conf.d/hooks.conf

  arch-chroot /mnt env ROOT_PART="$ROOT_PART" /bin/bash -e <<'EOF'
# Get root partition UUID for boot configuration
ROOT_UUID=$(blkid -s UUID -o value "${ROOT_PART}")
echo "Using root UUID: ${ROOT_UUID}"

if [ ! -f /boot/vmlinuz-linux ]; then
  echo "ERROR: /boot/vmlinuz-linux not found inside chroot. Kernel install may have failed!" >&2
  echo "Contents of /boot:" >&2
  ls -ltr /boot >&2
  echo "Installed packages:" >&2
  pacman -Q | grep ^linux >&2
  exit 1
fi

echo "==> Adjust cmdline"
mkdir -p /etc/cmdline.d
cat > /etc/cmdline.d/10-root.conf <<EOL
rd.luks.name=${ROOT_UUID}=cryptroot root=/dev/mapper/cryptroot zswap.enabled=0 rw rootfstype=btrfs rootflags=subvol=/@
EOL

# limine-install deploys the EFI binaries and the removable-media fallback when
# limine-mkinitcpio-hook is installed. Putting them here first only gives it
# something to back up as limine_x64.bak on an otherwise fresh ESP.

echo "==> Removing stale Limine UEFI boot entries"
# The disk was just repartitioned, so any entry with this label points at a
# partition that no longer exists. Registering the new one is left to
# limine-install, which runs when limine-mkinitcpio-hook is installed; creating
# one here as well would leave the firmware with two entries of the same name.
while read -r bootnum; do
  echo "Removing stale entry Boot${bootnum}"
  efibootmgr --bootnum "$bootnum" --delete-bootnum >/dev/null ||
    echo "WARNING: could not remove Boot${bootnum}" >&2
done < <(efibootmgr 2>/dev/null |
  awk '$1 ~ /^Boot[0-9A-Fa-f]{4}\*?$/ && $2 == "Limine" { print substr($1, 5, 4) }')

echo "==> UEFI boot entries:"
efibootmgr || echo "WARNING: efibootmgr failed"
EOF
}

# Assembles the kernel command line the way mkinitcpio does when it embeds it in
# the UKI: every *.conf in /etc/cmdline.d/ in version-sort order, comments
# stripped, joined with spaces.
assemble_cmdline() {
  local -a files=()

  mapfile -t files < <(find /mnt/etc/cmdline.d -maxdepth 1 -type f -name '*.conf' 2>/dev/null |
    LC_ALL=C.UTF-8 sort -V)

  if [ "${#files[@]}" -eq 0 ]; then
    echo ""
    return 0
  fi

  grep -ha -- '^[^#]' "${files[@]}" | tr -s '\n' ' ' | sed 's/[[:space:]]*$//'
}

# limine-entry-tool reads a command line only from /etc/kernel/cmdline or
# /proc/cmdline, never from /etc/cmdline.d/. Inside the installer /proc/cmdline
# is the live ISO's, so the real one has to be written where the tool looks.
configure_limine_tool() {
  local cmdline

  print_msg "Configuring limine-entry-tool"

  cmdline=$(assemble_cmdline)

  if ! grep -q 'rd\.luks\.name=' <<<"$cmdline" || ! grep -q '\broot=' <<<"$cmdline"; then
    print_error "The assembled command line has no rd.luks.name= or root= parameter:"
    print_error "  ${cmdline}"
    exit 1
  fi

  install -D -m 0644 "$LIMINE_TOOL_CONF_SRC" /mnt/etc/limine-entry-tool.d/50-arch.conf

  install -D -m 0644 /dev/stdin /mnt/etc/default/limine <<EOF
# Written by arch-install.sh from /etc/cmdline.d/, which stays the source of
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

  # SNAP_PAC_SKIP stops snap-pac taking pre/post snapshots of this transaction.
  # Snapper has no configuration yet, so its hooks only fail noisily in the
  # chroot with 'fatal library error, lookup self'.
  arch-chroot /mnt env SNAP_PAC_SKIP=y bash -c \
    'pacman -U --noconfirm /var/cache/pacman/pkg/limine-mkinitcpio-hook-*.pkg.tar.zst /var/cache/pacman/pkg/limine-snapper-sync-*.pkg.tar.zst'

  # Installing the package fires its own pacman hook, which builds the UKIs
  # immediately -- which is why every piece of configuration it reads has to be
  # in place before this runs.
  arch-chroot /mnt /bin/bash -e <<'EOF'
# The hook overrides mkinitcpio's pacman hook and builds the UKIs by calling
# mkinitcpio directly, so the preset pacstrap generated is never read again.
# Leaving it behind invites a manual 'mkinitcpio -P' to write UKIs that
# disagree with the entries in limine.conf.
rm -f /etc/mkinitcpio.d/linux.preset

if [ ! -f /boot/EFI/Linux/arch_linux.efi ]; then
  echo "==> Generating UKIs"
  limine-mkinitcpio
fi

# pacstrap ran mkinitcpio with the stock preset, which wrote plain initramfs
# images. Now that /boot is the ESP those sit on the FAT partition costing a few
# hundred MiB, and nothing boots them -- the UKIs replaced them.
rm -f /boot/initramfs-linux.img /boot/initramfs-linux-fallback.img

if [ ! -f /boot/EFI/Linux/arch_linux.efi ]; then
  echo "ERROR: /boot/EFI/Linux/arch_linux.efi not found. UKI generation failed!" >&2
  find /boot/EFI -ls >&2
  exit 1
fi
EOF
}

# Snapshots of the root subvolume, and a Limine entry for each one.
configure_snapshots() {
  print_msg "Configuring Snapper"

  if ! arch-chroot /mnt test -x /usr/bin/limine-snapper-sync; then
    print_warning "limine-snapper-sync is missing; skipping snapshot configuration."
    return 0
  fi

  # create-config makes its own /.snapshots subvolume and refuses to run when
  # the path already exists, which is why no such subvolume is created earlier,
  # and why this only runs when there is no config yet.
  if [ ! -f /mnt/etc/snapper/configs/root ]; then
    arch-chroot /mnt snapper --no-dbus -c root create-config /
  fi

  install -D -m 0644 "$SNAPPER_CONFIG_SRC" /mnt/etc/snapper/configs/root
  install -D -m 0644 "$SNAPPER_CONFD_SRC" /mnt/etc/conf.d/snapper

  arch-chroot /mnt systemctl enable snapper-cleanup.timer limine-snapper-sync.service
}

# Enable services
enable_services() {
  print_msg "Enabling services"
  arch-chroot /mnt /bin/bash -e <<EOF
systemctl enable systemd-resolved systemd-timesyncd systemd-zram-setup@zram0.service sshd NetworkManager
systemctl mask systemd-networkd

# Periodic TRIM. The filesystems are mounted 'nodiscard', so freed blocks are
# discarded once a week in one batch instead of on every delete -- the shape
# Arch, Debian and Red Hat all recommend. It reaches the SSD because the LUKS
# container is opened with --allow-discards.
systemctl enable fstrim.timer
EOF
}

# Verify installation
verify_installation() {
  print_msg "Verifying critical components"

  # Check if EFI directory exists
  if [ ! -d "/mnt/boot/EFI" ]; then
    print_error "WARNING: EFI directory not found! Boot will not work properly."
    print_error "Please check that the EFI partition is properly mounted at /mnt/boot."
  fi

  # Check boot files
  print_msg "Checking boot files"
  if [ ! -f "/mnt/boot/EFI/Linux/arch_linux.efi" ]; then
    print_error "UKI not found at /boot/EFI/Linux/arch_linux.efi! System won't boot."
    print_error "Try rebuilding the boot configuration with: $0 --stage boot"
  fi

  # Check for bootloader
  if [ ! -f "/mnt/boot/EFI/limine/limine_x64.efi" ] && [ ! -f "/mnt/boot/EFI/BOOT/BOOTX64.EFI" ]; then
    print_error "Limine not found! System won't boot."
    print_error "Try reinstalling the bootloader with: $0 --stage boot"
  fi

  # Check for bootloader configuration
  if [ ! -f "/mnt/boot/limine.conf" ]; then
    print_error "Limine configuration not found at /boot/limine.conf!"
    print_error "Try rebuilding the boot configuration with: $0 --stage boot"
  fi

  # The UKI carries its own command line, so confirm it actually got embedded.
  print_msg "Checking kernel command line"
  if ! grep -q "rd.luks.name" /mnt/etc/cmdline.d/10-root.conf 2>/dev/null; then
    print_warning "No rd.luks.name in /etc/cmdline.d/10-root.conf; the UKI may not unlock the disk."
  fi

  # A swapfile without resume parameters swaps fine but can never resume from
  # hibernation, and nothing else would point that out.
  if grep -q "/swap/swapfile" /mnt/etc/fstab 2>/dev/null; then
    print_msg "Checking hibernation setup"
    if ! grep -q "resume_offset=[0-9]" /mnt/etc/cmdline.d/30-resume.conf 2>/dev/null; then
      print_warning "Swapfile configured but /etc/cmdline.d/30-resume.conf has no resume_offset; hibernation will not resume."
    fi
  fi

  # Plymouth only shows the theme plymouthd.conf names, and only if the hook is
  # in the UKI; either missing still boots, just to a plain text PIN prompt.
  print_msg "Checking Plymouth setup"
  if ! grep -qx "Theme=arch-linux" /mnt/etc/plymouth/plymouthd.conf 2>/dev/null; then
    print_warning "Plymouth theme is not set to 'arch-linux' in /etc/plymouth/plymouthd.conf."
  fi
  if ! grep -Eq '^HOOKS=\(.*\bplymouth\b' /mnt/etc/mkinitcpio.conf.d/hooks.conf 2>/dev/null; then
    print_warning "plymouth is missing from HOOKS in /etc/mkinitcpio.conf.d/hooks.conf; there will be no boot splash."
  fi

  # Check for essential files
  print_msg "Checking for essential files"
  # shellcheck disable=SC2043
  for file in /mnt/etc/fstab; do
    if [ ! -f "$file" ]; then
      print_warning "$file not found. This may cause problems."
    fi
  done

  # Check user setup
  print_msg "Checking user setup"
  if ! arch-chroot /mnt id "$USERNAME" &>/dev/null; then
    print_warning "User $USERNAME not properly created."
  fi

  # Show formatted EFI partition info
  if mountpoint -q "/mnt/boot"; then
    print_msg "EFI partition information:"
    file -sL "$(findmnt -n -o SOURCE "/mnt/boot")"
    print_msg "EFI partition contents:"
    find "/mnt/boot" -type f \( -name "*.efi" -o -name "*.EFI" \) | sort
  else
    print_warning "EFI partition not mounted, cannot check its contents."
  fi
}

check_shell_nesting() {
  PARENT_CMD="$(ps -o comm= -p "$(ps -o ppid= -p "$$" | xargs)")"

  if [ "$PARENT_CMD" != "login" ] && [ "$PARENT_CMD" != "agetty" ] && [ "$PARENT_CMD" != "systemd" ] && [ "$PARENT_CMD" != "zsh" ]; then
    print_msg "Exiting nested shell (parent: $PARENT_CMD)"
    exit
  else
    print_msg "Top-level shell detected (parent: $PARENT_CMD)"
    echo
  fi
}

print_logo() {
  # Colour is set around the heredoc rather than inside it, so the heredoc
  # stays quoted and the art is never subject to expansion.
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
}

# Print installation summary
print_summary() {
  echo
  echo "${WHITE}===${BLUE} INSTALLATION SUMMARY ${WHITE}===${NO_COLOR}"
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
  if [ -f "/mnt/boot/EFI/Linux/arch_linux.efi" ]; then
    echo " ${WHITE}- UKI present:${NO_COLOR} Yes (/boot/EFI/Linux/arch_linux.efi)"
  else
    echo " ${WHITE}- UKI present:${NO_COLOR} No (missing)"
  fi

  if [ -f "/mnt/boot/EFI/Linux/arch_linux-fallback.efi" ]; then
    echo " ${WHITE}- Fallback UKI:${NO_COLOR} Yes (/boot/EFI/Linux/arch_linux-fallback.efi)"
  else
    echo " ${WHITE}- Fallback UKI:${NO_COLOR} No (missing)"
  fi

  if [ -f "/mnt/boot/EFI/limine/limine_x64.efi" ]; then
    echo " ${WHITE}- Limine:${NO_COLOR} Yes (/boot/EFI/limine/limine_x64.efi)"
  else
    echo " ${WHITE}- Limine:${NO_COLOR} No (missing)"
  fi

  if [ -f "/mnt/boot/EFI/BOOT/BOOTX64.EFI" ]; then
    echo " ${WHITE}- Removable fallback:${NO_COLOR} Yes (/boot/EFI/BOOT/BOOTX64.EFI)"
  else
    echo " ${WHITE}- Removable fallback:${NO_COLOR} No (missing)"
  fi

  if [ -f "/mnt/boot/limine.conf" ]; then
    echo " ${WHITE}- Limine config:${NO_COLOR} Yes (/boot/limine.conf)"
  else
    echo " ${WHITE}- Limine config:${NO_COLOR} No (missing)"
  fi

  echo
  echo "${WHITE}The disk is unlocked with the LUKS passphrase. There is no second"
  echo "credential: losing the passphrase means losing the data.${NO_COLOR}"

  echo
  echo "${BLUE}==>${WHITE} Done. Ready to reboot! ${NO_COLOR}"
  echo "${BLUE}==>${WHITE} Secure Boot is not configured by this script; leave it disabled in BIOS for now. ${NO_COLOR}"
  echo "${BLUE}==>${WHITE} After reboot, log in as ${USERNAME}${NO_COLOR}"

  # Troubleshooting tips if boot issues were detected
  if [ ! -f "/mnt/boot/EFI/Linux/arch_linux.efi" ] || [ ! -f "/mnt/boot/EFI/BOOT/BOOTX64.EFI" ]; then
    echo
    echo "${WHITE}===${BLUE} BOOT TROUBLESHOOTING ${WHITE}===${NO_COLOR}"
    echo "If the system does not boot, try these steps:"
    echo "1. From the UEFI/BIOS setup, make sure Secure Boot is disabled"
    echo "2. Make sure the EFI partition is set as the primary boot device"
    echo "3. If it still does not boot, try rebuilding the boot setup:"
    echo "  - Boot from the Arch Linux installation media"
    echo "  - Mount the filesystems: mount -o subvol=@ /dev/mapper/cryptroot /mnt"
    echo "  - Mount the ESP: mount $EFI_PART /mnt/boot"
    echo "  - Chroot: arch-chroot /mnt"
    echo "  - Rerun: limine-install && limine-mkinitcpio"
    echo "  - Exit chroot and reboot"
  fi
}

# Main function
main() {
  check_shell_nesting

  print_logo

  parse_args "$@"

  validate_secure_boot

  # Determine partition names even if starting from a later stage
  if [[ "$START_STAGE" != "partitions" ]]; then
    setup_partitions
  fi

  # Run only the specified stages
  case "$START_STAGE" in
  partitions | start)
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
    ;;
  format)
    validate_inputs
    confirm_operation
    format_partitions
    setup_btrfs
    mount_filesystems
    install_base_system
    configure_system
    verify_installation
    print_summary
    ;;
  btrfs)
    ensure_cryptroot_open
    setup_btrfs
    mount_filesystems
    install_base_system
    configure_system
    verify_installation
    print_summary
    ;;
  mount)
    ensure_cryptroot_open
    mount_filesystems
    install_base_system
    configure_system
    verify_installation
    print_summary
    ;;
  base)
    ensure_mounted
    install_base_system
    configure_system
    verify_installation
    print_summary
    ;;
  configure)
    ensure_mounted
    configure_system
    verify_installation
    print_summary
    ;;
  users)
    prompt_for_passwords
    ensure_mounted

    configure_users

    # Ask if boot setup should be performed again
    if [ "$NON_INTERACTIVE" -eq 0 ]; then
      read -r -p "Do you want to reconfigure the boot setup? This might help if the system is not booting (y/N) " REPLY
      echo
      if [[ $REPLY =~ ^[Yy]$ ]]; then
        configure_boot
        enable_services
      fi
    fi

    verify_installation
    print_summary
    ;;
  boot)
    ensure_mounted
    configure_boot
    configure_limine_tool
    install_limine_hooks
    configure_snapshots
    enable_services
    verify_installation
    print_summary
    ;;
  verify)
    ensure_mounted
    verify_installation
    print_summary
    ;;
  *)
    echo "Unknown stage: $START_STAGE"
    show_help
    ;;
  esac
}

# Run the script
main "$@"
