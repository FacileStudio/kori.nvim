local M = {}

local config = require("kori.config")
local spool = require("kori.spool")

local state = { pane = nil }

--- The kori process the pane runs, or nil when there never was one.
--- @return table|nil pane with buf and win
function M.state()
  return state.pane
end

local function pane_windows()
  local pane = state.pane
  if not pane or not vim.api.nvim_buf_is_valid(pane.buf) then
    return {}
  end
  local tab = vim.api.nvim_get_current_tabpage()
  local wins = {}
  for _, win in ipairs(vim.fn.win_findbuf(pane.buf)) do
    if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_tabpage(win) == tab then
      wins[#wins + 1] = win
    end
  end
  return wins
end

local function running(buf)
  local chan = vim.api.nvim_get_option_value("channel", { buf = buf })
  if not chan or chan == 0 then
    return false
  end
  local ok, status = pcall(vim.fn.jobwait, { chan }, 0)
  return ok and status[1] == -1
end

local function widen(cfg)
  if cfg.ui.term_width > 0 then
    vim.cmd("vertical resize " .. cfg.ui.term_width)
  end
end

local function reveal(cfg, buf)
  vim.cmd("botright vsplit")
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  widen(cfg)
  vim.api.nvim_set_current_win(win)
  vim.cmd("startinsert")
  return win
end

local function spawn(cfg, argv)
  vim.cmd("botright vnew")
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_win_get_buf(win)
  vim.api.nvim_set_option_value("bufhidden", "hide", { buf = buf })
  widen(cfg)

  local ok, job = pcall(vim.fn.termopen, argv, {
    cwd = cfg.root,
    env = { KORI_NVIM_SPOOL_DIR = spool.dir(cfg), KORI_IDE = "1" },
  })
  if not ok or not job or job <= 0 then
    pcall(vim.api.nvim_win_close, win, true)
    return nil, ("could not run %s"):format(table.concat(argv, " "))
  end

  vim.api.nvim_set_option_value("filetype", "kori", { buf = buf })
  state.pane = { win = win, buf = buf }
  vim.cmd("startinsert")
  vim.api.nvim_exec_autocmds("User", { pattern = "KoriPaneOpened", data = { buf = buf, win = win } })
  return win
end

local function drop(wins)
  if #wins >= #vim.api.nvim_tabpage_list_wins(0) then
    vim.cmd("botright vnew")
  end
  for _, win in ipairs(wins) do
    pcall(vim.api.nvim_win_close, win, true)
  end
  state.pane = nil
end

--- The window holding the pane, or nil when it is not on screen.
--- @return integer|nil win
function M.pane()
  return pane_windows()[1]
end

--- The window holding the pane in any tab, nil when it is hidden.
---
--- `pane_windows` only looks at the current tab, which is what "is it open"
--- means. Opening a file beside the pane needs it across tabs, so that a follow
--- lands next to the chat rather than in a tab of its own.
--- @return integer|nil win
function M.window()
  local pane = state.pane
  if not pane or not vim.api.nvim_buf_is_valid(pane.buf) then
    return nil
  end
  for _, win in ipairs(vim.fn.win_findbuf(pane.buf)) do
    if vim.api.nvim_win_is_valid(win) then
      return win
    end
  end
  return nil
end

--- Whether the pane is currently on screen.
--- @return boolean
function M.is_open()
  return #pane_windows() > 0
end

--- Close the pane window, leaving kori running. Refuses to close the last one.
--- @return boolean closed
function M.hide()
  local wins = pane_windows()
  if #wins == 0 then
    return false
  end
  if #wins >= #vim.api.nvim_tabpage_list_wins(0) then
    vim.notify("kori.nvim: refusing to close the last window", vim.log.levels.WARN)
    return false
  end
  for _, win in ipairs(wins) do
    pcall(vim.api.nvim_win_close, win, true)
  end
  vim.api.nvim_exec_autocmds("User", { pattern = "KoriPaneClosed" })
  return true
end

--- Open the chat pane, reusing a live kori rather than starting a second one.
--- @param cmd table|nil command and arguments, defaulting to kori
--- @return boolean opened
function M.start(cmd)
  local cfg = config.get()

  local wins = pane_windows()
  if #wins > 0 and running(state.pane.buf) then
    vim.api.nvim_set_current_win(wins[1])
    vim.cmd("startinsert")
    return true
  end

  if #wins > 0 then
    drop(wins)
  end

  local buf = state.pane and state.pane.buf
  if buf and vim.api.nvim_buf_is_valid(buf) then
    if running(buf) then
      reveal(cfg, buf)
      return true
    end
    state.pane = nil
  end

  local argv = cmd
  if not argv or #argv == 0 then
    argv = { "kori" }
  end

  local _, err = spawn(cfg, argv)
  if err then
    vim.notify("kori.nvim: " .. err, vim.log.levels.ERROR)
    return false
  end
  return true
end

--- Open the pane if it is closed, close it if it is open.
--- @param cmd table|nil command and arguments, defaulting to kori
--- @return boolean open afterwards
function M.toggle(cmd)
  if M.is_open() then
    M.hide()
    return false
  end
  M.start(cmd)
  return M.is_open()
end

return M