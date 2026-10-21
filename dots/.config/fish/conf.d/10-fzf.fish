# fzf reads its default options from FZF_DEFAULT_OPTS_FILE: the colors that
# Noctalia renders into ~/.config/fzf/colors. Set only once the file exists, as
# fzf refuses to start when the file is missing.
set -l fzf_colors $HOME/.config/fzf/colors
set -q XDG_CONFIG_HOME[1]; and set fzf_colors $XDG_CONFIG_HOME/fzf/colors
test -f $fzf_colors; and set -gx FZF_DEFAULT_OPTS_FILE $fzf_colors

# Options added to the colors. fzf runs the preview command through $SHELL,
# which is fish. Ctrl+Space selects, Tab and Shift+Tab move, ? toggles the
# preview, Ctrl+A selects all, Ctrl+E opens the selection in vim and Ctrl+V
# in VS Code.
set -gx FZF_DEFAULT_OPTS (string join ' ' -- \
    --layout=reverse \
    --info=inline \
    --height=80% \
    --multi \
    "--preview='if test -f {}; bat --style=numbers --color=always --line-range=:200 {}; else if test -d {}; eza --tree --level=2 --color=always --icons=always {}; else; echo {}; end'" \
    --preview-window=right,border-sharp \
    "--bind='ctrl-space:toggle'" \
    "--bind='tab:down'" \
    "--bind='btab:up'" \
    "--bind='change:top'" \
    "--bind='?:toggle-preview'" \
    "--bind='ctrl-a:select-all'" \
    "--bind='ctrl-e:execute(vim {+} >/dev/tty)'" \
    "--bind='ctrl-v:execute(code {+})'")

# Key bindings: Ctrl+R searches the history, Ctrl+T inserts files and Alt+C
# changes to a directory.
if status is-interactive
    fzf --fish | source
end
