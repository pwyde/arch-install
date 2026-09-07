#!/bin/bash
# arch-install.sh v1.0
#
# A comprehensive Arch Linux installation script with LUKS encryption, TPM2 unlocking,
# Btrfs subvolumes, secure boot and Unified Kernel Image (UKI).
#
# Features:
# - Full disk encryption with LUKS2
# - TPM2 integration
# - Btrfs filesystem with customizable subvolumes
# - Unified Kernel Image for secure boot compatibility
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
DEFAULT_SUBVOLUMES="@ @home @cache @log @.snapshots @root"
DEFAULT_PACKAGES="base base-devel bash-completion btrfs-progs cryptsetup dosfstools git linux linux-firmware man-db man-pages nano networkmanager openssh sbctl sudo terminus-font unzip util-linux vim zram-generator"

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
    if mountpoint -q /mnt/efi 2>/dev/null; then
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
VERSION="1.0"
START_STAGE="partitions" # Default start at beginning

# Password variables
USER_PASSWORD=""
ROOT_PASSWORD=""
USER_PASSWORD_VALID=0
ROOT_PASSWORD_VALID=0

# Help function
show_help() {
  cat <<EOF
Arch Linux Encrypted Installation Script (v${VERSION})

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

  # Create EFI System Partition - 512MB
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
  mount -o subvol=@,compress=zstd:1,noatime /dev/mapper/cryptroot /mnt || {
    print_error "Failed to mount root subvolume"
    print_msg "Debug info:"
    mount /dev/mapper/cryptroot /mnt
    ls -la /mnt/
    btrfs subvolume list /mnt
    umount /mnt
    exit 1
  }

  mkdir -p /mnt/efi
  print_msg "Mounting EFI partition to /mnt/efi"
  mount "$EFI_PART" /mnt/efi

  # Add /efi mount to fstab if not already present
  ESP_UUID=$(blkid -s UUID -o value "$EFI_PART")
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
      @snapshots) mountpoint="/.snapshots" ;;
      *)
        mountpoint="${subvol#@}"
        mountpoint="/$mountpoint"
        ;;
      esac

      print_msg "Mounting subvolume $subvol to /mnt$mountpoint"
      mkdir -p "/mnt$mountpoint"
      mount -o "subvol=$subvol,compress=zstd:1,noatime" /dev/mapper/cryptroot "/mnt$mountpoint" || {
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

  if mountpoint -q /mnt/boot; then
    print_error "/mnt/boot is a mount point — EFI must be mounted at /mnt/efi, not /mnt/boot"
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

  if ! grep -qE "UUID=${ESP_UUID}[[:space:]]+/efi[[:space:]]" /mnt/etc/fstab; then
    echo "UUID=$ESP_UUID  /efi  vfat  defaults,noatime  0  1" >>/mnt/etc/fstab
    print_msg "Added /efi entry to /etc/fstab"
  else
    print_msg "/efi entry already exists in /etc/fstab"
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

  # Boot setup (dracut, UKI, systemd-boot, secure boot)
  configure_boot

  # Enable services
  enable_services

  # Clean up chroot mounts
  cleanup_chroot
}

