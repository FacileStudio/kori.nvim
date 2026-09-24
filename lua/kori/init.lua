local M = {}

local config = require("kori.config")
local spool = require("kori.spool")
local edit = require("kori.edit")
local marks = require("kori.marks")
local ui = require("kori.ui")

local runtime = { spool = nil, autocmds = nil }

local function apply_marks_of_current_buffer()
  local name = vim.api.nvim_buf_get_name(0)
  if name == "" then
    return
  end
  local path = vim.fn.fnamemodify(name, ":p")
  local entry = marks.state[path]
  if entry and not vim.api.nvim_get_option_value("modified", { buf = 0 }) then
    marks.apply(0, entry)
  end
end

local function follow(path, ranges)
  local cfg = config.get()
  if cfg.follow == "off" then
    return
  end
  if cfg.follow == "peek" then
    ui.peek(path, ranges)
    return
  end
  local buf = nil
  for _, candidate in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(candidate) and vim.api.nvim_buf_get_name(candidate) ~= "" then
      if vim.fn.fnamemodify(vim.api.nvim_buf_get_name(candidate), ":p") == path then
        buf = candidate
        break
      end
    end
  end
  ui.open(path, ranges, buf)
end

local function handle(result)
  if not result then
    return
  end
  if result.stale then
    vim.notify(
      ("kori changed %s, but the buffer has unsaved changes"):format(vim.fn.fnamemodify(result.path, ":t")),
      vim.log.levels.WARN
    )
    return
  end
  ui.notify(result.path, result.ranges)
  follow(result.path, result.ranges)
  vim.api.nvim_exec_autocmds("User", { pattern = "KoriEdit", data = result })
end

local function on_event(payload)
  local result = edit.on_event(payload)
  if result then
    vim.schedule(function()
      handle(result)
    end)
  end
end

local function keymaps(cfg)
  if not cfg.keymaps then
    return
  end
  local function map(lhs, rhs, desc)
    if vim.fn.maparg(lhs, "n") ~= "" then
      return
    end
    vim.keymap.set("n", lhs, rhs, { desc = desc })
  end
  map("]r", function()
    if not marks.jump(0, 1) then
      vim.notify("kori.nvim: no kori edits in this buffer", vim.log.levels.INFO)
    end
  end, "kori: next edit")
  map("[r", function()
    if not marks.jump(0, -1) then
      vim.notify("kori.nvim: no kori edits in this buffer", vim.log.levels.INFO)
    end
  end, "kori: previous edit")
  map("<leader>ko", function()
    M.toggle()
  end, "kori: toggle chat pane")
  map("<leader>kc", function()
    ui.changes()
  end, "kori: changes")
  map("<leader>kp", function()
    local path = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":p")
    local entry = marks.of(path)
    if not entry or #entry.ranges == 0 then
      vim.notify("kori.nvim: no kori edits in this buffer", vim.log.levels.INFO)
      return
    end
    ui.peek(path, entry.ranges)
  end, "kori: peek last edit")
end

function M.setup(opts)
  local cfg = config.setup(opts)

  marks.setup(cfg.marks)

  if runtime.spool then
    spool.stop(runtime.spool)
  end
  if runtime.autocmds then
    for _, id in ipairs(runtime.autocmds) do
      pcall(vim.api.nvim_del_autocmd, id)
    end
  end
  runtime.autocmds = {}

  keymaps(cfg)

  runtime.autocmds[#runtime.autocmds + 1] = vim.api.nvim_create_autocmd("BufReadPost", {
    callback = apply_marks_of_current_buffer,
    desc = "kori: reapply edit marks",
  })

  if not cfg.enabled then
    return cfg
  end

  local state, err = spool.start(cfg, on_event)
  if err then
    vim.notify("kori.nvim: " .. err, vim.log.levels.ERROR)
    return cfg
  end
  runtime.spool = state
  return cfg
end

function M.changes()
  ui.changes()
end

function M.clear()
  marks.clear()
  edit.forget_all()
end

function M.statusline()
  return ui.status()
end

local function pane_windows()
  local pane = runtime.pane
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

local function pane_running(buf)
  local chan = vim.api.nvim_get_option_value("channel", { buf = buf })
  if not chan or chan == 0 then
    return false
  end
  local ok, status = pcall(vim.fn.jobwait, { chan }, 0)
  return ok and status[1] == -1
end

function M.pane()
  return pane_windows()[1]
end

function M.is_open()
  return #pane_windows() > 0
end

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
  return true
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
    env = { KORI_NVIM_SPOOL_DIR = spool.dir(cfg) },
  })
  if not ok or not job or job <= 0 then
    pcall(vim.api.nvim_win_close, win, true)
    return nil, ("could not run %s"):format(table.concat(argv, " "))
  end

  vim.api.nvim_set_option_value("filetype", "kori", { buf = buf })
  runtime.pane = { win = win, buf = buf }
  vim.cmd("startinsert")
  return win
end

function M.start(cmd)
  local cfg = config.get()

  local wins = pane_windows()
  if #wins > 0 and pane_running(runtime.pane.buf) then
    vim.api.nvim_set_current_win(wins[1])
    vim.cmd("startinsert")
    return true
  end

  if #wins > 0 then
    if #wins >= #vim.api.nvim_tabpage_list_wins(0) then
      vim.cmd("botright vnew")
    end
    for _, win in ipairs(wins) do
      pcall(vim.api.nvim_win_close, win, true)
    end
    runtime.pane = nil
  end

  local buf = runtime.pane and runtime.pane.buf
  if buf and vim.api.nvim_buf_is_valid(buf) then
    if pane_running(buf) then
      reveal(cfg, buf)
      return true
    end
    runtime.pane = nil
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

function M.toggle(cmd)
  if M.is_open() then
    M.hide()
    return false
  end
  M.start(cmd)
  return M.is_open()
end

function M._runtime()
  return runtime
end

return M
