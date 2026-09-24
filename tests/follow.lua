-- follow = "open" must show the file without ever hiding the chat or stealing the
-- cursor you are typing with. A file already on screen only moves the cursor;
-- with the pane open any other file lands in a window beside the pane, reusing
-- that window rather than stacking columns; with the pane closed it opens in its
-- own tab, as before, and only when you are not typing.
-- Run with: nvim --headless -u NONE -l tests/follow.lua

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(root)

local failures = 0
local checks = 0

local function pass(label)
  checks = checks + 1
  io.write(("ok   %s\n"):format(label))
end

local function fail(label, detail)
  checks = checks + 1
  failures = failures + 1
  io.write(("FAIL %s\n     %s\n"):format(label, detail))
end

local function eq(got, want, label)
  if got == want then
    pass(label)
  else
    fail(label, ("got %s, want %s"):format(vim.inspect(got), vim.inspect(want)))
  end
end

vim.o.columns = 200
vim.o.lines = 50

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")

local config = require("kori.config")
config.setup({ root = tmp, spool_dir = tmp .. "/spool", follow = "open", keymaps = false })
local kori = require("kori")
local ui = require("kori.ui")
local accept = require("kori.accept")

local ranges = { { first = 2, last = 2, added = 1, removed = 1 } }

local typing = false
ui.typing = function()
  return typing
end

local function tabs()
  return #vim.api.nvim_list_tabpages()
end

local function windows()
  return #vim.api.nvim_tabpage_list_wins(0)
end

local function cursor_line()
  return vim.api.nvim_win_get_cursor(0)[1]
end

local function name_of(buf)
  return vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":t")
end

local function buffer_for(path)
  return accept.buffer_for(path)
end

local function window_of(path)
  local buf = buffer_for(path)
  return buf and vim.fn.win_findbuf(buf)[1] or nil
end

local function write(path, lines)
  vim.fn.writefile(lines, path)
  return path
end

local function reset()
  vim.cmd("silent! tabonly")
  local wins = vim.api.nvim_tabpage_list_wins(0)
  for i = #wins, 2, -1 do
    pcall(vim.api.nvim_win_close, wins[i], true)
  end
  vim.cmd("enew")
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = 0 })
end

local one = write(tmp .. "/one.lua", { "local a = 1", "local b = 2", "local c = 3" })
local two = write(tmp .. "/two.lua", { "local x = 1", "local y = 2", "local z = 3" })

io.write("\n-- the edited file is the one already open\n")

reset()
vim.cmd("edit " .. vim.fn.fnameescape(one))
vim.api.nvim_win_set_cursor(0, { 1, 0 })
local before_tabs = tabs()
local before_windows = windows()

eq(ui.open(one, ranges, buffer_for(one)), true, "the edit is followed")
eq(tabs(), before_tabs, "no tab was opened for the file already on screen")
eq(windows(), before_windows, "no split was created")
eq(name_of(vim.api.nvim_get_current_buf()), "one.lua", "the current buffer is still the edited file")
eq(cursor_line(), 2, "the cursor moved to the first changed line")

io.write("\n-- no pane: another file opens in its own tab\n")

reset()
vim.cmd("edit " .. vim.fn.fnameescape(one))
eq(ui.open(two, ranges, buffer_for(two)), true, "the edit is followed")
eq(tabs(), 2, "the file opened in a new tab")
eq(windows(), 1, "the new tab holds a single window")
eq(name_of(vim.api.nvim_get_current_buf()), "two.lua", "the new tab shows the edited file")
eq(cursor_line(), 2, "the cursor landed on the first changed line")

io.write("\n-- no pane: a file already open in another tab is reached, not duplicated\n")

vim.cmd("tabnext 1")
eq(tabs(), 2, "we are back in the first tab")
eq(name_of(vim.api.nvim_get_current_buf()), "one.lua", "the first tab shows the other file")

eq(ui.open(two, ranges, buffer_for(two)), true, "the edit is followed again")
eq(tabs(), 2, "no second tab was opened for the same file")
eq(windows(), 1, "no split was created")
eq(vim.fn.tabpagenr(), 2, "the tab holding the file was focused")
eq(cursor_line(), 2, "the cursor is on the changed line")

io.write("\n-- no pane: nothing opens while you are typing\n")

reset()
typing = true
local quiet_tabs = tabs()
eq(ui.open(one, ranges, buffer_for(one)), false, "a follow while typing is refused")
eq(tabs(), quiet_tabs, "the refusal opened nothing")
typing = false

