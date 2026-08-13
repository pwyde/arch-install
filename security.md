# TPM2, PCR 7, Secure Boot, and LUKS Volume Pinning

This document describes the security design used by the automated Arch Linux installation script, together with the additional LUKS volume-key pinning configuration recommended after installation.

- UEFI Secure Boot
- a signed Unified Kernel Image (UKI)
- `systemd-boot` / `systemd-stub`
- LUKS2 full-disk encryption
- `systemd-cryptenroll`
- a TPM2 device
- a TPM PIN
- direct TPM binding to PCR 7
- LUKS volume-key pinning with `fixate-volume-key=`

The goal is to explain **why** these mechanisms are used together, the security properties they provide, and how to configure them without binding TPM-based unlocking to PCRs that routinely change during normal Arch Linux updates.

> [!IMPORTANT]
> Always maintain a known-working LUKS passphrase or recovery key before changing TPM enrollment, Secure Boot keys, PCR policy, or volume-key fixation. TPM-based unlocking provides an additional security and convenience layer and should not be the only means of recovering an encrypted system.

> [!NOTE]
> LUKS volume-key pinning is not configured automatically by the installation script because determining the expected volume-key hash requires a staged procedure and a reboot. It must therefore be configured manually after the installation is complete by following the instructions in this document.

---

## 1. Threat model and design goals

A TPM-backed LUKS configuration should ideally accomplish several things:

1. The encrypted volume should not unlock automatically if the machine's trusted Secure Boot policy changes.
2. An attacker should not be able to replace the boot environment with an unsigned or unauthorized one and still obtain the disk unlock secret.
3. TPM-based unlocking should require a PIN, so possession of the computer alone is not enough.
4. Routine kernel, initramfs, microcode, and UKI updates should not require TPM re-enrollment.
5. The signed boot environment should be pinned to the **actual LUKS volume key**, not merely to spoofable metadata such as a LUKS UUID.
6. The configuration should remain practical on a rolling-release distribution such as Arch Linux.

The resulting design is:

```text
                         UEFI Secure Boot
                                │
                                ▼
                         trusted db keys
                                │
                                ▼
                    signed systemd-boot / UKI
                                │
                 ┌──────────────┴──────────────┐
                 │                             │
                 ▼                             ▼
              PCR 7                    embedded UKI cmdline
                 │                             │
                 ▼                             ▼
           TPM2 + TPM PIN             fixate-volume-key=
                 │                             │
                 └──────────────┬──────────────┘
                                ▼
                              LUKS2
                                │
                   actual volume-key hash
                                │
                     must equal expected
                                │
                                ▼
                          encrypted root
```

These mechanisms complement each other. They do not all protect against the same attack.

---

## 2. What is a TPM?

A **Trusted Platform Module (TPM)** is a hardware-backed security device that can perform cryptographic operations and protect secrets.

For LUKS2, `systemd-cryptenroll` can enroll a TPM2-backed unlock mechanism. The LUKS volume is not encrypted *by* the TPM. Instead, systemd enrolls a secret into a LUKS keyslot and seals the material needed to recover that secret to the TPM. At boot, the TPM will release the sealed material only when the configured TPM policy is satisfied.

A policy can include:

- PCR values
- a TPM PIN
- signed PCR policies
- other TPM2 policy mechanisms supported by systemd

For the configuration described here, the policy is intentionally simple:

```text
expected PCR 7
      +
correct TPM PIN
      │
      ▼
TPM permits release of the enrolled secret
      │
      ▼
LUKS2 can be unlocked
```

The PIN is handled by the TPM policy and is distinct from the normal LUKS passphrase.

---

## 3. What are PCRs?

TPM **Platform Configuration Registers (PCRs)** hold measurements of the boot environment. A PCR is not normally assigned an arbitrary value. Measurements are *extended* into it:

```text
new_PCR = HASH(old_PCR || new_measurement)
```

This creates an ordered, tamper-evident history. Changing a measured component generally results in a different final PCR value.

