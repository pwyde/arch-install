# Arch Linux Install

<div align="center">
    <img
        src="https://archlinux.org/static/logos/archlinux-logo-light-scalable.svg"
        align="center" alt="Arch Linux">
</div>

## Description

A custom, opinionated [Arch Linux](https://archlinux.org/) installation, from
an empty disk to a complete desktop in two scripts. `base-install.sh` builds an
encrypted, snapshot-protected system that can boot a recent snapshot from the
boot menu. `desktop-install.sh` adds a Wayland desktop built on
[niri](https://niri-wm.github.io/niri/) and [Noctalia](https://noctalia.dev/),
with the applications, themes and configuration already in place.

The choices are made in advance and applied the same way on every run, which
results in a secure, consistent and reproducible system without hours of
manual setup.

## Base Installation

`base-install.sh` installs and configures an encrypted Arch Linux system in a
single sequential run. The system uses **LUKS2** full disk encryption,
**Btrfs** subvolumes, **Unified Kernel Images (UKIs)** booted by the
**Limine** bootloader, and **Snapper** snapshots with a boot entry for each
snapshot.

The installer validates its input and the live environment before any change
is made to the disk, and cleans up the mounts and the LUKS container when an
installation fails.

### Features

- Automatically detects the target disk and erases existing data.
- CPU microcode for Intel or AMD, detected automatically.
- GPT partitioning:
  - 2 GiB EFI System Partition mounted at `/boot`.
  - LUKS2-encrypted root partition on the remaining space.
- Btrfs with configurable subvolumes compressed with zstd:
  - `/`
  - `/home`
  - `/var/cache`
  - `/var/log`
  - `/root`
- UKIs built by `mkinitcpio` with a systemd-based initramfs, booted directly
  by Limine.
- Snapper snapshots around every pacman transaction, the most recent bootable
  from the Limine menu.
- Hibernation to a Btrfs swapfile the size of RAM where supported, alongside
  zram swap.
- A Plymouth boot splash that also takes the LUKS passphrase.
- System tuning and hardening: sysctl, sshd, journald, core dumps, shutdown
  timeouts and periodic TRIM.
- The [paru](https://github.com/Morganamilo/paru) AUR helper, built from
  source.
- A complete log of the installation.

### Requirements

- An Arch Linux installation [image](https://archlinux.org/download), booted
  in UEFI mode.
- UEFI Secure Boot disabled. The installer refuses to run while it is enabled.
- A network connection.
- A target disk whose contents may be erased.

### Instructions

Boot the Arch Linux installation image, then clone the repository and run the
installer as root:

```bash
git clone --depth 1 https://github.com/pwyde/arch-install
cd arch-install
./base-install.sh
```

> [!NOTE]
> A shallow clone (`--depth 1`) is recommended. The repository contains prebuilt
> packages, and a full clone would also fetch every previous version of them.

The installer prompts for the LUKS passphrase and for the user and root
passwords.

> [!WARNING]
> All data on the target disk will be erased.

### Usage

```text
./base-install.sh --help

Usage: base-install.sh [options]

Options:
  -d, --disk DISK            Specify disk (default: /dev/sda)
  -k, --keymap KEYMAP        Set keymap (default: uk)
  -l, --locale LOCALE        Set locale (default: en_GB.UTF-8)
  -n, --hostname HOSTNAME    Set hostname (default: arch-linux)
  -p, --packages PACKAGES    Additional packages to install, space-separated
                             (appended to defaults)
  -s, --subvolumes SUBVOLS   Btrfs subvolumes, space-separated
                             (default: @ @home @cache @log @root)
  -t, --timezone TIMEZONE    Set timezone (default: Europe/London)
  -u, --username USERNAME    Set username (default: admin)
  -y, --yes                  Non-interactive mode, use defaults for prompts
                             (requires --disk)
  -h, --help                 Show this help message
```

Example:

```bash
./base-install.sh --disk /dev/nvme0n1 --keymap sv-latin1 \
  --locale sv_SE.UTF-8 --timezone Europe/Stockholm --username patrik
```

- **`--disk`** defaults to the first disk reported by `lsblk`, excluding loop,
  zram, optical and RAM devices as well as removable and USB-attached disks,
  such as the installation medium. The default shown therefore depends on the
  machine. The value must name a whole disk, such as `/dev/nvme0n1` or a link
  under `/dev/disk/by-id/`, not a partition.
- **`--locale`** sets the regional formats: numbers, dates, currency,
  measurements, paper size and collation. Messages remain in English
  (`LANG=en_GB.UTF-8`), as set in [`etc/locale.conf`](./etc/locale.conf).
  Only UTF-8 locales are accepted, such as `sv_SE.UTF-8`.
- **`--yes`** requires `--disk`, as it skips the only prompt that names the disk
  to be erased. It also sets the temporary password `changeme` for both the user
  and root. An empty or mismatched password at the prompt has the same result.
  The summary at the end of the installation lists the affected accounts.

## Desktop Installation

`desktop-install.sh` turns the installed system into a complete Wayland desktop
in a single sequential run. The desktop uses the **niri** scrollable-tiling
compositor, the **Noctalia** desktop shell, the **Noctalia greeter** on
**greetd** as the login screen and a selection of **KDE** applications that run
without Plasma.

The installer validates its options, the connected displays and the repository
files before any package is installed. Configuration is written to the user's
home directory and follows the XDG base directories. System-wide changes are
limited to the login manager, the session entry, the font defaults, the login
shell and the rule that syncs the appearance to the greeter. The installer
can be run again to restore the configuration from the repository.

### Features

- niri with PipeWire audio, XDG desktop portals and Xwayland support.
- The Noctalia shell and greeter, with the desktop appearance synced to the
  login screen.
- KDE applications, web browsers, LibreOffice, GIMP, Inkscape and VSCodium.
- kitty, fish, Neovim with LazyVim and modern command-line tools.
- Matching Qt and GTK themes, icons, cursor and fonts.
- Keyboard layout and display settings for niri, given as options.
- A complete log of the installation.

### Requirements

- An Arch Linux system installed by `base-install.sh`, or one that provides:
  - A regular user account with `sudo` privileges.
  - The [paru](https://github.com/Morganamilo/paru) AUR helper.
- A network connection.
- A full checkout of the repository.

### Instructions

After the first boot of the base system, log in on the console as the regular
user and run the installer from the copy of the repository in the home
directory:

```bash
cd ~/arch-install
./desktop-install.sh
```

The installer asks for confirmation and upgrades the system before it
installs anything. `sudo` asks for the password when it is needed, and paru
shows the build files of each AUR package for review. Reboot after the
installation to start the greeter.

> [!NOTE]
> The installer must run as the regular user, not as root. It uses `sudo` for
> the few system-wide changes.

> [!WARNING]
> Files in the home directory with the same names as those in
> [`dots/`](./dots/) will be overwritten. Other files are left in place.

### Usage

```text
./desktop-install.sh --help

Usage: desktop-install.sh [options]

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
```

Example:

```bash
./desktop-install.sh --address "Stockholm, Sweden" --display DP-1:3840x2160 \
  --xkb-layout se --scale DP-1:1.5
```

- **`--display`**, **`--position`** and **`--scale`** require a connected
  monitor on the connector, and `--display` a resolution that the monitor
  reports. The refresh rate is not checked: niri chooses a mode itself when
  the rate does not match one exactly.
- **`--xkb-layout se`** also replaces the five niri key bindings that the
  Swedish layout cannot reach with the alternatives in
  [`70-binds.kdl`](./dots/.config/niri/config.d/70-binds.kdl).
- **`--address`** is not resolved by the installer. Noctalia looks it up when
  the desktop starts.
- **`--yes`** also skips paru's review of the AUR build files.

## Logging

Both installers record all terminal output in
`logs/<script-name>-<timestamp>.log` in the repository they run from.
Passwords are never recorded. A repeated run in the same checkout appends to
the existing log.

After a successful installation, `base-install.sh` copies the repository and
its log to the new user's home directory, under the name of the checkout
directory (`~/arch-install` for a default clone). `desktop-install.sh` runs
from that copy and adds its own log next to the first.

## Documentation

- [ARCHITECTURE.md](./ARCHITECTURE.md) describes both installations in depth:
  boot chain, filesystem layout, snapshots, hibernation, initramfs, Plymouth,
  system tuning and the prebuilt packages for the base system, and the
  packages, login and session, and user configuration for the desktop.
- [SECURITY.md](./SECURITY.md) describes the threat model, and why TPM2
  unlocking and UEFI Secure Boot are not used.

## References

### Base Installation

- [ArchWiki - dm-crypt / Encrypting an entire system / LUKS on a partition with TPM2 and Secure Boot](https://wiki.archlinux.org/title/Dm-crypt/Encrypting_an_entire_system#LUKS_on_a_partition_with_TPM2_and_Secure_Boot)
- [ArchWiki - Btrfs](https://wiki.archlinux.org/title/Btrfs)
- [ArchWiki - Snapper](https://wiki.archlinux.org/title/Snapper)
- [ArchWiki - Trusted Platform Module](https://wiki.archlinux.org/title/Trusted_Platform_Module)
- [ArchWiki - Secure Boot](https://wiki.archlinux.org/title/Unified_Extensible_Firmware_Interface/Secure_Boot)
- [ArchWiki - Unified kernel image](https://wiki.archlinux.org/title/Unified_kernel_image)
- [ArchWiki - Limine](https://wiki.archlinux.org/title/Limine)
- [Limine - CONFIG.md](https://github.com/limine-bootloader/limine/blob/trunk/CONFIG.md)
- [ArchWiki - systemd-cryptenroll](https://wiki.archlinux.org/title/Systemd-cryptenroll)
- [ArchWiki - mkinitcpio](https://wiki.archlinux.org/title/Mkinitcpio)
- [ArchWiki - Plymouth](https://wiki.archlinux.org/title/Plymouth)
- [ArchWiki - Power management / Suspend and hibernate](https://wiki.archlinux.org/title/Power_management/Suspend_and_hibernate)
- [ArchWiki - Zram](https://wiki.archlinux.org/title/Zram)
- [ArchWiki - dm-crypt / System configuration / Pinning a LUKS volume](https://wiki.archlinux.org/title/Dm-crypt/System_configuration#Pinning_a_LUKS_volume)
- [ArchWiki - cryptsetup actions specific for LUKS / Key management](https://wiki.archlinux.org/title/Dm-crypt/Device_encryption#Key_management)
- [ArchWiki - dm-crypt / Specialties](https://wiki.archlinux.org/title/Dm-crypt/Specialties)
- [cryptsetup - Frequently Asked Questions](https://gitlab.com/cryptsetup/cryptsetup/-/wikis/FrequentlyAskedQuestions)

### Desktop Installation

- [niri - Getting Started](https://niri-wm.github.io/niri/Getting-Started)
- [Noctalia - Documentation](https://docs.noctalia.dev/)
- [ArchWiki - niri](https://wiki.archlinux.org/title/Niri)
- [ArchWiki - greetd](https://wiki.archlinux.org/title/Greetd)
- [ArchWiki - PipeWire](https://wiki.archlinux.org/title/PipeWire)
- [ArchWiki - XDG Base Directory](https://wiki.archlinux.org/title/XDG_Base_Directory)
- [ArchWiki - XDG MIME Applications](https://wiki.archlinux.org/title/XDG_MIME_Applications)
- [ArchWiki - Font configuration](https://wiki.archlinux.org/title/Font_configuration)
- [LazyVim - Documentation](https://www.lazyvim.org/)
