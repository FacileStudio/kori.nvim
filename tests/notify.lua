local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(root)

local failures = 0
local checks = 0
local seen = {}

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

local function shown(message, label)
  for _, entry in ipairs(seen) do
    if entry.message == message then
      pass(label)
      return
    end
  end
  fail(label, ("%s was never shown, saw %s"):format(vim.inspect(message), vim.inspect(seen)))
end

local notify = require("kori.notify")

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local a = tmp .. "/a.lua"
local b = tmp .. "/b.lua"
local gone = tmp .. "/gone.lua"

local function fill(path, count)
  local content = {}
  for i = 1, count do
    content[i] = ("line %d"):format(i)
  end
  vim.fn.writefile(content, path)
end

fill(a, 20)
fill(b, 5)

local function collect(message, level)
  seen[#seen + 1] = { message = message, level = level }
end

local function await(count)
  vim.wait(400, function()
    return #seen >= count
  end, 10)
end

local function settle()
  vim.wait(400, function()
    return false
  end, 10)
end

local function reset()
  notify.cancel()
  seen = {}
end

eq(notify.setup({}).window_ms, 250, "the coalescing window defaults to 250ms")
eq(notify.setup({}).enabled, true, "notifications are on by default")
notify.setup({ enabled = true, window_ms = 50, root = tmp, notify = collect })

io.write("\n-- ten rapid edits to one file land as one notification\n")

reset()
local line = { { first = 3, last = 3, added = 1, removed = 1 } }
for _ = 1, 10 do
  notify.record(a, line)
end
eq(#seen, 0, "nothing is shown before the window closes")
eq(#notify._pending(), 1, "the ten edits are one pending file")
await(1)
eq(#seen, 1, "ten edits produce exactly one notification")
eq(
  seen[1].message,
  "kori changed a.lua (10 places, 20 lines, +10 -10)",
  "the summary sums the burst and reports the final line count"
)
eq(seen[1].level, vim.log.levels.INFO, "the summary is informational")
settle()
eq(#seen, 1, "the burst does not fire twice")

io.write("\n-- edits to different files stay apart\n")

reset()
notify.record(a, { { first = 1, last = 1, added = 2, removed = 0 } })
notify.record(b, { { first = 2, last = 2, added = 1, removed = 3 } })
notify.record(a, { { first = 5, last = 5, added = 1, removed = 1 } })
eq(#notify._pending(), 2, "two files are pending")
await(2)
eq(#seen, 2, "each file gets one notification, whichever window closes first")
shown("kori changed a.lua (2 places, 20 lines, +3 -1)", "the first file sums only its own edits")
shown("kori changed b.lua (line 2, 5 lines, +1 -3)", "the second file keeps its own count")

io.write("\n-- a burst that outruns the window is still one notification\n")

reset()
for _ = 1, 5 do
  notify.record(a, { { first = 1, last = 1, added = 1, removed = 0 } })
  vim.wait(20, function()
    return false
  end, 5)
end
await(1)
eq(#seen, 1, "edits spaced inside the window are still one notification")
eq(seen[1].message, "kori changed a.lua (5 places, 20 lines, +5 -0)", "the last edit of the burst is reported")

io.write("\n-- flush delivers immediately\n")

reset()
notify.record(a, { { first = 4, last = 4, added = 1, removed = 2 } })
eq(#seen, 0, "the summary waits for the window")
eq(notify.flush(), 1, "flush reports one delivery")
eq(#seen, 1, "flush shows it straight away")
eq(seen[1].message, "kori changed a.lua (line 4, 20 lines, +1 -2)", "flush uses the same summary")
eq(#notify._pending(), 0, "flush leaves nothing pending")
settle()
eq(#seen, 1, "the timer flush replaced never fires again")

io.write("\n-- cancel drops the pending burst\n")

reset()
notify.record(a, { { first = 1, last = 1, added = 1, removed = 0 } })
notify.record(b, { { first = 1, last = 1, added = 1, removed = 0 } })
eq(#notify._pending(), 2, "both files are pending")
eq(notify.cancel(), 2, "cancel drops both summaries")
eq(#notify._pending(), 0, "nothing is pending after cancel")
eq(notify.cancel(), 0, "a second cancel has nothing to do")
eq(notify.flush(), 0, "flush after cancel delivers nothing")
settle()
eq(#seen, 0, "no timer survives cancel: a full window passes in silence")

io.write("\n-- enabled = false suppresses everything\n")

notify.setup({ enabled = false })
reset()
eq(notify.record(a, line), false, "a disabled notifier refuses the edit")
eq(#notify._pending(), 0, "nothing is queued while disabled")
eq(notify.flush(), 0, "flush delivers nothing while disabled")
settle()
eq(#seen, 0, "nothing arrives while disabled")

notify.setup({ enabled = true })
notify.record(a, line)
await(1)
eq(#seen, 1, "re-enabling restores notifications")

io.write("\n-- edge cases\n")

reset()
eq(notify.record(a, {}), false, "an edit with no ranges is refused")
eq(notify.record(a, nil), false, "an edit without ranges is refused")
eq(#notify._pending(), 0, "a refused edit queues nothing")
eq(notify.record(a, line), true, "a well formed edit is queued")
notify.cancel()

notify.record(gone, line)
eq(notify.flush(), 1, "an edit of a file that vanished is still delivered")
eq(seen[1].message, "kori changed gone.lua (line 3, +1 -1)", "without a file on disk the line count is left out")

local ok, err = pcall(notify.setup, { window_ms = -1 })
eq(ok, false, "a negative window is rejected")
eq(type(err) == "string" and err:match("window_ms") ~= nil, true, "the error names window_ms")

notify.cancel()
io.write(("\n%d checks, %d failures\n"):format(checks, failures))
os.exit(failures == 0 and 0 or 1)