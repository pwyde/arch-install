# AGENTS.md

Two Bash installers for Arch Linux and the configuration files they deploy.
[README.md](README.md) covers usage, [ARCHITECTURE.md](ARCHITECTURE.md) the
design and [SECURITY.md](SECURITY.md) the threat model. CLAUDE.md only
imports this file, so rules are written here.

## Repository

| Path | Role |
| --- | --- |
| `assets/wallpapers/` | Copied to `~/Pictures/Wallpapers` |
| `base-install.sh` | Runs as root from the Arch Linux ISO in UEFI mode; erases the target disk and installs LUKS2, Btrfs, Limine, UKIs and Snapper |
| `defaults/` | Installed to other locations; see ARCHITECTURE.md, Repository Layout |
| `desktop-install.sh` | Runs as the regular user on an installed system; installs niri, Noctalia and greetd with paru and copies `dots/` |
| `dots/` | Merged into `$HOME` by `desktop-install.sh`, without the `AGENTS.md` files |
| `etc/` | Installed to the same path under `/etc` |
| `packages/` | Prebuilt AUR packages, installed by `base-install.sh` with `pacman -U` |

The repository has no build system, CI, tests, database or migrations.

## Repository-Wide Rules

### Safety

- Never run an installer outside a virtual machine: `base-install.sh` erases
  a disk, and `desktop-install.sh` upgrades the system, writes to `/etc` and
  overwrites files in `$HOME`. `--help` or `-h` is the only invocation
  allowed on the development machine. Behavior changes are tested in the
  maintainer's VM; see VM Test.
- Do not run on the development machine:
  - privilege escalation: `sudo`, `doas`, `pkexec`, `run0` and `su`
  - package transactions: `pacman` and `paru` other than read-only queries
    (`-Q`, `-Si`, `-Ss`, `-Sg`, `-Sp` and `-F` without `-y`), `makepkg` with
    `-i`, `-s` or `-r`, and `pacstrap`
  - `arch-chroot`, `pkgctl` and `chsh`
  - service and power state changes: `systemctl` verbs such as `enable`,
    `start` or `daemon-reload`, and `reboot`, `poweroff`, `shutdown` and
    `halt`
  - disk tools: `sgdisk`, `cryptsetup`, `wipefs` and `mkfs`
- Outside the repository, write only to a scratch directory and to the
  agent's own state, such as its memory. Any other file, for example in the
  development machine's home directory or `/etc`, is changed only when the
  maintainer asks.
- Install no software, skill, plugin or hook on the development machine
  without the maintainer's approval, through any tool, including `npm`,
  `pip` and `cargo`.
- Secrets are read with `read -rs` and reach programs only on standard input.
  Never put them in arguments, files or output.
- Option values are validated in the `validate_*` functions before the first
  change. Values substituted into `sed`, TOML or KDL are rejected by a strict
  pattern or escaped. Do not use `eval`.
- Adding `NOPASSWD`, widening sudo, Polkit or SSH access, or weakening a
  hardening setting requires the maintainer's approval. The settings are
  listed in SECURITY.md, Hardening of the Running System, and their files
  in `etc/AGENTS.md`.

### Installer Structure

- Keep the installers independent: neither references, calls or depends on
  the other. `desktop-install.sh` must work on any Arch Linux system with a
  sudo-capable user and paru.
- `main` calls one function per step: option parsing, every check that can
  fail, `confirm_operation` (skipped by `--yes`), then the changes. Both
  scripts use `set -euo pipefail` and an `EXIT` trap named `cleanup`.
- Install files with `install` and an explicit `-m` mode; sudoers drop-ins
  use `0440`. Create temporary files with `mktemp` and let `cleanup` remove
  them on failure.
- Steps whose failure leaves a working system warn and continue, as
  `install_aur_helper` and `enable_passwordless_sync` do.
- Keep reruns safe: paru installs with `--needed`, copies overwrite, and
  generated blocks go to files that `copy_dotfiles` restores first.
- `desktop-install.sh` refuses to run as root and uses `sudo` only for the
  system-wide steps in ARCHITECTURE.md (Login and Session, System-Wide
  Files). User configuration goes under `$HOME`, in XDG locations where the
  program supports them.

### Configuration Files

- Configuration lives in `etc/`, `defaults/` or `dots/` and is installed as
  is; run-time values are `@NAME@` placeholders that the installer fills
  with `sed`.
- Extend packaged configuration with drop-ins. Editing, appending to or
  replacing a packaged file that the installers do not already change
  requires the maintainer's approval.

### Files with Special Handling

