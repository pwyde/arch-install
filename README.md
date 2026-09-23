# arch-install

<div align="center">
    <img src="https://archlinux.org/static/logos/archlinux-logo-light-scalable.svg" align="center" alt="Arch Linux">
</div>

## Description

`arch-install.sh` is an automated Arch Linux installation script that installs and configures an encrypted Arch Linux system using **LUKS2**, **Btrfs**, **Unified Kernel Images (UKIs)**, the **Limine** bootloader and **Snapper** snapshots with a boot entry for each snapshot.

The script is designed to automate the complete installation process in a single sequential run, while providing validation, error handling and cleanup.

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
- Builds Unified Kernel Images (UKIs) with `mkinitcpio`, carrying the kernel
  command line.
- Installs and configures `limine` as bootloader, booting the UKIs directly.
- Installs `limine-mkinitcpio-hook`, which deploys Limine and a removable-media
  fallback loader to the ESP, registers a UEFI boot entry, and redeploys both
  whenever `limine` is upgraded.
- Creates a Btrfs swapfile the size of RAM for hibernation, with resume
  parameters embedded in the UKI.
- Configures Snapper on the root subvolume and installs the Limine snapshot
  packages, prebuilt in this repository, so each snapshot gets its own boot
  entry.
- Configures a Plymouth boot splash with an Arch Linux theme, which also takes
  the LUKS passphrase at boot.
- Configures zram swap, `sudo` for the `wheel` group, NetworkManager, OpenSSH
  and weekly TRIM.
- Provides customizable installation parameters.
- Provides cleanup functionality when the installation fails.

## Instructions

