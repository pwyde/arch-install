# AGENTS.md: dots/.config/noctalia/

Noctalia shell configuration and color templates, copied to
`~/.config/noctalia/` by `desktop-install.sh`. The root
[AGENTS.md](../../../AGENTS.md) applies as well.

- The shell files (`*.toml`) use the color role names of the Noctalia
  version in the `extra` repository. Check that version before adopting a
  name from newer release notes, as an older version does not recognize
  it; 5.4.0, for example, renamed `surface_variant` to `surface_container`
  and `outline` to `outline_variant`.
- `templates/` uses the template color names, which did not change:
  `colors.surface_variant` and `colors.outline` remain valid there.
- A new template is registered in `10-default.toml` under
  `[theme.templates.user.<name>]`. `templates/vscode.json` and
  `templates/claude-code.json` are Noctalia's upstream templates, kept as
  published.
- `@LOCATION_ADDRESS@` in `10-default.toml` is filled in by
  `configure_location`, and `@LOCKSCREEN_OUTPUT@` in `10-default.toml` and
  `20-lockscreen-widgets.toml` by `configure_lockscreen`, which deletes the
  `monitors` line by its exact text when no display is connected; keep the
  tokens and that line as they are.