PCRs 0 through 23 have conventional uses. Some particularly relevant PCRs on a modern UEFI/systemd system include:

| PCR | Typical role |
|---|---|
| 0 | Platform / firmware code |
| 1 | Platform configuration |
| 2 | External / option-ROM code |
| 3 | External / option-ROM configuration |
| 4 | Boot-loader / EFI executable code |
| 5 | Boot-loader configuration |
| 7 | Secure Boot policy |
| 9 | Kernel/initrd-related measurements |
| 11 | UKI/kernel boot measurements made by `systemd-stub` |
| 12 | Kernel configuration / command-line-related measurements |
| 15 | System identity and systemd userspace measurements, including optional LUKS volume-key measurements |

The exact event sequence is firmware- and software-dependent. Inspect the current values with:

```bash
systemd-analyze pcrs
```

---

## 4. Why use PCR 7?

PCR 7 represents the **Secure Boot policy**. On a correctly configured UEFI Secure Boot system it reflects the Secure Boot state and relevant Secure Boot policy/key material.

Enroll the TPM against PCR 7 with:

```bash
sudo systemd-cryptenroll \
    --wipe-slot=tpm2 \
    --tpm2-device=auto \
    --tpm2-pcrs=7 \
    --tpm2-with-pin=yes \
    /dev/<LUKS_DEVICE>
```

For example, `<LUKS_DEVICE>` might be an NVMe partition such as `/dev/nvme0n1p2`, but use the actual encrypted block device for the system being configured.

Verify the enrollment:

```bash
sudo cryptsetup luksDump --debug-json /dev/<LUKS_DEVICE> \
    | sed -n '/systemd-tpm2/,/}/p'
```

The TPM token should show the equivalent of:

```json
"tpm2-pcrs":[
    7
],
"tpm2-pcr-bank":"sha256",
"tpm2-pin":true
```

### Security property

Binding to PCR 7 means TPM unlock is tied to the expected Secure Boot policy. Changes such as disabling Secure Boot or materially modifying its trust policy should change PCR 7 and cause the existing TPM policy to stop matching.

### Why not directly bind to PCR 11?

PCR 11 is valuable because `systemd-stub` measures UKI/kernel boot information into it. However, a **direct** enrollment such as `--tpm2-pcrs=7+11` binds the TPM to the *current literal PCR 11 value*.

A routine update that rebuilds the UKI can therefore change PCR 11:

```text
kernel/initramfs/microcode update
              │
              ▼
           new UKI
              │
              ▼
         PCR 11 changes
```

With direct `7+11` binding, TPM unlock may then require re-enrollment.

PCR 7 avoids that maintenance problem:

```text
new correctly signed UKI
          │
          ├── PCR 11 may change
          │
          └── PCR 7 remains stable
                    │
                    ▼
              TPM unlock works
```

A more advanced alternative is a **signed PCR 11 policy**, where trusted future PCR 11 values are authorized cryptographically. That is a different design and requires additional signing infrastructure. It is not required for the configuration documented here.

---

## 5. Why PCR 7 alone is not the whole security story

PCR 7 tells the TPM about the **Secure Boot policy**, but it does not by itself identify the exact LUKS volume that should be attached. This distinction becomes particularly relevant when the Secure Boot trust database contains more than one trusted certificate, for example a local signing key plus vendor certificates.

The signed UKI authenticates the boot environment, but systemd still has to locate and attach the encrypted root volume. Device identifiers are metadata, for example:

- LUKS UUID
- partition UUID
- filesystem UUID
- labels

This metadata can potentially be copied or reproduced. This leads to a subtle attack class: a rogue operating environment or substituted encrypted volume might copy identifying metadata from the legitimate system and attempt to impersonate the expected root device.

This is what **LUKS volume-key pinning** is intended to harden.

---

## 6. What is `fixate-volume-key=`?

