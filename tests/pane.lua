-- The pane must never take over the buffer you are editing, and toggling it
-- must not stack terminals. The bug this exists for: `vsplit` shows the *same*
-- buffer in the new window, so a `termopen` in that window converts the buffer
-- every window is showing, turning the editor window into a second terminal.
-- Run with: nvim --headless -u NONE -l tests/pane.lua

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
config.setup({ root = tmp, spool_dir = tmp .. "/spool", keymaps = false })
local kori = require("kori")

local slow = { "sh", "-c", "sleep 60" }

local function windows()
  local out = {}
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local buf = vim.api.nvim_win_get_buf(win)
    out[#out + 1] = {
      win = win,
      buf = buf,
      buftype = vim.api.nvim_get_option_value("buftype", { buf = buf }),
      filetype = vim.api.nvim_get_option_value("filetype", { buf = buf }),
    }
  end
  return out
end

local function terminals()
  local out = {}
  for _, w in ipairs(windows()) do
    if w.buftype == "terminal" then
      out[#out + 1] = w
    end
  end
  return out
end

local function shown_by(buf)
  local n = 0
  for _, w in ipairs(windows()) do
    if w.buf == buf then
      n = n + 1
    end
  end
  return n
end

local function close_all_but(keep)
  for _, w in ipairs(windows()) do
    if w.win ~= keep then
      pcall(vim.api.nvim_win_close, w.win, true)
    end
  end
end

local function pane_buffer()
  local runtime = kori._runtime()
  return runtime.pane and runtime.pane.buf
end

local function channel_of(buf)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return nil
  end
  return vim.api.nvim_get_option_value("channel", { buf = buf })
end

local function running(buf)
  local chan = channel_of(buf)
  if not chan or chan == 0 then
    return false
  end
  local ok, status = pcall(vim.fn.jobwait, { chan }, 0)
  return ok and status[1] == -1
end

local function wait_for_death(buf, ms)
  vim.wait(ms, function()
    return not running(buf)
  end)
end

io.write("\n-- toggling from a file buffer\n")

local file = tmp .. "/edited.lua"
vim.fn.writefile({ "local a = 1", "local b = 2" }, file)
vim.cmd("edit " .. vim.fn.fnameescape(file))
local editor_buf = vim.api.nvim_get_current_buf()

eq(kori.toggle(slow), true, "the first toggle opens the pane")
eq(#windows(), 2, "exactly one window was added")
eq(#terminals(), 1, "exactly one terminal exists")
eq(vim.api.nvim_get_option_value("buftype", { buf = editor_buf }), "", "the edited buffer is still a file")
eq(
  vim.api.nvim_buf_get_lines(editor_buf, 0, -1, false)[2],
  "local b = 2",
  "the edited buffer still holds its content"
)

local pane_buf = pane_buffer()
eq(pane_buf ~= editor_buf, true, "the pane has its own buffer, not the editor's")
eq(shown_by(editor_buf), 1, "the edited buffer is shown in exactly one window")
eq(shown_by(pane_buf), 1, "the pane buffer is shown in exactly one window")

io.write("\n-- toggling again hides it and comes back\n")

eq(kori.toggle(slow), false, "the second toggle closes the pane")
eq(#windows(), 1, "the editor window is alone again")
eq(kori.is_open(), false, "the pane reports closed")
eq(vim.api.nvim_buf_is_valid(pane_buf), true, "hiding keeps the pane buffer alive")
eq(running(pane_buf), true, "hiding keeps kori running, it is a toggle and not a restart")

eq(kori.toggle(slow), true, "toggling back reopens it")
eq(#windows(), 2, "still one window added")
eq(pane_buffer(), pane_buf, "the same kori process was reused")
eq(#terminals(), 1, "still exactly one terminal")

io.write("\n-- toggling ten times does not stack panes\n")

for _ = 1, 10 do
  kori.toggle(slow)
end
eq(kori.is_open(), true, "the last toggle left it open")
eq(#terminals(), 1, "never more than one terminal")
eq(#windows(), 2, "never more than two windows")

io.write("\n-- starting when already open does not duplicate\n")

local before = #windows()
kori.start(slow)
eq(#windows(), before, "start() on an open pane changes nothing")
eq(#terminals(), 1, "start() on an open pane adds no terminal")

io.write("\n-- from a dashboard-like scratch buffer\n")

kori.toggle(slow)
close_all_but(nil)
vim.cmd("enew")
vim.api.nvim_set_option_value("buftype", "nofile", { buf = 0 })
vim.api.nvim_set_option_value("filetype", "alpha", { buf = 0 })
vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = 0 })
local dashboard = vim.api.nvim_get_current_buf()
eq(#windows(), 1, "the dashboard is alone")

eq(kori.toggle(slow), true, "the pane opens from the dashboard buffer")
eq(
  vim.api.nvim_get_option_value("buftype", { buf = dashboard }),
  "nofile",
  "the dashboard buffer was not turned into a terminal"
)
eq(
  vim.api.nvim_get_option_value("filetype", { buf = dashboard }),
  "alpha",
  "the dashboard buffer kept its filetype"
)
eq(shown_by(dashboard), 1, "the dashboard is still shown in one window")
eq(#terminals(), 1, "still exactly one terminal")
eq(#windows(), 2, "the dashboard kept its own window")

io.write("\n-- the pane is not closed while it is the only window\n")

local pane_win = kori.pane()
close_all_but(pane_win)
eq(#windows(), 1, "only the pane is left")
kori.toggle(slow)
eq(#windows(), 1, "the toggle refused to close the last window")
eq(kori.is_open(), true, "the pane is still open")

io.write("\n-- a dead process is replaced rather than shown as a corpse\n")

local dead = pane_buffer()
vim.fn.jobstop(channel_of(dead))
wait_for_death(dead, 3000)
eq(running(dead), false, "the pane process has exited")

vim.cmd("botright vnew")
eq(kori.start(slow), true, "start() replaces a pane whose process exited")
eq(pane_buffer() ~= dead, true, "a finished process is not reused")
eq(#terminals(), 1, "the replacement did not leave the old one behind")

io.write("\n-- start() recovers when the dead pane is the only window\n")

local old = pane_buffer()
close_all_but(kori.pane())
vim.fn.jobstop(channel_of(old))
wait_for_death(old, 3000)
eq(kori.start(slow), true, "start() works from the last remaining window")
eq(#windows() >= 2, true, "a window survived to hold the new pane")
eq(pane_buffer() ~= old, true, "the dead pane was replaced here too")

io.write("\n-- a command that cannot run is refused, not thrown\n")

local doomed = pane_buffer()
if doomed then
  vim.fn.jobstop(channel_of(doomed))
  wait_for_death(doomed, 3000)
end
kori.hide()
local windows_before = #windows()

local threw, reported = pcall(kori.start, { "/nonexistent/kori-binary" })
eq(threw, true, "a bad command does not throw at the caller")
eq(reported, false, "a bad command reports failure instead")
eq(#windows(), windows_before, "the failed attempt left no window behind")
eq(kori.is_open(), false, "a failed start leaves no pane behind")

io.write(("\n%d checks, %d failures\n"):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
