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
  `[theme.templates.user.<name>]`. `templates/vscode.json` is Noctalia's
  upstream template, kept as published.
- `@LOCATION_ADDRESS@` in `10-default.toml` and `@LOCKSCREEN_OUTPUT@` in
  `20-lockscreen-widgets.toml` are filled in by `configure_location` and
  `configure_lockscreen`; keep both tokens.
