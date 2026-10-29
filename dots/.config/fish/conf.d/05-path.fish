# User commands in ~/.local/bin, which the XDG Base Directory specification
# expects in PATH. Runs after 00-profile.fish, which sets PATH for login shells,
# and the niri session takes PATH over from the login shell.
fish_add_path --path ~/.local/bin
