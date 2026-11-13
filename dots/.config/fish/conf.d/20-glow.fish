# glow renders Markdown with the colors that Noctalia writes to
# ~/.config/glow/noctalia.json. glow does not expand ~ or variables in a style
# path from its own configuration, which leaves GLOW_STYLE. Set only once the
# file exists, as glow refuses to start when the style is missing.
set -l glow_style $HOME/.config/glow/noctalia.json
set -q XDG_CONFIG_HOME[1] && set glow_style $XDG_CONFIG_HOME/glow/noctalia.json
test -f $glow_style && set -gx GLOW_STYLE $glow_style
