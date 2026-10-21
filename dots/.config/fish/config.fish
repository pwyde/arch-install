# Interactive sessions only: scripts run through fish skip the prompt setup.
if status is-interactive
    # No welcome message when a shell starts.
    set -g fish_greeting

    # Starship draws the prompt.
    starship init fish | source
end