Boot system from a Arch Linux installation [image](https://archlinux.org/download). Clone repository and execute script.

```
git clone --depth 1 https://github.com/pwyde/arch-install
cd arch-install
./arch-install.sh
```

`--depth 1` matters: the repository carries prebuilt packages (see
[Prebuilt packages](#prebuilt-packages)), so a full clone would also fetch every
previous version of them.

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
```

- **`--disk`** defaults to the first disk `lsblk` reports, skipping loop, zram,
  optical and RAM devices, so the default shown depends on the machine.
- **`--locale`** sets the regional formats: numbers, dates, currency,
  measurements, paper size and sort order. Messages stay in English
  (`LANG=en_GB.UTF-8`), as set in [`etc/locale.conf`](./etc/locale.conf).
- **`--yes`** sets both the user and root password to `changeme`. So does an
  empty or mismatched password at the prompt; the summary at the end lists which
  accounts got it.

## Bootloader

The script installs [Limine](https://wiki.archlinux.org/title/Limine) from the
official repositories and writes its menu, then installs `limine-mkinitcpio-hook`
and `limine-snapper-sync` (see [Prebuilt packages](#prebuilt-packages)). The
first deploys Limine to the ESP and builds the UKIs; the second gives snapshots
their boot entries.

The ESP is mounted at **`/boot`**, so the kernel, the UKIs and
the bootloader all live on the same FAT partition and there is no separate
`/efi`.

| Path | Purpose |
| --- | --- |
| `/boot/vmlinuz-linux` | Kernel, installed straight onto the ESP |
| `/boot/EFI/limine/limine_x64.efi` | The bootloader, registered as a UEFI boot entry |
| `/boot/EFI/BOOT/BOOTX64.EFI` | Removable-media fallback, used if the firmware loses its NVRAM entry |
| `/boot/EFI/Linux/arch_linux.efi` | UKI built by `mkinitcpio` |
| `/boot/EFI/Linux/arch_linux-fallback.efi` | Fallback UKI |
| `/boot/limine.conf` | Menu entries and theming, installed from [`default/limine/limine.conf`](./default/limine/limine.conf) |

Notes:

- **The ESP must be mounted before `pacstrap`**, because the kernel is installed
  onto it. The script enforces this: installing the kernel to the Btrfs root and
  then mounting the ESP over it would leave an unbootable system.
- **The ESP is mounted `fmask=0177,dmask=0077`** (files 0600, directories 0700).
  FAT carries no permission bits, so without this the kernel and the UKIs on
  `/boot` are world-readable. These values match what `mkinitcpio` would have
  applied on a normal filesystem -- it builds initramfs images and UKIs under
  `umask 077`, because an initramfs can carry secrets such as a LUKS keyfile.
- **The kernel command line lives inside the UKI.** It is assembled from every
  file in `/etc/cmdline.d/` -- [`10-root.conf`](./etc/cmdline.d/10-root.conf)
  for the root and LUKS parameters,
  the rest for hibernation and the splash -- and embedded when the UKI is built.
  Limine chainloads the UKI with `protocol: efi` and supplies no command line of
  its own.
- **The paths are the ones `limine-entry-tool` uses.** It derives
  `${ESP_PATH}/EFI/limine/limine_x64.efi`, `${ESP_PATH}/EFI/BOOT/BOOTX64.EFI`
  and `${ESP_PATH}/limine.conf`, and those are not configurable. The UKI names
  follow its `${CUSTOM_UKI_NAME}_${kernel}.efi` scheme, so
  `CUSTOM_UKI_NAME="arch"` produces `arch_linux.efi`, the file the entries in
  `limine.conf` boot.
- **Limine is redeployed on upgrade** by `80-limine-efi-deploy.hook`, which
  `limine-mkinitcpio-hook` ships. It runs `limine-install` whenever `limine` is
  installed or upgraded. The `limine` package itself only updates the copy under
  `/usr/share/limine/`; without the hook the one on the ESP would silently stay
  at the old version.
- **ESP sizing**: 2 GiB holds the kernel and both UKIs comfortably, and leaves
  room for `limine-snapper-sync`, which keeps copies of the boot files a snapshot
  needs once the kernel has moved on. Identical copies are deduplicated, and at
  most six snapshot entries are kept.

Secure Boot is **not** used, and the installer refuses to run while it is
enabled: nothing installed here is signed, so the firmware would reject the
bootloader. TPM2 unlocking is not used either. Both decisions are motivated in
[security.md](./security.md).

## Filesystem layout

Btrfs subvolumes, all mounted `compress=zstd:3,noatime,nodiscard`:

| Subvolume | Mount point |
| --- | --- |
| `@` | `/` |
| `@home` | `/home` |
| `@cache` | `/var/cache` |
| `@log` | `/var/log` |
| `@root` | `/root` |

Two more are created later: `/swap` for the hibernation swapfile (see
[Hibernation](#hibernation)) and `/.snapshots`, by Snapper.

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
  so creating one here would only have to be worked around later. The installer
  runs `create-config` itself once the base system is in place.

Note that enabling TRIM on a dm-crypt device leaks which blocks are free, which
can be enough to reveal the filesystem in use. See
[dm-crypt/Specialties](https://wiki.archlinux.org/title/Dm-crypt/Specialties#Discard/TRIM_support_for_solid_state_drives_(SSD))
for the trade-off; it is enabled here deliberately.

## Snapshots

Snapper takes a snapshot of the root subvolume around each pacman transaction,
and `limine-snapper-sync` gives every snapshot its own entry in the boot menu, so
a failed upgrade can be booted out of rather than repaired from a live ISO.

- **`snapper -c root create-config /`** runs after the base system is installed.
  It creates its own `/.snapshots` subvolume, which is why the installer creates
  no such subvolume itself.
- **The retention policy** comes from
  [`default/snapper/root`](./default/snapper/root): five snapshots, no timeline.
  Snapshots are taken by `snap-pac` around pacman transactions rather than on a
  schedule, so each entry in the menu corresponds to an upgrade.
- **`limine-mkinitcpio-hook` and `limine-snapper-sync`** are installed from
  [`packages/`](./packages/) with `pacman -U`, which resolves their runtime
  dependencies from the official repositories. Once the hook is installed it
  owns UKI generation: it overrides mkinitcpio's pacman hook and calls
  `mkinitcpio` directly, so `/etc/mkinitcpio.d/linux.preset` is no longer read
  and the installer removes it.
- **The kernel command line is mirrored to `/etc/default/limine`**, because
  `limine-entry-tool` reads one only from `/etc/kernel/cmdline` or
  `/proc/cmdline` and never from `/etc/cmdline.d/`. Inside the installer
  `/proc/cmdline` belongs to the live ISO, so the real command line has to be
  written where the tool looks. `/etc/cmdline.d/` stays the source of truth;
  after changing anything there, mirror it and run `limine-mkinitcpio`.
- **Settings for the tool** live in
  [`etc/limine-entry-tool.d/50-arch.conf`](./etc/limine-entry-tool.d/50-arch.conf).

## Prebuilt packages

`limine-mkinitcpio-hook` and `limine-snapper-sync` exist only in the AUR, and
both compile with GraalVM `native-image`: a ~250 MB toolchain download and
several GB of RAM. That does not belong in an installer, so they are built once
and committed to [`packages/`](./packages/).

They are ordinary AUR packages once installed, listed by `pacman -Qm` like any
other. An AUR helper picks them up and offers updates in the normal way, since
they carry the AUR's own package names and versions.

To rebuild them, on a machine with enough memory:

```bash
sudo pacman -S --needed devtools git
mkdir -p ~/build && cd ~/build

for pkg in limine-mkinitcpio-hook limine-snapper-sync; do
    git clone "https://aur.archlinux.org/${pkg}.git"
    (cd "$pkg" && pkgctl build)
done

cp ~/build/*/*.pkg.tar.zst /path/to/arch-install/packages/
```

`pkgctl build` builds in a clean chroot containing only `base-devel` and the
declared dependencies, so the result cannot pick up something that happens to be
installed on the build machine but is missing on a freshly installed system.

Do not edit the PKGBUILDs or bump `pkgrel`: the versions have to match the AUR's
for an AUR helper to offer later updates.

## Hibernation

Hibernation is set up as follows:

- A **`/swap` Btrfs subvolume** marked `NODATACOW` (`chattr +C`), nested under
  `@`. A Btrfs subvolume cannot be snapshotted while it holds an active
  swapfile, so the swapfile gets a subvolume of its own; being nested, it is
  also left out of snapshots of `@`.
- **`/swap/swapfile`**, created with `btrfs filesystem mkswapfile` and sized to
  total RAM.
- An fstab entry at **`pri=0`**, below the priority of 100 set in
  [`etc/systemd/zram-generator.conf.d/90-zram.conf`](./etc/systemd/zram-generator.conf.d/90-zram.conf),
  so everyday swapping stays in compressed RAM and the file is effectively
  reserved for hibernation images.
- **`resume=` and `resume_offset=`** in `/etc/cmdline.d/30-resume.conf`, embedded in
  the UKI. The offset comes from `btrfs inspect-internal map-swapfile`, since it
  must be physical and relative to the unlocked LUKS device.
- `rtc_cmos.use_acpi_alarm=1` on systems that suspend with s2idle, needed for
  suspend-then-hibernate.
- The [`keyboard-backlight`](./default/systemd/system-sleep/keyboard-backlight)
  system-sleep hook, installed to
  `/usr/lib/systemd/system-sleep/`, which turns the keyboard backlight off
  before hibernating (some ASUS controllers otherwise block the S4 power-off).
  It needs `brightnessctl`, which is not installed by default and does nothing
  without it; add it with `--packages brightnessctl` on affected hardware.

Three deliberate choices:

| Common approach | This script | Why |
| --- | --- | --- |
| `HOOKS+=(resume)` | no `resume` hook | That hook is only required by a busybox initramfs. The `systemd` hook used here ships `systemd-hibernate-resume`, which reads the same parameters. |
| `resume=` in a `limine-entry-tool` drop-in | `resume=` in `/etc/cmdline.d/` | `/etc/cmdline.d/` is the single source of the command line. The installer mirrors it into `/etc/default/limine`, so a second copy of the parameters there would drift. |
| `swapon` after creating the file | no `swapon` | In the installer it would activate swap on the live ISO's kernel and pin `/mnt`. The fstab entry activates it on first boot. |

The resume offset is fixed at install time. If the swapfile is ever recreated,
regenerate `/etc/cmdline.d/30-resume.conf` and rebuild the UKI with
`limine-mkinitcpio`.

## Initramfs

`HOOKS` comes from the drop-in
[`etc/mkinitcpio.conf.d/hooks.conf`](./etc/mkinitcpio.conf.d/hooks.conf),
installed to `/etc/mkinitcpio.conf.d/`, so `/etc/mkinitcpio.conf` stays as the
package ships it. Drop-ins are read after the main file, so this `HOOKS` wins.

```
HOOKS=(base systemd plymouth autodetect microcode modconf kms keyboard
       sd-vconsole vconsole-latin block sd-encrypt filesystems fsck
       sd-btrfs-overlayfs)
```

This is a **systemd-based initramfs**. `limine-mkinitcpio-hook` ships an
overlayfs hook for each kind -- `sd-btrfs-overlayfs` for this one and
`btrfs-overlayfs` for a busybox initramfs -- so bootable snapshots do not
constrain the choice. systemd is used because it carries three things the
busybox path would need worked around:

- **`sd-vconsole` puts `/etc/vconsole.conf` in the initramfs**, which is what
  gives Plymouth the right `XKBLAYOUT` at the passphrase prompt. A busybox
  initramfs does not include that file at all.
- **Resuming from hibernation needs no extra hook.** The `systemd` hook ships
  `systemd-hibernate-resume`, which reads the `resume=` parameters; the busybox
  path needs `HOOKS+=(resume)`.
- **LUKS2 tokens remain usable.** Only `sd-encrypt` can use a token written by
  `systemd-cryptenroll`, so adding a hardware key later would not mean rebuilding
  the initramfs and rewriting the command line.

Other notes:

- **`sd-encrypt`** unlocks the container named by `rd.luks.name=` on the kernel
  command line.
- **`plymouth`** sits after `systemd` and before `sd-encrypt`, so the splash is
  up in time to take the passphrase through `systemd-ask-password`.
- **`keyboard`** loads keyboard modules, which is not the same as `sd-vconsole`:
  one makes a USB keyboard work at all, the other applies the keymap and font.
- **`sd-btrfs-overlayfs`** only exists once `limine-mkinitcpio-hook` is
  installed, and `mkinitcpio` fails on an unknown hook. That is why the UKIs are
  built by the package's own pacman hook when it is installed, not before.

There is **no mkinitcpio preset**. `limine-mkinitcpio-hook` overrides
mkinitcpio's own pacman hook and builds the UKIs by calling `mkinitcpio`
directly with `--kernel` and `--uki`, so `/etc/mkinitcpio.d/` is never read. The
installer deletes the preset that `pacstrap` generates.

## Boot screen colors

The Limine menu and the Plymouth splash draw on the Arch Linux colors against a
black background. Arch publishes no formal color scheme; the accent is the blue
of the official logo, and the gray matches archlinux.org.

| Color | Limine ([`limine.conf`](./default/limine/limine.conf)) | Plymouth theme |
| --- | --- | --- |
| `#000000` | `term_background`, `backdrop`, palette black | window background |
| `#999999` | `term_foreground`, `term_foreground_bright` | password field, bullets, lock icon, messages |
| `#1793D1` | `interface_help_color` (help keys) | progress bar |
| `#FFFFFF` | `interface_branding_color`, palette cyan | white of the logo |
| `#1A1A1A` | `term_background_bright`, bright palette black | -- |
| `#333333` | -- | progress bar track |

The remaining palette slots (red, green, yellow, blue, magenta and white) are
left at Nord values.

The theme's images were recolored the same way a theme switcher
does it: every pixel takes the new color and keeps its transparency.
`preview-unlock.png`, which is not shown at boot, was left as it was.

`logo.png` is the official Arch Linux logo for dark backgrounds, the unaltered
`archlinux-logo-light-90dpi.png` from [archlinux.org/art](https://archlinux.org/art/)
(600×199, blue `#1793D1` and white). It is not recolored to `#999999`: the
[trademark policy](https://terms.archlinux.org/docs/trademark-policy/) asks for
the logos to be used in their standard form.

Limine draws the selected menu entry in reverse video, swapping text and
background, so the selection bar is `#999999` rather than the accent.

## Plymouth

The boot splash is made up of:

- **The `arch-linux` theme** (display name "Arch Linux"), installed to
  `/usr/share/plymouth/themes/arch-linux/`.
  The files live in this repository under
  [`default/plymouth/arch-linux/`](./default/plymouth/arch-linux/), derived from
  an MIT-licensed theme, recolored to the Arch Linux colors and carrying the
  Arch Linux logo (see below). The
  installer therefore has to run from a full checkout of this repository; it
  checks for the files before touching the disk.
- **`Theme=arch-linux`** in `/etc/plymouth/plymouthd.conf`, installed from
  [`etc/plymouth/plymouthd.conf`](./etc/plymouth/plymouthd.conf). The theme id has no
  space because `plymouth-set-default-theme` uses it unquoted in paths.
- **The `plymouth` mkinitcpio hook**, after `systemd` and before `sd-encrypt`, in
  the `HOOKS` of the drop-in
  [`etc/mkinitcpio.conf.d/hooks.conf`](./etc/mkinitcpio.conf.d/hooks.conf).
- **Quiet-boot kernel parameters**, embedded in the UKI:
  - [`etc/cmdline.d/80-initramfs-async.conf`](./etc/cmdline.d/80-initramfs-async.conf):
    `initramfs_async=0`, working around a kernel 7.1 race in which Plymouth
    exits before it can read `/proc/cmdline` and an encrypted boot falls back
    to a plain text prompt.
  - [`etc/cmdline.d/90-splash.conf`](./etc/cmdline.d/90-splash.conf):
    `quiet splash loglevel=0 systemd.show_status=false rd.udev.log_level=0 vt.global_cursor_default=0`.

How it fits the rest of this install:

- **The passphrase prompt.** Plymouth does not unlock anything; with a systemd
  initramfs the hook installs `systemd-ask-password-plymouth`, so the passphrase
  `systemd-cryptsetup` asks for is typed into the splash. The theme draws a lock
  icon and an entry field but not the prompt text.
- **Keyboard layout.** `/etc/vconsole.conf` is written by
  `systemd-firstboot --keymap`, which sets `KEYMAP` and derives the
  matching `XKBLAYOUT`, `XKBMODEL` and `XKBOPTIONS` from systemd's
  `kbd-model-map` (for example `sv-latin1` becomes `se`). The `sd-vconsole`
  hook copies the file into the initramfs, and because `XKBLAYOUT` is set,
  Plymouth reads the passphrase with that xkb layout. With
  a keymap whose layout does not type Latin letters (such as Russian or Greek),
  a Latin passphrase could not be typed at the prompt. The local mkinitcpio hook
  [`etc/initcpio/install/vconsole-latin`](./etc/initcpio/install/vconsole-latin),
  installed to `/etc/initcpio/install/` and listed after `sd-vconsole`, guards
  against that: for such layouts it replaces the initramfs copy of
  `vconsole.conf` with one that sets `XKBLAYOUT=us`. The installed system's
  `vconsole.conf` is not changed, and the check runs on every rebuild.
- **Console cursor.** `vt.global_cursor_default=0` hides the cursor on text
  consoles after boot too, not just during the splash.

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
- [Arch Linux Wiki - systemd-cryptenroll](https://wiki.archlinux.org/title/Systemd-cryptenroll)
- [Arch Linux Wiki - mkinitcpio](https://wiki.archlinux.org/title/Mkinitcpio)
- [Arch Linux Wiki - dm-crypt / System configuration / Pinning a LUKS volume](https://wiki.archlinux.org/title/Dm-crypt/System_configuration#Pinning_a_LUKS_volume)
- [Arch Linux Wiki - cryptsetup actions specific for LUKS / Key management](https://wiki.archlinux.org/title/Dm-crypt/Device_encryption#Key_management)
