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

io.write(("\n%d checks, %d failures\n"):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
