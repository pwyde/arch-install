# Fish does not read /etc/profile, where /etc/profile.d sets the environment of
# login shells: the XDG Base Directories, the default editor and pager, and the
# settings of packages such as Flatpak. Login shells therefore run it in bash
# and take over the result. That covers SSH and TTY logins, and the niri
# session, which niri-session starts through the login shell.
if status is-login
    bash -c 'source /etc/profile >/dev/null 2>&1; env -0' | while read -lz entry
        set -l pair (string split -m 1 -- = $entry)
        # Variables that describe the bash process rather than the session.
        switch $pair[1]
            case PWD OLDPWD SHLVL _
                continue
        end
        set -gx $pair[1] $pair[2]
    end
end