# Configure basic system settings
configure_basic_system() {
  print_msg "Configuring basic system settings"
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

echo "==> Setting keymap to ${KEYMAP}"
cat > /etc/vconsole.conf <<EOL
KEYMAP=${KEYMAP}
EOL

echo "==> Setting locale to ${LOCALE}"
sed -i 's/#\(en_US.UTF-8\)/\1/' /etc/locale.gen
sed -i 's/#\(en_GB.UTF-8\)/\1/' /etc/locale.gen
sed -i 's/#\(${LOCALE}\)/\1/' /etc/locale.gen
locale-gen
cat > /etc/locale.conf <<EOL
# Determines the default locale in the absence of other locale related environment variables.
LANG=en_GB.UTF-8
# Format of interactive words and responses.
LC_MESSAGES=en_GB.UTF-8
# Character classification and case conversion.
LC_CTYPE=${LOCALE}
# Numeric formatting.
LC_NUMERIC=${LOCALE}
# Date and time formats.
LC_TIME=${LOCALE}
# Monetary formatting.
LC_MONETARY=${LOCALE}
# Default measurement system used within the region.
LC_MEASUREMENT=${LOCALE}
# Convention used for formatting of street or postal addresses.
LC_ADDRESS=${LOCALE}
# Conventions used for representation of telephone numbers.
LC_TELEPHONE=${LOCALE}
# Default paper size for region.
LC_PAPER=${LOCALE}
# Collation order.
LC_COLLATE=${LOCALE}
EOL

echo "==> Configuring ZRAM"
cat > /etc/systemd/zram-generator.conf <<EOL
[zram0]
zram-size = min(ram / 2, 16384)
compression-algorithm = zstd
EOL

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

    # Configure sudo
    print_msg "Configuring sudo"
    arch-chroot /mnt /bin/bash -e <<EOF
cat > /etc/sudoers.d/timeout <<EOL
# Disable password prompt timeout.
Defaults passwd_timeout=0

# Reset environment variables and timeout for sudo sessions to 60 min.
Defaults timestamp_timeout=60
EOL
cat > /etc/sudoers.d/wheel <<EOL
# Allow members of group wheel to execute any command.
%wheel ALL=(ALL:ALL) ALL
EOL
EOF

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

# Configure boot
configure_boot() {
  print_msg "Configuring boot"

  # Ensure the EFI partition is mounted
  if ! mountpoint -q /mnt/efi; then
    print_warning "EFI partition not mounted at /mnt/efi. Attempting to mount."
    mkdir -p /mnt/efi
    if [ -b "$EFI_PART" ]; then
      if mount "$EFI_PART" /mnt/efi; then
        print_msg "EFI partition reformatted and remounted."
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
  if ! file -sL "$(findmnt -n -o SOURCE /mnt/efi)" | grep -q "FAT"; then
    print_warning "WARNING: EFI System Partition is not formatted as FAT filesystem."
    print_msg "Current filesystem type: $(file -sL "$(findmnt -n -o SOURCE /mnt/efi)")"
    if [ "$NON_INTERACTIVE" -eq 0 ]; then
      read -r -p "Format the EFI partition with FAT32? This will erase all data on it. (y/N) " REPLY
      echo
      if [[ $REPLY =~ ^[Yy]$ ]]; then
        # Unmount first, then format
        umount /mnt/efi
        mkfs.fat -F32 -n "EFI" "$EFI_PART"
        mount "$EFI_PART" /mnt/efi
        print_msg "EFI partition reformatted and remounted."
      else
        print_msg "Continuing without reformatting. Boot might fail."
      fi
    else
      print_msg "Continuing without reformatting in non-interactive mode."
    fi
  fi

  arch-chroot /mnt env ROOT_PART="$ROOT_PART" HOSTNAME="$HOSTNAME" TIMEZONE="$TIMEZONE" /bin/bash -e <<'EOF'
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
cat > /etc/kernel/cmdline <<EOL
loglevel=3
EOL

mkdir -p /etc/cmdline.d
cat > /etc/cmdline.d/root.conf <<EOL
rd.luks.name=${ROOT_UUID}=cryptroot root=/dev/mapper/cryptroot zswap.enabled=0 rootfstype=btrfs rootflags=subvol=/@ rw
EOL

echo "==> Configure mkinitcpio"
sed -i "s/HOOKS=.*/HOOKS=(base systemd autodetect microcode modconf kms keyboard sd-vconsole sd-encrypt block filesystems fsck)/g" /etc/mkinitcpio.conf
sed -i 's/#\(COMPRESSION="zstd"\)/\1/' /etc/mkinitcpio.conf

echo "==> Configure UKI (Unified Kernel Image)"
cat > /etc/mkinitcpio.d/linux.preset <<EOL
# mkinitcpio preset file for the 'linux' package

ALL_config="/etc/mkinitcpio.conf"
ALL_kver="/boot/vmlinuz-linux"

PRESETS=('default' 'fallback')

#default_config="/etc/mkinitcpio.conf"
#default_image="/boot/initramfs-linux.img"
default_uki="/efi/EFI/Linux/arch-linux.efi"
default_options="--splash /usr/share/systemd/bootctl/splash-arch.bmp"

#fallback_config="/etc/mkinitcpio.conf"
#fallback_image="/boot/initramfs-linux-fallback.img"
fallback_uki="/efi/EFI/Linux/arch-linux-fallback.efi"
fallback_options="-S autodetect"
EOL

echo "==> Generate UKI (Unified Kernel Image)"
mkdir -p /efi/EFI/Linux
mkinitcpio -P

if [ ! -f /efi/EFI/Linux/arch-linux.efi ]; then
  echo "ERROR: /efi/EFI/Linux/arch-linux.efi not found inside chroot. UKI install may have failed!" >&2
  echo "Contents of /efi/EFI/Linux:" >&2
  find /efi/EFI/Linux -ls >&2
  exit 1
fi

echo "==> Installing systemd-boot"
bootctl install --esp-path=/efi || {
  echo "WARNING: systemd-boot installation failed, trying manual installation"
  mkdir -p /efi/EFI/systemd /efi/EFI/BOOT
  cp /usr/lib/systemd/boot/efi/systemd-bootx64.efi /efi/EFI/systemd/systemd-bootx64.efi
  cp /usr/lib/systemd/boot/efi/systemd-bootx64.efi /efi/EFI/BOOT/BOOTX64.EFI
}

cat > /efi/loader/loader.conf <<EOL
timeout 5
editor 0
console-mode 1
EOL

echo "==> EFI directory contents:"
find /efi/EFI -type f | sort

echo "==> Boot loader status:"
bootctl status || echo "WARNING: bootctl status command failed, this might be normal if using manual installation"

echo "==> Configuring secure boot"
sbctl create-keys

echo "==> Enroll Microsoft keys"
sbctl enroll-keys -m

echo "==> Sign UKI and bootloader"
sbctl sign -s /efi/EFI/BOOT/BOOTX64.EFI
sbctl sign -s /efi/EFI/Linux/arch-linux.efi
sbctl sign -s /efi/EFI/Linux/arch-linux-fallback.efi
sbctl sign -s /efi/EFI/systemd/systemd-bootx64.efi

echo "==> Secure boot status:"
sbctl status || echo "WARNING: sbctl status command failed"
EOF

  # Verify boot files exist
  print_msg "Verifying boot files..."
  if [ -f /mnt/efi/EFI/Linux/arch-linux.efi ]; then
    print_msg "UKI created successfully"
  elif [ -f /mnt/boot/initramfs-linux.img ]; then
    print_warning "⚠️  UKI not created, but initramfs fallback exists!  ⚠️"
  else
    print_warning "⚠️  Neither UKI nor initramfs found. Boot will likely fail!  ⚠️"
  fi
}

# Enable services
enable_services() {
  print_msg "Enabling services"
  arch-chroot /mnt /bin/bash -e <<EOF
systemctl enable systemd-resolved systemd-timesyncd systemd-zram-setup@zram0.service sshd NetworkManager
systemctl mask systemd-networkd
EOF
}

# Verify installation
verify_installation() {
  print_msg "Verifying critical components"

  # Check if EFI directory exists
  if [ ! -d /mnt/efi/EFI ]; then
    print_error "WARNING: EFI directory not found! Boot will not work properly."
    print_error "Please check that the EFI partition is properly mounted at /mnt/boot."
  fi

  # Check boot files
  print_msg "Checking boot files"
  if [ ! -f /mnt/efi/EFI/Linux/arch-linux.efi ] && [ ! -f /mnt/boot/initramfs-linux.img ]; then
    print_error "Neither UKI nor fallback initramfs found! System won't boot."
    print_error "Try rebuilding the boot configuration with: $0 --stage boot"
  elif [ ! -f /mnt/efi/EFI/Linux/arch-linux.efi ]; then
    print_error "UKI not found at /mnt/efi/EFI/Linux/arch-linux.efi! System won't boot."
    print_error "Try rebuilding the boot configuration with: $0 --stage boot"
  fi

  # Check for bootloader
  if [ ! -f /mnt/efi/EFI/systemd/systemd-bootx64.efi ] && [ ! -f /mnt/efi/EFI/BOOT/BOOTX64.EFI ]; then
    print_error "No bootloader found! System won't boot."
    print_error "Try reinstalling the bootloader with: $0 --stage boot"
  fi

  # Check for bootloader configuration
  if [ ! -f /mnt/efi/loader/loader.conf ]; then
    print_error "Boot loader configuration not found!"
    print_error "Try rebuilding the boot configuration with: $0 --stage boot"
  fi

  # Check for secure boot setup status
  print_msg "Checking secure boot status"
  arch-chroot /mnt sbctl status && arch-chroot /mnt sbctl verify
  print_msg "Verify above that secure boot status is in a healthy state..."

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
  if mountpoint -q /mnt/efi; then
    print_msg "EFI partition information:"
    file -sL "$(findmnt -n -o SOURCE /mnt/efi)"
    print_msg "EFI partition contents:"
    find /mnt/efi -type f -name "*.efi" | sort
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
  if [ -f /mnt/efi/EFI/Linux/arch-linux.efi ]; then
    echo " ${WHITE}- UKI present:${NO_COLOR} Yes (/efi/EFI/Linux/arch-linux.efi)"
  else
    echo " ${WHITE}- UKI present:${NO_COLOR} No (missing)"
  fi

  if [ -f /mnt/boot/initramfs-linux.img ]; then
    echo " ${WHITE}- Fallback initramfs:${NO_COLOR} Yes (/boot/initramfs-linux.img)"
  else
    echo " ${WHITE}- Fallback initramfs:${NO_COLOR} No (missing)"
  fi

  if [ -f /mnt/efi/EFI/BOOT/BOOTX64.EFI ]; then
    echo " ${WHITE}- Fallback bootloader:${NO_COLOR} Yes (/efi/EFI/BOOT/BOOTX64.EFI)"
  else
    echo " ${WHITE}- Fallback bootloader:${NO_COLOR} No (missing)"
  fi

  if [ -f /mnt/efi/EFI/systemd/systemd-bootx64.efi ]; then
    echo " ${WHITE}- systemd-boot:${NO_COLOR} Yes (/efi/EFI/systemd/systemd-bootx64.efi)"
  else
    echo " ${WHITE}- systemd-boot:${NO_COLOR} No (missing)"
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
  echo "${BLUE}==>${YELLOW} Also verify that ${WHITE}Secure Boot${YELLOW} is enabled in BIOS before booting into Arch Linux! ${NO_COLOR}"
  echo "${BLUE}==>${YELLOW} After reboot, log in as ${WHITE}${USERNAME}${NO_COLOR}"

  # Troubleshooting tips if boot issues were detected
  if [ ! -f /mnt/efi/EFI/Linux/arch-linux.efi ] || [ ! -f /mnt/efi/EFI/BOOT/BOOTX64.EFI ]; then
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
    echo "  - Rerun bootctl install"
    echo "  - Exit chroot and reboot"
  fi
}

# Main function
main() {
  echo "${YELLOW}===${BLUE} Arch Linux Encrypted Installation Script v${VERSION} ${YELLOW}===${NO_COLOR}"
  echo

  check_shell_nesting

  parse_args "$@"

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
          mount -o subvol=@,compress=zstd:1,noatime /dev/mapper/cryptroot /mnt || {
            print_error "Could not mount root filesystem. Please check the subvolume configuration!"
            cryptsetup close cryptroot
            exit 1
          }

          # Also mount EFI partition if it exists
          if [ -b "$EFI_PART" ]; then
            print_msg "Mounting EFI partition"
            mkdir -p /mnt/boot
            mount "$EFI_PART" /mnt/boot || {
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
              @snapshots) mountpoint="/.snapshots" ;;
              *)
                mountpoint="${subvol#@}"
                mountpoint="/$mountpoint"
                ;;
              esac

              print_msg "Trying to mount subvolume $subvol to /mnt$mountpoint"
              mkdir -p "/mnt$mountpoint"
              mount -o "subvol=$subvol,compress=zstd:1,noatime" /dev/mapper/cryptroot "/mnt$mountpoint" || {
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
      if ! mountpoint -q /mnt/boot && [ -b "$EFI_PART" ]; then
        print_msg "Mounting EFI partition"
        mkdir -p /mnt/boot
        mount "$EFI_PART" /mnt/boot || {
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
