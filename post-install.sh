#!/bin/bash
# post-install.sh v1.0
#
# Post-installation script for a system installed with arch-install.sh. Adds the
# pieces that need a booted system: Btrfs snapshots with Snapper, the Limine
# AUR hooks that take over UKI generation, and Secure Boot with sbctl.
#
# Features:
# - Snapper configuration for the root subvolume
# - limine-mkinitcpio-hook and limine-snapper-sync, built from the AUR
# - Snapshot boot entries in the Limine menu
# - Secure Boot key enrollment and signing with sbctl
# - TPM2 re-enrollment against the Secure Boot PCR
#
# Usage: ./post-install.sh [options]
# See --help for available options

set -euo pipefail

DEFAULT_AUR_HELPER="paru"

RED=$'\033[91m'
GREEN=$'\033[92m'
BLUE=$'\033[94m'
YELLOW=$'\033[93m'
WHITE=$'\033[97m'
NO_COLOR=$'\033[0m'

print_msg() {
  echo -e "${GREEN}==>${NO_COLOR}${WHITE}" "${@}" "${NO_COLOR}" >&1
}

print_warning() {
  echo -e "${YELLOW}==> WARNING:${NO_COLOR}${WHITE}" "${@}" "${NO_COLOR}" >&2
}

print_error() {
  echo -e "${RED}==> ERROR:${NO_COLOR}${WHITE}" "${@}" "${NO_COLOR}" >&2
}

# Repository files
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SNAPPER_CONFIG_SRC="${SCRIPT_DIR}/default/snapper/root"
SNAPPER_CONFD_SRC="${SCRIPT_DIR}/etc/conf.d/snapper"
LIMINE_TOOL_CONF_SRC="${SCRIPT_DIR}/etc/limine-entry-tool.d/50-arch.conf"

ESP_PATH="/boot"
LIMINE_DEFAULT_CONF="/etc/default/limine"
SNAPPER_CONFIG="/etc/snapper/configs/root"

REPO_PACKAGES="snapper snap-pac sbctl git base-devel"
AUR_PACKAGES="limine-mkinitcpio-hook limine-snapper-sync"

AUR_USER=""
ASSUME_YES=0
START_STAGE="packages"

show_help() {
  cat <<EOF
Arch Linux Post-Installation Script

Configures a system installed with arch-install.sh. Run it as root on the
installed system after the first boot, not from the live ISO.

Usage: post-install.sh [options]

Options:
  -h, --help                 Show this help message
  -u, --user USERNAME        User account to build AUR packages as
                             (default: the sole non-system user, if there is one)
  -y, --yes                  Non-interactive mode, use defaults for prompts
      --stage STAGE          Start from a specific stage:
                             'packages', 'aur', 'limine', 'snapper',
                             'secureboot', 'tpm', 'verify'

Stages:
  packages    Install the repository packages
  aur         Bootstrap ${DEFAULT_AUR_HELPER} and build the Limine AUR packages
  limine      Pin the kernel command line and configure limine-entry-tool
  snapper     Create and configure the Snapper root config
  secureboot  Enrol Secure Boot keys with sbctl and sign the boot files
  tpm         Re-enrol TPM2 unlocking against the current PCR 7
  verify      Check the resulting configuration

EOF
  exit 0
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      -h | --help)
        show_help
        ;;
      -u | --user)
        AUR_USER="$2"
        shift 2
        ;;
      -y | --yes)
        ASSUME_YES=1
        shift
        ;;
      --stage)
        START_STAGE="$2"
        shift 2
        ;;
      *)
        print_error "Unknown option: $1"
        print_error "Run with --help for usage."
        exit 1
        ;;
    esac
  done
}

confirm_operation() {
  local prompt="$1"

  if [ "$ASSUME_YES" -eq 1 ]; then
    return 0
  fi

  read -r -p "${prompt} [y/N]: " reply
  case "$reply" in
    [yY] | [yY][eE][sS]) return 0 ;;
    *) return 1 ;;
  esac
}

