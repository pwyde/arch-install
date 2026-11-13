# The names of the web apps, from the launchers webapp-install created.
function __webapp_remove_names
    set -l data_home $HOME/.local/share
    set -q XDG_DATA_HOME[1] && set data_home $XDG_DATA_HOME
    for file in $data_home/applications/*.desktop
        string match -q -r '^Exec=.*/webapp-launch"? ' <$file || continue
        set -l name (string match -r -g '^Name=(.*)' <$file)
        test -n "$name[1]" && echo $name[1]
    end
end

complete -c webapp-remove -f -a '(__webapp_remove_names)' -d 'Web app'
