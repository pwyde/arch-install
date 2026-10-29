# Architecture

This document describes how `base-install.sh` builds the installed system, how
`desktop-install.sh` adds the desktop to it and the reasoning behind the design
decisions of both. [README.md](./README.md) covers installation and usage;
[SECURITY.md](./SECURITY.md) covers the threat model.

## Contents

- [Installation Sequence](#installation-sequence)
- [Repository Layout](#repository-layout)
- Base Installation:
  - [Filesystem Layout](#filesystem-layout)
  - [Boot Chain](#boot-chain)
  - [Initramfs](#initramfs)
  - [Snapshots](#snapshots)
  - [Prebuilt Packages](#prebuilt-packages)
  - [Hibernation](#hibernation)
  - [Plymouth](#plymouth)
  - [System Tuning](#system-tuning)
  - [User Environment](#user-environment)
  - [AUR Helper](#aur-helper)
- [Desktop Installation](#desktop-installation):
  - [Desktop Installation Sequence](#desktop-installation-sequence)
  - [Packages](#packages)
  - [Login and Session](#login-and-session)
  - [System-Wide Files](#system-wide-files)
  - [User Configuration](#user-configuration)
  - [Keyboard and Displays](#keyboard-and-displays)
- [Logging](#logging)

## Installation Sequence

`base-install.sh` runs as a single sequence of functions, called in order by
`main`. The sequence of `desktop-install.sh` is described under
[Desktop Installation Sequence](#desktop-installation-sequence).

| Step | Function | Purpose |
| --- | --- | --- |
| 1 | `check_shell_nesting` | Refuses to run unless started from a top-level shell |
| 2 | `start_logging` | Re-runs the installer under `script(1)` |
| 3 | `parse_args` | Parses the command-line options |
| 4 | `validate_secure_boot` | Refuses to continue while Secure Boot is enabled |
| 5 | `validate_inputs` | Checks the disk, every option, UEFI mode, required tools and repository files |
| 6 | `setup_partitions` | Derives partition names and the microcode package |
| 7 | `confirm_operation` | Asks for confirmation before the disk is erased |
| 8 | `create_partitions` | Writes a new GPT with an ESP and a root partition |
| 9 | `format_partitions` | Formats the ESP and creates the LUKS2 container |
| 10 | `setup_btrfs` | Creates the Btrfs filesystem and its subvolumes |
| 11 | `mount_filesystems` | Mounts the subvolumes and the ESP under `/mnt` |
| 12 | `install_base_system` | Installs the base system with `pacstrap` |
| 13 | `configure_system` | Configures the installed system inside a chroot |
| 14 | `verify_installation` | Checks the boot files, configuration and user setup |
| 15 | `print_summary` | Prints the installation summary |
| 16 | `copy_installer_to_home` | Copies the repository and its log to the new user's home |

Steps 1 and 2 run only on the first invocation, not in the re-run under
`script(1)`, and neither runs for `--help`, which works from any shell. Every
check that can fail without consequence runs before step 8.

Step 5 checks each option against a strict pattern, which makes escaping
unnecessary where the values are substituted, and against the data of the live
system: the time zone, the UTF-8 locale and the absence of a system account with
the given username. The disk must be a whole disk that is not in use: nothing on
it may be mounted, used as swap or held by a LUKS container, LVM or RAID, and
`/mnt` and `/dev/mapper/cryptroot` must be free. Packages given with
`--packages` are resolved against a temporary copy of the sync databases, so the
network connection is already required at this step.

Until the first write to the disk, a failure exits quietly; the `EXIT` trap only
removes the temporary sync databases. After it, the trap also unmounts the
target filesystems, stops the `gpg-agent` left running on the target keyring and
closes the LUKS container if the installer opened it.

`configure_system` runs its steps in a fixed order. Hibernation and Plymouth
are configured before the boot setup, since both contribute kernel parameters
and initramfs content. `limine-mkinitcpio-hook` is installed last, as its
pacman hook builds the UKIs immediately from the configuration already in
place. The AUR helper follows, and its failure does not fail the installation.

## Repository Layout

| Path | Contents |
| --- | --- |
| [`base-install.sh`](./base-install.sh) | The base installer, described in this document |
| [`desktop-install.sh`](./desktop-install.sh) | The desktop installer, run on the installed system |
| [`etc/`](./etc/) | Configuration files, installed to the same path under `/etc`. `vim/xdg.vim` is appended to `/etc/vimrc`. The `greetd`, `pam.d/greetd` and `fonts/` files are installed by `desktop-install.sh` |
| [`defaults/`](./defaults/) | Files installed elsewhere: the Limine configuration, the Plymouth theme, the Snapper configuration, the system-sleep hook and the user's bashrc. The greeter configuration and the niri session entry are installed by `desktop-install.sh` |
| [`packages/`](./packages/) | Prebuilt AUR packages; see [Prebuilt Packages](#prebuilt-packages) |
| [`dots/`](./dots/) | Desktop configuration under `.config/` and `.local/`, copied to the user's home directory by `desktop-install.sh` |
| [`assets/wallpapers/`](./assets/wallpapers/) | Wallpapers, copied to `~/Pictures/Wallpapers` by `desktop-install.sh` |
| `logs/` | Installation logs, created at run time and excluded from version control |

Files containing `@HOSTNAME@`, `@USERNAME@`, `@LOCALE@` or `@ROOT_UUID@` are
templates; the installer substitutes the values when it installs them.
`desktop-install.sh` fills in the placeholders in the greeter and Noctalia
configuration in the same way.

## Filesystem Layout

The disk receives a new GPT partition table with two partitions:

| Partition | Size | Content |
| --- | --- | --- |
| EFI System Partition | 2 GiB | FAT32, mounted at `/boot` |
| Root | Remaining space | LUKS2 container holding a Btrfs filesystem |

Btrfs subvolumes, all mounted with `compress=zstd:3,noatime,nodiscard`:

| Subvolume | Mount point |
| --- | --- |
| `@` | `/` |
| `@home` | `/home` |
| `@cache` | `/var/cache` |
| `@log` | `/var/log` |
| `@root` | `/root` |

Two further subvolumes are created later: `/swap` for the hibernation
swapfile (see [Hibernation](#hibernation)), and `/.snapshots`, created by
Snapper.

- **`compress=zstd:3`** is the Btrfs default level. Compression applies only
  to newly written data, which makes install time the correct moment to set
  it.
- **`noatime`** avoids a metadata write on every file access. On a
  copy-on-write filesystem, each atime update also makes snapshots diverge
  from their parent without any change in content.
- **`nodiscard` with `fstrim.timer`**: the LUKS container is opened with
  `--allow-discards`, which makes the device support TRIM, and Btrfs would
  otherwise enable continuous `discard=async` by default (kernel 6.2 and
  later). Arch, Debian and Red Hat all recommend periodic TRIM instead; freed
  blocks are discarded once a week in a single batch.
- **No snapshots subvolume is created by the installer.** `snapper
  create-config` creates its own `/.snapshots` and refuses to run when the
  path already exists.

Enabling TRIM on a dm-crypt device reveals which blocks are free, which can be
enough to identify the filesystem in use. The trade-off is described in
[dm-crypt/Specialties](https://wiki.archlinux.org/title/Dm-crypt/Specialties#Discard/TRIM_support_for_solid_state_drives_(SSD));
TRIM is enabled here deliberately.

## Boot Chain

[Limine](https://wiki.archlinux.org/title/Limine) is installed from the
official repositories, with its global settings from
[`defaults/limine/limine.conf`](./defaults/limine/limine.conf).
`limine-mkinitcpio-hook` and `limine-snapper-sync` follow (see
[Prebuilt Packages](#prebuilt-packages)). The first deploys Limine to the ESP,
builds the UKIs and writes their boot entries; the second adds an entry for
each snapshot.

The ESP is mounted at `/boot`. The kernel, the UKIs and the bootloader share
the same FAT partition, and there is no separate `/efi`.

| Path | Purpose |
| --- | --- |
| `/boot/vmlinuz-linux` | Kernel, installed directly onto the ESP |
| `/boot/EFI/limine/limine_x64.efi` | Bootloader, registered as a UEFI boot entry |
| `/boot/EFI/BOOT/BOOTX64.EFI` | Removable-media fallback, used when the firmware loses its NVRAM entry |
| `/boot/EFI/Linux/arch_linux.efi` | UKI built by `mkinitcpio` |
| `/boot/EFI/Linux/arch_linux-fallback.efi` | Fallback UKI, built without `autodetect` |
| `/boot/limine.conf` | Global options and default entry; boot entries written by `limine-entry-tool` |

- **The ESP is mounted before `pacstrap`**, which installs the kernel onto it.
  A kernel installed to the Btrfs root would be hidden once the ESP is mounted
  over it, leaving an unbootable system.
- **The ESP is mounted with `fmask=0177,dmask=0077`** (files 0600, directories
  0700). FAT carries no permission bits; without these options, the kernel and
  the UKIs on `/boot` are world-readable. The values match what `mkinitcpio`
  applies on a normal filesystem, where it builds images under `umask 077`
  because an initramfs can carry secrets such as a LUKS keyfile.
- **The kernel command line is embedded in the UKI.** It is assembled from
  every file in [`etc/cmdline.d/`](./etc/cmdline.d/):
  [`10-root.conf`](./etc/cmdline.d/10-root.conf) for the root and LUKS
  parameters, and the remaining files for hibernation, the console and the
  splash. Limine chainloads the UKI with `protocol: efi` and supplies no
  command line of its own to the default entries. Without Secure Boot, the UKI
  would accept one; see [SECURITY.md](./SECURITY.md#limitations).
- **The paths are those `limine-entry-tool` uses.** It derives
  `${ESP_PATH}/EFI/limine/limine_x64.efi`, `${ESP_PATH}/EFI/BOOT/BOOTX64.EFI`
  and `${ESP_PATH}/limine.conf`, none of which is configurable. UKI names
  follow its `${CUSTOM_UKI_NAME}_${kernel}.efi` scheme: `CUSTOM_UKI_NAME="arch"`
  produces `arch_linux.efi`.
- **Limine is redeployed on upgrade** by `80-limine-efi-deploy.hook`, shipped
  by `limine-mkinitcpio-hook`, which runs `limine-install` whenever `limine`
  is installed or upgraded. The `limine` package only updates the copy under
  `/usr/share/limine/`; without the hook, the copy on the ESP would remain at
  the old version.
- **The default entry is set by path**, `Arch Linux/linux`. "Arch Linux" is a
  directory holding the kernel, fallback and snapshot entries; an index would
  name the directory, and Limine disables autoboot when the default entry is
  not bootable.
- **The ESP is sized at 2 GiB.** This holds the kernel and both UKIs, with
  room for `limine-snapper-sync`, which keeps copies of the boot files a
  snapshot needs once the kernel has been upgraded. Identical copies are
  deduplicated, and at most six snapshot entries are kept.

Secure Boot is **not** used, and the installer refuses to run while it is
enabled: nothing installed is signed, and the firmware would reject the
bootloader. TPM2 unlocking is not used either. Both decisions are explained in
[SECURITY.md](./SECURITY.md).

### Boot Screen Colors

The Limine menu and the Plymouth splash use the Arch Linux colors on a black
background. Arch publishes no formal color scheme; the accent is the blue of
the official logo, and the gray matches archlinux.org.

| Color | Limine ([`limine.conf`](./defaults/limine/limine.conf)) | Plymouth theme |
| --- | --- | --- |
| `#000000` | `term_background`, `backdrop`, palette black | Window background |
| `#999999` | `term_foreground`, `term_foreground_bright` | Password field, bullets, lock icon, messages |
| `#1793D1` | `interface_help_color` (help keys) | Progress bar |
| `#FFFFFF` | `interface_branding_color`, palette cyan | White of the logo |
| `#1A1A1A` | `term_background_bright`, bright palette black | -- |
| `#333333` | -- | Progress bar track |

The remaining palette slots (red, green, yellow, blue, magenta and white)
keep Nord values. Limine draws the selected menu entry in reverse video, which
makes the selection bar `#999999` rather than the accent color.

## Initramfs

`HOOKS` is set by the drop-in
[`etc/mkinitcpio.conf.d/hooks.conf`](./etc/mkinitcpio.conf.d/hooks.conf),
leaving `/etc/mkinitcpio.conf` as the package ships it. Drop-ins are read
after the main file, and this `HOOKS` takes precedence.

```bash
HOOKS=(base systemd plymouth autodetect microcode modconf kms keyboard
       sd-vconsole vconsole-latin block sd-encrypt filesystems fsck
       sd-btrfs-overlayfs)
```

The initramfs is **systemd-based**. `limine-mkinitcpio-hook` ships an overlayfs
hook for both kinds (`sd-btrfs-overlayfs` for systemd, `btrfs-overlayfs` for
busybox), and bootable snapshots do not constrain the choice. systemd is used
for three reasons:

- **`sd-vconsole` includes `/etc/vconsole.conf` in the initramfs**, which
  gives Plymouth the correct `XKBLAYOUT` at the passphrase prompt. A busybox
  initramfs does not include that file.
- **Resuming from hibernation needs no extra hook.** The `systemd` hook ships
  `systemd-hibernate-resume`, which reads the `resume=` parameters; a busybox
  initramfs needs `HOOKS+=(resume)`.
- **LUKS2 tokens remain usable.** Only `sd-encrypt` can use a token enrolled
  with `systemd-cryptenroll`. Adding a hardware key later requires no change
  to the initramfs or the command line.

Hook order:

| Hook | Notes |
| --- | --- |
| `plymouth` | After `systemd` and before `sd-encrypt`: the splash must be running to take the passphrase through `systemd-ask-password` |
| `keyboard` | Loads the modules a USB keyboard needs at the passphrase prompt; `sd-vconsole` only applies the keymap and font |
| `vconsole-latin` | Local hook after `sd-vconsole`; see [Plymouth](#plymouth) |
| `block` | Before `sd-encrypt`: the block device modules must be present when the container is unlocked |
| `sd-encrypt` | Unlocks the container named by `rd.luks.name=` |
| `sd-btrfs-overlayfs` | Boots a read-only snapshot under a writable overlay |

`sd-btrfs-overlayfs` exists only once `limine-mkinitcpio-hook` is installed,
and `mkinitcpio` fails on an unknown hook. The UKIs are therefore built by the
package's own pacman hook when it is installed, not earlier.

There is **no mkinitcpio preset**. `limine-mkinitcpio-hook` overrides the
pacman hook of `mkinitcpio` and builds the UKIs by calling `mkinitcpio`
directly with `--kernel` and `--uki`; `/etc/mkinitcpio.d/` is never read. The
installer removes the preset generated by `pacstrap`, together with the plain
initramfs images it produced.

## Snapshots

Snapper takes a snapshot of the root subvolume around each pacman
transaction, and `limine-snapper-sync` gives every snapshot its own entry in
the boot menu. A failed upgrade can be booted out of, rather than repaired
from a live image.

- **`snapper -c root create-config /`** runs after the base system is
  installed and creates the `/.snapshots` subvolume.
- **The retention policy** comes from
  [`defaults/snapper/root`](./defaults/snapper/root): five snapshots and no
  timeline. Snapshots are taken by `snap-pac` around pacman transactions
  rather than on a schedule; each menu entry corresponds to an upgrade.
- **The kernel command line is mirrored to `/etc/default/limine`.**
  `limine-entry-tool` reads a command line only from `/etc/kernel/cmdline` or
  `/proc/cmdline`, never from `/etc/cmdline.d/`. Inside the installer,
  `/proc/cmdline` belongs to the live image, which is why the installer writes
  the real command line where the tool reads it. `/etc/cmdline.d/` remains the
  source of truth; after a change there, the mirror must be updated and
  `limine-mkinitcpio` run.
- **Settings for `limine-entry-tool`** are in
  [`etc/limine-entry-tool.d/50-arch.conf`](./etc/limine-entry-tool.d/50-arch.conf).
  `MAX_SNAPSHOT_ENTRIES=6` allows for the sixth snapshot that exists briefly
  before Snapper's cleanup removes the oldest.

## Prebuilt Packages

`limine-mkinitcpio-hook` and `limine-snapper-sync` are available only in the
AUR, and both compile with GraalVM `native-image`, which requires a toolchain
download of about 250 MB and several GB of RAM. They are therefore built once
and committed to [`packages/`](./packages/), then installed with `pacman -U`,
which resolves their runtime dependencies from the official repositories.

Once installed, they are ordinary AUR packages, listed by `pacman -Qm`. They
carry the AUR package names and versions, and an AUR helper offers updates for
them in the usual way.

To rebuild them on a machine with sufficient memory:

```bash
sudo pacman -S --needed devtools git
mkdir -p ~/build && cd ~/build

for pkg in limine-mkinitcpio-hook limine-snapper-sync; do
  git clone "https://aur.archlinux.org/${pkg}.git"
  (cd "${pkg}" && pkgctl build)
done

rm /path/to/arch-install/packages/*.pkg.tar.zst
cp ~/build/*/*.pkg.tar.zst /path/to/arch-install/packages/
```

The previous versions are removed first: `base-install.sh` refuses to run
while `packages/` holds more than one file for either package.

`pkgctl build` builds in a clean chroot containing only `base-devel` and the
declared dependencies. The result cannot depend on software that happens to
be installed on the build machine but is missing on a new installation.

The PKGBUILDs must not be edited and `pkgrel` must not be changed: the
versions have to match the AUR for an AUR helper to offer later updates.

## Hibernation

- **A `/swap` Btrfs subvolume**, nested under `@` and marked `NODATACOW`
  (`chattr +C`). A Btrfs subvolume cannot be snapshotted while it holds an
  active swapfile, which is why the swapfile has a subvolume of its own. As a
  nested subvolume, it is also excluded from snapshots of `@`.
- **`/swap/swapfile`**, created with `btrfs filesystem mkswapfile` and sized
  to total RAM.
- **An fstab entry at `pri=0`**, below the priority of 100 set in
  [`etc/systemd/zram-generator.conf.d/90-zram.conf`](./etc/systemd/zram-generator.conf.d/90-zram.conf).
  Everyday swapping stays in compressed RAM, and the swapfile is effectively
  reserved for hibernation images.
- **`resume=` and `resume_offset=`** in `/etc/cmdline.d/30-resume.conf`,
  embedded in the UKI. The offset comes from `btrfs inspect-internal
  map-swapfile`, as it must be physical and relative to the unlocked LUKS
  device.
- **`rtc_cmos.use_acpi_alarm=1`** from
  [`etc/cmdline.d/20-rtc-alarm.conf`](./etc/cmdline.d/20-rtc-alarm.conf), on
  systems that suspend with s2idle. It is required for suspend-then-hibernate.
- **The
  [`keyboard-backlight`](./defaults/systemd/system-sleep/keyboard-backlight)
  system-sleep hook**, installed to `/usr/lib/systemd/system-sleep/`. It turns
  the keyboard backlight off before hibernation, as the keyboard controller on
  some ASUS laptops otherwise blocks the S4 power-off. The hook requires
  `brightnessctl`, which `desktop-install.sh` installs. On a base system
  without the desktop, it can be added with `--packages brightnessctl`.

Three deliberate departures from common practice:

| Common approach | This installer | Reason |
| --- | --- | --- |
| `HOOKS+=(resume)` | No `resume` hook | Only a busybox initramfs requires it. The `systemd` hook ships `systemd-hibernate-resume`, which reads the same parameters. |
| `resume=` in a `limine-entry-tool` drop-in | `resume=` in `/etc/cmdline.d/` | `/etc/cmdline.d/` is the single source of the command line. The installer mirrors it into `/etc/default/limine`, and a second copy of the parameters would drift. |
| `swapon` after creating the file | No `swapon` | In the installer, it would activate swap on the live image's kernel and keep `/mnt` busy. The fstab entry activates the swapfile on first boot. |

The resume offset is fixed at install time. If the swapfile is recreated,
`/etc/cmdline.d/30-resume.conf` must be regenerated and the UKI rebuilt with
`limine-mkinitcpio`.

## Plymouth

The boot splash consists of:

- **The `arch-linux` theme** (display name "Arch Linux"), installed to
  `/usr/share/plymouth/themes/arch-linux/` from
  [`defaults/plymouth/arch-linux/`](./defaults/plymouth/arch-linux/). It is
  derived from an MIT-licensed theme and recolored to the Arch Linux colors.
  The installer checks that the theme files are present before any change to
  the disk.
- **`Theme=arch-linux`** in `/etc/plymouth/plymouthd.conf`, installed from
  [`etc/plymouth/plymouthd.conf`](./etc/plymouth/plymouthd.conf). The theme
  name contains no space, as `plymouth-set-default-theme` uses it unquoted in
  paths.
- **The `plymouth` mkinitcpio hook**; see [Initramfs](#initramfs).
- **Quiet-boot kernel parameters**, embedded in the UKI:

  | File | Parameters | Purpose |
  | --- | --- | --- |
  | [`80-initramfs-async.conf`](./etc/cmdline.d/80-initramfs-async.conf) | `initramfs_async=0` | Avoids a kernel 7.1 race in which Plymouth exits before it can read `/proc/cmdline`, and an encrypted boot falls back to a text prompt |
  | [`85-console.conf`](./etc/cmdline.d/85-console.conf) | `console=tty0` | Without any `console=`, systemd-stub appends a serial console whenever the firmware's `ConOut` includes a serial port, as it always does under QEMU with OVMF. Plymouth then forces details mode, and the LUKS prompt falls back to plain text |
  | [`90-splash.conf`](./etc/cmdline.d/90-splash.conf) | `quiet splash loglevel=0 systemd.show_status=false rd.udev.log_level=0 vt.global_cursor_default=0` | Starts Plymouth and keeps kernel, systemd and udev output off the screen |

Integration with the rest of the system:

- **Passphrase prompt.** Plymouth does not unlock anything itself. With a
  systemd initramfs, the hook installs `systemd-ask-password-plymouth`, and
  the passphrase requested by `systemd-cryptsetup` is typed into the splash.
  The theme draws a lock icon and an entry field, without prompt text.
- **Keyboard layout.** `systemd-firstboot --keymap` writes
  `/etc/vconsole.conf`, setting `KEYMAP` and the matching `XKBLAYOUT`,
  `XKBMODEL` and `XKBOPTIONS` from systemd's `kbd-model-map` (for example,
  `uk` becomes `gb`). The `sd-vconsole` hook copies the file into the
  initramfs, and Plymouth reads the passphrase with that layout. A layout
  without Latin letters, such as Russian or Greek, would make a Latin
  passphrase impossible to type. The local hook
  [`etc/initcpio/install/vconsole-latin`](./etc/initcpio/install/vconsole-latin)
  replaces the initramfs copy of `vconsole.conf` with one that sets
  `XKBLAYOUT=us` for such layouts. The installed system's `vconsole.conf` is
  not modified, and the check runs on every rebuild.
- **Console cursor.** `vt.global_cursor_default=0` also hides the cursor on
  text consoles after boot, not only during the splash.

The theme's images were recolored by giving every pixel the new color while
keeping its transparency. `preview-unlock.png`, which is not shown at boot,
is a 1920×1080 screenshot of the passphrase prompt. `logo.png` is the official
Arch Linux logo for dark backgrounds, `archlinux-logo-light-90dpi.png` from
[archlinux.org/art](https://archlinux.org/art/) (600×199, blue `#1793D1` and
white), with the trademark symbol removed. It is not recolored to `#999999`:
the [trademark policy](https://terms.archlinux.org/docs/trademark-policy/)
asks for the logos to be used in their standard form.

## System Tuning

Kernel parameters are set by drop-ins in [`etc/sysctl.d/`](./etc/sysctl.d/).
Arch's `/usr/lib/sysctl.d/10-arch.conf` already raises the inotify limits and
`vm.max_map_count`, and systemd's `50-default.conf` covers several hardening
defaults; only settings those files omit are included.

| File | Purpose |
| --- | --- |
| `40-net.conf` | Core socket buffer maxima and queue lengths |
| `41-ipv4.conf` | TCP autotuning bounds, Fast Open, MTU probing |
| `45-bbr.conf` | BBR congestion control, paced through `fq` |
| `50-vm.conf` | Reclaim tuned for swap on zram, bounded writeback |
| `60-net-hardening.conf` | SYN cookies, strict reverse path filtering, no ICMP redirects |
| `61-kernel-hardening.conf` | Restricted dmesg, kernel pointers and ptrace; no set-user-ID dumps |

- **BBR requires its module first.** sysctl cannot select a congestion
  control algorithm the kernel has not registered;
  [`etc/modules-load.d/bbr.conf`](./etc/modules-load.d/bbr.conf) loads
  `tcp_bbr`.
- **Reverse path filtering uses the glob form** `net.ipv4.conf.*.rp_filter`
  rather than `conf.all`. The kernel applies the maximum of `conf.all` and the
  per-interface value; setting `conf.all` would force strict mode on every
  interface, with no way to relax it for a VPN, a bridge or an asymmetric
  route.
- **TCP timestamps remain enabled.** Disabling them loses PAWS protection and
  the round-trip time calculation, and no longer hides the uptime, as Linux
  randomizes the offset per connection.
- **The reclaim values assume zram.** `vm.page-cluster=0` and
  `vm.swappiness=150` suit a compressed RAM device and not a disk.

Further systemd and service configuration:

| Area | Configuration |
| --- | --- |
| Index rebuilds | Drop-ins in [`man-db.timer.d/`](./etc/systemd/system/man-db.timer.d/) and [`plocate-updatedb.timer.d/`](./etc/systemd/system/plocate-updatedb.timer.d/) move both timers from midnight to late morning, without the catch-up run after a missed slot. The packages enable the timers themselves. |
| Locate index | A drop-in in [`plocate-updatedb.service.d/`](./etc/systemd/system/plocate-updatedb.service.d/) indexes the Btrfs subvolumes, which `updatedb` skips as bind mounts by default, and excludes `/.snapshots`. The run is skipped on battery. `/etc/updatedb.conf` is left untouched, as pacman tracks it as a backup file. |
| Shutdown | Three drop-ins under [`etc/systemd/`](./etc/systemd/) lower `DefaultTimeoutStopSec` to 5 s for system and user services, and `TimeoutStopSec` of `user@.service` from 120 s to 10 s. Units that declare their own timeout keep it. |
| sshd | A drop-in in [`etc/ssh/sshd_config.d/`](./etc/ssh/sshd_config.d/) allows key authentication only, refuses root and limits `AllowUsers` to the account the installer creates. Remote login requires a public key installed from the console first. `Ciphers`, `KexAlgorithms` and `MACs` are not set, leaving OpenSSH's defaults, which lead with hybrid post-quantum key exchange. |
| Journal | [`etc/systemd/journald.conf.d/`](./etc/systemd/journald.conf.d/) caps the journal at 500M instead of 10% of the filesystem, which holds about a month of logs. |
| Core dumps | [`etc/systemd/coredump.conf.d/`](./etc/systemd/coredump.conf.d/) disables them with `Storage=none` and `ProcessSizeMax=0`, as a dump holds the memory of the crashed process, including keys and passphrases. |
| IPv6 | Enabled, with rotating privacy addresses from [`10-ipv6-privacy.conf`](./etc/NetworkManager/conf.d/10-ipv6-privacy.conf). |
| Wi-Fi | Power save is disabled by [`20-wifi-powersave.conf`](./etc/NetworkManager/conf.d/20-wifi-powersave.conf); it adds latency on an idle link, and some Intel firmware drops the connection while the radio sleeps. |

Enabled services: `systemd-resolved`, `systemd-timesyncd`, zram swap, `sshd`,
`NetworkManager`, `fstrim.timer`, `snapper-cleanup.timer` and
`limine-snapper-sync.service`.

## User Environment

The user is created in the `wheel` group, with bash as the login shell. Shell
and editor configuration follows the
[XDG Base Directory](https://wiki.archlinux.org/title/XDG_Base_Directory)
specification, which keeps the home directory free of dotfiles.

| File | Purpose |
| --- | --- |
| [`00-xdg.sh`](./etc/profile.d/00-xdg.sh) | Sets `XDG_CONFIG_HOME`, `XDG_DATA_HOME`, `XDG_STATE_HOME` and `XDG_CACHE_HOME` to the specification's defaults for every login shell, and moves the Python history, Cargo, rustup and the readline configuration into them |
| [`10-defaults.sh`](./etc/profile.d/10-defaults.sh) | Sets `EDITOR`, `VISUAL`, `PAGER`, `LESS` and colored man pages; a value already set is kept |
| [`zz-xdg-bash.sh`](./etc/profile.d/zz-xdg-bash.sh) | Loads `~/.config/bash/bashrc` in bash login shells, and keeps the history in `~/.local/state/bash/` |
| [`xdg.vim`](./etc/vim/xdg.vim) | Appended to `/etc/vimrc`; moves Vim's `viminfo` to the state directory and netrw's files to the data directory |
| [`bashrc`](./defaults/bash/bashrc) | The user's bashrc, installed to `~/.config/bash/bashrc` |

- **The profile scripts run in name order.** `00-xdg.sh` runs first, so the
  other `profile.d` files can rely on its variables, and `zz-xdg-bash.sh` runs
  last. The niri session inherits the same environment, as `niri-session`
  starts in a login shell.
- **The skeleton files are removed while unchanged.** `useradd` copies
  `.bashrc`, `.bash_profile` and `.bash_logout` from `/etc/skel`; each is
  deleted if it is identical to the skeleton copy, as bash reads its
  configuration from the XDG location instead.
- **`~/.local/state` is created by the installer**, as the user and with mode
  0700. less and Python write their history there, and neither creates the
  directory.

sudo is configured by drop-ins in [`etc/sudoers.d/`](./etc/sudoers.d/),
installed with mode 0440:

| File | Setting |
| --- | --- |
| `00-wheel` | Members of `wheel` may run any command |
| `01-timeout` | No timeout on the password prompt; cached credentials stay valid for 60 minutes |
| `02-passwd-tries` | Ten password attempts before sudo gives up |

[`etc/hosts`](./etc/hosts) maps the hostname to `127.0.1.1`, as
Debian-derived systems do, for software that resolves its own name on a
machine without a permanent IP address.

## AUR Helper

[paru](https://github.com/Morganamilo/paru) is built from the AUR at the end
of the installation, once the system is otherwise complete.

- **It is built from source rather than installed as `paru-bin`.** paru links
  against `libalpm`, and a prebuilt binary stops working whenever pacman
  changes that library's soname.
- **Only the build runs as the user.** `makepkg` refuses to run as root, and the
  user has no password-free sudo. The steps that require root (installing
  `rust`, installing the package and removing `rust` again) run as root around
  the build. No temporary `NOPASSWD` rule is created, which a failed build could
  otherwise leave behind.
- **`rust` is removed afterwards**, unless it was requested with
  `--packages`. It is only a build dependency.
- **A failure is not fatal.** If the AUR or crates.io cannot be reached, the
  installer issues a warning and continues; paru can be built manually after
  the first boot.

## Desktop Installation

`desktop-install.sh` runs as the regular user on an installed Arch Linux system
and installs a Wayland desktop: the niri compositor, the Noctalia shell, the
Noctalia greeter on greetd and a selection of KDE applications that run without
Plasma. It does not depend on `base-install.sh`; it requires only a user with
sudo privileges, paru and a full checkout of the repository.

The installer writes the user's configuration to the home directory,
following the XDG Base Directory specification wherever a program supports
it. Files outside the home directory are installed only for components that
have no per-user configuration; see [System-Wide Files](#system-wide-files).

### Desktop Installation Sequence

| Phase | Functions | Purpose |
| --- | --- | --- |
| Logging | `start_logging` | Re-runs the installer under `script(1)` |
| Input | `parse_args` | Parses the command-line options |
| Validation | `validate_inputs`, `validate_xkb_layout`, `validate_displays`, `validate_address`, `validate_packages` | Checks the account, the required commands, the repository files and every option |
| Confirmation | `confirm_operation` | Lists what will be installed and asks for confirmation |
| Packages | `update_system`, `install_compositor`, `install_desktop_shell`, `install_cli_tools`, `install_neovim`, `install_extra_packages` | Upgrades the system and installs the packages |
| System | `install_greeter_config`, `configure_greetd`, `configure_fonts`, `enable_passwordless_sync`, `set_login_shell` | Configures the login screen, the session, the fonts and the login shell |
| User | `create_user_dirs`, `copy_wallpapers`, `copy_dotfiles`, `configure_gtk_settings`, `install_neovim_plugins`, `configure_vscodium` | Deploys the configuration to the home directory and applies it |
| Options | `configure_keyboard_layout`, `configure_swedish_binds`, `configure_displays`, `configure_location`, `configure_lockscreen` | Applies the keyboard, display and location options |
| Summary | `print_summary` | Prints the installation summary |

- **Nothing changes before the confirmation.** Every option is validated
  first, and the confirmation lists the packages, the system-wide changes and
  the values given. Additional packages are looked up with `paru -Si`, or as
  a group with `pacman -Sg`, in the package databases as they stand before
  the upgrade.
- **A failure needs no undoing.** Each package installation is a single
  pacman transaction, and every later step can be repeated. The `EXIT` trap
  removes a temporary file left by the failed step and reports a failure once
  the first change has been made, and the installer can be run again after the
  cause is resolved.
- **Reruns restore the configuration.** Packages are installed with
  `--needed`, the copy of `dots/` replaces files of the same name, and the
  blocks generated from the options are written to a file that the copy
  restores first.
- **Optional steps are not fatal.** The Polkit rule, the GTK settings, the
  Neovim plugins and the VSCodium extensions print a warning on failure, and
  the installation continues.

### Packages

The system is upgraded with `paru -Syu` before anything is installed.
Installing from a stale package database risks a partial upgrade, which Arch
does not support.

| Array | Contents |
| --- | --- |
| `DEFAULT_COMPOSITOR_PACKAGES` | niri, nirimod, PipeWire, WirePlumber, the XDG desktop portals, `xwayland-satellite`, and tools for brightness, media keys and the clipboard |
| `DEFAULT_NOCTALIA_PACKAGES` | The Noctalia shell and greeter |
| `DEFAULT_TERMINAL_PACKAGES` | kitty, fish, Starship, fastfetch, btop and superfile |
| `DEFAULT_KDE_PACKAGES` | Dolphin, Kate, Konsole, Ark, Gwenview, Okular and Haruna, and the KDE services and integration they require outside Plasma |
| `DEFAULT_BROWSER_PACKAGES` | Firefox, Chromium, Zen Browser and Pywalfox |
| `DEFAULT_OFFICE_PACKAGES` | LibreOffice with English spelling dictionaries, GIMP and Inkscape |
| `DEFAULT_DEVELOPMENT_PACKAGES` | VSCodium with the Visual Studio Marketplace |
| `DEFAULT_THEME_PACKAGES` | Qt and GTK themes, Papirus icons, `nwg-look` and the cursor theme |
| `DEFAULT_FONT_PACKAGES` | JetBrains Mono Nerd Font, Inter, Noto and Liberation |
| `DEFAULT_CLI_PACKAGES` | bat, duf, dust, eza, fd, fzf, glow, procs, ripgrep and zoxide |
| `DEFAULT_NEOVIM_PACKAGES` | Neovim and the tools LazyVim's plugins require |

- **One transaction for the desktop.** The Noctalia, terminal, KDE, browser,
  office, development, theme and font packages are installed by a single paru
  run: one confirmation, one review of the AUR build files and one transaction
  that resolves their dependencies together.
- **AUR packages are reviewed.** paru shows the build files of each AUR
  package before it builds. `--yes` adds `--noconfirm` and `--skipreview`.
- **Additional packages** from `--packages` are installed last, after the
  defaults.

### Login and Session

- **greetd starts the Noctalia greeter** on the first virtual terminal. The
  service is enabled, not started: starting it during the installation would
  stop `getty@tty1`, and with it a login session on that terminal.
- **The greeter configuration is rendered** from
  [`defaults/noctalia-greeter/greeter.toml`](./defaults/noctalia-greeter/greeter.toml).
  The keyboard layout and the first display given with `--display`,
  `--scale` or `--position` replace its placeholders; a setting not given
  loses its line, and without any display option the `[output]` section is
  removed and the greeter appears on every monitor. The file is installed to
  `/var/lib/noctalia-greeter/` with the owner and group of that directory,
  which the package's install hook creates for the greetd user.
- **In a virtual machine, hardware cursors are disabled** for the greeter
  with `WLR_NO_HARDWARE_CURSORS=1`. wlroots otherwise draws the cursor upside
  down on the virtio-gpu cursor plane.
- **KWallet is unlocked at login.** The repository's
  [`etc/pam.d/greetd`](./etc/pam.d/greetd) adds `pam_kwallet5`, which opens
  the wallet with the login password. The Secret Service, and with it
  Noctalia's encrypted storage, then finds an unlocked collection. Both lines
  are optional, which keeps login working if the module fails.
- **The niri session logs to the journal.** The session entry in
  [`defaults/wayland-sessions/niri.desktop`](./defaults/wayland-sessions/niri.desktop)
  runs `niri-session` through `systemd-cat`. Installed to
  `/usr/local/share/wayland-sessions/`, it takes precedence over the
  package's entry of the same name.
- **fish is the login shell.** fish does not read `/etc/profile`, which sets
  the environment of login shells through `/etc/profile.d/`.
  [`00-profile.fish`](./dots/.config/fish/conf.d/00-profile.fish) runs it in
  bash and imports the result, which also gives the niri session the XDG
  variables and the default programs.
- **The systemd user manager receives its own environment** from
  [`dots/.config/environment.d/`](./dots/.config/environment.d/). Programs
  started through D-Bus, such as the KDE Wallet dialogs and the KDE portal's
  file dialogs, do not inherit niri's environment and take the Qt theme and
  the VSCodium data location from there.
- **Appearance sync needs no password.** `noctalia-greeter passwordless-sync`
  adds a Polkit rule that lets the user copy the desktop appearance to the
  greeter. The rule covers only that action.

### System-Wide Files

| Destination | Source | Purpose |
| --- | --- | --- |
| `/etc/greetd/config.toml` | [`etc/greetd/config.toml`](./etc/greetd/config.toml) | Starts the greeter on the first virtual terminal |
| `/etc/pam.d/greetd` | [`etc/pam.d/greetd`](./etc/pam.d/greetd) | Unlocks KWallet at login |
| `/var/lib/noctalia-greeter/greeter.toml` | [`defaults/noctalia-greeter/greeter.toml`](./defaults/noctalia-greeter/greeter.toml) | Keyboard layout and display of the login screen |
| `/usr/local/share/wayland-sessions/niri.desktop` | [`defaults/wayland-sessions/niri.desktop`](./defaults/wayland-sessions/niri.desktop) | The niri session, logging to the journal |
| `/etc/fonts/conf.d/50-generic-families.conf` | [`etc/fonts/conf.d/50-generic-families.conf`](./etc/fonts/conf.d/50-generic-families.conf) | The fonts for sans-serif, serif, monospace and `system-ui`, which web pages mostly rely on |
| Polkit rule | `noctalia-greeter passwordless-sync` | Appearance sync without authentication |
| Login shell | `chsh` | fish for the installing user |

### User Configuration

[`dots/`](./dots/) is merged into the home directory file by file with
`cp --parents`, except the `AGENTS.md` files, which describe the repository to
coding agents. Files from the repository replace files of the same name, and
every other file is left in place. The wallpapers in
[`assets/wallpapers/`](./assets/wallpapers/) are copied to
`~/Pictures/Wallpapers`, after `xdg-user-dirs-update` has created the XDG user
directories.

- **niri** reads [`config.kdl`](./dots/.config/niri/config.kdl), which includes
  the files in `config.d/` in numbered order: input, layout, window rules,
  environment, startup, animations, key bindings, layer rules and
  `90-user-extra.kdl` for local additions. niri starts Noctalia, the KWallet
  initialization and the KDE service cache rebuild at login.
- **Noctalia** reads `10-default.toml` and `20-lockscreen-widgets.toml`.
  Its templates color fzf, eza, VSCodium and, through Pywalfox, Firefox from
  the current color scheme.
- **GTK settings are stored in GSettings.** On Wayland, GTK 3 takes the
  theme, icons, cursor and fonts from GSettings, and its values replace those
  in `settings.ini`. The installer copies the values from
  `gtk-3.0/settings.ini` to `org.gnome.desktop.interface`, where dconf stores
  them in `~/.config/dconf/user`.
- **XDG desktop portals** are assigned per interface in
  [`niri-portals.conf`](./dots/.config/xdg-desktop-portal/niri-portals.conf):
  GNOME for screen capture, KDE for file dialogs and settings, KWallet for
  secrets, and GNOME, then GTK, for the rest.
- **Default applications** are set in
  [`mimeapps.list`](./dots/.config/mimeapps.list): Firefox for the web,
  Gwenview for images, Haruna for video, Okular for PDF, LibreOffice for
  office documents, Kate for text and Ark for archives.
- **Neovim's plugins are installed ahead of the first start.** A headless
  Neovim runs `Lazy! sync` and installs the syntax parsers LazyVim lists,
  waiting up to ten minutes for them to compile.
- **VSCodium runs in portable mode.** `VSCODE_PORTABLE` keeps its settings,
  extensions and caches in `~/.local/share/vscodium`. The installer creates
  the directory, which VSCodium requires, and installs the extensions that
  `extensions.json` recommends.
- **Web apps** are managed by the commands in
  [`dots/.local/bin/`](./dots/.local/bin/). `webapp-install` creates a
  desktop entry that opens a site in a Chromium window without tabs or
  address bar, with the site's icon; `webapp-remove` deletes one.
  [`05-path.fish`](./dots/.config/fish/conf.d/05-path.fish) adds
  `~/.local/bin` to `PATH`.

### Keyboard and Displays

The keyboard and display options are validated against the system before
anything is installed, and applied after the configuration has been copied.

- **The keyboard layout** must appear in systemd's `kbd-model-map`, and a
  variant must be one that xkeyboard-config defines for that layout. Both are
  written to an `input` block in `90-user-extra.kdl`, which niri reads last,
  and to the greeter configuration.
- **The Swedish layout swaps five key bindings.** niri matches a binding
  against the symbol a key produces without Shift or AltGr. With `se`, five
  of the default bindings use symbols that need a modifier; the installer
  replaces them with the alternatives marked "Swedish:" in
  [`70-binds.kdl`](./dots/.config/niri/config.d/70-binds.kdl).
- **Displays are checked in `/sys/class/drm`.** Each connector must exist and
  have a monitor attached, and a resolution must be one that the monitor
  reports. The kernel lists no refresh rates, which leaves the rate
  unchecked; it defaults to 60 Hz, and niri chooses a mode itself when the
  rate does not match one exactly. Each connector receives one `output` block
  in `90-user-extra.kdl`.
- **The lock screen widgets** are placed on the first display given with an
  option, or else on the first connected display.
- **The location** from `--address` is written to the Noctalia
  configuration, which resolves it when the desktop starts. Double quotes,
  backslashes and control characters are rejected, as the value is placed in
  a TOML string.

## Logging

Both installers record all terminal output in
`logs/<script-name>-<timestamp>.log` in the repository they run from.

- **The complete terminal session is recorded.** Each installer re-runs
  itself under `script(1)`, which records what the terminal displays,
  including the output of pacman, paru, cryptsetup and makepkg. A pipe
  through `tee` would capture the same text, but these tools change their
  behavior when output is not a terminal, and progress bars and color would
  be lost.
- **Passwords are not recorded.** `script(1)` records output, not input, and
  password prompts do not echo.
- **Repeated runs append.** The timestamp in the file name is that of the
  first run. A later run in the same checkout appends to the same file, and an
  installation that needed several attempts has a single log. `script(1)`
  marks the start and end of each run, with its exit status.
- **The base log is copied with the installer.** After a successful
  installation, `base-install.sh` copies the repository and its log to the
  new user's home directory, under the name of the checkout directory
  (`~/arch-install` for a default clone). A failed copy only produces a
  warning, as the installation itself is complete at that point.
  `desktop-install.sh` runs from that copy and writes its log next to the
  first.

The log contains terminal control sequences for progress bars and color.
`cat` or `less -R` display it as it originally appeared.
