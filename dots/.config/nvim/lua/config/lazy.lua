local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not (vim.uv or vim.loop).fs_stat(lazypath) then
    local lazyrepo = "https://github.com/folke/lazy.nvim.git"
    local out = vim.fn.system({ "git", "clone", "--filter=blob:none", "--branch=stable", lazyrepo, lazypath })
    if vim.v.shell_error ~= 0 then
        vim.api.nvim_echo({
            { "Failed to clone lazy.nvim:\n", "ErrorMsg" },
            { out, "WarningMsg" },
            { "\nPress any key to exit..." },
        }, true, {})
        vim.fn.getchar()
        os.exit(1)
    end
end
vim.opt.rtp:prepend(lazypath)

require("lazy").setup({
    spec = {
        -- LazyVim and its plugins.
        { "LazyVim/LazyVim", import = "lazyvim.plugins" },
        -- Additions and overrides from lua/plugins.
        { import = "plugins" },
    },
    defaults = {
        -- Only LazyVim's plugins are lazy-loaded; the ones in lua/plugins load
        -- at startup unless their spec says otherwise.
        lazy = false,
        -- The latest Git commit of each plugin. Many plugins with version tags
        -- have outdated releases; version = "*" would use the latest release.
        version = false,
    },
    install = { colorscheme = { "tokyonight", "habamax" } },
    checker = {
        -- Checks for plugin updates in the background, without notifications.
        enabled = true,
        notify = false,
    },
    performance = {
        rtp = {
            -- Built-in runtime plugins that are not loaded.
            disabled_plugins = {
                "gzip",
                -- "matchit",
                -- "matchparen",
                -- "netrwPlugin",
                "tarPlugin",
                "tohtml",
                "tutor",
                "zipPlugin",
            },
        },
    },
})
