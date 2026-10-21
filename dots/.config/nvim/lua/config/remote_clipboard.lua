-- Clipboard for Neovim inside tmux or over SSH. Copies reach the local Wayland
-- clipboard and the attached terminals through OSC 52. Pastes read Wayland or
-- tmux's buffer, falling back to this Neovim's last copy. The terminal is
-- never queried with OSC 52: support for writes does not imply permission to
-- read, and an unanswered query blocks an ordinary paste for ten seconds.
-- Text from the host without a readable clipboard needs a terminal paste.
--
-- vim.g.remote_clipboard_osc52 = false turns off OSC 52 and tmux, and
-- vim.g.remote_clipboard_sync = false keeps the unnamed register separate
-- from the clipboard. Both are set before setup() runs.
local M = {}

function M.setup()
  local in_tmux = vim.env.TMUX ~= nil
  local in_ssh = vim.env.SSH_TTY ~= nil or vim.env.SSH_CONNECTION ~= nil

  if not (in_tmux or in_ssh) then
    return
  end

  local osc52 = require("vim.ui.clipboard.osc52")
  local has_wayland = vim.env.WAYLAND_DISPLAY ~= nil
    and vim.fn.executable("wl-copy") == 1
    and vim.fn.executable("wl-paste") == 1

  local has_tmux = in_tmux and vim.fn.executable("tmux") == 1
  local last_copy = {}

  local function tmux_export_enabled()
    local setting = vim.fn.systemlist({ "tmux", "show-options", "-sv", "set-clipboard" })
    return vim.v.shell_error == 0 and (setting[1] == "on" or setting[1] == "external")
  end

  local function copy(register)
    local emit = osc52.copy(register)

    return function(lines, regtype)
      last_copy[register] = { vim.deepcopy(lines), regtype }

      if has_wayland then
        local cmd = { "wl-copy", "--sensitive", "--type", "text/plain" }
        if register == "*" then
          cmd[#cmd + 1] = "--primary"
        end
        vim.fn.system(cmd, lines)
      end

      if vim.g.remote_clipboard_osc52 ~= false then
        if has_tmux and register == "+" then
          -- tmux ignores empty loads. The current buffer's name is recorded
          -- instead: every Neovim instance reads an empty clipboard until a
          -- new buffer arrives, and tmux's clipboard history stays intact.
          if #lines == 0 or (#lines == 1 and lines[1] == "") then
            vim.fn.system({ "tmux", "set-option", "-sF", "@nvim-cleared-buffer", "#{buffer_name}" })
            return
          end
          -- tmux emits the OSC 52 sequence itself, avoiding the payload size
          -- limit of its input parser. An explicit -w bypasses set-clipboard
          -- and is therefore only passed when that setting allows exports.
          local cmd = { "tmux", "load-buffer" }
          if tmux_export_enabled() then
            cmd[#cmd + 1] = "-w"
          end
          cmd[#cmd + 1] = "-"
          vim.fn.system(cmd, lines)
          if vim.v.shell_error == 0 then
            return
          end
        end
        emit(lines)
      end
    end
  end

  local function paste(register)
    return function()
      local cmd
      -- tmux's buffer is shared between the Neovim instances on the server.
      -- Over SSH, it takes precedence over the remote machine's unrelated
      -- graphical clipboard.
      if has_tmux and register == "+" and (in_ssh or not has_wayland)
        and vim.g.remote_clipboard_osc52 ~= false then
        local buffers = vim.fn.systemlist({ "tmux", "display-message", "-p",
          "#{buffer_name}\n#{@nvim-cleared-buffer}" })
        if vim.v.shell_error ~= 0 then
          return vim.deepcopy(last_copy[register] or { {}, "v" })
        end
        if not buffers[1] or buffers[1] == "" or buffers[1] == buffers[2] then
          return { {}, "v" }
        end
        -- The buffer checked above is read by name, which keeps a concurrent
        -- copy from changing the payload in between.
        cmd = { "tmux", "save-buffer", "-b", buffers[1], "-" }
      elseif has_wayland then
        cmd = { "wl-paste", "--no-newline" }
        if register == "*" then
          cmd[#cmd + 1] = "--primary"
        end
      end

      if cmd then
        local lines = vim.fn.systemlist(cmd, "", 1)
        if vim.v.shell_error == 0 then
          -- An empty clipboard is valid; only a failed read falls back.
          if last_copy[register] and vim.deep_equal(lines, last_copy[register][1]) then
            return vim.deepcopy(last_copy[register])
          end
          return lines
        end
      end

      return vim.deepcopy(last_copy[register] or { {}, "v" })
    end
  end

  vim.g.clipboard = {
    name = "RemoteClipboard",
    copy = { ["+"] = copy("+"), ["*"] = copy("*") },
    paste = { ["+"] = paste("+"), ["*"] = paste("*") },
    cache_enabled = 0,
  }

  -- LazyVim clears this over SSH.
  if vim.g.remote_clipboard_sync ~= false then
    vim.opt.clipboard:append("unnamedplus")
  end
end

return M