`fixate-volume-key=` was added in **systemd v260**. It allows systemd to pin an encrypted volume to the expected cryptographic hash of its actual **LUKS volume key**.

Conceptually:

```text
find LUKS device by UUID
          │
          ▼
obtain/use volume key
          │
          ▼
hash actual volume key
          │
     ┌────┴────┐
     │         │
  matches    differs
     │         │
     ▼         ▼
  attach     refuse
  volume     attachment
```

The important distinction is:

```text
LUKS UUID              = metadata
volume-key hash        = cryptographic identity of the encrypted volume
```

Copying a UUID does not reproduce the real volume encryption key. The expected digest used by `fixate-volume-key=` is the SHA-256 digest that systemd reports when `tpm2-measure-pcr=` is enabled.

---

## 7. What does `tpm2-measure-pcr=yes` do?

The cryptsetup option `tpm2-measure-pcr=yes` asks systemd to measure information about the activated encrypted volume into TPM **PCR 15**. The measurement includes the volume key together with information identifying the activated volume. This is separate from the PCRs used to authorize TPM unlocking.

These two settings must not be confused:

```text
--tpm2-pcrs=7
```

means:

> PCR 7 must satisfy the TPM's policy before the enrolled TPM secret can be used.

whereas:

```text
tpm2-measure-pcr=yes
```

means:

> After activation, measure the volume identity/key information into PCR 15 and log the measurement.

The TPM enrollment can therefore remain bound only to PCR 7 even though PCR 15 receives a volume-key measurement.

---

## 8. Why use `fixate-volume-key=` with a signed UKI?

The strongest aspect of this design is that the expected volume-key hash is placed in the **kernel command line embedded in the UKI**. The UKI is then signed for Secure Boot.

For example:

```text
signed UKI
  │
  ├── kernel
  ├── initramfs
  ├── microcode
  └── embedded command line
           │
           └── fixate-volume-key=<EXPECTED_HASH>
```

An attacker cannot simply replace the expected hash with the hash of a rogue volume without modifying the UKI. Modifying the UKI invalidates its Secure Boot signature unless the attacker possesses a trusted signing key.

This creates a chain from the firmware trust policy to the expected encrypted-volume identity:

```text
UEFI Secure Boot
       │
       ▼
trusted signing certificate
       │
       ▼
signed UKI
       │
       ▼
signed embedded cmdline
       │
       ▼
fixate-volume-key=<expected hash>
       │
       ▼
actual LUKS volume key must match
```

This is why volume-key fixation is especially useful together with a signed UKI.

---

# 9. Step-by-step: configure TPM PCR 7 + PIN

> [!WARNING]
> Verify that a normal LUKS passphrase or recovery credential works before wiping an existing TPM enrollment.

Enroll the TPM:

```bash
sudo systemd-cryptenroll \
    --wipe-slot=tpm2 \
    --tpm2-device=auto \
    --tpm2-pcrs=7 \
    --tpm2-with-pin=yes \
    /dev/<LUKS_DEVICE>
```

Verify:

```bash
sudo cryptsetup luksDump --debug-json /dev/<LUKS_DEVICE> \
    | sed -n '/systemd-tpm2/,/}/p'
```

Look for:

```text
tpm2-hash-pcrs: 7
tpm2-pcr-bank:  sha256
tpm2-pin:       true
```

Reboot and confirm that TPM + PIN successfully unlocks the volume.

---

# 10. Step-by-step: pin the LUKS volume key

The pinning procedure should be performed in **two stages**.

## Stage 1 — measure the volume key

Assume an existing UKI command line similar to:

```text
rd.luks.name=<LUKS_UUID>=cryptroot root=/dev/mapper/cryptroot rootfstype=btrfs rootflags=subvol=/@ rw
```

Add an `rd.luks.options=` parameter:

```text
rd.luks.options=<LUKS_UUID>=tpm2-device=auto,tpm2-measure-pcr=yes
```

The complete `/etc/cmdline.d/root.conf` becomes:

