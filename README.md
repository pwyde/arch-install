# arch-install

<div align="center">
    <img src="https://archlinux.org/static/logos/archlinux-logo-light-scalable.svg" align="center" alt="Arch Linux">
</div>

## Description

`arch-install.sh` installs and configures an encrypted Arch Linux system in a
single sequential run. The system uses **LUKS2** full disk encryption,
**Btrfs** subvolumes, **Unified Kernel Images (UKIs)** booted by the
**Limine** bootloader, and **Snapper** snapshots with a boot entry for each
snapshot.

The installer validates its input and the live environment before any change
is made to the disk, and cleans up the mounts and the LUKS container when an
installation fails.

## Features

- GPT partitioning: a 2 GiB EFI System Partition mounted at `/boot`, and a
  LUKS2-encrypted root partition on the remaining space.
- Btrfs with configurable subvolumes for `/`, `/home`, `/var/cache`,
  `/var/log` and `/root`, compressed with zstd.
- UKIs built by `mkinitcpio` with a systemd-based initramfs, booted directly
  by Limine.
- Snapper snapshots around every pacman transaction, each bootable from the
  Limine menu.
- Hibernation to a Btrfs swapfile the size of RAM, alongside zram swap.
- A Plymouth boot splash with an Arch Linux theme, which also takes the LUKS
  passphrase.
- CPU microcode for Intel or AMD, detected automatically.
- System tuning and hardening: sysctl, sshd, journald, core dumps, shutdown
  timeouts and periodic TRIM.
- The [paru](https://github.com/Morganamilo/paru) AUR helper, built from
  source.
- A complete log of the installation, copied with the installer to the new
  user's home directory.

## Requirements

- An Arch Linux installation [image](https://archlinux.org/download), booted
  in UEFI mode.
- UEFI Secure Boot disabled. The installer refuses to run while it is enabled.
- A network connection.
- A target disk whose contents may be erased.

## Instructions

Boot the Arch Linux installation image, then clone the repository and run the
installer as root:

```
git clone --depth 1 https://github.com/pwyde/arch-install
cd arch-install
./arch-install.sh
```

A shallow clone (`--depth 1`) is recommended. The repository contains prebuilt
packages, and a full clone would also fetch every previous version of them.

The installer prompts for the LUKS passphrase and for the user and root
passwords, and asks for confirmation before the disk is erased.

> [!WARNING]
> All data on the target disk is erased.

## Usage

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
```

Example:

```
./arch-install.sh --disk /dev/sda --hostname arch-linux --username patrik
```

- **`--disk`** defaults to the first disk reported by `lsblk`, excluding loop,
  zram, optical and RAM devices. The default shown therefore depends on the
  machine.
- **`--locale`** sets the regional formats: numbers, dates, currency,
  measurements, paper size and collation. Messages remain in English
  (`LANG=en_GB.UTF-8`), as set in [`etc/locale.conf`](./etc/locale.conf).
- **`--yes`** sets the temporary password `changeme` for both the user and
  root. An empty or mismatched password at the prompt has the same result.
  The summary at the end of the installation lists the affected accounts.

## Logging

All terminal output is recorded in `logs/arch-install-<timestamp>.log` in the
repository. Passwords are never recorded. A repeated run in the same checkout
appends to the existing log. After a successful installation, the repository
and its log are copied to `~/arch-install` in the new user's home directory.

## Documentation

- [ARCHITECTURE.md](./ARCHITECTURE.md) describes the installation in depth:
  boot chain, filesystem layout, snapshots, hibernation, initramfs, Plymouth,
  system tuning and the prebuilt packages.
- [SECURITY.md](./SECURITY.md) describes the threat model, and why TPM2
  unlocking and UEFI Secure Boot are not used.

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
- [Arch Linux Wiki - systemd-cryptenroll](https://wiki.archlinux.org/title/Systemd-cryptenroll)
- [Arch Linux Wiki - mkinitcpio](https://wiki.archlinux.org/title/Mkinitcpio)
- [Arch Linux Wiki - dm-crypt / System configuration / Pinning a LUKS volume](https://wiki.archlinux.org/title/Dm-crypt/System_configuration#Pinning_a_LUKS_volume)
- [Arch Linux Wiki - cryptsetup actions specific for LUKS / Key management](https://wiki.archlinux.org/title/Dm-crypt/Device_encryption#Key_management)
