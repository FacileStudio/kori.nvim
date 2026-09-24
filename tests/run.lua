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

local function shape(ranges)
  local out = {}
  for _, r in ipairs(ranges) do
    out[#out + 1] = ("%d-%d+%d-%d"):format(r.first, r.last, r.added, r.removed)
  end
  return table.concat(out, ",")
end

local config = require("kori.config")
local edit = require("kori.edit")
local marks = require("kori.marks")
local spool = require("kori.spool")

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
config.setup({ root = tmp, spool_dir = tmp .. "/spool", notify = true })
marks.setup({})

io.write("\n-- ranges_from\n")

eq(
  shape(edit.ranges_from({ "a", "b", "c" }, { "a", "x", "c" })),
  "2-2+1-1",
  "one line replaced"
)
eq(
  shape(edit.ranges_from({ "a", "b", "c" }, { "a", "x", "y", "b", "c" })),
  "2-3+2-0",
  "two lines inserted"
)
eq(
  shape(edit.ranges_from({ "a", "b", "c" }, { "a", "c" })),
  "2-2+0-1",
  "one line deleted marks the line that took its place"
)
eq(
  shape(edit.ranges_from({ "a", "b", "c" }, { "a", "b", "c" })),
  "",
  "identical content produces no ranges"
)
eq(
  shape(edit.ranges_from({}, { "x", "y" })),
  "1-2+2-0",
  "a file created from nothing marks every line"
)
eq(
  shape(edit.ranges_from({ "a", "b", "c" }, {})),
  "1-1+0-3",
  "an emptied file marks line 1 rather than line 0"
)
eq(
  shape(edit.ranges_from({ "a", "b", "c" }, { "a", "c" })),
  "2-2+0-1",
  "a deletion at the end clamps to the new line count"
)
eq(shape(edit.ranges_from({ "a", "b", "c" }, { "a", "b", "c", "d" })), "4-4+1-0", "append at the end")eq(shape(edit.ranges_from({ "a", "b" }, { "x", "b" })), "1-1+1-1", "change on the first line")

io.write("\n-- apply_path against a real buffer\n")

local file = tmp .. "/sample.lua"
vim.fn.writefile({ "local a = 1", "local b = 2", "local c = 3" }, file)
vim.cmd("edit " .. vim.fn.fnameescape(file))

vim.fn.writefile({ "local a = 1", "local b = 22", "local c = 3" }, file)
local result = edit.apply_path(file, { tool = "edit_file" })
eq(shape(result.ranges), "2-2+1-1", "apply_path finds the changed line")
eq(result.stale, false, "an unmodified buffer is not stale")
eq(
  vim.api.nvim_buf_get_lines(0, 1, 2, false)[1],
  "local b = 22",
  "the buffer was reloaded from disk"
)
local entry = marks.of(file)
eq(entry ~= nil, true, "marks were recorded for the file")
eq(#entry.ranges, 1, "one range recorded")
eq(marks.count(), 1, "one file has marks")
eq(marks.jump(0, 1), true, "navigation reaches the marked line")
eq(vim.api.nvim_win_get_cursor(0)[1], 2, "navigation lands on the changed line")

vim.fn.writefile({ "local a = 1", "local b = 22", "local d = 4", "local c = 3" }, file)
local second = edit.apply_path(file, { tool = "edit_file" })
eq(shape(second.ranges), "3-3+1-0", "a second edit is diffed from the previous snapshot")
eq(
  vim.api.nvim_buf_get_lines(0, 2, 3, false)[1],
  "local d = 4",
  "the second reload landed too"
)

io.write("\n-- a closed file is marked from the payload's own old/new\n")

local closed = tmp .. "/closed.lua"
vim.fn.writefile({ "local a = 1", "local b = 22", "local c = 3" }, closed)
local first = edit.apply_path(closed, { tool = "edit_file", old = "local b = 2", new = "local b = 22" })
eq(first.had_buffer, false, "the file was not open in a buffer")
eq(shape(first.ranges), "2-2+1-1", "the first edit of a closed file still gets a range")
eq(marks.of(closed) ~= nil, true, "the closed file is recorded for the changes panel")

local no_payload = tmp .. "/no-payload.lua"
vim.fn.writefile({ "one", "two" }, no_payload)
local second_first = edit.apply_path(no_payload, { tool = "write_file" })
eq(shape(second_first.ranges), "", "without a base and without old/new, nothing is claimed")

io.write("\n-- a before_tool_call snapshot is the base write_file and run_command lack\n")

local function before(tool, input)
  return edit.on_event({ event = "before_tool_call", tool = tool, input = vim.json.encode(input) })
end

local function after(tool, input)
  return edit.on_event({ event = "after_tool_call", tool = tool, input = vim.json.encode(input) })
end

local made = tmp .. "/made.lua"
eq(before("write_file", { path = made, content = "one\ntwo\n" }), nil, "a before event reports nothing to the UI")
vim.fn.writefile({ "one", "two" }, made)
eq(
  shape(after("write_file", { path = made, content = "one\ntwo\n" }).ranges),
  "1-2+2-0",
  "a file kori created marks every line as added"
)

local replaced = tmp .. "/replaced.lua"
vim.fn.writefile({ "keep", "old", "tail" }, replaced)
before("write_file", { path = replaced, content = "new\n" })
vim.fn.writefile({ "new" }, replaced)
eq(
  shape(after("write_file", { path = replaced, content = "new\n" }).ranges),
  "1-1+1-3",
  "an overwritten file is diffed against its pre-image, not claimed whole"
)

local ambiguous = tmp .. "/ambiguous.lua"
vim.fn.writefile({ "same", "b", "c" }, ambiguous)
before("edit_file", { path = ambiguous, old = "c", new = "same" })
vim.fn.writefile({ "same", "b", "same" }, ambiguous)
eq(
  shape(after("edit_file", { path = ambiguous, old = "c", new = "same" }).ranges),
  "3-3+1-1",
  "the snapshot beats the old/new text when the new text is not unique"
)

local unreadable = tmp .. "/unreadable.lua"
vim.fn.writefile({ "keep", "me" }, unreadable)
vim.fn.setfperm(unreadable, "---------")
eq(before("write_file", { path = unreadable, content = "new\n" }), nil, "a before event still reports nothing")
eq(after("write_file", { path = unreadable, content = "new\n" }), nil, "a file that cannot be read is claimed nowhere")
vim.fn.setfperm(unreadable, "rw-------")

io.write("\n-- a modified buffer is never clobbered\n")

vim.cmd("edit " .. vim.fn.fnameescape(file))
vim.api.nvim_buf_set_lines(0, 0, 1, false, { "local a = 999" })
vim.api.nvim_set_option_value("modified", true, { buf = 0 })
vim.fn.writefile({ "local a = 1", "local b = 22", "local d = 4", "local c = 5" }, file)
local third = edit.apply_path(file, { tool = "edit_file" })
eq(third.stale, true, "a buffer with unsaved changes is reported stale")
eq(
  vim.api.nvim_buf_get_lines(0, 0, 1, false)[1],
  "local a = 999",
  "the unsaved line survived"
)
eq(
  vim.api.nvim_buf_get_lines(0, 3, 4, false)[1],
  "local c = 3",
  "the buffer was not reloaded"
)
local modified_marks = vim.api.nvim_buf_get_extmarks(0, vim.api.nvim_create_namespace("kori.nvim"), 0, -1, {})
eq(#modified_marks, 0, "no marks are drawn in a buffer that disagrees with disk")

io.write("\n-- the shim end to end\n")

local shim = root .. "/bin/kori-nvim"
eq(vim.fn.filereadable(shim), 1, "the shim exists")

local spool_dir = tmp .. "/shim-spool"
vim.env.KORI_NVIM_SPOOL_DIR = spool_dir
local payload = vim.json.encode({
  event = "after_tool_call",
  tool = "edit_file",
  input = vim.json.encode({ path = "sample.lua", old = "local b = 2", new = "local b = 22" }),
  result = "edited sample.lua",
  retry = false,
})
local run = vim.fn.system({ "sh", shim, "emit" }, payload)
eq(vim.v.shell_error, 0, "the shim exits 0")
eq(run, "", "the shim prints nothing on emit")

local spools = spool._list_spools(spool_dir)
eq(#spools, 1, "the shim wrote exactly one spool file")

local raw = table.concat(vim.fn.readfile(spools[1]), "\n")
eq(raw:sub(-1), "}", "the shim terminated the line")
local decoded = vim.json.decode(raw)
eq(decoded.tool, "edit_file", "the payload round-trips")
local inner = vim.json.decode(decoded.input)
eq(inner.path, "sample.lua", "input is a nested JSON string, decoded on the plugin side")
eq(inner.new, "local b = 22", "the new text survived the shell")

local perm = vim.fn.getfperm(spools[1])
eq(perm:sub(1, 2), "rw", "the spool file is writable by its owner")
eq(perm:sub(4), "------", "the spool file is not readable by others")
local dir_perm = vim.fn.getfperm(spool_dir)
eq(dir_perm:sub(4), "------", "the spool directory is not readable by others")

io.write("\n-- events reach the handler\n")

local seen = 0
local state = spool.start(config.get(), function()
  seen = seen + 1
end)
eq(state ~= nil, true, "the watcher starts")
eq(seen, 0, "a fresh watcher replays nothing it already deleted")
spool.stop(state)

io.write("\n-- the before hook waits for the plugin to take the snapshot\n")

local hand_dir = tmp .. "/hand-spool"
vim.env.KORI_NVIM_SPOOL_DIR = hand_dir
local hand_config = config.setup({ root = tmp, spool_dir = hand_dir })
local hand_seen = {}
local hand_state = spool.start(hand_config, function(payload)
  hand_seen[#hand_seen + 1] = payload.event
  edit.on_event(payload)
end)

local marker = hand_dir .. "/plugin"
eq(vim.fn.filereadable(marker), 1, "the plugin publishes a marker while it watches")
eq(tonumber(vim.fn.readfile(marker)[1]), vim.uv.os_getpid(), "the marker names this process")

local watched = tmp .. "/watched.lua"
vim.fn.writefile({ "before" }, watched)
local hand_input = vim.json.encode({ path = watched, content = "after\n" })
local hand_payload = vim.json.encode({
  event = "before_tool_call",
  tool = "write_file",
  input = hand_input,
})

local exit_code
local job = vim.fn.jobstart({ "sh", shim, "before" }, {
  pty = false,
  on_exit = function(_, code)
    exit_code = code
  end,
})
vim.fn.chansend(job, hand_payload)
vim.fn.chanclose(job, "stdin")
local returned = vim.wait(2000, function()
  return exit_code ~= nil
end, 20)

eq(returned, true, "the before shim returns without waiting out its cap")
eq(exit_code, 0, "it exits 0")
eq(hand_seen[1], "before_tool_call", "the plugin was handed the before event")
eq(#spool._list_requests(hand_dir), 0, "the request file was served and removed")

vim.fn.writefile({ "after" }, watched)
local hand_applied = edit.on_event({
  event = "after_tool_call",
  tool = "write_file",
  input = hand_input,
})
eq(
  shape(hand_applied.ranges),
  "1-1+1-1",
  "the pre-image taken during the handshake is what the diff is taken from"
)
spool.stop(hand_state)

io.write("\n-- with no plugin watching, the hook does not hold the call up\n")

local lonely = tmp .. "/lonely-spool"
vim.fn.mkdir(lonely, "p")
vim.env.KORI_NVIM_SPOOL_DIR = lonely

local function before_shim()
  local started = vim.uv.hrtime()
  local out = vim.fn.system({ "sh", shim, "before" }, hand_payload)
  return (vim.uv.hrtime() - started) / 1000000, out
end

local elapsed, printed = before_shim()
eq(vim.v.shell_error, 0, "the shim exits 0 with no plugin watching")
eq(printed, "", "it prints nothing")
eq(elapsed < 400, true, ("it returns at once, not after its cap (%dms)"):format(elapsed))
eq(#spool._list_requests(lonely), 0, "it leaves no request behind")

vim.fn.writefile({ "9999999" }, lonely .. "/plugin")
local stale, _ = before_shim()
eq(stale < 400, true, ("a marker with no live process behind it is ignored (%dms)"):format(stale))

io.write(("\n%d checks, %d failures\n"):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
