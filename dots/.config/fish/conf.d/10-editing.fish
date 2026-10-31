if status is-interactive
    # Ctrl+Backspace removes one path component rather than the whole path.
    # Terminals without the kitty keyboard protocol send it as ctrl-h.
    bind ctrl-backspace backward-kill-path-component
    bind ctrl-h backward-kill-path-component
    bind ctrl-delete kill-word

    # Ctrl+Left and Ctrl+Right stop inside a path rather than jump over it.
    bind ctrl-left backward-path-component
    bind ctrl-right forward-path-component

    # Commands from other running shells become available straight away,
    # as with share_history in Zsh.
    function __share_history --on-event fish_prompt
        history merge
    end
end
