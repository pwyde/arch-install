#!/bin/bash
# virt-install.sh
#
# Installs QEMU/KVM virtualization with libvirt and virt-manager on an Arch
# Linux system, and configures it for virtual machines run by the system.
#
# Features:
# - QEMU with KVM, UEFI firmware and a TPM emulator
# - libvirt's modular daemons and virt-manager
# - A Btrfs subvolume for disk images, outside the snapshots of /
# - The default NAT network, with DHCP and DNS for guests
# - Clean shutdown of running guests with the host
# - Options for additional packages, the libvirt group, the default network,
#   the subvolume and the shutdown timeout
# - Error handling and validation
#
# Usage: ./virt-install.sh [options]
# See --help for available options

set -euo pipefail

# QEMU, libvirt and virt-manager. dnsmasq serves DHCP and DNS on libvirt's
# default network, swtpm emulates the TPM that Windows 11 requires, and
# e2fsprogs provides chattr for the disk image subvolume.
readonly DEFAULT_VIRT_PACKAGES=(
  qemu-desktop
  libvirt
  edk2-ovmf
  virt-manager
  dnsmasq
  swtpm
  e2fsprogs
)
# The modular libvirt daemons for virtual machines, networks, storage, host
# devices and secrets: the drivers that virt-manager uses.
readonly LIBVIRT_DAEMONS=(
  virtqemud
  virtnetworkd
  virtstoraged
  virtnodedevd
  virtsecretd
)
readonly LIBVIRT_URI="qemu:///system"
readonly LIBVIRT_GROUP="libvirt"

# Seconds each running guest has to shut down with the host, without
# --shutdown-timeout.
readonly DEFAULT_SHUTDOWN_TIMEOUT=120

# Terminal colors.
readonly RED=$'\033[91m'
readonly GREEN=$'\033[92m'
# 24-bit #1793D1, the Arch blue used by the Limine menu and the Plymouth theme.
readonly BLUE=$'\033[38;2;23;147;209m'
readonly YELLOW=$'\033[93m'
readonly WHITE=$'\033[1;97m'
readonly NO_COLOR=$'\033[0m'

# Repository files
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly LOG_DIR="${SCRIPT_DIR}/logs"
readonly GUESTS_CONF_SRC="${SCRIPT_DIR}/etc/conf.d/libvirt-guests"

# Destinations
readonly IMAGES_DIR="/var/lib/libvirt/images"
readonly IMAGES_SUBVOLUME="@libvirt-images"
readonly FSTAB="/etc/fstab"
readonly NFTABLES_CONF="/etc/nftables.conf"

# Global variables
EXTRA_PACKAGES=""
NON_INTERACTIVE=0
# Set by --group, --no-network and --skip-subvolume.
ADD_TO_GROUP=0
CONFIGURE_NETWORK=1
SKIP_SUBVOLUME=0
# Seconds from --shutdown-timeout, written to /etc/conf.d/libvirt-guests.
SHUTDOWN_TIMEOUT="${DEFAULT_SHUTDOWN_TIMEOUT}"
# Set by validate_virtualization. Without KVM, QEMU emulates the processor.
KVM_AVAILABLE=1
# Set by validate_images_location: 1 gives the disk images a subvolume of their
# own on the root filesystem with ROOT_UUID, mounted with IMAGES_MOUNT_OPTIONS;
# 0 keeps IMAGES_DIR as it is, for the reason in KEEP_IMAGES_REASON.
CREATE_SUBVOLUME=0
ROOT_UUID=""
IMAGES_MOUNT_OPTIONS=""
KEEP_IMAGES_REASON=""
# Set by the first step that changes the system. Earlier failures are argument
# and validation errors, which report themselves.
STARTED=0
# Top-level mount point and fstab entry of create_images_subvolume, which
# cleanup unmounts and removes on failure.
TEMP_DIR=""
TEMP_FILE=""