```text
rd.luks.name=<LUKS_UUID>=cryptroot root=/dev/mapper/cryptroot rootfstype=btrfs rootflags=subvol=/@ rw rd.luks.options=<LUKS_UUID>=tpm2-device=auto,tpm2-measure-pcr=yes
```

Keep the command line on a **single line**. Rebuild the UKI:

```bash
sudo mkinitcpio -P
```

If an `sbctl` mkinitcpio post-hook is configured, it should automatically sign the regenerated UKI. Verify the Secure Boot signatures:

```bash
sudo sbctl verify
```

Reboot.

After boot, inspect the volume-key measurement:

```bash
sudo grep volume-key /run/log/systemd/tpm2-measure.log
```

Extract the digest:

```bash
sudo grep volume-key /run/log/systemd/tpm2-measure.log \
    | jq --seq '.digests[].digest'
```

The result should be a 64-character SHA-256 digest, for example:

```text
"1bedc5b93286d16446faec24f02ad018378405a3bef84671957754f1dfadbd3e"
```

---

## Stage 2 — enforce the expected volume key

Append `fixate-volume-key=<VOLUME_KEY_SHA256>` to the LUKS options. The final command line becomes:

```text
rd.luks.name=<LUKS_UUID>=cryptroot root=/dev/mapper/cryptroot rootfstype=btrfs rootflags=subvol=/@ rw rd.luks.options=<LUKS_UUID>=tpm2-device=auto,tpm2-measure-pcr=yes,fixate-volume-key=<VOLUME_KEY_SHA256>
```

Rebuild and sign the UKI:

```bash
sudo mkinitcpio -P
```

Verify:

```bash
sudo sbctl verify
```

Reboot.

Keep the normal LUKS recovery credential available during this first test. An incorrect `fixate-volume-key=` value is intentionally supposed to prevent the encrypted volume from being attached.

---

# 11. Verify the final configuration

After a successful reboot, verify the active kernel command line:

```bash
cat /proc/cmdline
```

Confirm that it includes:

- `tpm2-measure-pcr=yes`
- `fixate-volume-key=<VOLUME_KEY_SHA256>`

Check the measured volume-key digest again:

```bash
sudo grep volume-key /run/log/systemd/tpm2-measure.log \
    | jq --seq '.digests[].digest'
```

It should match `<VOLUME_KEY_SHA256>`. Verify PCR 7:

```bash
systemd-analyze pcrs | grep secure-boot-policy
```

Verify TPM enrollment:

```bash
sudo cryptsetup luksDump --debug-json /dev/<LUKS_DEVICE> \
    | sed -n '/systemd-tpm2/,/}/p'
```

The TPM enrollment should still show PCR 7 and TPM PIN protection.

Optionally inspect PCR 15:

```bash
systemd-analyze pcrs | grep system-identity
```

Do not expect the final PCR 15 value itself to equal `<VOLUME_KEY_SHA256>`. PCRs are extended with measurements; they are not simply assigned the measured digest.

---

# 12. What changes the volume-key hash?

The `fixate-volume-key=` value tracks the underlying **LUKS volume encryption key**, not ordinary authentication methods around that key.

The following operations normally **do not** change the expected hash:

- changing the TPM PIN
- wiping and re-enrolling the TPM2 keyslot
- changing PCR selection
- adding a LUKS passphrase
- changing a LUKS passphrase
- removing an ordinary LUKS keyslot
- rebuilding the initramfs
- rebuilding the UKI
- updating the Linux kernel
- updating CPU microcode
- updating firmware packages
- updating `systemd`
- normal `pacman -Syu` upgrades

For example, re-enrolling the TPM with:

```bash
sudo systemd-cryptenroll \
    --wipe-slot=tpm2 \
    --tpm2-device=auto \
    --tpm2-pcrs=7 \
    --tpm2-with-pin=yes \
    /dev/<LUKS_DEVICE>
```

Does not normally replace the LUKS volume encryption key, so `fixate-volume-key=` remains unchanged.

