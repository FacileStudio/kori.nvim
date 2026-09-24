-- follow = "open" must never split the view. A file kori edited that is already
-- on screen only moves the cursor; any other file opens in its own tab, and a
-- file already open in another tab is reached by switching to that tab rather
-- than by opening a second copy of it.
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

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")

local config = require("kori.config")
config.setup({ root = tmp, spool_dir = tmp .. "/spool", follow = "open", keymaps = false })
local ui = require("kori.ui")
local accept = require("kori.accept")

local ranges = { { first = 2, last = 2, added = 1, removed = 1 } }

local function tabs()
  return #vim.api.nvim_list_tabpages()
end

local function windows_of(tab)
  return #vim.api.nvim_tabpage_list_wins(tab)
end

local function total_windows()
  local n = 0
  for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
    n = n + windows_of(tab)
  end
  return n
end

local function cursor_line()
  return vim.api.nvim_win_get_cursor(0)[1]
end

local one = tmp .. "/one.lua"
local two = tmp .. "/two.lua"
vim.fn.writefile({ "local a = 1", "local b = 2", "local c = 3" }, one)
vim.fn.writefile({ "local x = 1", "local y = 2", "local z = 3" }, two)

io.write("\n-- the edited file is the one already open\n")

vim.cmd("edit " .. vim.fn.fnameescape(one))
vim.api.nvim_win_set_cursor(0, { 1, 0 })
local before_tabs = tabs()
local before_windows = total_windows()

eq(ui.open(one, ranges, accept.buffer_for(one)), true, "the edit is followed")
eq(tabs(), before_tabs, "no tab was opened for the file already on screen")
eq(total_windows(), before_windows, "no split was created")
eq(vim.api.nvim_get_current_buf(), accept.buffer_for(one), "the current buffer is still the edited file")
eq(cursor_line(), 2, "the cursor moved to the first changed line")

io.write("\n-- the edited file is not open anywhere\n")

eq(ui.open(two, ranges, accept.buffer_for(two)), true, "the edit is followed")
eq(tabs(), before_tabs + 1, "the file opened in a new tab")
eq(windows_of(1), 1, "the tab you were in kept its single window")
eq(windows_of(tabs()), 1, "the new tab holds one window")
eq(vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":t"), "two.lua", "the new tab shows the edited file")
eq(cursor_line(), 2, "the cursor landed on the first changed line")

io.write("\n-- the edited file is already open in another tab\n")

vim.cmd("tabnext 1")
eq(tabs(), before_tabs + 1, "we are back in the first tab")
eq(vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":t"), "one.lua", "the first tab shows the other file")
local windows_before = total_windows()

eq(ui.open(two, ranges, accept.buffer_for(two)), true, "the edit is followed again")
eq(tabs(), before_tabs + 1, "no second tab was opened for the same file")
eq(total_windows(), windows_before, "no split was created")
eq(vim.fn.tabpagenr(), 2, "the tab holding the file was focused")
eq(vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":t"), "two.lua", "the cursor is on the edited file")

io.write("\n-- a buffer with unsaved changes is still refused\n")

vim.cmd("tabnext 1")
vim.cmd("edit " .. vim.fn.fnameescape(two))
vim.api.nvim_set_option_value("modified", true, { buf = 0 })
local guarded_tabs = tabs()
eq(ui.open(two, ranges, accept.buffer_for(two)), false, "a modified buffer is not followed")
eq(tabs(), guarded_tabs, "the refusal opened nothing")
vim.api.nvim_set_option_value("modified", false, { buf = 0 })

io.write("\n-- a file kori edits twice does not stack tabs\n")

local three = tmp .. "/three.lua"
vim.fn.writefile({ "local p = 1", "local q = 2" }, three)
vim.cmd("tabnext 1")
for _ = 1, 3 do
  ui.open(three, ranges, accept.buffer_for(three))
end
eq(tabs(), guarded_tabs + 1, "three edits of a closed file yield one tab")
eq(total_windows(), tabs(), "one window per tab, never a split")

io.write(("\n%d checks, %d failures\n"):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
