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
    M.start()
  end, "kori: open chat pane")
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

function M.pane()
  if runtime.pane and vim.api.nvim_buf_is_valid(runtime.pane.buf) then
    local wins = vim.fn.win_findbuf(runtime.pane.buf)
    if #wins > 0 then
      return wins[1]
    end
  end
  runtime.pane = nil
  return nil
end

function M.start(cmd)
  local cfg = config.get()

  local existing = M.pane()
  if existing then
    vim.api.nvim_set_current_win(existing)
    vim.cmd("startinsert")
    return
  end

  local argv = cmd
  if not argv or #argv == 0 then
    argv = { "kori" }
  end

  local parent = vim.api.nvim_get_current_win()
  vim.cmd("botright vsplit")
  vim.cmd("vertical resize " .. cfg.ui.term_width)

  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_win_get_buf(win)
  vim.api.nvim_set_option_value("filetype", "kori", { buf = buf })
  vim.api.nvim_buf_set_name(buf, ("kori://%d"):format(buf))
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })

  local ok, err = pcall(vim.fn.termopen, argv, {
    cwd = cfg.root,
    env = { KORI_NVIM_SPOOL_DIR = spool.dir(cfg) },
  })
  if not ok then
    vim.notify("kori.nvim: could not start kori: " .. tostring(err), vim.log.levels.ERROR)
    vim.api.nvim_win_close(win, true)
    if vim.api.nvim_win_is_valid(parent) then
      vim.api.nvim_set_current_win(parent)
    end
    return
  end

  runtime.pane = { win = win, buf = buf }
  vim.cmd("startinsert")
end

function M._runtime()
  return runtime
end

return M
