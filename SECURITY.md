# Security Design

This document describes what the installation protects, what it deliberately
does not protect, and why TPM2 unlocking and UEFI Secure Boot are **not** part
of the design.

## Threat Model

The design addresses one scenario above all others:

> The machine is powered off and comes into the possession of a third party,
> whether lost, stolen or confiscated, and the data on it must remain
> unreadable.

Every decision below follows from this scenario. A different threat model,
such as protecting a running shared workstation against a local attacker,
would justify different choices.

The design has two objectives:

1. **Confidentiality at rest.** No data on the disk can be recovered without
   a secret held by the owner.
2. **Recoverability.** A design that locks out its owner has failed, even if
   it never discloses any data.

The following are explicitly out of scope: protecting a machine that is
running or suspended, defending against an attacker who has already executed
code as root, and defending against compelled disclosure of the passphrase.

## Protections in Place

- **LUKS2 encryption of the entire root partition**, with Argon2id, the
  cryptsetup default for LUKS2, as the key derivation function. The passphrase
  is the only credential: there is no second keyslot and no key sealed to
  hardware.
- **Restrictive ESP permissions.** The ESP is mounted with
  `fmask=0177,dmask=0077`, which makes the kernel and the UKIs readable by
  root only. FAT has no permission bits of its own.
- **Encrypted swap and hibernation.** zram swap exists only in RAM, and the
  hibernation swapfile, created where the hardware supports hibernation,
  resides inside the encrypted volume.
- **Local snapshots**, which inherit the encryption of the volume containing
  them. They are a recovery mechanism, not a backup.

The encryption boundary can be stated in one sentence: everything outside the
ESP is encrypted, the ESP holds no secrets, and a single passphrase unlocks
the volume.

## Hardening of the Running System

A running system lies outside the threat model. The installers nevertheless
apply a baseline that limits what is exposed while the volume is unlocked:

- **SSH.** sshd is enabled, accepts public-key authentication only, refuses root
  logins and admits only the user created by the installer. No key is installed,
  so no remote login is possible until one is added. `base-install.sh` refuses a
  username that names an existing system account, such as root, which would
  otherwise receive a password and SSH access. It checks the live system before
  the disk is erased, and the installed system again when it creates the user,
  which catches accounts added by packages from `--packages`.
- **No core dumps.** systemd-coredump stores nothing, and setuid programs
  never dump core, so process memory is not written to disk.
- **Kernel restrictions.** The kernel log and kernel pointers are restricted
  to root, and ptrace is limited to a process's own descendants.
- **Network stack hardening.** Strict reverse path filtering, no ICMP redirects
  and no replies to broadcast pings.
- **Automatic screen lock.** The desktop locks the screen after 15 minutes of
  inactivity.

One rule relaxes the defaults: `desktop-install.sh` allows the user to sync
the desktop appearance to the greeter without authentication. The rule covers
only that action.

## Rationale for Omitting TPM2 Unlocking

TPM2 unlocking replaces the passphrase with a key that the chip releases when
the measured boot state matches the state at enrollment, usually combined with
a short PIN. It is a **convenience** feature, and under this threat model it
reduces security.

### A Strong Secret Is Replaced by a Weak One

A LUKS2 passphrase of 20 or more characters is not vulnerable to any feasible
offline attack: Argon2id makes each guess expensive, and the search space is
extremely large.

A TPM PIN typically consists of six digits. Such a PIN is safe only while the
TPM enforces its anti-hammering lockout. The security of the entire disk then
depends on the chip refusing further attempts, rather than on the strength of
the secret. If the chip can be circumvented, a six-digit PIN is exhausted in
seconds.

These attacks are documented. Sealed keys have been recovered by sniffing the
bus between a discrete TPM and the CPU, and firmware TPMs have had extraction
vulnerabilities of their own. Such attacks require physical access and
equipment, which is precisely what an adversary in possession of a
confiscated machine has.

### Without Secure Boot, the PCR Policy Provides No Protection

TPM enrollment binds the key to PCR 7, which measures the Secure Boot policy.
With Secure Boot disabled, PCR 7 holds the same value on every boot of the
machine, regardless of what is booted. An attacker can boot a custom kernel
and initramfs from a USB drive, the policy still matches, and the TPM releases
the key into that environment. The six-digit PIN is then the only remaining
barrier.

TPM unlocking without Secure Boot therefore incurs the cost of a weak secret
without the protection intended to justify it. This combination is weaker
than either a plain passphrase or a fully signed boot chain, and it is also
the configuration most easily reached by accident.

### A Second Path to Data Loss Is Introduced

Every sealed-key design has failure modes that a passphrase does not: a
firmware update that changes the measurements, a cleared TPM or a replaced
mainboard. Each is recoverable only with a credential stored elsewhere. The
strong secret has to exist regardless, and the TPM adds only a second, weaker
path to the same data.

## Rationale for Omitting Secure Boot

Secure Boot ensures that the firmware executes only signed boot components.
It protects boot **integrity**. It encrypts nothing and does not protect the
**confidentiality** of data at rest: a powered-off encrypted disk is equally
unreadable with Secure Boot enabled or disabled.

Its value lies in preventing tampering: an attacker with temporary physical
access modifies the bootloader or the initramfs to capture the passphrase, and
returns later to collect it. This is a genuine attack, but it belongs to a
different threat model, one that assumes the attacker gains a second
opportunity for access.