io.write("\n-- a buffer with unsaved changes is still refused\n")

reset()
vim.cmd("edit " .. vim.fn.fnameescape(two))
vim.api.nvim_set_option_value("modified", true, { buf = 0 })
eq(ui.open(two, ranges, buffer_for(two)), false, "a modified buffer is not followed")
eq(tabs(), 1, "the refusal opened nothing")
vim.api.nvim_set_option_value("modified", false, { buf = 0 })

io.write("\n-- the followed file carries its marks\n")

reset()
local six = write(tmp .. "/six.lua", { "local v = 1", "local w = 2" })
require("kori.marks").record(six, ranges, { tool = "edit_file", old = "local w = 1", new = "local w = 2" })
eq(ui.open(six, ranges, buffer_for(six)), true, "the edit is followed")
local namespace = vim.api.nvim_create_namespace("kori.nvim")
eq(
  #vim.api.nvim_buf_get_extmarks(accept.buffer_for(six), namespace, 0, -1, {}),
  1,
  "the changed line is marked on the buffer that was just shown"
)

io.write("\n-- the pane is open, and the file is new\n")

reset()
eq(kori.toggle({ "sh", "-c", "sleep 60" }), true, "the pane opened from a scratch buffer")
local pane_win = kori.pane()
local pane_width = vim.api.nvim_win_get_width(pane_win)
eq(pane_width, 80, "the pane took the configured width")

local three = write(tmp .. "/three.lua", { "local p = 1", "local q = 2" })
local follow_tabs = tabs()
local follow_windows = windows()

typing = true
vim.api.nvim_set_current_win(pane_win)
eq(ui.open(three, ranges, buffer_for(three)), true, "the edit is followed from the pane")
eq(tabs(), follow_tabs, "no tab was opened")
eq(windows(), follow_windows + 1, "one window was added beside the pane")
eq(vim.api.nvim_win_get_width(pane_win), pane_width, "the chat pane kept its width")
eq(kori.is_open(), true, "the pane is still open")
eq(vim.api.nvim_get_current_win(), pane_win, "the cursor stayed in the pane while typing")
eq(window_of(three) ~= pane_win, true, "the file got a window of its own")
eq(vim.api.nvim_win_get_cursor(window_of(three))[1], 2, "the file is scrolled to the first change")
eq(
  vim.api.nvim_get_option_value("buftype", { buf = vim.api.nvim_win_get_buf(pane_win) }),
  "terminal",
  "the pane is still a terminal"
)
typing = false

io.write("\n-- a second file reuses that window instead of stacking columns\n")

local four = write(tmp .. "/four.lua", { "local r = 1", "local s = 2" })
local stacked = tabs()
local follow_win = window_of(three)
eq(ui.open(four, ranges, buffer_for(four)), true, "the second edit is followed")
eq(windows(), follow_windows + 1, "still one window beside the pane")
eq(tabs(), stacked, "still no tab")
eq(name_of(vim.api.nvim_get_current_buf()), "four.lua", "the window switched to the new file")
eq(vim.api.nvim_get_current_win(), follow_win, "the reused window is the one beside the pane")

io.write("\n-- a window you navigated elsewhere is not taken back\n")

vim.cmd("edit " .. vim.fn.fnameescape(one))
eq(name_of(vim.api.nvim_get_current_buf()), "one.lua", "the follow window now shows another file")
eq(ui.open(two, ranges, buffer_for(two)), true, "the next edit is followed")
eq(vim.api.nvim_get_current_win() ~= follow_win, true, "a fresh window was used rather than the one moved by hand")
eq(windows(), follow_windows + 2, "the hand-moved window was left where it was")
eq(name_of(vim.api.nvim_get_current_buf()), "two.lua", "the edited file is on screen")

io.write("\n-- the pane is in another tab\n")

vim.cmd("tabnew")
eq(kori.pane(), nil, "the pane is not in this tab")
local elsewhere = windows()
local five = write(tmp .. "/five.lua", { "local t = 1", "local u = 2" })

typing = true
eq(ui.open(five, ranges, buffer_for(five)), false, "nothing opens while typing in another tab")
eq(windows(), elsewhere, "that refusal added no window")
typing = false

eq(ui.open(five, ranges, buffer_for(five)), true, "it opens once you are not typing")
eq(name_of(vim.api.nvim_get_current_buf()), "five.lua", "the edited file is on screen")
eq(kori.is_open(), true, "the tab holding the pane was reached, and the chat is there")

io.write(("\n%d checks, %d failures\n"):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
