# AGENTS.md: packages/

Prebuilt AUR packages that `base-install.sh` installs with `pacman -U`. The
root [AGENTS.md](../AGENTS.md) applies as well.

- Never edit, rename or build these files by hand. The maintainer rebuilds
  them with the procedure in ARCHITECTURE.md, Prebuilt Packages
  (`pkgctl build` in a clean chroot); agents do not run it.
- Keep exactly one file per package: remove the previous version when adding
  a new one. `base-install.sh` refuses to run otherwise.
- The PKGBUILD and `pkgrel` must match the AUR. Verify a new file before it
  is committed:

  ```bash
  bsdtar -xOf packages/<file> .PKGINFO
  bsdtar -xOf packages/<file> .BUILDINFO \
    | grep -E '^(pkgbuild_sha256sum|buildtool) '
  curl -fsSL 'https://aur.archlinux.org/cgit/aur.git/plain/.SRCINFO?h=<name>'
  curl -fsSL 'https://aur.archlinux.org/cgit/aur.git/plain/PKGBUILD?h=<name>' \
    | sha256sum
  ```

  The version, dependencies, optional dependencies, provides, conflicts and
  backup entries in `.PKGINFO` match `.SRCINFO`, `pkgbuild_sha256sum` equals
  the SHA-256 of the AUR PKGBUILD, and `buildtool` is `devtools`.
