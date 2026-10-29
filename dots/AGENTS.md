# AGENTS.md: dots/

User configuration, merged into the home directory by `copy_dotfiles` in
`desktop-install.sh`. The root [AGENTS.md](../AGENTS.md) applies as well,
and `.config/niri/` and `.config/noctalia/` have their own AGENTS.md.

- On every run, a file here replaces the file of the same name in the home
  directory; every other file there is left in place.
- Each copied file that `desktop-install.sh` reads or edits after the copy
  has a constant under `# Destinations`; moving or renaming the file
  requires changing that constant.
- The scripts in `.local/bin/` are committed as executable (mode `100755`),
  since the copy keeps the mode.