The hash **does** need to be regenerated if an operation actually replaces/rekeys the underlying LUKS volume encryption key, such as an applicable LUKS reencryption/rekey operation. After any operation intended to replace the volume key, repeat the measurement procedure before relying on the old fixation value.

---

# 13. Expected behavior during normal Arch Linux updates

A useful property of this design is that routine updates may change PCRs associated with the boot artifact without breaking TPM unlock.

For example:

```text
pacman upgrade
       │
       ├── kernel/initramfs/microcode may change
       │
       ├── UKI is rebuilt
       │
       ├── UKI is signed again
       │
       ├── PCR 4/9/11 may change
       │
       ├── PCR 7 should remain stable if Secure Boot policy is unchanged
       │
       └── LUKS volume key remains unchanged
                    │
                    ▼
             TPM + PIN still works
                    +
          fixate-volume-key still matches
```

This is the primary reason to prefer direct PCR 7 binding over direct `7+11` binding for this design.

---

# 14. What happens when PCR 7 changes?

If the TPM enrollment is directly bound to PCR 7, changing the Secure Boot policy should invalidate TPM unlocking.

Examples can include:

- disabling Secure Boot
- clearing Secure Boot keys
- replacing the enrolled Platform Key
- changing KEK/db policy in a way reflected in PCR 7
- otherwise altering the measured Secure Boot policy

In that situation, unlock with the normal LUKS recovery credential and re-enroll the TPM **only after verifying that the Secure Boot state is legitimate**.

Do not automatically re-enroll the TPM merely because PCR 7 changed. A mismatch is a security signal that should be understood first.

---

# 15. Why not `1+3+5+7+12`?

A broader direct PCR set such as `1+3+5+7+12` is a valid design if the goal is to bind TPM unlock to a much more specific machine/platform configuration.

It can detect additional changes involving:

- platform configuration
- external-device configuration
- boot configuration
- command-line-related state

The tradeoff is greater fragility. Legitimate firmware configuration changes, firmware updates, hardware changes, partition/boot changes, or other maintenance can invalidate the TPM enrollment.

The choice is therefore primarily a threat-model decision:

```text
PCR 7
    → trust the expected Secure Boot policy
    → resilient to normal signed UKI changes

1+3+5+7+12
    → trust a much narrower platform state
    → detects more environmental changes
    → greater chance of legitimate TPM lockout
```

For a rolling-release desktop/workstation where Secure Boot and a signed UKI are already enforced, **PCR 7 + TPM PIN + LUKS volume-key fixation** provides a practical balance.

---

# 16. Why not direct `7+11`?

PCR 11 is an excellent measurement for UKIs, but direct PCR binding has an important operational consequence `--tpm2-pcrs=7+11` records the current PCR 11 state in the TPM policy. A new legitimate UKI normally produces a new PCR 11 value. That means routine kernel/UKI updates can make the existing TPM enrollment unusable.

A **signed PCR 11 policy** avoids that problem by authorizing expected future PCR 11 values with a signing key, but it requires additional infrastructure and is outside the scope of this guide.

For this simpler design, rely on:

- Secure Boot to authenticate the UKI
- PCR 7 to bind TPM unlocking to the Secure Boot policy
- the TPM PIN for user authorization
- `fixate-volume-key=` to bind the signed boot environment to the real LUKS volume

---

# 17. Security properties of the complete design

The final security chain provides complementary protections.

## Secure Boot

Prevents execution of unauthorized EFI binaries in the trusted boot chain.

## Signed UKI

Cryptographically protects the unified boot artifact, including components such as the kernel, initramfs and embedded command line.

## PCR 7

Binds TPM release to the expected Secure Boot policy rather than to one exact kernel build.

## TPM PIN

Requires user knowledge in addition to possession of the TPM-equipped system.

## LUKS2

Provides at-rest encryption of the root filesystem.

## `tpm2-measure-pcr=yes`