# The user that owns the AUR build. makepkg refuses to run as root, so the
# build drops to a normal account with sudo rights.
detect_aur_user() {
  local candidates

  if [ -n "$AUR_USER" ]; then
    if ! id "$AUR_USER" &>/dev/null; then
      print_error "User '$AUR_USER' does not exist."
      exit 1
    fi
    return 0
  fi

  candidates=$(awk -F: '$3 >= 1000 && $3 < 65534 { print $1 }' /etc/passwd)

  if [ "$(echo "$candidates" | wc -w)" -ne 1 ]; then
    print_error "Could not determine which user to build AUR packages as."
    print_error "Candidates: $(echo "$candidates" | tr '\n' ' ')"
    print_error "Pass one with --user."
    exit 1
  fi

  AUR_USER="$candidates"
  print_msg "Building AUR packages as '${AUR_USER}'"
}

# makepkg and paru both call sudo to install what they build, so the build user
# needs sudo rights and will be asked for its own password even in -y mode.
check_aur_user_sudo() {
  if ! id -nG "$AUR_USER" | grep -qw wheel; then
    print_error "User '${AUR_USER}' is not in the wheel group and cannot install packages."
    exit 1
  fi

  print_warning "sudo will ask for ${AUR_USER}'s password during the AUR build."
}

validate_inputs() {
  if [ "$(id -u)" -ne 0 ]; then
    print_error "This script must be run as root."
    exit 1
  fi

  if [ ! -d /sys/firmware/efi/efivars ]; then
    print_error "System not booted in UEFI mode."
    exit 1
  fi

  # A live ISO would configure the wrong system entirely.
  if findmnt -no FSTYPE / | grep -q "^overlay$\|^tmpfs$"; then
    print_error "This looks like a live environment. Run the script on the installed system."
    exit 1
  fi

  if ! mountpoint -q "$ESP_PATH"; then
    print_error "The ESP is not mounted at ${ESP_PATH}."
    exit 1
  fi

  if ! command -v limine >/dev/null 2>&1 && [ ! -f "${ESP_PATH}/limine.conf" ]; then
    print_error "Limine does not appear to be installed. Run arch-install.sh first."
    exit 1
  fi

  local repo_file
  local -a repo_files=(
    "$SNAPPER_CONFIG_SRC"
    "$SNAPPER_CONFD_SRC"
    "$LIMINE_TOOL_CONF_SRC"
  )

  for repo_file in "${repo_files[@]}"; do
    [ -f "$repo_file" ] && continue
    print_error "Missing repository file: $repo_file"
    print_error "Run the script from a full checkout of the repository."
    exit 1
  done
}

# Echoes the Secure Boot state: enabled, disabled or unknown.
secure_boot_state() {
  local sb_var sb_line

  sb_var="/sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c"

  if [ -r "$sb_var" ]; then
    # Four bytes of EFI variable attributes, then the state byte.
    case "$(od -An -t u1 -j 4 -N 1 "$sb_var" 2>/dev/null | tr -d '[:space:]')" in
      1)
        echo "enabled"
        return 0
        ;;
      0)
        echo "disabled"
        return 0
        ;;
    esac
  fi

  if command -v bootctl >/dev/null 2>&1; then
    sb_line=$(bootctl status 2>/dev/null | grep -m1 "Secure Boot:" || true)
    case "$sb_line" in
      *enabled*)
        echo "enabled"
        return 0
        ;;
      *disabled*)
        echo "disabled"
        return 0
        ;;
    esac
  fi

  echo "unknown"
}

# The root device behind the LUKS container, needed for TPM re-enrolment.
detect_root_device() {
  local root_source crypt_name

  root_source=$(findmnt -no SOURCE --nofsroot / 2>/dev/null || true)
  crypt_name=$(lsblk -nso NAME,TYPE "$root_source" 2>/dev/null |
    awk '$2 == "crypt" { print $1; exit }' || true)

  if [ -z "$crypt_name" ]; then
    echo ""
    return 0
  fi

  lsblk -nspo NAME,TYPE "/dev/mapper/${crypt_name}" 2>/dev/null |
    awk '$2 == "part" { print $1; exit }' || true
}

