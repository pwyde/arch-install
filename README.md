# arch-install

<div align="center">
    <img src="https://archlinux.org/static/logos/archlinux-logo-light-scalable.svg" align="center" alt="Arch Linux">
</div>

## Description

`arch-install.sh` is an automated Arch Linux installation script that installs and configures an encrypted Arch Linux system using **LUKS2**, **Btrfs**, **TPM2**, **Unified Kernel Images (UKIs)** and the **Limine** bootloader.

The script is designed to automate the complete installation process while providing validation, error handling, cleanup, and support for resuming the installation from individual stages.

## Features

- Erases existing data on the selected disk.
- Automatically detects the target disk and CPU vendor.
- Creates a new GPT partition table:
  - Creates a 2 GiB EFI System Partition formatted with FAT32, mounted at `/boot`.
  - Creates a root partition using the remaining disk space.
- Creates a LUKS2-encrypted root partition.
- Formats the encrypted container with Btrfs.
- Creates configurable Btrfs subvolumes:
  - `/`
  - `/home`
  - `/var/cache`
  - `/var/log`
  - `/root`
- Installs the Arch Linux base system and configurable additional packages.
- Automatically installs the appropriate CPU microcode package for Intel or AMD processors.
- Configures base system, i.e. timezone, hostname, locale and more...
- Detects available TPM hardware and configures TPM2-based disk unlocking with a PIN.
- Configures `mkinitcpio` to generate Unified Kernel Images (UKIs).
- Installs and configures `limine` as bootloader, booting the UKIs directly.
- Installs Limine as the removable-media fallback loader and registers a UEFI
  boot entry with `efibootmgr`.
- Installs a pacman hook that redeploys Limine to the ESP on package upgrade.
- Creates a Btrfs swapfile the size of RAM for hibernation, with resume
  parameters embedded in the UKI.
- Configures a Plymouth boot splash using Omarchy's theme, which also takes the
  TPM2 PIN at boot.
- Provides customizable installation parameters.
- Provides cleanup functionality when the installation fails.
- Supports resuming the installation from different stages instead of starting over.

## Instructions

