# Security design

This document explains what the installation protects, what it deliberately does
not, and why TPM2 unlocking and UEFI Secure Boot are **not** part of it.

## Threat model

The design targets one scenario above all others:

> The machine is powered off and ends up in someone else's hands -- lost, stolen,
> or confiscated -- and the data on it must stay unreadable.

Everything below follows from that sentence. A different threat model, such as
defending a running shared workstation against a local attacker, would justify
different choices.

Two properties matter:

1. **Confidentiality at rest.** Nothing on the disk should be recoverable
   without a secret the owner holds.
2. **Recoverability.** A design that quietly locks out its owner has failed,
   even if it never leaks a byte.

Explicitly out of scope: protecting a machine that is running or suspended,
defending against an attacker who has already executed code as root, and
defending against someone who can compel disclosure of the passphrase.

## What the installation does

- **LUKS2 with Argon2id** on the whole root partition. The passphrase is the
  only credential; there is no second keyslot and nothing sealed to hardware.
- **The ESP is mounted `fmask=0177,dmask=0077`**, so the kernel and the UKIs are
  not world-readable. FAT carries no permission bits of its own.
- **The kernel command line is embedded in the UKI**, not read from a file on
  the ESP at boot.
- **Snapshots are local**, and inherit the encryption of the volume they live
  on. They are a recovery tool, not a backup.

The encryption boundary is simple enough to state in one line: everything
outside the ESP is encrypted, the ESP holds no secrets, and one passphrase opens
the volume.

## Why there is no TPM2 unlocking

TPM2 unlocking replaces "type a passphrase" with "the chip releases the key when
the machine looks the way it did at enrollment, and you type a short PIN". It is
a **convenience** feature, and against this threat model it is a downgrade.

### It replaces a strong secret with a weak one

A LUKS2 passphrase of 20 or more characters has no feasible offline attack:
Argon2id makes each guess expensive, and the search space is astronomically
large.

A TPM PIN is typically six digits. That is only safe while the TPM enforces its
own anti-hammering lockout. The security of the whole disk then rests on the
chip refusing to answer too many times, rather than on the secret itself. If the
chip can be worked around, six digits falls in seconds.

That is not hypothetical. Sealed keys have been recovered by sniffing the bus
between a discrete TPM and the CPU, and firmware TPMs have had their own
extraction flaws. Those attacks need physical access and equipment -- exactly
what an adversary who has confiscated the machine has.

### Without Secure Boot, the PCR policy adds nothing

TPM enrollment binds the key to PCR 7, which measures the Secure Boot policy.
With Secure Boot disabled, PCR 7 holds the same value on every boot of that
machine, whatever is booted. An attacker can boot their own kernel and initramfs
from a USB stick and the policy still matches, so the TPM is willing to release
the key into that environment. The only thing then standing between an attacker
and the volume is the six-digit PIN.

TPM unlocking without Secure Boot therefore carries the cost of a weak secret
without the protection that is supposed to justify it. That combination is worse
than either a plain passphrase or a fully signed setup, and it is the one most
easily arrived at by accident.

### It adds a second way to lose the data

Every sealed-key design has failure modes a passphrase does not: a firmware
update that changes the measurements, a cleared TPM, a replaced mainboard. Each
is recoverable only from a credential kept elsewhere -- so the strong secret has
to exist anyway, and the TPM has only added a second, weaker path to the same
data.

## Why there is no Secure Boot

Secure Boot verifies that the firmware only executes signed boot components. It
protects boot **integrity**. It encrypts nothing, and it does not protect the
**confidentiality** of data at rest: a powered-off encrypted disk is exactly as
unreadable with Secure Boot off as with it on.

Its real value is against tampering -- an attacker with temporary physical access
who modifies the bootloader or initramfs to capture the passphrase, then returns
to collect it. That is a genuine attack, but it is a different threat model from
the one above, and defending against it assumes the attacker gets a second visit.

Secure Boot would matter a great deal *if* TPM unlocking were used, because
signing is what makes PCR 7 meaningful: the certificate that authorised each
executed image is measured into it, so only images signed by the owner's key can
satisfy the policy. With no TPM unlocking, there is nothing for that binding to
protect.

What it would cost:

- A key enrollment step that needs the firmware in Setup Mode, which cannot be
  automated from the installer and differs between machines.
- Every boot component signed, and re-signed on every kernel update.
- Microsoft's certificates enrolled as well, or some firmware and option ROMs
  stop working -- which weakens the guarantee, since a large set of
  third-party-signed binaries then remains bootable.
- A new class of failure in which a working machine stops booting after an
  update, recoverable only by entering the firmware.

For a system meant to be reinstalled quickly and reproducibly, that is a large,
machine-specific cost for a protection outside the stated threat model.

**The installer refuses to run while Secure Boot is enabled.** It signs nothing,
so the firmware would reject the bootloader it installs. That check is a
correctness guard, not a security feature.

## What actually protects the data

In rough order of how much they matter:

1. **A long, high-entropy LUKS passphrase.** This is the entire security of the
   system. Everything else is convenience or integrity.
2. **Powering the machine off.** A running or suspended machine holds the volume
   key in RAM, where it is recoverable by cold-boot and DMA attacks. Seizure
   while suspended defeats full-disk encryption completely. Shut down rather
   than close the lid when it matters.
3. **Keeping the passphrase somewhere durable.** There is no recovery key and no
   TPM fallback. Losing the passphrase destroys the data as thoroughly as any
   attacker could.

## Limitations, stated plainly

- **The ESP is unauthenticated.** Anyone who can write to it can alter the
  bootloader or the UKI. The next boot would then run attacker-controlled code
  and could capture the passphrase. This is the evil-maid attack, and this
  design does not defend against it.
- **No protection against a running system.** Once the volume is unlocked, the
  usual access controls are all that remain.
- **Snapshots are not backups.** They share the disk and its encryption. A
  failed drive or a wiped partition takes them with it.
- **Compelled disclosure is a legal question, not a technical one**, and varies
  by jurisdiction. Nothing described here changes that.

## If the threat model changes

The pieces left out here are not wrong in general -- they are wrong for this
purpose. A machine facing an evil-maid threat rather than a confiscation threat
would reasonably add Secure Boot with a locally enrolled key, sign the bootloader
and the UKIs, and bind a TPM2 key to PCR 7 so a tampered boot chain cannot unlock
the disk. That design is coherent, but it is a different design, and it trades
reinstall speed and recoverability for tamper resistance.

## References

- [Arch Wiki -- dm-crypt](https://wiki.archlinux.org/title/Dm-crypt)
- [Arch Wiki -- Unified Kernel Image](https://wiki.archlinux.org/title/Unified_kernel_image)
- [Arch Wiki -- Limine](https://wiki.archlinux.org/title/Limine)
- [Arch Wiki -- Snapper](https://wiki.archlinux.org/title/Snapper)
- [Arch Wiki -- Trusted Platform Module](https://wiki.archlinux.org/title/Trusted_Platform_Module)
- [Arch Wiki -- Secure Boot](https://wiki.archlinux.org/title/Unified_Extensible_Firmware_Interface/Secure_Boot)
- [cryptsetup FAQ](https://gitlab.com/cryptsetup/cryptsetup/-/wikis/FrequentlyAskedQuestions)