- `packages/`: never edit or build the packages by hand; follow
  [packages/AGENTS.md](packages/AGENTS.md).
- Files that `.editorconfig` exempts from formatting (program-written files,
  the upstream Noctalia template, the fastfetch ASCII art): keep their format.
- `logs/` is created at run time and ignored by Git.

### Style

- Formatting and linting follow `.editorconfig`, `.markdownlint.yaml`,
  `dots/.config/nvim/stylua.toml` and `dots/.config/nvim/selene.toml`.
- Markdown also follows `.claude/skills/markdown-documentation/SKILL.md`.
- Bash follows the Google Shell Style Guide, `etc/profile.d/*.sh` is POSIX
  sh, and fish is formatted by `fish_indent`.
- Width is 80 columns for prose, comments and shell code. Exempt are literal
  paths, URLs and identifiers that cannot be split, fish code lines (not fish
  comments) and Markdown tables.
- Comments state why, briefly, and only where the code does not show it.
  Extended reasoning belongs in ARCHITECTURE.md or the configuration file.
- Comments and documentation are formal and impersonal, without
  contractions, in US English.
- Lists of three or more words or phrases in comments and documentation have no
  comma before the final "and" or "or" ("niri, Noctalia and greetd"), unless an
  item itself contains "and" or "or". Only a series of independent clauses, each
  with its own subject, may keep the comma.

### Git

- Work on `main`. Commit only when asked and only the files named; push only
  when asked.
- Do not discard uncommitted changes or stashes, and do not rewrite or
  delete history on the remote, for example with `git reset --hard`,
  `git clean -f` or `git push --force`; the maintainer runs such commands.
- Commits are GPG-signed (`commit.gpgsign` is set in the maintainer's Git
  configuration); never bypass signing.
- Subject: imperative, sentence case, no type prefix, no final period, at most
  72 characters. Body: the reason for the change, wrapped at 80 columns.
- A commit made with an agent ends with a `Co-Authored-By:` trailer that
  names the agent and model, with the agent's no-reply address, for example
  `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Validation

Before reporting a change, run the checks for the changed files; report a
check whose tool is missing as not run.

| Files | Check |
| --- | --- |
| Bash scripts | `shellcheck` |
| `etc/profile.d/*.sh` | `shellcheck -s sh -e SC1091` |
| `etc/sudoers.d/*` | `visudo -cf` |
| fish | `fish --no-execute` and `fish_indent --check` |
| JSON and JSONC | `prettier --check --trailing-comma none`, except the files `.editorconfig` exempts |
| Lua in `dots/.config/nvim` | `stylua --check .` and `selene .`, run in that directory |
| Markdown | `markdownlint-cli2 <files>`, run from the repository root |
| TOML | `taplo fmt --check`, except `defaults/noctalia-greeter/greeter.toml` |

### VM Test

The maintainer tests behavior changes in a VM that agents cannot access,
with the repository pulled from GitHub after a push. List the scenarios to
run under "VM test needed" in the completion report.

## Task-Specific Requirements

- **Option or default:** keep `show_help` sorted by short option, with
  `-h, --help` last, and the README.md usage block matching its output.
- **New installed file:** check it in `validate_repository` like the existing
  files, and add it to ARCHITECTURE.md.
- **Step added, removed or reordered:** update the sequence table in
  ARCHITECTURE.md.
- **Encryption, SSH, sudo, Polkit, PAM or sysctl:** update SECURITY.md.

## Completion Report

End every task with this list, written as Markdown rather than in a code
block. An item with one value stays on its label's line; an item with several
values gets one nested bullet per value.

```markdown
- **Changed:**
  - `<file>`: <change>
- **Behavior:** <what an installer now does differently, or "none">
- **Documentation:** <files updated, or why none were needed>
- **Checks:**
  - `<command>`: <result>
  - not run: <check> (<reason>)
- **VM test needed:** <scenario, or "none">
- **Open questions:** <decisions left to the maintainer, or "none">
```

## Nested AGENTS.md

Read the AGENTS.md in a directory before changing files in it:

- [defaults/AGENTS.md](defaults/AGENTS.md)
- [dots/AGENTS.md](dots/AGENTS.md)
- [dots/.config/niri/AGENTS.md](dots/.config/niri/AGENTS.md)
- [dots/.config/noctalia/AGENTS.md](dots/.config/noctalia/AGENTS.md)
- [etc/AGENTS.md](etc/AGENTS.md)
- [packages/AGENTS.md](packages/AGENTS.md)

`copy_dotfiles` skips every file named `AGENTS.md`, so the files under `dots/`
are not deployed, and no configuration file may have that name.