install_packages() {
  print_msg "Installing repository packages"

  # shellcheck disable=SC2086
  pacman -S --needed --noconfirm $REPO_PACKAGES
}

# makepkg refuses to run as root, so the build runs as $AUR_USER in a directory
# that user owns.
bootstrap_aur_helper() {
  local build_dir

  if command -v "$DEFAULT_AUR_HELPER" >/dev/null 2>&1; then
    print_msg "${DEFAULT_AUR_HELPER} is already installed"
    return 0
  fi

  print_msg "Bootstrapping ${DEFAULT_AUR_HELPER} from the AUR"

  build_dir=$(sudo -u "$AUR_USER" mktemp -d)

  sudo -u "$AUR_USER" git clone --depth 1 \
    "https://aur.archlinux.org/${DEFAULT_AUR_HELPER}.git" "${build_dir}/${DEFAULT_AUR_HELPER}"

  # makepkg -si calls pacman through sudo, which needs the user in wheel.
  sudo -u "$AUR_USER" bash -c "cd '${build_dir}/${DEFAULT_AUR_HELPER}' && makepkg -si --noconfirm"

  rm -rf "$build_dir"

  if ! command -v "$DEFAULT_AUR_HELPER" >/dev/null 2>&1; then
    print_error "${DEFAULT_AUR_HELPER} was not installed."
    exit 1
  fi
}

install_aur_packages() {
  print_msg "Building the Limine AUR packages"
  print_warning "limine-mkinitcpio-hook compiles with GraalVM native-image."
  print_warning "It downloads a large toolchain and needs several GB of RAM; expect a long build."

  # shellcheck disable=SC2086
  sudo -u "$AUR_USER" "$DEFAULT_AUR_HELPER" -S --needed --noconfirm $AUR_PACKAGES
}

# Assemble the kernel command line exactly as mkinitcpio does when it embeds it
# in the UKI: every *.conf in /etc/cmdline.d/ in version-sort order, comments
# stripped, joined with spaces.
assemble_cmdline() {
  local -a files=()

  mapfile -t files < <(find /etc/cmdline.d -maxdepth 1 -type f -name '*.conf' 2>/dev/null |
    LC_ALL=C.UTF-8 sort -V)

  if [ "${#files[@]}" -eq 0 ]; then
    echo ""
    return 0
  fi

  grep -ha -- '^[^#]' "${files[@]}" | tr -s '\n' ' ' | sed 's/[[:space:]]*$//'
}

# limine-entry-tool reads a command line only from /etc/kernel/cmdline or
# /proc/cmdline, never from /etc/cmdline.d/, and any KERNEL_CMDLINE[...]+= makes
# it ignore both. Without this the regenerated UKI would lose rd.luks.name and
# root=, and the next boot would land in an emergency shell.
configure_limine_tool() {
  local cmdline

  print_msg "Configuring limine-entry-tool"

  cmdline=$(assemble_cmdline)

  if [ -z "$cmdline" ]; then
    print_error "No kernel parameters found in /etc/cmdline.d/."
    exit 1
  fi

  # Refuse to write a command line that cannot unlock or mount the root
  # filesystem, rather than discover it at the next boot.
  if ! grep -q 'rd\.luks\.name=' <<<"$cmdline"; then
    print_error "The assembled command line has no rd.luks.name= parameter:"
    print_error "  $cmdline"
    print_error "Writing it would leave the system unable to unlock its disk."
    exit 1
  fi

  if ! grep -q '\broot=' <<<"$cmdline"; then
    print_error "The assembled command line has no root= parameter:"
    print_error "  $cmdline"
    exit 1
  fi

  print_msg "Pinning the kernel command line:"
  echo "    ${cmdline}"

  install -D -m 0644 "$LIMINE_TOOL_CONF_SRC" /etc/limine-entry-tool.d/50-arch.conf

  # /etc/default/limine overrides the drop-ins, so the command line goes here.
  cat >"$LIMINE_DEFAULT_CONF" <<EOF
# Written by post-install.sh from /etc/cmdline.d/, which stays the source of
# truth for the kernel command line. Re-run 'post-install.sh --stage limine'
# after changing anything in that directory, then 'limine-mkinitcpio'.
KERNEL_CMDLINE[default]+=${cmdline}
EOF
  chmod 0644 "$LIMINE_DEFAULT_CONF"
}