print_msg() {
  echo "${GREEN}==>${NO_COLOR}${WHITE}" "$*${NO_COLOR}"
}

print_warning() {
  echo "${YELLOW}==> WARNING:${NO_COLOR}${WHITE}" "$*${NO_COLOR}" >&2
}

print_error() {
  echo "${RED}==> ERROR:${NO_COLOR}${WHITE}" "$*${NO_COLOR}" >&2
}

# Unmounts and removes the temporary mount point, removes the temporary file and
# reports a failed run. Nothing needs undoing: the packages are installed in one
# pacman transaction, and every later step can be repeated.
cleanup() {
  local exit_code=$?

  # Left only if create_images_subvolume failed while they were in use.
  [[ -z "${TEMP_FILE:-}" ]] || rm -f "${TEMP_FILE}"
  if [[ -n "${TEMP_DIR:-}" ]]; then
    if mountpoint -q "${TEMP_DIR}"; then
      sudo umount "${TEMP_DIR}" || true
    fi
    rmdir "${TEMP_DIR}" || true
  fi

  if ((exit_code != 0 && STARTED)); then
    print_error "Script exited with error code ${exit_code}."
    print_msg "The script can be run again once the error is resolved."
  fi
}

# Re-runs the script under script(1), which records everything printed on the
# terminal to the log. Typed passwords are never logged: input is not
# recorded, and password prompts do not echo.
#
# The timestamp in the file name is the first run's. A later run in the same
# checkout appends to that file, and script(1) marks where each run starts and
# ends.
start_logging() {
  local arg log_file command_line

  for arg in "$@"; do
    case "${arg}" in -h | --help) return 0 ;; esac
  done

  if ! command -v script &>/dev/null; then
    print_warning "script(1) is not available; continuing without a log file."
    return 0
  fi

  mkdir -p "${LOG_DIR}"
  log_file=$(find "${LOG_DIR}" -maxdepth 1 -name 'virt-install-*.log' \
    | sort \
    | tail -n 1)
  if [[ -z "${log_file}" ]]; then
    log_file="${LOG_DIR}/virt-install-$(date +%Y%m%d-%H%M%S).log"
  fi
  print_msg "Logging to ${log_file}"

  # script(1) runs the command through $SHELL; bash, to match the quoting.
  command_line=$(printf '%q ' env VIRT_INSTALL_LOG="${log_file}" \
    "${SCRIPT_DIR}/$(basename "$0")" "$@")
  exec env SHELL=/bin/bash script --quiet --append --flush --return \
    --command "${command_line}" "${log_file}"
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
  print_heading "ViRTUALiZATiON iNSTALLATiON SCRiPT"
  echo
}

show_help() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  -g, --group                Add the user to the libvirt group, which manages
                             virtual machines without a password prompt
                             (default: the administrator password, through
                             Polkit)
  -n, --no-network           Do not start libvirt's default NAT network, now or
                             at boot
  -p, --packages PACKAGES    Additional packages from the official
                             repositories (no AUR), space-separated
                             (appended to defaults)
  -s, --skip-subvolume       Keep disk images on the root filesystem, without
                             a Btrfs subvolume of their own
  -t, --shutdown-timeout SECONDS
                             Seconds each running guest has to shut down
                             with the host, 1 to 3600
                             (default: ${DEFAULT_SHUTDOWN_TIMEOUT})
  -y, --yes                  Non-interactive mode, no confirmation prompts
  -h, --help                 Show this help message

Example:
  $(basename "$0") --shutdown-timeout 300 --packages "guestfs-tools"

EOF
  exit 0
}

# Options with a value check for it. Without this check, an omitted value fails
# with a bare "$2: unbound variable" from set -u, which does not name the
# option.
require_value() {
  if [[ -z "${2:-}" ]]; then
    print_error "Option $1 requires a value."
    print_msg "Run with --help for the available options."
    exit 1
  fi
}

