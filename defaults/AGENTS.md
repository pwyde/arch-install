# AGENTS.md: defaults/

Files installed to a path other than their own, unlike `etc/`. The root
[AGENTS.md](../AGENTS.md) applies as well.

- `plymouth/arch-linux/` is copied as a whole, so a new file there is
  installed without being named; `validate_inputs` checks
  `arch-linux.plymouth` for the directory.
- `noctalia-greeter/greeter.toml` is invalid TOML until rendered; never run
  a TOML formatter on it. `install_greeter_config` fills `@XKB_LAYOUT@` and
  the `@OUTPUT_*@` placeholders, and deletes the line of a placeholder
  without a value, so each placeholder stays on a line of its own. Without
  any display option, it deletes the `[output]` section up to the next
  blank line, which therefore ends the section.
- `limine/limine.conf` holds no boot entries; `limine-entry-tool` writes
  them.
- `NUMBER_LIMIT` in `snapper/root` stays one below `MAX_SNAPSHOT_ENTRIES` in
  `etc/limine-entry-tool.d/50-arch.conf`; a change to one is made to both.
- `bash/bashrc` is Bash without a shebang; check it with
  `shellcheck -s bash`.