Measures the activated LUKS volume identity/key information into PCR 15 and records the measurement in systemd's TPM event log.

## `fixate-volume-key=`

Requires the actual LUKS volume key to match the hash embedded in the signed UKI, preventing a volume from being accepted merely because it copied expected metadata.

Together:

```text
                 physical machine
                       │
                       ▼
                     TPM2
                       │
              expected PCR 7
                       +
                    TPM PIN
                       │
                       ▼
                 Secure Boot
                       │
                       ▼
                  signed UKI
                       │
                embedded cmdline
                       │
              fixate-volume-key
                       │
                       ▼
              expected LUKS2 volume
                       │
                       ▼
               encrypted Btrfs root
```

No single mechanism replaces the others.

---

# 18. Recovery considerations

Always retain at least one independent LUKS recovery method.

Before changing any of the following, verify that recovery method:

- Secure Boot keys
- TPM enrollment
- PCR selection
- TPM PIN
- UKI generation
- `fixate-volume-key=`
- LUKS reencryption/rekeying

If TPM unlock stops working after a legitimate Secure Boot policy change:

1. Unlock with the LUKS recovery credential.
2. Verify Secure Boot state and enrolled keys.
3. Inspect PCR 7.
4. Re-enroll the TPM only after confirming the new state is trusted.

If boot fails immediately after enabling `fixate-volume-key=`, first verify the hash for typographical errors. The option is specifically designed to reject a volume whose actual volume-key hash does not match.

---

# 19. Useful verification commands

Check Secure Boot:

```bash
sbctl status
bootctl status
```

Verify signed EFI binaries:

```bash
sudo sbctl verify
```

Inspect TPM PCRs:

```bash
systemd-analyze pcrs
```

Inspect the LUKS TPM2 token:

```bash
sudo cryptsetup luksDump --debug-json /dev/<LUKS_DEVICE> \
    | sed -n '/systemd-tpm2/,/}/p'
```

List TPM devices known to systemd:

```bash
systemd-cryptenroll --tpm2-device=list
```

Inspect the active kernel command line:

```bash
cat /proc/cmdline
```

Read the measured volume-key digest:

```bash
sudo grep volume-key /run/log/systemd/tpm2-measure.log \
    | jq --seq '.digests[].digest'
```

Check the active LUKS mapping:

```bash
sudo cryptsetup status cryptroot
```

---

## Summary

For a modern Arch Linux installation using LUKS2, TPM2, Secure Boot and a signed UKI, a practical policy is:

```text
Secure Boot
    +
signed UKI
    +
TPM2 bound to PCR 7
    +
TPM PIN
    +
tpm2-measure-pcr=yes
    +
fixate-volume-key=
```

This avoids tying TPM unlocking to PCRs that routinely change during legitimate kernel/UKI updates while still binding the TPM to the expected Secure Boot policy and binding the signed boot environment to the cryptographic identity of the intended LUKS volume.

---

# References

- [Arch Linux Wiki - systemd-cryptenroll](https://wiki.archlinux.org/title/Systemd-cryptenroll)
- [Arch Linux Wiki - dm-crypt / system configuration / Pinning a LUKS volume](https://wiki.archlinux.org/title/Dm-crypt/System_configuration#Pinning_a_LUKS_volume)
- [Arch Linux Manual - `systemd-cryptenroll(1)`](https://man.archlinux.org/man/systemd-cryptenroll.1)
- [Arch Linux Manual - `crypttab(5)`](https://man.archlinux.org/man/crypttab.5)
- [systemd `systemd-cryptenroll(1)`](https://www.freedesktop.org/software/systemd/man/systemd-cryptenroll.html)
- [systemd `systemd-stub(7)`](https://www.freedesktop.org/software/systemd/man/systemd-stub.html)
- [systemd `crypttab(5)` - `tpm2-measure-pcr=` and `fixate-volume-key=`](https://www.freedesktop.org/software/systemd/man/crypttab.html)