parse_args() {
  while (($# > 0)); do
    case $1 in
      -h | --help)
        show_help
        ;;
      -g | --group)
        ADD_TO_GROUP=1
        shift
        ;;
      -n | --no-network)
        CONFIGURE_NETWORK=0
        shift
        ;;
      -p | --packages)
        require_value "$1" "${2:-}"
        EXTRA_PACKAGES="$2"
        shift 2
        ;;
      -s | --skip-subvolume)
        SKIP_SUBVOLUME=1
        shift
        ;;
      -t | --shutdown-timeout)
        require_value "$1" "${2:-}"
        SHUTDOWN_TIMEOUT="$2"
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

# Validates the environment, the libvirt daemons and the repository files.
validate_inputs() {
  validate_environment
  validate_libvirt_daemon
  validate_repository
}

# The regular user, with the commands the installer runs.
validate_environment() {
  local cmd

  # Running virt-manager as root would bypass the Polkit prompt that guards
  # the system's virtual machines.
  if ((EUID == 0)); then
    print_error "This script must be run as the regular user, not as root."
    exit 1
  fi

  # Tools required on the installed system.
  for cmd in sudo pacman systemctl findmnt mountpoint; do
    if ! command -v "${cmd}" &>/dev/null; then
      print_error "Required command not found: ${cmd}"
      exit 1
    fi
  done
}

# libvirtd runs every driver in one daemon, which the modular daemons replace.
# Both enabled at once would compete for the same virtual machines.
validate_libvirt_daemon() {
  local unit

  for unit in libvirtd.service libvirtd.socket; do
    if systemctl is-enabled --quiet "${unit}" 2>/dev/null; then
      print_error "${unit} is enabled; the modular libvirt daemons replace it."
      print_error "Disable it first: sudo systemctl disable --now" \
        "libvirtd.service libvirtd.socket libvirtd-ro.socket" \
        "libvirtd-admin.socket"
      exit 1
    fi
  done
}

validate_repository() {
  local src
  local -a repo_files=(
    "${GUESTS_CONF_SRC}"
  )

  for src in "${repo_files[@]}"; do
    if [[ ! -f "${src}" ]]; then
      print_error "Missing repository file: ${src}"
      print_error "Run the script from a full checkout of the repository."
      exit 1
    fi
  done
}

# libvirt-guests waits this long for each guest. 0 would wait without limit,
# and the service has no stop timeout of its own, so the host would not finish
# shutting down while a guest ignores the request. The value is substituted
# into the configuration with sed.
validate_shutdown_timeout() {
  if [[ ! "${SHUTDOWN_TIMEOUT}" =~ ^[1-9][0-9]{0,3}$ ]] \
    || ((SHUTDOWN_TIMEOUT > 3600)); then
    print_error "Invalid shutdown timeout '${SHUTDOWN_TIMEOUT}'; give 1 to" \
      "3600 seconds."
    exit 1
  fi
}

# Additional packages are looked up with pacman -Si, or as a group with
# pacman -Sg, in the package databases as they stand before the upgrade. The
# installer uses pacman, so AUR packages are not available.
validate_packages() {
  local pattern='^([a-z0-9_-]+/)?[a-z0-9@_+][a-z0-9@._+-]*$' pkg
  local -a pkgs

  read -ra pkgs <<<"${EXTRA_PACKAGES}"
  for pkg in "${pkgs[@]}"; do
    if [[ ! "${pkg}" =~ ${pattern} ]]; then
      print_error "Invalid package name '${pkg}'."
      exit 1
    fi
    if ! pacman -Si -- "${pkg}" &>/dev/null \
      && ! pacman -Sg -- "${pkg}" &>/dev/null; then
      print_error "Package '${pkg}' was not found in the sync databases;" \
        "AUR packages are not supported."
      print_error "A package added recently is found after a system" \
        "upgrade with 'sudo pacman -Syu'."
      exit 1
    fi
  done
}