Boot system from a Arch Linux installation [image](https://archlinux.org/download). Clone repository and execute script.

```
git clone https://github.com/pwyde/arch-install
cd arch-install
./arch-install.sh
```

Using script with parameters.

```
./arch-install.sh --hostname arch-linux --username patrik
```

## Usage

See help for available parameters and functionality.

```
./arch-install.sh --help

Usage: arch-install.sh [options]

Options:
  -h, --help                 Show this help message
  -d, --disk DISK            Specify disk (default: /dev/nvme0n1)
  -n, --hostname HOSTNAME    Set hostname (default: arch-linux)
  -u, --username USERNAME    Set username (default: admin)
  -t, --timezone TIMEZONE    Set timezone (default: Europe/Stockholm)
  -k, --keymap KEYMAP        Set keymap (default: sv-latin1)
  -l, --locale LOCALE        Set locale (default: sv_SE.UTF-8)
  -s, --subvolumes SUBVOLS   Btrfs subvolumes, space-separated (default: @ @home @cache @log @root)
  -p, --packages PACKAGES    Additional packages to install (appended to defaults)
  -y, --yes                  Non-interactive mode, use defaults for prompts
  --stage STAGE              Start from specific installation stage:
                             'partitions', 'format', 'btrfs', 'mount',
                             'base', 'configure', 'users', 'boot', 'verify'
```

## Bootloader

The script installs [Limine](https://wiki.archlinux.org/title/Limine) from the
official repositories and configures it by hand -- `limine-mkinitcpio-hook` and
`limine-snapper-sync` are AUR packages and are deliberately left out.

The ESP is mounted at **`/boot`** (as Omarchy does), so the kernel, the UKIs and
the bootloader all live on the same FAT partition and there is no separate
`/efi`.

| Path | Purpose |
| --- | --- |
| `/boot/vmlinuz-linux` | Kernel, installed straight onto the ESP |
| `/boot/EFI/limine/limine_x64.efi` | The bootloader, registered as a UEFI boot entry |
| `/boot/EFI/BOOT/BOOTX64.EFI` | Removable-media fallback, used if the firmware loses its NVRAM entry |
| `/boot/EFI/Linux/arch_linux.efi` | UKI built by `mkinitcpio` |
| `/boot/EFI/Linux/arch_linux-fallback.efi` | Fallback UKI |
| `/boot/limine.conf` | Menu entries and theming |

Notes:

- **The ESP must be mounted before `pacstrap`**, because the kernel is installed
  onto it. The script enforces this: installing the kernel to the Btrfs root and
  then mounting the ESP over it would leave an unbootable system.
- **The ESP is mounted `fmask=0177,dmask=0077`** (files 0600, directories 0700).
  FAT carries no permission bits, so without this the kernel and the UKIs on
  `/boot` are world-readable. These values match what `mkinitcpio` would have
  applied on a normal filesystem -- it builds initramfs images and UKIs under
  `umask 077`, because an initramfs can carry secrets such as a LUKS keyfile.
- **The kernel command line lives inside the UKI**, written to
  `/etc/cmdline.d/10-root.conf` and embedded by `mkinitcpio`. Limine chainloads the
  UKI with `protocol: efi` and supplies no command line of its own.
- **The paths match what `limine-entry-tool` expects.** It derives
  `${ESP_PATH}/EFI/limine/limine_x64.efi`, `${ESP_PATH}/EFI/BOOT/BOOTX64.EFI`
  and `${ESP_PATH}/limine.conf` and those are not configurable, so installing
  `limine-mkinitcpio-hook` later takes over these files rather than creating a
  second set. The UKI names follow the same tool's
  `${CUSTOM_UKI_NAME}_${kernel}.efi` scheme, so `CUSTOM_UKI_NAME="arch"` writes
  the same `arch_linux.efi` instead of a duplicate.
- **A pacman hook redeploys Limine on upgrade.** The `limine` package only
  updates `/usr/share/limine/BOOTX64.EFI`; without the hook the copies on the
  ESP would silently stay at the old version.
- **ESP sizing**: 2 GiB holds the kernel and both UKIs comfortably. Bear it in
  mind if you later add snapshot boot entries, since each snapshot can carry its
  own UKI.

Secure Boot is **not** configured by this script -- leave it disabled in
firmware. It is handled by a separate post-installation script.

## Filesystem layout

Btrfs subvolumes, all mounted `compress=zstd:3,noatime,nodiscard`:

| Subvolume | Mount point |
| --- | --- |
| `@` | `/` |
| `@home` | `/home` |
| `@cache` | `/var/cache` |
| `@log` | `/var/log` |
| `@root` | `/root` |

- **`compress=zstd:3`** is btrfs's own default level. The level applies only to
  newly written data, so it is set at install time rather than changed later.
- **`noatime`**: on a copy-on-write filesystem every atime update is a metadata
  write, which also makes snapshots diverge from their parent for no change in
  content.
- **`nodiscard` plus `fstrim.timer`**: the LUKS container is opened with
  `--allow-discards`, so the device supports TRIM and btrfs would otherwise
  enable continuous `discard=async` by default (kernel 6.2 and later). Arch,
  Debian and Red Hat all recommend periodic TRIM over continuous, so freed
  blocks are discarded weekly in one batch instead of on every delete.
- **There is deliberately no snapshots subvolume.** `snapper create-config`
  creates its own `/.snapshots` and refuses to run when the path already exists,
  so creating one here would only have to be worked around later. Snapper is set
  up by a separate post-installation script.

Note that enabling TRIM on a dm-crypt device leaks which blocks are free, which
can be enough to reveal the filesystem in use. See
[dm-crypt/Specialties](https://wiki.archlinux.org/title/Dm-crypt/Specialties#Discard/TRIM_support_for_solid_state_drives_(SSD))
for the trade-off; it is enabled here deliberately.

## Hibernation

The script sets up hibernation the way Omarchy's `omarchy-hibernation-setup`
does:

- A **`/swap` Btrfs subvolume** marked `NODATACOW` (`chattr +C`), nested under
  `@`. A Btrfs subvolume cannot be snapshotted while it holds an active
  swapfile, so the swapfile gets a subvolume of its own; being nested, it is
  also left out of snapshots of `@`.
- **`/swap/swapfile`**, created with `btrfs filesystem mkswapfile` and sized to
  total RAM.
- An fstab entry at **`pri=0`**, below zram's priority of 100, so everyday
  swapping stays in compressed RAM and the file is effectively reserved for
  hibernation images.
- **`resume=` and `resume_offset=`** in `/etc/cmdline.d/30-resume.conf`, embedded in
  the UKI. The offset comes from `btrfs inspect-internal map-swapfile`, since it
  must be physical and relative to the unlocked LUKS device.
- `rtc_cmos.use_acpi_alarm=1` on systems that suspend with s2idle, needed for
  suspend-then-hibernate.
- Omarchy's `keyboard-backlight` system-sleep hook, which turns the keyboard
  backlight off before hibernating (some ASUS controllers otherwise block the S4
  power-off). Needs `brightnessctl`.

Three deliberate differences from Omarchy:

| Omarchy | This script | Why |
| --- | --- | --- |
| `HOOKS+=(resume)` | no `resume` hook | Omarchy boots a busybox initramfs, where that hook is required. The `systemd` hook used here replaces it and ships `systemd-hibernate-resume`, which reads the same parameters. |
| `resume=` in a `limine-entry-tool` drop-in | `resume=` in `/etc/cmdline.d/` | There is no `limine-entry-tool` at install time; the UKI's command line comes from `/etc/cmdline.d/`. |
| `swapon` after creating the file | no `swapon` | In the installer it would activate swap on the live ISO's kernel and pin `/mnt`. The fstab entry activates it on first boot. |

The resume offset is fixed at install time. If the swapfile is ever recreated,
regenerate `/etc/cmdline.d/30-resume.conf` and rebuild the UKI with `mkinitcpio -P`.

## Plymouth

The boot splash is set up the way Omarchy does it:

- **Omarchy's `omarchy` theme**, installed to `/usr/share/plymouth/themes/omarchy/`.
  The files live in this repository under
  [`default/plymouth/omarchy/`](./default/plymouth/omarchy/), copied unchanged from Omarchy's
  `default/plymouth/` (commit `9c5482c5` on the `quattro` branch) together with
  Omarchy's MIT license. The installer therefore has to run from a full checkout
  of this repository; it checks for the files before touching the disk.
- **`Theme=omarchy`** in `/etc/plymouth/plymouthd.conf`.
- **The `plymouth` mkinitcpio hook**, after `systemd` and before `sd-encrypt`:
  `HOOKS=(base systemd plymouth autodetect microcode modconf kms keyboard sd-vconsole vconsole-latin block sd-encrypt filesystems fsck)`.
- **Omarchy's quiet-boot kernel parameters**, embedded in the UKI:
  - `/etc/cmdline.d/80-initramfs-async.conf`: `initramfs_async=0`, working
    around a kernel 7.1 race in which Plymouth exits before it can read
    `/proc/cmdline` and an encrypted boot falls back to a plain text prompt.
  - `/etc/cmdline.d/90-splash.conf`:
    `quiet splash loglevel=0 systemd.show_status=false rd.udev.log_level=0 vt.global_cursor_default=0`.

How it fits the rest of this install:

- **TPM2 PIN.** Plymouth does not unlock anything; with a systemd initramfs the
  hook installs `systemd-ask-password-plymouth`, so the PIN that
  `systemd-cryptsetup` asks for is typed into the splash. The theme draws a lock
  icon and an entry field but not the prompt text, so the PIN prompt and a
  recovery-key prompt look the same.
- **Keyboard layout.** `/etc/vconsole.conf` is written by
  `systemd-firstboot --keymap`, as on Omarchy, which sets `KEYMAP` and derives the
  matching `XKBLAYOUT`, `XKBMODEL` and `XKBOPTIONS` from systemd's
  `kbd-model-map` (for example `sv-latin1` becomes `se`). The `sd-vconsole` hook
  copies the file into the initramfs, and because `XKBLAYOUT` is set, Plymouth
  reads the PIN with that xkb layout. With a keymap whose layout does not type
  Latin letters (such as Russian or Greek), a Latin PIN or passphrase could not
  be typed at the prompt. The local mkinitcpio hook
  [`etc/initcpio/install/vconsole-latin`](./etc/initcpio/install/vconsole-latin),
  installed to `/etc/initcpio/install/` and listed after `sd-vconsole`, guards
  against that: for such layouts it replaces the initramfs copy of
  `vconsole.conf` with one that sets `XKBLAYOUT=us`. The installed system's
  `vconsole.conf` is not changed, and the check runs on every rebuild.
- **Console cursor.** `vt.global_cursor_default=0` hides the cursor on text
  consoles after boot too, not just during the splash.

Two differences from Omarchy, forced by the systemd initramfs and the lack of
`limine-entry-tool` at install time:

| Omarchy | This script | Why |
| --- | --- | --- |
| `FILES+=(/etc/vconsole.conf)` in its mkinitcpio hooks drop-in | not needed | Omarchy's busybox initramfs does not include `vconsole.conf` by itself; the `sd-vconsole` hook used here already does. |
| kernel parameters in a `limine-entry-tool` drop-in | kernel parameters in `/etc/cmdline.d/` | The UKI's command line comes from `/etc/cmdline.d/`. |

## Security Design

See in-depth documentation [here](./security.md).

## References

- [fdmux.dev - A Sealed Deal: TPM2, UKI, and the Arch Install Script That Nearly Broke Me](https://fdmux.dev/posts/sealed-deal-arch-linux-install/#mkinitcpio-vs-dracut-whats-the-difference)
- [Oliver Daff's GitHub Gist - archtpm-install.sh](https://gist.github.com/oliverdaff/c3c037b0509ba9d961c8c1039a70706e)
- [Lyle Liu - Arch Linux Secure Boot + Systemd-boot + Btrfs + Full Disk Encryption + TPM Auto-Unlock](https://heylyle.com/en/posts/arch-secure-boot-fde-tpm2)
- [Lyle Liu - Revisiting TPM2 PCR Selection](https://heylyle.com/en/posts/revisiting-tpm2-pcr-selection)
- [Lyle Liu - Arch Linux Post-Installation Tasks](https://heylyle.com/en/posts/archlinux-post-installation-task)
- [Arch Linux Wiki - dm-crypt / Encrypting an entire system / LUKS on a partition with TPM2 and Secure Boot](https://wiki.archlinux.org/title/Dm-crypt/Encrypting_an_entire_system#LUKS_on_a_partition_with_TPM2_and_Secure_Boot)
- [Arch Linux Wiki - Btrfs](https://wiki.archlinux.org/title/Btrfs)
- [Arch Linux Wiki - Trusted Platform Module](https://wiki.archlinux.org/title/Trusted_Platform_Module)
- [Arch Linux Wiki - Secure Boot](https://wiki.archlinux.org/title/Unified_Extensible_Firmware_Interface/Secure_Boot)
- [Arch Linux Wiki - Unified kernel image](https://wiki.archlinux.org/title/Unified_kernel_image)
- [Arch Linux Wiki - Limine](https://wiki.archlinux.org/title/Limine)
- [Limine - CONFIG.md](https://github.com/limine-bootloader/limine/blob/trunk/CONFIG.md)
- [Omarchy](https://github.com/omacom/omarchy)
- [Arch Linux Wiki - systemd-cryptenroll](https://wiki.archlinux.org/title/Systemd-cryptenroll)
- [Arch Linux Wiki - mkinitcpio](https://wiki.archlinux.org/title/Mkinitcpio)
- [Arch Linux Wiki - dm-crypt / System configuration / Pinning a LUKS volume](https://wiki.archlinux.org/title/Dm-crypt/System_configuration#Pinning_a_LUKS_volume)
- [Arch Linux Wiki - cryptsetup actions specific for LUKS / Key management](https://wiki.archlinux.org/title/Dm-crypt/Device_encryption#Key_management)
