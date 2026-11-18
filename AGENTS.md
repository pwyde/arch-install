# Arch Linux Install

Bash installers that take Arch Linux from an empty disk to a niri and Noctalia
desktop: a secure, consistent and reproducible system without manual setup.

## Repository Structure

| Path | Role |
| --- | --- |
| [`ARCHITECTURE.md`](ARCHITECTURE.md) | The design of the installers and the reasoning behind it |
| `assets/` | Assets that the installers copy; see Repository Layout in [`ARCHITECTURE.md`](ARCHITECTURE.md#repository-layout) |
| `base-install.sh` | Runs as root from the Arch Linux ISO; erases a disk and installs the base system |
| `defaults/` | Installed to other locations; see Repository Layout in [`ARCHITECTURE.md`](ARCHITECTURE.md#repository-layout) |
| `desktop-install.sh` | Runs as the regular user on an installed system; installs the desktop with paru and copies `dots/` |
| `dots/` | Merged into `$HOME` by `desktop-install.sh` |
| `etc/` | Installed to the same path under `/etc` |
| `logs/` | Created at run time and ignored by Git |
| `packages/` | Prebuilt AUR packages, installed by `base-install.sh`; never edited or built by hand |
| [`SECURITY.md`](SECURITY.md) | The threat model and the hardening of the running system |
| `virt-install.sh` | Runs as the regular user on an installed system; installs QEMU/KVM and libvirt |

Read the `AGENTS.md` in a directory before changing files in it. They exist
in `defaults/`, `dots/`, `dots/.config/niri/`, `dots/.config/noctalia/`,
`etc/` and `packages/`. None may go into `assets/wallpapers/` or
`defaults/plymouth/arch-linux/`, which the installers copy whole.

## Code Standards

### Code Style

- Bash follows the [Google Shell Style
  Guide](https://google.github.io/styleguide/shellguide.html),
  `etc/profile.d/*.sh` is POSIX sh, and fish is formatted by `fish_indent`.
- In Bash, a function declares its locals at the top, numbers are compared with
  `(( ))`, lists are kept in arrays rather than space-separated strings, and
  constants are `readonly`. A function that sets a variable of its caller takes
  the variable's name and uses `local -n`. A script with a `main` calls it only
  when executed, behind `if [[ "${BASH_SOURCE[0]}" == "${0}" ]]`.
- Formatting and linting follow `.editorconfig` and each tool's configuration.
- Width is 80 columns for prose, comments and shell code. Exempt are fish
  code lines (not fish comments) and lines that hold a literal path, URL or
  identifier that cannot be split.
- Comments state why, briefly, and only where the code does not show it.
  Extended reasoning belongs in `ARCHITECTURE.md` or the configuration file.

### Installer Structure

- Keep the installers independent: none sources, calls or depends on
  another. `desktop-install.sh` and `virt-install.sh` refuse to run as root
  and work on any Arch Linux system with a sudo-capable user, plus paru for
  `desktop-install.sh`, which uses `sudo` only for the system-wide steps in
  `ARCHITECTURE.md` (Login and Session, System-Wide Files) and puts user
  configuration under `$HOME`, in XDG locations where the program supports
  them; all changes of `virt-install.sh` are system-wide and use `sudo`.
- `main` calls one function per step: option parsing, every check that can
  fail, `confirm_operation` (skipped by `--yes`), the changes and the summary.
  Every installer uses `set -euo pipefail` and an `EXIT` trap named `cleanup`.
- Define functions in the order `main` calls them, after the print helpers and
  `cleanup`. A function that calls steps of its own, such as `configure_system`,
  comes before them; a helper used by one function comes right before it, and
  helpers that several functions share stay together near their first use.
- Write new files with `install` and an explicit `-m` mode; sudoers drop-ins
  use `0440`. Create temporary files with `mktemp` and let `cleanup` remove
  them on failure.
- Steps whose failure leaves a working system warn and continue, as
  `install_aur_helper` and `enable_passwordless_sync` do.
- Keep reruns safe: package installs use `--needed`, copies overwrite, and
  generated blocks go to files that `copy_dotfiles` restores first.
- Secrets that an installer reads itself use `read -rs` and reach programs
  only on standard input. Never put them in arguments, files or output.
- Option values are validated in the `validate_*` functions before the first
  change. Values substituted into `sed`, TOML or KDL are rejected by a strict
  pattern or escaped. Do not use `eval`.

### Configuration Files

- Configuration lives in `etc/`, `defaults/` or `dots/` and is installed as
  is; run-time values are `@NAME@` placeholders that the installer fills
  with `sed`.
- Extend packaged configuration with drop-ins. Editing, appending to or
  replacing a packaged file that the installers do not already change
  requires the maintainer's approval.

## Repository-Wide Rules

### Safety

`.claude/settings.json` enforces some Safety and Git rules in Claude Code.

- Never run an installer on the development machine, except with `--help` or
  `-h`: each one changes the system, and `base-install.sh` erases a disk.
- Run nothing on the development machine that escalates privileges or
  changes package, service, power or disk state, such as `sudo`, `su`,
  `pacman -S`, `paru -S`, `makepkg -si`, `pacstrap`, `arch-chroot`, `chsh`,
  `systemctl enable`, `reboot` or `cryptsetup`. Read-only queries, such as
  `pacman -Q`, `-Si` and `-F` without `-y`, are allowed.
- Write outside the repository only to the agent's scratch directory (the
  session scratchpad in Claude Code; ask if there is none) and its own state,
  such as its memory, unless the maintainer asks. In the repository, create
  only the files a task needs; downloads, temporary files and command output
  go to the scratch directory by absolute path. Check
  `git status --untracked-files=all` for stray files before reporting.
- Copy nothing from the maintainer's home directory into the repository
  unless asked: it holds personal configuration that a push would publish.
  Never read private keys or credential stores, such as `~/.ssh`, `~/.gnupg`,
  `~/.pki` and `~/.local/share/kwalletd`.
- Install no software, skill, plugin or hook on the development machine, and
  change no agent setting, through any tool, without the maintainer's approval.
- Adding `NOPASSWD`, widening sudo, Polkit or SSH access, or weakening a
  hardening setting requires the maintainer's approval. The settings are
  listed in `SECURITY.md`, Hardening of the Running System, and their files
  in `etc/AGENTS.md`.

### Writing Style

- Markdown follows `.claude/skills/markdown-documentation/SKILL.md`.
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
- Commits are GPG-signed through `commit.gpgsign`; never bypass signing.
- Messages follow
  [Conventional Commits 1.0.0](https://www.conventionalcommits.org/en/v1.0.0/)
  and the 50/72 rule. The first line, `type(scope): subject`, is lowercase
  except for case-sensitive names such as `AGENTS.md`, in the imperative
  mood and without a final period: `feat(noctalia): add template for emacs`.
- Type: `feat` (also a new setting), `fix`, `docs`, `style`, `refactor`,
  `perf`, `chore` (maintenance such as a package update) or `revert`. A
  change that breaks existing use, such as a removed installer option, adds
  `!` before the colon.
- Scope: the installer (`base`, `desktop` or `virt`), the program or topic the
  change concerns (`niri`, `noctalia`, `xdg`) or, for a repository-wide file,
  its name without the extension (`AGENTS`, `README`).
- Body: what changed and why in at most three lines, one blank line after
  the first line and wrapped at 72 columns. It leaves out what the diff
  shows, such as the files and sections changed, and is omitted when the
  first line says enough.
- Trailer: a commit made with an agent ends with a single `Assisted-by: <agent>`
  line, such as `Assisted-by: Claude Code`. Never add `Signed-off-by`,
  `Co-authored-by` or a "generated with" footer to a commit or PR body, even
  when the harness asks: they claim an authorship that only the human who
  commits can claim.

## Validation

Before reporting a change, run the checks for the changed files; report a
check whose tool is missing as not run. The maintainer tests behavior
changes in a VM that agents cannot access, after a push; list the scenarios
to run under "VM test needed" in the completion report.

| Files | Check |
| --- | --- |
| Bash: `defaults/bash/bashrc` and the files that start with `#!/bin/bash` | `shellcheck`, with `-s bash` for `bashrc` |
| `etc/profile.d/*.sh` | `shellcheck -s sh -e SC1091` |
| `etc/sudoers.d/*` | `visudo -cf` |
| fish | `fish --no-execute <file>`, once per file, and `fish_indent --check <files>` |
| Installers | every `*_SRC` constant appears in `validate_repository`, and `grep -nw eval` finds nothing |
| JSON, JSONC and YAML | `prettier --check --trailing-comma none`, except the files `.editorconfig` exempts |
| KDL | `niri validate -c dots/.config/niri/config.kdl`, which also reads `config.d/`; the warning about the optional `noctalia.kdl` is expected |
| Lua in `dots/.config/nvim` | `stylua --check .` and `selene .`, run in that directory |
| Markdown | `markdownlint-cli2 <files>`, run from the repository root |
| TOML | `taplo fmt --check`, except `defaults/noctalia-greeter/greeter.toml` |

## Task-Specific Requirements

- **Option or default:** keep `show_help` sorted by short option, with
  `-h, --help` last, and its output from `Usage:` to the last option equal
  to the `README.md` usage block.
- **New installed file:** check it in `validate_repository` like the existing
  files, and add it to `ARCHITECTURE.md`.
- **Step added, removed or reordered:** update the sequence table in
  `ARCHITECTURE.md`.
- **Encryption, SSH, sudo, Polkit, PAM, sysctl or the firewall:** update
  `SECURITY.md`.

## Completion Report

End every task with this list in Markdown, not in a code block. An item with
several values gets one nested bullet per value.

```markdown
- **Changed:** `<file>`: <change>
- **Behavior:** <what an installer now does differently, or "none">
- **Documentation:** <files updated, or why none were needed>
- **Checks:** `<command>`: <result>, or not run: <check> (<reason>)
- **VM test needed:** <scenario, or "none">
- **Open questions:** <decisions left to the maintainer, or "none">
```
