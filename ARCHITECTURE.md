# Architecture

This document describes how `arch-install.sh` builds the installed system and
the reasoning behind its design decisions. [README.md](./README.md) covers
installation and usage; [SECURITY.md](./SECURITY.md) covers the threat model.

## Contents

- [Installation sequence](#installation-sequence)
- [Repository layout](#repository-layout)
- [Filesystem layout](#filesystem-layout)
- [Boot chain](#boot-chain)
- [Initramfs](#initramfs)
- [Snapshots](#snapshots)
- [Prebuilt packages](#prebuilt-packages)
- [Hibernation](#hibernation)
- [Plymouth](#plymouth)
- [System tuning](#system-tuning)
- [AUR helper](#aur-helper)
- [Logging](#logging)

## Installation sequence

The installer runs as a single sequence of functions, called in order by
`main`:

| Step | Function | Purpose |
| --- | --- | --- |
| 1 | `start_logging` | Re-runs the installer under `script(1)` |
| 2 | `parse_args` | Parses the command-line options |
| 3 | `validate_secure_boot` | Refuses to continue while Secure Boot is enabled |
| 4 | `validate_inputs` | Checks the disk, UEFI mode, required tools and repository files |
| 5 | `setup_partitions` | Derives partition names and the microcode package |
| 6 | `confirm_operation` | Asks for confirmation before the disk is erased |
| 7 | `create_partitions` | Writes a new GPT with an ESP and a root partition |
| 8 | `format_partitions` | Formats the ESP and creates the LUKS2 container |
| 9 | `setup_btrfs` | Creates the Btrfs filesystem and its subvolumes |
| 10 | `mount_filesystems` | Mounts the subvolumes and the ESP under `/mnt` |
| 11 | `install_base_system` | Installs the base system with `pacstrap` |
| 12 | `configure_system` | Configures the installed system inside a chroot |
| 13 | `verify_installation` | Checks the boot files, configuration and user setup |
| 14 | `print_summary` | Prints the installation summary |
| 15 | `copy_installer_to_home` | Copies the repository and its log to the new user's home |

Every check that can fail without consequence runs before step 7. Until the
first write to the disk, a failure exits quietly; after it, the `EXIT` trap
unmounts the target filesystems, stops the `gpg-agent` left running on the
target keyring, and closes the LUKS container if the installer opened it.

`configure_system` runs its steps in a fixed order. Hibernation and Plymouth
are configured before the boot setup, since both contribute kernel parameters
and initramfs content. `limine-mkinitcpio-hook` is installed last, as its
pacman hook builds the UKIs immediately from the configuration already in
place. The AUR helper follows, and its failure does not fail the installation.

## Repository layout

| Path | Contents |
| --- | --- |
| [`arch-install.sh`](./arch-install.sh) | The installer |
| [`etc/`](./etc/) | Configuration files, installed to the same path under `/etc` |
| [`defaults/`](./defaults/) | Files installed elsewhere: the Limine configuration, the Plymouth theme, the Snapper configuration and the system-sleep hook |
| [`packages/`](./packages/) | Prebuilt AUR packages; see [Prebuilt packages](#prebuilt-packages) |
| [`dots/.config/`](./dots/.config/) | Desktop configuration for niri, kitty, nirimod and Noctalia; not deployed by the installer |
| `logs/` | Installation logs, created at run time and excluded from version control |

Files containing `@HOSTNAME@`, `@USERNAME@`, `@LOCALE@` or `@ROOT_UUID@` are
templates; the installer substitutes the values when it installs them.

## Filesystem layout

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

## Boot chain

[Limine](https://wiki.archlinux.org/title/Limine) is installed from the
official repositories, with its global settings from
[`defaults/limine/limine.conf`](./defaults/limine/limine.conf).
`limine-mkinitcpio-hook` and `limine-snapper-sync` follow (see
[Prebuilt packages](#prebuilt-packages)). The first deploys Limine to the ESP,
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
  command line of its own.
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

### Boot screen colors

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

```
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

## Prebuilt packages

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
    (cd "$pkg" && pkgctl build)
done

cp ~/build/*/*.pkg.tar.zst /path/to/arch-install/packages/
```

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
- **The [`keyboard-backlight`](./defaults/systemd/system-sleep/keyboard-backlight)
  system-sleep hook**, installed to `/usr/lib/systemd/system-sleep/`. It turns
  the keyboard backlight off before hibernation, as the keyboard controller on
  some ASUS laptops otherwise blocks the S4 power-off. The hook requires
  `brightnessctl`, which is not installed by default; on affected hardware it
  can be added with `--packages brightnessctl`.

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
  `sv-latin1` becomes `se`). The `sd-vconsole` hook copies the file into the
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
was left unchanged. `logo.png` is the official Arch Linux logo for dark
backgrounds, `archlinux-logo-light-90dpi.png` from
[archlinux.org/art](https://archlinux.org/art/) (600×199, blue `#1793D1` and
white), with the trademark symbol removed. It is not recolored to `#999999`:
the [trademark policy](https://terms.archlinux.org/docs/trademark-policy/)
asks for the logos to be used in their standard form.

## System tuning

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
| sshd | A drop-in in [`etc/ssh/sshd_config.d/`](./etc/ssh/sshd_config.d/) allows key authentication only, refuses root, and limits `AllowUsers` to the account the installer creates. Remote login requires a public key installed from the console first. `Ciphers`, `KexAlgorithms` and `MACs` are not set, leaving OpenSSH's defaults, which lead with hybrid post-quantum key exchange. |
| Journal | [`etc/systemd/journald.conf.d/`](./etc/systemd/journald.conf.d/) caps the journal at 500M instead of 10% of the filesystem, which holds about a month of logs. |
| Core dumps | [`etc/systemd/coredump.conf.d/`](./etc/systemd/coredump.conf.d/) disables them with `Storage=none` and `ProcessSizeMax=0`, as a dump holds the memory of the crashed process, including keys and passphrases. |
| IPv6 | Enabled, with rotating privacy addresses from [`10-ipv6-privacy.conf`](./etc/NetworkManager/conf.d/10-ipv6-privacy.conf). |
| Wi-Fi | Power save is disabled by [`20-wifi-powersave.conf`](./etc/NetworkManager/conf.d/20-wifi-powersave.conf); it adds latency on an idle link, and some Intel firmware drops the connection while the radio sleeps. |

Enabled services: `systemd-resolved`, `systemd-timesyncd`, zram swap, `sshd`,
`NetworkManager`, `fstrim.timer`, `snapper-cleanup.timer` and
`limine-snapper-sync.service`.

## AUR helper

[paru](https://github.com/Morganamilo/paru) is built from the AUR at the end
of the installation, once the system is otherwise complete.

- **It is built from source rather than installed as `paru-bin`.** paru links
  against `libalpm`, and a prebuilt binary stops working whenever pacman
  changes that library's soname.
- **Only the build runs as the user.** `makepkg` refuses to run as root, and
  the user has no password-free sudo. The steps that require root (installing
  `rust`, installing the package, and removing `rust` again) run as root
  around the build. No temporary `NOPASSWD` rule is created, which a failed
  build could otherwise leave behind.
- **`rust` is removed afterwards**, unless it was requested with
  `--packages`. It is only a build dependency.
- **A failure is not fatal.** If the AUR or crates.io cannot be reached, the
  installer issues a warning and continues; paru can be built manually after
  the first boot.

## Logging

All terminal output is recorded in `logs/arch-install-<timestamp>.log` in the
repository.

- **The complete terminal session is recorded.** The installer re-runs itself
  under `script(1)`, which records what the terminal displays, including the
  output of pacman, cryptsetup and makepkg. A pipe through `tee` would capture
  the same text, but these tools change their behaviour when output is not a
  terminal, and progress bars and colour would be lost.
- **Passwords are not recorded.** `script(1)` records output, not input, and
  password prompts do not echo.
- **Repeated runs append.** The timestamp in the file name is that of the
  first run. A later run in the same checkout appends to the same file, and an
  installation that needed several attempts has a single log. `script(1)`
  marks the start and end of each run, with its exit status.
- **The log is copied with the installer.** After a successful installation,
  the repository and its log are copied to `~/arch-install` in the new user's
  home directory. A failed copy only produces a warning, as the installation
  itself is complete at that point.

The log contains terminal control sequences for progress bars and colour.
`cat` or `less -R` display it as it originally appeared.
