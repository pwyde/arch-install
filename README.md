# arch-install

<div align="center">
    <img src="https://archlinux.org/static/logos/archlinux-logo-light-scalable.svg" align="center" alt="Arch Linux">
</div>

## Description

`arch-install.sh` is an automated Arch Linux installation script that installs and configures an encrypted Arch Linux system using **LUKS2**, **Btrfs**, **TPM2**, **Secure Boot**, and **Unified Kernel Images (UKIs)**.

The script is designed to automate the complete installation process while providing validation, error handling, cleanup, and support for resuming the installation from individual stages.

## Features

- Erases existing data on the selected disk.
- Automatically detects the target disk and CPU vendor.
- Creates a new GPT partition table.
  - Creates a 2 GiB EFI System Partition formatted with FAT32.
  - Creates A root partition using the remaining disk space.
- Creates a LUKS2-encrypted root partition.
- Formats the encrypted container with Btrfs.
- Creates configurable Btrfs subvolumes:
  - `/`
  - `/home`
  - `/var/cache`
  - `/var/log`
  - `/.snapshots`
  - `/root`
- Installs the Arch Linux base system and configurable additional packages.
- Automatically installs the appropriate CPU microcode package for Intel or AMD processors.
- Configures base system, i.e. timezone, hostname, locale and more...
- Detects available TPM hardware and configures TPM2-based disk unlocking with a PIN.
- Configures `mkinitcpio` to generate Unified Kernel Images (UKIs).
- Installs and configures `systemd-boot` as bootloader.
- Configures secure boot using `sbctl`.
- Creates secure boot keys and enrolls Microsoft keys.
- Signs the UKI and systemd-boot EFI binaries.
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
  -s, --subvolumes SUBVOLS   Btrfs subvolumes, space-separated (default: @ @home @cache @log @.snapshots @root)
  -p, --packages PACKAGES    Additional packages to install (appended to defaults)
  -y, --yes                  Non-interactive mode, use defaults for prompts
  --stage STAGE              Start from specific installation stage:
                             'partitions', 'format', 'btrfs', 'mount',
                             'base', 'configure', 'users', 'boot', 'verify'
```