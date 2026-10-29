# Man pages through batman from bat-extras, with bat's syntax highlighting.
# Replaces the less-based MANPAGER that /etc/profile.d/10-defaults.sh sets.
if command -q batman
    set -gx MANPAGER "env BATMAN_IS_BEING_MANPAGER=yes bash "(command -s batman)
    set -gx MANROFFOPT -c
end

# Help output in color: --help expands to pipe the text through bat.
if status is-interactive
    abbr --add --position anywhere -- --help '--help 2>&1 | bat --language=help --style=plain'
end