# Not fatal: without KVM, QEMU emulates the processor in software, which works
# but is many times slower. In a virtual machine, KVM requires nested
# virtualization.
validate_virtualization() {
  if [[ ! -c /dev/kvm ]]; then
    KVM_AVAILABLE=0
    print_warning "KVM is not available; virtual machines will run without" \
      "hardware acceleration. Enable AMD-V or VT-x in the firmware setup."
  fi
}

# A subvolume of its own keeps the disk images out of the snapshots of /, and
# without copy-on-write, images are written in place. A directory that already
# holds files, or that another filesystem is mounted on or listed for in fstab,
# is left as it is.
validate_images_location() {
  local fstype source fstab_options root_options
  local uuid_pattern='^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$'
  local options_pattern='^[A-Za-z0-9_=:,./@+-]+$'

  if ((SKIP_SUBVOLUME)); then
    KEEP_IMAGES_REASON="--skip-subvolume was given"
    return 0
  fi

  fstype=$(findmnt -no FSTYPE /)
  if [[ "${fstype}" != "btrfs" ]]; then
    KEEP_IMAGES_REASON="the root filesystem is ${fstype}, not Btrfs"
    return 0
  fi

  if fstab_options=$(findmnt --fstab -no OPTIONS --mountpoint "${IMAGES_DIR}") \
    && [[ ",${fstab_options}," != *",subvol=/${IMAGES_SUBVOLUME},"* ]]; then
    KEEP_IMAGES_REASON="${FSTAB} mounts another filesystem there"
    return 0
  fi

  # A rerun finds the subvolume already mounted, and repeats the steps.
  if source=$(findmnt -no SOURCE --mountpoint "${IMAGES_DIR}"); then
    if [[ "${source}" != *"[/${IMAGES_SUBVOLUME}]" ]]; then
      KEEP_IMAGES_REASON="${source} is already mounted there"
      return 0
    fi
  elif [[ -d "${IMAGES_DIR}" ]] \
    && { [[ ! -r "${IMAGES_DIR}" ]] \
      || [[ -n "$(find "${IMAGES_DIR}" -mindepth 1 -maxdepth 1 -print \
        -quit)" ]]; }; then
    KEEP_IMAGES_REASON="it already holds files"
    return 0
  fi

  if ! command -v btrfs &>/dev/null; then
    print_error "Required command not found: btrfs (package btrfs-progs)"
    exit 1
  fi

  # Written to fstab. The options repeat those of / with the subvolume
  # replaced, as for the other subvolumes: Btrfs takes most of them from the
  # first mount of the filesystem, and noatime applies to each mount point.
  ROOT_UUID=$(findmnt -no UUID /)
  if [[ ! "${ROOT_UUID}" =~ ${uuid_pattern} ]]; then
    print_error "Unexpected UUID '${ROOT_UUID}' for the root filesystem."
    exit 1
  fi
  root_options=$(findmnt --fstab -no OPTIONS --mountpoint /) \
    || root_options="rw,noatime"
  IMAGES_MOUNT_OPTIONS=$(sed -E 's/(^|,)subvol(id)?=[^,]*//g; s/^,//' \
    <<<"${root_options}")
  IMAGES_MOUNT_OPTIONS="${IMAGES_MOUNT_OPTIONS:+${IMAGES_MOUNT_OPTIONS},}"
  IMAGES_MOUNT_OPTIONS+="subvol=/${IMAGES_SUBVOLUME}"
  if [[ ! "${IMAGES_MOUNT_OPTIONS}" =~ ${options_pattern} ]]; then
    print_error "Unexpected mount options '${IMAGES_MOUNT_OPTIONS}'."
    exit 1
  fi
  CREATE_SUBVOLUME=1
}

