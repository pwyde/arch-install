-- Options are loaded before lazy.nvim starts, on top of LazyVim's defaults:
-- https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/options.lua
require("config.remote_clipboard").setup()

-- Absolute line numbers, and no formatting on save.
vim.opt.relativenumber = false
vim.g.autoformat = false
