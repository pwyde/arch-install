# Interactive sessions only: scripts run through fish skip the prompt setup.
if status is-interactive
    # Starship draws the prompt.
    starship init fish | source
end
