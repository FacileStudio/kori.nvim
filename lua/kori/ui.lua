local M = {}

local config = require("kori.config")
local marks = require("kori.marks")
local notify = require("kori.notify")
local pane = require("kori.pane")

local function display(path)
  local root = config.get().root
  if path:sub(1, #root) == root then
    return path:sub(#root + 2)
  end
  return vim.fn.fnamemodify(path, ":~")
end

--- Queue kori's edit notification for a path, coalesced by `kori.notify`.
--- @param path string absolute path of the file kori edited
--- @param ranges table list of `{ first, last, added, removed }` from one edit event
--- @return boolean true when the edit was queued
function M.notify(path, ranges)
  return notify.record(path, ranges)
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

--- Whether moving focus now would interrupt what you are typing.
---
--- A terminal in insert mode reports "t", and that is where the chat pane
--- lives, so this is what keeps a follow from stealing the cursor out of it.
--- Overridable, because a headless Neovim never leaves normal mode and the
--- test suite has to pin the behaviour without a UI.
--- @return boolean
function M.typing()
  return vim.api.nvim_get_mode().mode ~= "n"
end

--- The window a follow opened last, and the buffer it was given.
local follow = { win = nil, buf = nil }

local function load(path, buf)
  if buf then
    return buf
  end
  local created = vim.fn.bufadd(path)
  vim.fn.bufload(created)
  return created
end

local function usable(win)
  return win
    and vim.api.nvim_win_is_valid(win)
    and vim.api.nvim_win_get_config(win).relative == ""
end

--- Take back the window the previous follow opened, when it is still showing
--- what was put there. A window the user navigated elsewhere is left alone, so
--- this never clobbers a file they moved to themselves. While typing, only a
--- window in the current tab counts: anything else would be invisible.
--- @param buffer integer the buffer to show
--- @param typing boolean whether the user is typing right now
--- @return integer|nil win
local function reuse(buffer, typing)
  if not usable(follow.win) or vim.api.nvim_win_get_buf(follow.win) ~= follow.buf then
    return nil
  end
  if vim.api.nvim_get_option_value("modified", { buf = follow.buf }) then
    return nil
  end
  if typing and vim.api.nvim_win_get_tabpage(follow.win) ~= vim.api.nvim_get_current_tabpage() then
    return nil
  end
  vim.api.nvim_win_set_buf(follow.win, buffer)
  follow.buf = buffer
  return follow.win
end

--- The window the pane sits next to, so the new one lands between it and the pane.
--- @param tab integer tabpage holding the pane
--- @param pane integer window id of the pane
--- @return integer|nil win
local function neighbour(tab, pane)
  local found, column
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
    if win ~= pane and usable(win) then
      local col = vim.api.nvim_win_get_position(win)[2]
      if not column or col > column then
        found, column = win, col
      end
    end
  end
  return found
end

--- Open the file in a window of the pane's tab, keeping the pane where it is.
---
--- 'equalalways' is on by default and equalizes every window in the tab as soon
--- as one is opened. The pane then takes its width back from its left
--- neighbour, which is the window just opened, so the file ends up squeezed
--- into the leftovers. Both widths are therefore set explicitly afterwards: the
--- pane to `term_width`, the new window to what a plain split would have given
--- it, with the window that was split absorbing the difference.
--- @param pane_win integer window id of the pane
--- @param buffer integer the buffer to show
--- @param focus boolean whether to move the cursor into the new window
--- @return integer win
local function beside(pane_win, buffer, focus)
  local cfg = config.get()
  local anchor = neighbour(vim.api.nvim_win_get_tabpage(pane_win), pane_win)
  local before = anchor and vim.api.nvim_win_get_width(anchor) or 0
  local win
  if anchor then
    win = vim.api.nvim_open_win(buffer, focus, { split = "right", win = anchor })
  else
    win = vim.api.nvim_open_win(buffer, focus, { split = "left", win = pane_win })
  end
  if cfg.ui.term_width > 0 then
    pcall(vim.api.nvim_win_set_width, pane_win, cfg.ui.term_width)
    if anchor then
      local wanted = math.max(1, math.floor(before / 2))
      local delta = wanted - vim.api.nvim_win_get_width(win)
      if delta ~= 0 then
        pcall(vim.api.nvim_win_set_width, anchor, vim.api.nvim_win_get_width(anchor) - delta)
      end
    end
  end
  follow.win, follow.buf = win, buffer
  return win
end

--- Put a file on screen: beside the chat pane when there is one, in its own tab
--- otherwise. Never splits a window you are typing in.
--- @param path string absolute path of the file
--- @param buf integer|nil the loaded buffer for it, when there is one
--- @param typing boolean whether the user is typing right now
--- @return integer|nil win the window showing the file, nil when it was refused
local function place(path, buf, typing)
  local buffer = load(path, buf)
  local win = reuse(buffer, typing)
  if win then
    return win
  end

  local pane_win = pane.window()
  if pane_win then
    if typing then
      if vim.api.nvim_win_get_tabpage(pane_win) ~= vim.api.nvim_get_current_tabpage() then
        return nil
      end
      return beside(pane_win, buffer, false)
    end
    vim.api.nvim_set_current_tabpage(vim.api.nvim_win_get_tabpage(pane_win))
    return beside(pane_win, buffer, true)
  end

  if typing then
    return nil
  end
  if buf then
    vim.cmd("tab sbuffer " .. buffer)
  else
    vim.cmd("tabedit " .. vim.fn.fnameescape(path))
  end
  return vim.api.nvim_get_current_win()
end

function M.open(path, ranges, buf)
  if #ranges == 0 then
    return false
  end
  if buf and vim.api.nvim_get_option_value("modified", { buf = buf }) then
    return false
  end

  local typing = M.typing()
  local win = buf and vim.fn.win_findbuf(buf)[1] or nil
  if not win then
    win = place(path, buf, typing)
  end
  if not win or (typing and win == vim.api.nvim_get_current_win()) then
    return false
  end

  local target = vim.api.nvim_win_get_buf(win)
  local entry = marks.of(path)
  if entry and not vim.api.nvim_get_option_value("modified", { buf = target }) then
    marks.apply(target, entry)
  end
  local line = math.min(ranges[1].first, vim.api.nvim_buf_line_count(target))
  vim.api.nvim_win_set_cursor(win, { line, 0 })
  vim.api.nvim_win_call(win, function()
    vim.cmd("normal! zz")
  end)
  if not typing then
    vim.api.nvim_set_current_win(win)
  end
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