Secure Boot would be essential *if* TPM unlocking were used, because signing
is what gives PCR 7 its meaning: the certificate that authorized each executed
image is measured into it, and only images signed with the owner's key can
satisfy the policy. Without TPM unlocking, that binding has nothing to
protect.

The costs of Secure Boot would be:

- A key enrollment step that requires the firmware to be in Setup Mode, which
  the installer cannot automate and which differs between machines.
- Signing every boot component, and re-signing on every kernel update.
- Enrolling Microsoft's certificates as well, since some firmware and option
  ROMs otherwise stop working. This weakens the guarantee, as a large set of
  third-party-signed binaries then remains bootable.
- A new class of failure, in which a working machine no longer boots after an
  update and can be recovered only through the firmware setup.

For a system designed to be reinstalled quickly and reproducibly, these are
significant, machine-specific costs for a protection outside the stated
threat model.

**The installer refuses to run while Secure Boot is enabled.** It signs
nothing, and the firmware would reject the bootloader it installs. This check
guards correctness; it is not a security feature.

## Factors That Protect the Data

In approximate order of importance:

1. **A long, high-entropy LUKS passphrase.** The security of the system rests
   entirely on it. Every other measure concerns convenience or integrity.
2. **Powering the machine off.** A running or suspended machine holds the
   volume key in RAM, where cold-boot and DMA attacks can recover it. Seizure
   of a suspended machine defeats full disk encryption entirely. Where this
   matters, the machine should be shut down or hibernated rather than
   suspended. A hibernated machine is equivalent to a powered-off one: the
   memory image is stored in the encrypted volume, and resuming requires the
   passphrase. The desktop installed by `desktop-install.sh` suspends the
   machine after one hour of inactivity; where seizure is a concern, this
   idle action should be disabled in Noctalia's settings.
3. **Durable storage of the passphrase.** There is no recovery key and no TPM
   fallback. Loss of the passphrase destroys the data as thoroughly as any
   attacker could.

## Limitations

- **The ESP is not authenticated.** Anyone with write access to it can modify
  the bootloader or the UKI. The next boot then runs attacker-controlled code,
  which can capture the passphrase. This is the evil-maid attack, and this
  design does not defend against it.
- **The kernel command line can be overridden.** It is embedded in the UKI,
  and Limine supplies none of its own for the default entries, but without
  Secure Boot the UKI accepts a command line passed by the bootloader. The
  embedded command line keeps the configuration in one place; it does not
  prevent tampering.
- **Temporary account passwords.** With `--yes`, or after an empty or
  mismatched password at the prompt, `base-install.sh` sets the password
  `changeme` for the user and for root. The installation summary names the
  affected accounts, and their passwords must be changed with `passwd` before
  the machine is used. The LUKS passphrase is always entered interactively.
- **AUR packages are trusted as published.** The AUR holds user-submitted build
  files, which can run any code when a package is built or installed.
  `base-install.sh` builds the AUR helper paru from its current AUR build files
  without showing them for review, and installs the result as root. The two
  Limine packages in `packages/` are built by the maintainer from their AUR
  build files in a clean chroot and installed unsigned from this repository.
  `desktop-install.sh` installs some of its default packages, and any AUR
  package given with `--packages`, through paru, which shows their build files
  for review before it builds them; `--yes` skips that review.
- **A running system is not protected.** Once the volume is unlocked, only
  the regular access controls remain.
- **Snapshots are not backups.** They share the disk and its encryption. A
  failed drive or an erased partition destroys them as well.
- **Compelled disclosure is a legal matter, not a technical one**, and varies
  by jurisdiction. Nothing described here affects it.

## Changes to the Threat Model

The omitted components are not unsuitable in general; they are unsuitable
for this purpose. A machine facing an evil-maid threat rather than a
confiscation threat would reasonably add Secure Boot with a locally enrolled
key, sign the bootloader and the UKIs, and bind a TPM2 key to PCR 7, which
prevents a tampered boot chain from unlocking the disk. Such a design is
coherent, but it is a different design, and it trades reinstallation speed
and recoverability for tamper resistance.

## References

- [ArchWiki - dm-crypt](https://wiki.archlinux.org/title/Dm-crypt)
- [ArchWiki - Unified kernel image](https://wiki.archlinux.org/title/Unified_kernel_image)
- [ArchWiki - Limine](https://wiki.archlinux.org/title/Limine)
- [ArchWiki - Snapper](https://wiki.archlinux.org/title/Snapper)
- [ArchWiki - Power management / Suspend and hibernate](https://wiki.archlinux.org/title/Power_management/Suspend_and_hibernate)
- [ArchWiki - Trusted Platform Module](https://wiki.archlinux.org/title/Trusted_Platform_Module)
- [ArchWiki - Secure Boot](https://wiki.archlinux.org/title/Unified_Extensible_Firmware_Interface/Secure_Boot)
- [ArchWiki - Sysctl / TCP/IP stack hardening](https://wiki.archlinux.org/title/Sysctl#TCP/IP_stack_hardening)
- [systemd - systemd-stub](https://www.freedesktop.org/software/systemd/man/latest/systemd-stub.html)
- [cryptsetup - Frequently Asked Questions](https://gitlab.com/cryptsetup/cryptsetup/-/wikis/FrequentlyAskedQuestions)
