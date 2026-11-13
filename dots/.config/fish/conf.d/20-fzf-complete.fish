# Tab picks with fzf after cd, with a preview from eza, and after cat, ls and
# the eza aliases, where several entries can be selected with Ctrl+Space. Other
# commands, options and tokens with a variable, glob, brace expansion or command
# substitution keep the normal completion. The list comes from fish's own
# completions.
if status is-interactive
    function __fzf_complete
        set -l tokens (commandline -xpc)
        set -l token (commandline -ct)
        set -l fzf_opts
        switch "$tokens[1]"
            case cd
                set fzf_opts --no-multi \
                    --preview='eza -hl --git --color=always --icons=always (string replace -r "^~" $HOME -- {})'
            case cat ls la ll lD lDD lsd lsdl lS lT
                set fzf_opts --no-preview
            case '*'
                commandline -f complete
                return
        end
        if commandline -P
            or string match -qr -- '[$*{(]' "$token"
            or string match -q -- '-*' "$token"
            commandline -f complete
            return
        end

        # fish lists the entries in natural, case-insensitive order. The token
        # is the query, so every entry of a directory such as "Documents/"
        # matches equally; --tiebreak=index keeps such entries in that order
        # instead of putting the shortest names first.
        set -l picks (complete -C -- "$(commandline -cp)" | string split -f1 \t |
            fzf --select-1 --exit-0 --height=50% --tiebreak=index --query=$token $fzf_opts)
        commandline -f repaint
        set -q picks[1] || return

        # Keeps a leading ~ unquoted, so that fish still expands it.
        set -l escaped (string escape --no-quoted -- $picks | string replace -r '^\\\\~' '~')
        set -l result (string join ' ' -- $escaped)
        # A space ends the argument, except after one directory, which Tab can
        # enter next.
        if set -q picks[2]; or not string match -q -- '*/' $picks[1]
            set result "$result "
        end
        commandline -rt -- $result
    end
    bind tab __fzf_complete
end
