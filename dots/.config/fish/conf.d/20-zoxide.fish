# zoxide: z jumps to a frequently used directory, zi picks one with fzf. The
# fzf colors come from FZF_DEFAULT_OPTS_FILE, set in 10-fzf.fish.
if status is-interactive
    zoxide init fish | source
end

set -gx _ZO_FZF_OPTS (string join ' ' -- \
    --layout=reverse \
    --info=inline \
    --height=80% \
    --multi \
    "--preview='eza -hl --git --color=always --icons {2..}'" \
    --preview-window=right,border-sharp \
    "--bind='ctrl-space:toggle'" \
    "--bind='tab:down'" \
    "--bind='btab:up'" \
    "--bind='change:top'" \
    "--bind='?:toggle-preview'")