# Not fatal: a firewall that drops incoming traffic by default also drops the
# guests' DHCP and DNS requests to the host's dnsmasq. Only nftables is
# checked, by whether its ruleset names the virbr bridges at all, and only for
# the default network.
validate_firewall() {
  if ((CONFIGURE_NETWORK)) \
    && systemctl is-enabled --quiet nftables.service 2>/dev/null \
    && [[ -r "${NFTABLES_CONF}" ]] \
    && ! grep -q 'virbr' "${NFTABLES_CONF}"; then
    print_warning "${NFTABLES_CONF} has no rule for libvirt's virbr bridges;" \
      "guests on the default network may receive no address."
    print_warning "Accept UDP ports 53 and 67 and TCP port 53 on" \
      "iifname \"virbr*\" in its input chain."
  fi
}

# Asks for confirmation before anything is installed or overwritten.
confirm_operation() {
  local reply

  if ((!NON_INTERACTIVE)); then
    echo "The following will be installed and configured:"
    echo "  - QEMU/KVM, libvirt, virt-manager, UEFI firmware and a TPM" \
      "emulator"
    if [[ -n "${EXTRA_PACKAGES}" ]]; then
      echo "  - Additional packages: ${EXTRA_PACKAGES}"
    fi
    if ((CREATE_SUBVOLUME)); then
      echo "  - The Btrfs subvolume ${IMAGES_SUBVOLUME} for disk images," \
        "mounted at ${IMAGES_DIR}"
    else
      echo "  - Disk images in ${IMAGES_DIR} as it is, since" \
        "${KEEP_IMAGES_REASON}"
    fi
    echo "  - The libvirt daemons, started now and at every boot"
    if ((CONFIGURE_NETWORK)); then
      echo "  - The default NAT network, started now and at every boot"
    fi
    echo "  - Clean shutdown of running guests when the host shuts down," \
      "${SHUTDOWN_TIMEOUT} seconds for each"
    if ((ADD_TO_GROUP)); then
      echo "  - $(id -un) in the ${LIBVIRT_GROUP} group: virtual machines" \
        "managed without a password"
    fi
    echo
    echo "WARNING: /etc/conf.d/libvirt-guests will be overwritten."
    read -r -p "Are you sure you want to continue? (y/N) " reply
    echo
    if [[ ! "${reply}" =~ ^[Yy]$ ]]; then
      echo "Installation cancelled."
      exit 1
    fi
  fi
}

# Upgrades the system first. Installing from a stale package database risks a
# partial upgrade, which Arch does not support.
update_system() {
  local -a flags=()

  STARTED=1
  print_msg "Upgrading the system"

  if ((NON_INTERACTIVE)); then
    flags+=(--noconfirm)
  fi

  sudo pacman -Syu "${flags[@]}"
}

# Installs the packages given as arguments with pacman.
pacman_install() {
  local -a flags=(--needed)
  if ((NON_INTERACTIVE)); then
    flags+=(--noconfirm)
  fi

  sudo pacman -S "${flags[@]}" -- "$@"
}

install_packages() {
  print_msg "Installing QEMU, libvirt and virt-manager"
  pacman_install "${DEFAULT_VIRT_PACKAGES[@]}"
}

install_extra_packages() {
  local -a packages

  if [[ -n "${EXTRA_PACKAGES}" ]]; then
    print_msg "Installing additional packages"
    read -ra packages <<<"${EXTRA_PACKAGES}"
    pacman_install "${packages[@]}"
  fi
}

