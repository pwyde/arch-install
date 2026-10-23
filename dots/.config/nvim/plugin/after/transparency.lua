-- Highlight groups lose their background, letting the terminal background
-- show through, while keeping their other attributes. Applied again after
-- every colorscheme load, including Noctalia's live reloads.
local groups = {
    "Normal",
    "NormalFloat",
    "FloatBorder",
    "Pmenu",
    "Terminal",
    "EndOfBuffer",
    "FoldColumn",
    "Folded",
    "SignColumn",
    "LineNr",
    "CursorLineNr",
    "StatusLine",
    "StatusLineNC",
    "NormalNC",
    "WhichKeyFloat",
    "TelescopeBorder",
    "TelescopeNormal",
    "TelescopePromptBorder",
    "TelescopePromptTitle",
    -- neo-tree
    "NeoTreeNormal",
    "NeoTreeNormalNC",
    "NeoTreeVertSplit",
    "NeoTreeWinSeparator",
    "NeoTreeEndOfBuffer",
    -- nvim-tree
    "NvimTreeNormal",
    "NvimTreeVertSplit",
    "NvimTreeEndOfBuffer",
    -- nvim-notify
    "NotifyINFOBody",
    "NotifyERRORBody",
    "NotifyWARNBody",
    "NotifyTRACEBody",
    "NotifyDEBUGBody",
    "NotifyINFOTitle",
    "NotifyERRORTitle",
    "NotifyWARNTitle",
    "NotifyTRACETitle",
    "NotifyDEBUGTitle",
    "NotifyINFOBorder",
    "NotifyERRORBorder",
    "NotifyWARNBorder",
    "NotifyTRACEBorder",
    "NotifyDEBUGBorder",
    -- The current line as well, leaving its number to mark it.
    "CursorLine",
}

local function make_transparent(name)
    local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
    if ok then
        hl.bg = nil
        vim.api.nvim_set_hl(0, name, hl)
    end
end

local function apply()
    -- The file tree marks its selection with the current line alone and
    -- keeps that line's color.
    local cursorline = vim.api.nvim_get_hl(0, { name = "CursorLine", link = false })
    if cursorline.bg then
        vim.api.nvim_set_hl(0, "NeoTreeCursorLine", { bg = cursorline.bg })
    end

    for _, name in ipairs(groups) do
        make_transparent(name)
    end
end

apply()
vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("transparency", { clear = true }),
    callback = apply,
})
