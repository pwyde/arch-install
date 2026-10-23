-- The noctalia colorscheme, which Noctalia's lazyvim template renders to
-- colors/noctalia.lua and reloads in running sessions on every palette
-- change. Until Noctalia has written it, LazyVim's tokyonight is used.
return {
    {
        "LazyVim/LazyVim",
        opts = {
            colorscheme = function()
                local ok = pcall(function() vim.cmd.colorscheme("noctalia") end)
                if not ok then
                    vim.cmd.colorscheme("tokyonight")
                end
            end,
        },
    },
}