# Runs after the packages, which create IMAGES_DIR empty, and before the
# daemons, which would otherwise create the default storage pool's files on /.
# The subvolume is created at the top level of the filesystem, next to the
# others, and copy-on-write is disabled on it, so that new images inherit it.
# They also lose checksums and compression, as nodatacow files do on Btrfs.
create_images_subvolume() {
  local subvolume entry

  if ((!CREATE_SUBVOLUME)); then
    print_msg "Keeping ${IMAGES_DIR} as it is, since ${KEEP_IMAGES_REASON}"
    return 0
  fi

  print_msg "Creating the Btrfs subvolume ${IMAGES_SUBVOLUME} for disk images"
  TEMP_DIR=$(mktemp -d)
  subvolume="${TEMP_DIR}/${IMAGES_SUBVOLUME}"
  sudo mount -o subvolid=5 "/dev/disk/by-uuid/${ROOT_UUID}" "${TEMP_DIR}"
  if ! sudo btrfs subvolume show "${subvolume}" &>/dev/null; then
    sudo btrfs subvolume create "${subvolume}"
  fi
  sudo chattr +C "${subvolume}"
  sudo umount "${TEMP_DIR}"
  rmdir "${TEMP_DIR}"
  TEMP_DIR=""

  # The entry is checked on its own before it is appended: an fstab entry that
  # fails to mount at boot leaves the system in emergency mode.
  if ! findmnt --fstab -n --mountpoint "${IMAGES_DIR}" &>/dev/null; then
    print_msg "Adding ${IMAGES_SUBVOLUME} to ${FSTAB}"
    printf -v entry 'UUID=%s\t%s\tbtrfs\t%s\t0 0' "${ROOT_UUID}" \
      "${IMAGES_DIR}" "${IMAGES_MOUNT_OPTIONS}"
    TEMP_FILE=$(mktemp)
    printf '%s\n' "${entry}" >"${TEMP_FILE}"
    if ! sudo findmnt --verify --tab-file "${TEMP_FILE}"; then
      print_error "The entry for ${IMAGES_DIR} does not verify; ${FSTAB} is" \
        "unchanged."
      exit 1
    fi
    printf '\n# Disk images of virtual machines, added by %s\n%s\n' \
      "$(basename "$0")" "${entry}" | sudo tee -a "${FSTAB}" >/dev/null
    rm -f "${TEMP_FILE}"
    TEMP_FILE=""
    sudo systemctl daemon-reload
  fi

  if ! mountpoint -q "${IMAGES_DIR}"; then
    sudo mount "${IMAGES_DIR}"
  fi
}

# Each daemon is socket-activated and exits when idle. The services are
# enabled as well, which their Also= lines extend to their sockets: a daemon
# started at boot starts the networks and guests marked for autostart. The
# sockets are started rather than the services, so that each daemon receives
# its sockets from systemd.
enable_libvirt() {
  local daemon
  local -a services=() sockets=()

  for daemon in "${LIBVIRT_DAEMONS[@]}"; do
    services+=("${daemon}.service")
    sockets+=("${daemon}.socket" "${daemon}-ro.socket" \
      "${daemon}-admin.socket")
  done

  print_msg "Enabling the libvirt daemons"
  sudo systemctl enable "${services[@]}"
  sudo systemctl start "${sockets[@]}"
}

# The default network, which the libvirt package defines, is a NAT network on
# virbr0 with dnsmasq for DHCP and DNS. Not fatal: its address range can clash
# with the local network, and guests can use another network instead.
configure_default_network() {
  local active

  if ((!CONFIGURE_NETWORK)); then
    print_msg "Leaving the default network stopped, as --no-network was given"
    return 0
  fi

  print_msg "Starting the default network now and at every boot"
  if ! sudo virsh --connect "${LIBVIRT_URI}" net-autostart default; then
    print_warning "The default network could not be marked for autostart."
    return 0
  fi

  active=$(sudo virsh --connect "${LIBVIRT_URI}" net-list --name) || active=""
  if ! grep -qx 'default' <<<"${active}" \
    && ! sudo virsh --connect "${LIBVIRT_URI}" net-start default; then
    print_warning "The default network could not be started; see" \
      "'sudo virsh net-start default' for the reason."
  fi
}