configure_snapper() {
  print_msg "Configuring Snapper"

  # create-config makes its own /.snapshots subvolume and refuses to run when
  # the path already exists, which is why the installer creates no such
  # subvolume.
  if [ ! -f "$SNAPPER_CONFIG" ]; then
    snapper --no-dbus -c root create-config / >/dev/null 2>&1 ||
      snapper -c root create-config /
  fi

  install -D -m 0644 "$SNAPPER_CONFIG_SRC" "$SNAPPER_CONFIG"
  install -D -m 0644 "$SNAPPER_CONFD_SRC" /etc/conf.d/snapper

  # No timeline snapshots: snap-pac takes them around pacman transactions
  # instead, so every entry in the Limine menu corresponds to an upgrade.
  systemctl disable --now snapper-timeline.timer >/dev/null 2>&1 || true
  systemctl enable --now snapper-cleanup.timer
  systemctl enable --now limine-snapper-sync.service
}

configure_secureboot() {
  local sb_state

  print_msg "Configuring Secure Boot"

  sb_state=$(secure_boot_state)

  # The second pass, after the reboot that turned Secure Boot on: the keys are
  # enrolled and the firmware has left Setup Mode, so only signing repeats.
  if [ "$sb_state" = "enabled" ]; then
    print_msg "Secure Boot is already active; re-signing the boot files"
    sbctl sign-all
    sbctl verify || print_warning "sbctl reports unsigned files; check the list above."
    return 0
  fi

  if sbctl status | grep -q "Setup Mode:.*Disabled"; then
    print_error "The firmware is not in Setup Mode, so keys cannot be enrolled."
    print_error "Clear the existing Secure Boot keys in your firmware setup, reboot,"
    print_error "then run: post-install.sh --stage secureboot"
    exit 1
  fi

  if ! sbctl status | grep -q "Installed:.*sbctl is installed"; then
    print_msg "Creating Secure Boot keys"
    sbctl create-keys
  fi

  print_msg "Enrolling keys, including the Microsoft certificates"
  print_warning "Without the Microsoft certificates some firmware and option ROMs stop working."
  sbctl enroll-keys --microsoft

  print_msg "Signing the boot files"
  sbctl sign-all

  sbctl verify || print_warning "sbctl reports unsigned files; check the list above."
}

# PCR 7 measures the Secure Boot policy, so enabling Secure Boot changes it and
# invalidates the enrolment the installer made. Re-enrolling is only correct
# once the system has actually booted with Secure Boot active.
reenroll_tpm() {
  local root_part sb_state

  print_msg "Re-enrolling TPM2 unlocking"

  if [ ! -d /sys/class/tpm ] || [ -z "$(ls -A /sys/class/tpm 2>/dev/null)" ]; then
    print_warning "No TPM device found; skipping."
    return 0
  fi

  sb_state=$(secure_boot_state)

  case "$sb_state" in
    enabled) ;;
    disabled)
      print_warning "Secure Boot is not active yet, so PCR 7 still measures the old policy."
      print_warning "Enrolling now would bind the TPM to a value that changes at the next boot."
      print_warning "Reboot with Secure Boot enabled, then run: post-install.sh --stage tpm"
      return 0
      ;;
    *)
      print_warning "Could not determine the Secure Boot state, so PCR 7 cannot be trusted."
      print_warning "Verify it with 'bootctl status', then run: post-install.sh --stage tpm"
      return 0
      ;;
  esac

  root_part=$(detect_root_device)

  if [ -z "$root_part" ]; then
    print_warning "Could not find the LUKS partition behind /; skipping TPM enrolment."
    return 0
  fi

  print_msg "LUKS device: ${root_part}"
  print_warning "Make sure a recovery key or passphrase for this device still works."

  if ! confirm_operation "Re-enrol TPM2 with a PIN against PCR 7?"; then
    print_msg "Skipping TPM enrolment."
    return 0
  fi

  systemd-cryptenroll "$root_part" \
    --wipe-slot=tpm2 \
    --tpm2-device=auto \
    --tpm2-pcrs=7 \
    --tpm2-with-pin=yes
}

