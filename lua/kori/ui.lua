local M = {}

local config = require("kori.config")
local marks = require("kori.marks")

local function display(path)
  local root = config.get().root
  if path:sub(1, #root) == root then
    return path:sub(#root + 2)
  end
  return vim.fn.fnamemodify(path, ":~")
end

function M.notify(path, ranges)
  local cfg = config.get()
  if not cfg.notify then
    return
  end
  local added, removed = 0, 0
  for _, range in ipairs(ranges) do
    added = added + range.added
    removed = removed + range.removed
  end
  local where = #ranges == 1 and ("line " .. ranges[1].first) or (#ranges .. " places")
  vim.notify(
    ("kori changed %s (%s, +%d -%d)"):format(display(path), where, added, removed),
    vim.log.levels.INFO
  )
end

local peek_win

function M.close_peek()
  if peek_win and vim.api.nvim_win_is_valid(peek_win) then
    vim.api.nvim_win_close(peek_win, true)
  end
  peek_win = nil
end

function M.peek(path, ranges)
  M.close_peek()
  local lines = vim.fn.filereadable(path) == 1 and vim.fn.readfile(path) or {}
  if #lines == 0 or #ranges == 0 then
    return
  end
  local first = ranges[1].first
  local from = math.max(1, first - 3)
  local to = math.min(#lines, ranges[#ranges].last + 3)
  local body = {}
  for i = from, to do
    local marked = false
    for _, range in ipairs(ranges) do
      if i >= range.first and i <= range.last then
        marked = true
        break
      end
    end
    body[#body + 1] = ("%s%5d  %s"):format(marked and "\u{258e}" or " ", i, lines[i])
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, body)
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
  vim.api.nvim_set_option_value("filetype", "kori", { buf = buf })
  local width = 0
  for _, line in ipairs(body) do
    width = math.max(width, vim.fn.strdisplaywidth(line))
  end
  width = math.min(width + 2, math.max(20, vim.o.columns - 8))
  local height = math.min(#body, math.max(5, vim.o.lines - 6))
  peek_win = vim.api.nvim_open_win(buf, false, {
    relative = "editor",
    anchor = "NE",
    row = 2,
    col = vim.o.columns - 3,
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = " " .. display(path) .. " ",
    title_pos = "left",
    focusable = false,
  })
  vim.defer_fn(M.close_peek, 4000)
end

local function busy()
  local mode = vim.api.nvim_get_mode().mode
  return mode ~= "n"
end

function M.open(path, ranges, buf)
  if #ranges == 0 then
    return false
  end
  if busy() then
    return false
  end
  if not buf then
    local current = vim.api.nvim_get_current_buf()
    if vim.api.nvim_get_option_value("modified", { buf = current }) and not vim.o.hidden then
      return false
    end
  end
  if buf and vim.api.nvim_get_option_value("modified", { buf = buf }) then
    return false
  end
  local target = buf
  if target then
    local wins = vim.fn.win_findbuf(target)
    if #wins > 0 then
      vim.api.nvim_set_current_win(wins[1])
    else
      vim.cmd("keepalt split " .. vim.fn.fnameescape(path))
    end
  else
    vim.cmd("keepalt split " .. vim.fn.fnameescape(path))
  end
  local line = math.min(ranges[1].first, vim.api.nvim_buf_line_count(0))
  vim.api.nvim_win_set_cursor(0, { line, 0 })
  vim.cmd("normal! zz")
  return true
end

local panel

function M.changes()
  local cfg = config.get()
  local entries = {}
  for _, entry in pairs(marks.state) do
    if entry.ranges and #entry.ranges > 0 then
      entries[#entries + 1] = entry
    end
  end
  if #entries == 0 then
    vim.notify("kori.nvim: no edits recorded", vim.log.levels.INFO)
    return
  end
  table.sort(entries, function(a, b)
    if a.at ~= b.at then
      return a.at > b.at
    end
    return a.path < b.path
  end)

  local lines = {}
  for _, entry in ipairs(entries) do
    local added, removed = 0, 0
    for _, range in ipairs(entry.ranges) do
      added = added + range.added
      removed = removed + range.removed
    end
    lines[#lines + 1] = ("%-52s  %3s  +%-3d -%d"):format(
      display(entry.path),
      #entry.ranges .. "h",
      added,
      removed
    )
  end

  if panel and vim.api.nvim_win_is_valid(panel.win) then
    vim.api.nvim_win_close(panel.win, true)
  end

  vim.cmd("botright " .. cfg.ui.panel_height .. "split")
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(win, buf)
  panel = { win = win, buf = buf, entries = entries }

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
  vim.api.nvim_set_option_value("filetype", "kori", { buf = buf })

  local function open_selected()
    local row = vim.api.nvim_win_get_cursor(win)[1]
    local entry = panel and panel.entries[row]
    if not entry then
      return
    end
    local target = vim.fn.bufadd(entry.path)
    vim.fn.bufload(target)
    vim.api.nvim_win_set_buf(win, target)
    local line = math.min(entry.ranges[1].first, vim.api.nvim_buf_line_count(target))
    vim.api.nvim_win_set_cursor(win, { line, 0 })
    vim.cmd("normal! zz")
  end

  vim.keymap.set("n", "<CR>", open_selected, { buffer = buf, desc = "kori: open file at first edit" })
  vim.keymap.set("n", "q", function()
    if panel and vim.api.nvim_win_is_valid(panel.win) then
      vim.api.nvim_win_close(panel.win, true)
    end
  end, { buffer = buf, desc = "kori: close" })
end

function M.status()
  local entries = 0
  local ranges = 0
  local recent = false
  local now = os.time()
  for _, entry in pairs(marks.state) do
    if #entry.ranges > 0 then
      entries = entries + 1
      ranges = ranges + #entry.ranges
      if now - entry.at <= 2 then
        recent = true
      end
    end
  end
  if entries == 0 then
    return ""
  end
  local dot = recent and "\u{25d1}" or "\u{25cf}"
  return ("kori %s %d"):format(dot, ranges)
end

return M
