# AGENTS.md: dots/

User configuration, merged into the home directory by `copy_dotfiles` in
`desktop-install.sh`. The root [AGENTS.md](../AGENTS.md) applies as well.

- On every run, a file here replaces the file of the same name in the home
  directory; every other file there is left in place.
- `copy_dotfiles` skips only files named `AGENTS.md`, so no configuration
  file may have that name. Add no `CLAUDE.md` here: it would be copied into
  the home directory, where Claude Code would load it as instructions.
- The configuration in the home directory differs from `dots/` on purpose:
  a file there that `dots/` lacks is not a gap, and a difference is not a
  change to copy back unless the maintainer asks.
- Files that `.editorconfig` exempts from formatting keep their format. Most
  are written by their programs: change only the keys a task needs and keep
  the program's order.
- Noctalia writes its theme files at run time, from its own templates and
  those in `.config/noctalia/templates/`; such a file is never committed.
  Keep the lines that its template scripts add to files here, such as
  `include themes/noctalia.conf` in `.config/kitty/kitty.conf`; the scripts
  are the `apply.sh` files of the `noctalia` package.
- Each copied file that `desktop-install.sh` reads or edits after the copy
  has a constant under `# Destinations`; moving or renaming the file
  requires changing that constant.
- The scripts in `.local/bin/` are committed as executable (mode `100755`),
  since the copy keeps the mode.
- `webapp-remove` recognizes the entries that `webapp-install` writes by their
  `Exec` line and compares their names as the entries store them; a change to
  either format is made in both scripts.
