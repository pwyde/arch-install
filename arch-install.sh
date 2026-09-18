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
DEFAULT_DISK=$(lsblk -dpno NAME | grep -v loop | head -n1)
DEFAULT_HOSTNAME="arch-linux"
DEFAULT_USERNAME="admin"
DEFAULT_TIMEZONE="Europe/Stockholm"
DEFAULT_KEYMAP="sv-latin1"
DEFAULT_LOCALE="sv_SE.UTF-8"
# No snapshots subvolume here on purpose: 'snapper create-config' creates its
# own /.snapshots and refuses to run when the path already exists, so leaving it
# out keeps the post-install snapper setup a plain create-config.
DEFAULT_SUBVOLUMES="@ @home @cache @log @root"
DEFAULT_PACKAGES="base base-devel bash-completion brightnessctl btrfs-progs cryptsetup dosfstools efibootmgr git limine linux linux-firmware man-db man-pages nano networkmanager openssh plymouth sudo terminus-font unzip util-linux vim zram-generator"

# Color variables
RED=$'\033[91m'
GREEN=$'\033[92m'
BLUE=$'\033[94m'
YELLOW=$'\033[93m'
WHITE=$'\033[97m'
NO_COLOR=$'\033[0m'

# Trap for cleanup
trap cleanup EXIT INT TERM

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

    # Close the LUKS container if it exists
    if [ -e "/dev/mapper/cryptroot" ]; then
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
LIMINE_HOOK_SRC="${SCRIPT_DIR}/etc/pacman.d/hooks/90-limine-deploy.hook"
VCONSOLE_LATIN_HOOK_SRC="${SCRIPT_DIR}/etc/initcpio/install/vconsole-latin"
MKINITCPIO_HOOKS_CONF_SRC="${SCRIPT_DIR}/etc/mkinitcpio.conf.d/hooks.conf"
MKINITCPIO_PRESET_SRC="${SCRIPT_DIR}/etc/mkinitcpio.d/linux.preset"
CMDLINE_SRC="${SCRIPT_DIR}/etc/cmdline.d"
CMDLINE_FILES="20-rtc-alarm.conf 80-initramfs-async.conf 90-splash.conf"
LOCALE_CONF_SRC="${SCRIPT_DIR}/etc/locale.conf"
ZRAM_CONF_SRC="${SCRIPT_DIR}/etc/systemd/zram-generator.conf.d/90-zram.conf"
SUDOERS_SRC="${SCRIPT_DIR}/etc/sudoers.d"
SUDOERS_FILES="00-wheel 01-timeout 02-passwd-tries"
SLEEP_HOOK_SRC="${SCRIPT_DIR}/default/systemd/system-sleep/keyboard-backlight"

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
      print_error "Enable it again after running post-install.sh, which enrolls keys with sbctl."
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
    "$LIMINE_HOOK_SRC"
    "$VCONSOLE_LATIN_HOOK_SRC"
    "$MKINITCPIO_HOOKS_CONF_SRC"
    "$MKINITCPIO_PRESET_SRC"
    "$LOCALE_CONF_SRC"
    "$ZRAM_CONF_SRC"
    "$SLEEP_HOOK_SRC"
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
  # shellcheck disable=SC2086
  pacstrap -K /mnt $PACKAGES || {
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

  # Derived here rather than carried from mount_filesystems, so stages entering
  # at 'base' do not trip over an unset variable under `set -u`.
  ESP_UUID=$(blkid -s UUID -o value "$EFI_PART")
  if ! grep -qE "UUID=${ESP_UUID}[[:space:]]+/boot[[:space:]]" /mnt/etc/fstab; then
    echo "UUID=$ESP_UUID  /boot  vfat  ${ESP_MOUNT_OPTS},noatime  0  2" >>/mnt/etc/fstab
    print_msg "Added /boot entry to /etc/fstab"
  else
    print_msg "/boot entry already exists in /etc/fstab"
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

  # TPM2 setup
  configure_tpm

  # Hibernation swapfile. Must run before configure_boot: it writes resume=
  # into /etc/cmdline.d/, which mkinitcpio embeds in the UKI.
  configure_hibernation

  # Plymouth boot splash. Must run before configure_boot: the plymouth hook
  # reads the default theme, and the kernel parameters are embedded in the UKI.
  configure_plymouth

  # Boot setup (mkinitcpio, UKI, Limine)
  configure_boot

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

# Configure TPM
configure_tpm() {
  print_msg "Configuring TPM"

  # Check if a TPM device is available
  if [ -d /sys/class/tpm ] && [ -n "$(ls -A /sys/class/tpm 2>/dev/null)" ]; then
    print_msg "TPM device detected, enrolling recovery key..."
    arch-chroot /mnt systemd-cryptenroll --recovery-key "$ROOT_PART"

    # Enroll TPM unlocking using the provided PIN
    if ! arch-chroot /mnt systemd-cryptenroll "$ROOT_PART" \
      --wipe-slot=password,tpm2 \
      --tpm2-device=auto \
      --tpm2-with-pin=yes; then
      print_error "TPM enrollment failed!"
    fi
  else
    print_warning "System configured without TPM (not detected). Use LUKS passphrase to unlock!"
  fi
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
#   - No FILES+=(/etc/vconsole.conf) drop-in. That is only required by a busybox
#     initramfs; here the sd-vconsole hook already copies vconsole.conf in.
#   - The kernel parameters go into /etc/cmdline.d/, which mkinitcpio embeds in
#     the UKI, instead of a limine-entry-tool drop-in.
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

  print_msg "Installing pacman hook to redeploy Limine on upgrade"
  install -D -m 0644 "$LIMINE_HOOK_SRC" /mnt/etc/pacman.d/hooks/90-limine-deploy.hook

  # Local install hooks go in /etc/initcpio/install/, which mkinitcpio searches
  # before /usr/lib/initcpio/install/. Hook files are sourced, not executed.
  print_msg "Installing mkinitcpio hook vconsole-latin"
  install -D -m 0644 "$VCONSOLE_LATIN_HOOK_SRC" /mnt/etc/initcpio/install/vconsole-latin

  # HOOKS comes from a drop-in rather than an edit to /etc/mkinitcpio.conf,
  # which stays as the package ships it. Drop-ins are read after the main file.
  print_msg "Installing mkinitcpio drop-in hooks.conf"
  install -D -m 0644 "$MKINITCPIO_HOOKS_CONF_SRC" /mnt/etc/mkinitcpio.conf.d/hooks.conf

  # Replaces the preset shipped by the linux package, which builds bare
  # initramfs images instead of UKIs.
  print_msg "Installing mkinitcpio preset linux.preset"
  install -D -m 0644 "$MKINITCPIO_PRESET_SRC" /mnt/etc/mkinitcpio.d/linux.preset

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

echo "==> Generate UKI (Unified Kernel Image)"
mkdir -p "/boot/EFI/Linux"
mkinitcpio -P

# pacstrap ran mkinitcpio with the stock preset, which wrote plain initramfs
# images. Now that /boot is the ESP those sit on the FAT partition costing a few
# hundred MiB, and nothing boots them -- the UKIs replaced them.
rm -f /boot/initramfs-linux.img /boot/initramfs-linux-fallback.img

if [ ! -f "/boot/EFI/Linux/arch_linux.efi" ]; then
  echo "ERROR: /boot/EFI/Linux/arch_linux.efi not found. UKI generation failed!" >&2
  find "/boot/EFI/Linux" -ls >&2
  exit 1
fi

echo "==> Installing Limine"
# The limine package only ships the EFI binaries; deploying them and writing
# the config is left to the administrator. Mirror the layout that
# limine-entry-tool uses, so adding limine-mkinitcpio-hook later finds Limine
# where it expects it.
mkdir -p "/boot/EFI/limine" "/boot/EFI/BOOT"
cp /usr/share/limine/BOOTX64.EFI "/boot/EFI/limine/limine_x64.efi"
# Also install as the removable-media fallback, so the system still boots if
# the firmware loses its NVRAM entry.
cp /usr/share/limine/BOOTX64.EFI "/boot/EFI/BOOT/BOOTX64.EFI"

echo "==> Registering Limine with the UEFI firmware"
esp_dev=$(findmnt -n -o SOURCE "/boot")
esp_disk=$(lsblk -no PKNAME "$esp_dev")
esp_partnum=$(cat "/sys/class/block/$(basename "$esp_dev")/partition")

if efibootmgr 2>/dev/null | grep -q "Limine"; then
  echo "A Limine UEFI boot entry already exists, leaving it alone."
else
  efibootmgr --create --disk "/dev/${esp_disk}" --part "$esp_partnum" \
    --loader '\EFI\limine\limine_x64.efi' --label "Limine" --unicode ||
    echo "WARNING: could not create the UEFI boot entry. The fallback at /boot/EFI/BOOT/BOOTX64.EFI should still boot." >&2
fi

echo "==> UEFI boot entries:"
efibootmgr || echo "WARNING: efibootmgr failed"

echo "==> ESP contents:"
find "/boot/EFI" -type f \( -name '*.efi' -o -name '*.EFI' \) | sort
EOF

  # Verify boot files exist
  print_msg "Verifying boot files..."
  if [ -f "/mnt/boot/EFI/Linux/arch_linux.efi" ]; then
    print_msg "UKI created successfully"
  else
    print_warning "⚠️  UKI not found. Boot will likely fail!  ⚠️"
  fi
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

# Print installation summary
print_summary() {
  echo
  echo "${YELLOW}===${BLUE} INSTALLATION SUMMARY ${YELLOW}===${NO_COLOR}"
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

  if [ -d /sys/class/tpm ] && [ -n "$(ls -A /sys/class/tpm 2>/dev/null)" ]; then
    echo
    echo "${WHITE}System configured with TPM unlocking. If TPM unlock fails, use the recovery password.${NO_COLOR}"
    echo
    echo "${WHITE}Consider enrolling TPM with PCR selection:${NO_COLOR}"
    cat <<EOF
systemd-cryptenroll ${ROOT_PART} \\
  --wipe-slot=password,tpm2 \\
  --tpm2-device=auto \\
  --tpm2-pcrs=7 \\
  --tpm2-with-pin=yes
EOF
  else
    echo
    echo "${WHITE}System configured without TPM (not detected). Use LUKS passphrase to unlock! ${NO_COLOR}"
  fi

  echo
  echo "${BLUE}==>${YELLOW} Done. Ready to reboot! ${NO_COLOR}"
  echo "${BLUE}==>${YELLOW} Secure Boot is ${WHITE}not${YELLOW} configured by this script; leave it disabled in BIOS for now. ${NO_COLOR}"
  echo "${BLUE}==>${YELLOW} After reboot, log in as ${WHITE}${USERNAME}${NO_COLOR}"

  # Troubleshooting tips if boot issues were detected
  if [ ! -f "/mnt/boot/EFI/Linux/arch_linux.efi" ] || [ ! -f "/mnt/boot/EFI/BOOT/BOOTX64.EFI" ]; then
    echo
    echo "${YELLOW}===${BLUE} BOOT TROUBLESHOOTING ${YELLOW}===${NO_COLOR}"
    echo "If the system does not boot, try these steps:"
    echo "1. From the UEFI/BIOS setup, make sure Secure Boot is disabled"
    echo "2. Make sure the EFI partition is set as the primary boot device"
    echo "3. If it still does not boot, try rebuilding the boot setup:"
    echo "  - Boot from the Arch Linux installation media"
    echo "  - Mount the filesystems: mount -o subvol=@ /dev/mapper/cryptroot /mnt"
    echo "  - Mount the ESP: mount $EFI_PART /mnt/boot"
    echo "  - Chroot: arch-chroot /mnt"
    echo "  - Rerun: mkinitcpio -P && cp /usr/share/limine/BOOTX64.EFI /boot/EFI/limine/limine_x64.efi"
    echo "  - Exit chroot and reboot"
  fi
}

# Main function
main() {
  echo "${YELLOW}===${BLUE} Arch Linux Encrypted Installation Script v${VERSION} ${YELLOW}===${NO_COLOR}"
  echo

  check_shell_nesting

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
    setup_btrfs
    mount_filesystems
    install_base_system
    configure_system
    verify_installation
    print_summary
    ;;
  mount)
    mount_filesystems
    install_base_system
    configure_system
    verify_installation
    print_summary
    ;;
  base)
    install_base_system
    configure_system
    verify_installation
    print_summary
    ;;
  configure)
    configure_system
    verify_installation
    print_summary
    ;;
  users)
    prompt_for_passwords

    # Check if we need to mount root first
    if ! mountpoint -q /mnt; then
      print_msg "Root not mounted, attempting to mount for user setup"
      # Try to locate the LUKS container and mount it
      if [ -b "$ROOT_PART" ]; then
        print_msg "Found root partition $ROOT_PART"
        if cryptsetup isLuks "$ROOT_PART"; then
          print_msg "Opening LUKS container..."
          if ! cryptsetup open "$ROOT_PART" cryptroot; then
            print_error "Failed to open LUKS container!"
            print_msg "This might be due to a previous LUKS header still being detected."
            exit 1
          fi
          print_msg "Mounting root filesystem"
          mount -o "subvol=@,$BTRFS_MOUNT_OPTS" /dev/mapper/cryptroot /mnt || {
            print_error "Could not mount root filesystem. Please check the subvolume configuration!"
            cryptsetup close cryptroot
            exit 1
          }

          # Also mount EFI partition if it exists
          if [ -b "$EFI_PART" ]; then
            print_msg "Mounting EFI partition"
            mkdir -p "/mnt/boot"
            mount -o "$ESP_MOUNT_OPTS" "$EFI_PART" "/mnt/boot" || {
              print_warning "Could not mount EFI partition. Boot setup might fail!"
            }
          else
            print_warning "EFI partition $EFI_PART not found. Boot setup might fail!"
          fi

          # Mount other subvolumes if needed
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

              print_msg "Trying to mount subvolume $subvol to /mnt$mountpoint"
              mkdir -p "/mnt$mountpoint"
              mount -o "subvol=$subvol,$BTRFS_MOUNT_OPTS" /dev/mapper/cryptroot "/mnt$mountpoint" || {
                print_warning "Failed to mount subvolume $subvol to /mnt$mountpoint"
              }
            fi
          done
        else
          print_error "Root partition is not a LUKS container. Cannot continue!"
          exit 1
        fi
      else
        print_error "Root partition $ROOT_PART not found. Please specify the correct disk with --disk!"
        exit 1
      fi
    else
      # If root is mounted but boot is not, try to mount boot
      if ! mountpoint -q "/mnt/boot" && [ -b "$EFI_PART" ]; then
        print_msg "Mounting EFI partition"
        mkdir -p "/mnt/boot"
        mount -o "$ESP_MOUNT_OPTS" "$EFI_PART" "/mnt/boot" || {
          print_warning "Could not mount EFI partition. Boot setup might fail!"
        }
      fi
    fi

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
    configure_boot
    enable_services
    verify_installation
    print_summary
    ;;
  verify)
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