# libvirt-guests.service has no stop timeout of its own, so the host's shorter
# default does not end the guests before they shut down. The system daemons
# leave guests to it, as their auto_shutdown settings default to none. Not
# fatal: without it, the host's shutdown ends running guests at once.
configure_guest_shutdown() {
  print_msg "Shutting down running guests with the host, ${SHUTDOWN_TIMEOUT}" \
    "seconds for each"
  sed "s|@SHUTDOWN_TIMEOUT@|${SHUTDOWN_TIMEOUT}|g" "${GUESTS_CONF_SRC}" \
    | sudo install -D -m 0644 /dev/stdin /etc/conf.d/libvirt-guests
  if ! sudo systemctl enable --now libvirt-guests.service; then
    print_warning "libvirt-guests.service could not be enabled; running" \
      "guests will be ended at once when the host shuts down."
  fi
}

# The libvirt package's Polkit rule lets members of the libvirt group manage
# the system's virtual machines without authentication, which amounts to root
# access. Not fatal: without the membership, virt-manager asks for the
# administrator password instead.
add_to_libvirt_group() {
  local user

  if ((!ADD_TO_GROUP)); then
    return 0
  fi

  user=$(id -un)
  print_msg "Adding ${user} to the ${LIBVIRT_GROUP} group"
  if ! sudo usermod -aG "${LIBVIRT_GROUP}" "${user}"; then
    print_warning "${user} could not be added to the ${LIBVIRT_GROUP} group;" \
      "virt-manager asks for the administrator password instead."
  fi
}

print_summary() {
  echo
  print_heading "iNSTALLATiON SUMMARY"
  if ((KVM_AVAILABLE)); then
    echo "${WHITE}Hypervisor:${NO_COLOR} QEMU with KVM, managed by libvirt"
  else
    echo "${WHITE}Hypervisor:${NO_COLOR} QEMU without KVM, managed by libvirt"
  fi
  if [[ -n "${EXTRA_PACKAGES}" ]]; then
    echo "${WHITE}Additional packages:${NO_COLOR} ${EXTRA_PACKAGES}"
  fi
  if ((CREATE_SUBVOLUME)); then
    echo "${WHITE}Disk images:${NO_COLOR} ${IMAGES_DIR}, on the Btrfs" \
      "subvolume ${IMAGES_SUBVOLUME}"
  else
    echo "${WHITE}Disk images:${NO_COLOR} ${IMAGES_DIR}"
  fi
  if ((CONFIGURE_NETWORK)); then
    echo "${WHITE}Network:${NO_COLOR} default, NAT on virbr0"
  else
    echo "${WHITE}Network:${NO_COLOR} none started"
  fi
  echo "${WHITE}Host shutdown:${NO_COLOR} running guests are shut down" \
    "first, ${SHUTDOWN_TIMEOUT} seconds for each"
  echo
  if ((ADD_TO_GROUP)); then
    echo "${BLUE}==>${WHITE} Done. Log in again for the ${LIBVIRT_GROUP}" \
      "group to take effect.${NO_COLOR}"
  else
    echo "${BLUE}==>${WHITE} Done. virt-manager asks for the administrator" \
      "password when it connects.${NO_COLOR}"
  fi
}

main() {
  # Only EXIT runs cleanup: a signal handler would see the status of whatever
  # command the signal interrupted, which is 0 more often than not. Converting
  # the signals to an exit gives cleanup the real code, and only one trap fires.
  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  if [[ -z "${VIRT_INSTALL_LOG:-}" ]]; then
    start_logging "$@"
  fi

  print_logo

  parse_args "$@"

  validate_inputs
  validate_shutdown_timeout
  validate_packages
  validate_virtualization
  validate_images_location
  validate_firewall
  confirm_operation

  update_system
  install_packages
  install_extra_packages

  create_images_subvolume
  enable_libvirt
  configure_default_network
  configure_guest_shutdown
  add_to_libvirt_group

  print_summary
}

# Runs only when executed, so that sourcing the script defines its functions
# without installing anything.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
