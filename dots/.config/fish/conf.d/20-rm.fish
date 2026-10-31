# rm asks once before removing more than three files or removing recursively.
# A later -f, as in rm -rf, overrides this and removes without asking.
if status is-interactive
    alias rm 'rm -I'
end
