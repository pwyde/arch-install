# ls replacements with eza: human-readable binary sizes, a header row,
# directories first, Git status and icons.
if status is-interactive
    set -l eza 'eza -hb --group-directories-first --git --icons=auto'
    alias ls "$eza"
    alias la "$eza -la"
    alias ll "$eza -l"
    alias ldot "$eza -ld .*"
    alias lD "$eza -lD"
    alias lDD "$eza -lDa"
    alias lsd "$eza -d"
    alias lsdl "$eza -dl"
    alias lS "$eza -l -ssize"
    alias lT "$eza -l -snewest"
end