verify_configuration() {
  local cmdline uki_count

  print_msg "Verifying the configuration"

  if [ -f "$LIMINE_DEFAULT_CONF" ]; then
    cmdline=$(grep -h 'KERNEL_CMDLINE' "$LIMINE_DEFAULT_CONF" || true)
    if grep -q 'rd\.luks\.name=' <<<"$cmdline"; then
      print_msg "Kernel command line pinned with an unlock parameter"
    else
      print_error "${LIMINE_DEFAULT_CONF} has no rd.luks.name=; the next UKI rebuild will not boot."
    fi
  else
    print_error "${LIMINE_DEFAULT_CONF} is missing."
  fi

  if command -v limine-entry-tool >/dev/null 2>&1; then
    print_msg "limine-entry-tool reports:"
    limine-entry-tool --get-cmdline default 2>/dev/null || true
  fi

  uki_count=$(find "${ESP_PATH}/EFI/Linux" -maxdepth 1 -name '*.efi' 2>/dev/null | wc -l)
  print_msg "UKIs on the ESP: ${uki_count}"

  if [ -f "$SNAPPER_CONFIG" ]; then
    print_msg "Snapper snapshots: $(snapper -c root list 2>/dev/null | tail -n +3 | wc -l)"
  fi

  if command -v sbctl >/dev/null 2>&1; then
    sbctl status || true
  fi
}

print_summary() {
  echo
  echo "${YELLOW}===${BLUE} Post-installation complete ${YELLOW}===${NO_COLOR}"
  echo
  echo " ${WHITE}Next steps:${NO_COLOR}"
  echo "  - Reboot and enable Secure Boot in the firmware if it is not already on."
  echo "  - After that boot, run: ${WHITE}post-install.sh --stage tpm${NO_COLOR}"
  echo "    to bind TPM2 unlocking to the new PCR 7 value."
  echo "  - Keep the LUKS recovery key until TPM unlocking has been confirmed."
  echo
  echo " ${WHITE}If the system drops to an emergency shell:${NO_COLOR}"
  echo "  The regenerated UKI lost its command line. Check ${WHITE}${LIMINE_DEFAULT_CONF}${NO_COLOR}"
  echo "  against ${WHITE}/etc/cmdline.d/${NO_COLOR}, then run ${WHITE}limine-mkinitcpio${NO_COLOR}."
  echo
}

main() {
  echo "${YELLOW}===${BLUE} Arch Linux Post-Installation Script ${YELLOW}===${NO_COLOR}"

  validate_inputs

  case "$START_STAGE" in
    packages | aur | limine | snapper | secureboot | tpm | verify) ;;
    *)
      print_error "Unknown stage: $START_STAGE"
      print_error "Run with --help for the list of stages."
      exit 1
      ;;
  esac

  case "$START_STAGE" in
    packages)
      detect_aur_user
      check_aur_user_sudo
      install_packages
      bootstrap_aur_helper
      configure_limine_tool
      install_aur_packages
      configure_snapper
      configure_secureboot
      reenroll_tpm
      verify_configuration
      print_summary
      ;;
    aur)
      detect_aur_user
      check_aur_user_sudo
      bootstrap_aur_helper
      configure_limine_tool
      install_aur_packages
      ;;
    limine)
      configure_limine_tool
      if command -v limine-mkinitcpio >/dev/null 2>&1; then
        limine-mkinitcpio
      fi
      ;;
    snapper)
      configure_snapper
      ;;
    secureboot)
      configure_secureboot
      ;;
    tpm)
      reenroll_tpm
      ;;
    verify)
      verify_configuration
      ;;
  esac
}

parse_args "$@"
main
