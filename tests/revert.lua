local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(root)
vim.opt.hidden = true

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

local function refused(ok, reason, label)
  if ok ~= false then
    fail(label, ("expected a refusal, got %s"):format(vim.inspect(ok)))
    return
  end
  if type(reason) ~= "string" or reason == "" then
    fail(label, ("the refusal carried no reason: %s"):format(vim.inspect(reason)))
    return
  end
  pass(label)
end

local function text(lines)
  return table.concat(lines, "\n")
end

local function lines(path)
  return vim.fn.readfile(path)
end

local function bytes(path)
  local fd = io.open(path, "rb")
  if not fd then
    return nil
  end
  local data = fd:read("*a")
  fd:close()
  return data
end

local function buf_text()
  return text(vim.api.nvim_buf_get_lines(0, 0, -1, false))
end

local config = require("kori.config")
local edit = require("kori.edit")
local marks = require("kori.marks")
local revert = require("kori.revert")

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
config.setup({ root = tmp, spool_dir = tmp .. "/spool", notify = false })
marks.setup({})

io.write("\n-- a single hunk reverts on disk and in the buffer\n")

local file = tmp .. "/single.lua"
local original = { "local a = 1", "local b = 2", "local c = 3" }
local changed = { "local a = 1", "local b = 22", "local c = 3" }
vim.fn.writefile(original, file)
vim.cmd("edit " .. vim.fn.fnameescape(file))
vim.fn.writefile(changed, file)
edit.apply_path(file, { tool = "edit_file", old = "local b = 2", new = "local b = 22" })
local entry = marks.of(file)
eq(#entry.ranges, 1, "one hunk was recorded")
local ok, reason = revert.hunk(file, entry.ranges[1], entry.meta)
eq(ok, true, "the hunk revert succeeds: " .. tostring(reason))
eq(text(lines(file)), text(original), "the file on disk is restored")
eq(buf_text(), text(original), "the open buffer is restored")

io.write("\n-- revert.buffer resolves the hunk under the cursor\n")

local cursor_file = tmp .. "/cursor.lua"
local cursor_original = { "one", "two", "three" }
local cursor_changed = { "one", "TWO", "three" }
vim.fn.writefile(cursor_original, cursor_file)
vim.cmd("edit " .. vim.fn.fnameescape(cursor_file))
vim.fn.writefile(cursor_changed, cursor_file)
edit.apply_path(cursor_file, { tool = "edit_file", old = "two", new = "TWO" })
vim.api.nvim_win_set_cursor(0, { 2, 0 })
local cursor_ok, cursor_reason = revert.buffer(0, cursor_file)
eq(cursor_ok, true, "the buffer revert succeeds: " .. tostring(cursor_reason))
eq(text(lines(cursor_file)), text(cursor_original), "the file under the cursor is restored")

io.write("\n-- a cursor off the hunk is refused\n")

vim.api.nvim_win_set_cursor(0, { 3, 0 })
refused(revert.buffer(0, cursor_file), "the cursor is not on a hunk")

io.write("\n-- a buffer with unsaved changes is refused\n")

local dirty_file = tmp .. "/dirty.lua"
local dirty_original = { "alpha", "beta", "gamma" }
local dirty_changed = { "alpha", "BETA", "gamma" }
vim.fn.writefile(dirty_original, dirty_file)
vim.cmd("edit " .. vim.fn.fnameescape(dirty_file))
vim.fn.writefile(dirty_changed, dirty_file)
edit.apply_path(dirty_file, { tool = "edit_file", old = "beta", new = "BETA" })
local dirty_entry = marks.of(dirty_file)
vim.api.nvim_buf_set_lines(0, 0, 1, false, { "alpha edited" })
vim.api.nvim_set_option_value("modified", true, { buf = 0 })
local before = bytes(dirty_file)
local dirty_ok, dirty_reason = revert.hunk(dirty_file, dirty_entry.ranges[1], dirty_entry.meta)
refused(dirty_ok, dirty_reason, "a modified buffer is refused")
eq(bytes(dirty_file), before, "the file is byte-identical after the refusal")

io.write("\n-- a file that lost kori's text is refused\n")

local lost_file = tmp .. "/lost.lua"
vim.fn.writefile({ "keep", "target", "keep" }, lost_file)
local lost_entry = edit.apply_path(lost_file, { tool = "edit_file", old = "target", new = "TARGET" })
vim.fn.writefile({ "keep", "gone", "keep" }, lost_file)
refused(revert.hunk(lost_file, lost_entry.ranges[1], lost_entry.meta), "the missing text is refused")

io.write("\n-- a record with no old and new text is refused\n")

local bare_file = tmp .. "/bare.lua"
vim.fn.writefile({ "x", "y" }, bare_file)
edit.apply_path(bare_file, { tool = "write_file" })
refused(
  revert.hunk(bare_file, { first = 1, last = 1 }, marks.of(bare_file).meta),
  "a record without old and new text is refused"
)
local bare_count, bare_reason = revert.all(bare_file)
eq(bare_count, 0, "revert.all refuses too")
eq(type(bare_reason), "string", "revert.all carries a reason")

io.write("\n-- ambiguous text is refused\n")

local dup_file = tmp .. "/dup.lua"
vim.fn.writefile({ "same", "same" }, dup_file)
local dup_entry = edit.apply_path(dup_file, { tool = "edit_file", old = "one", new = "same" })
refused(revert.hunk(dup_file, dup_entry.ranges[1], dup_entry.meta), "text appearing twice is refused")

io.write("\n-- revert.all reverts a multi-hunk file\n")

local multi_file = tmp .. "/multi.lua"
local multi_original = { "alpha", "beta", "gamma", "delta", "epsilon" }
local multi_changed = { "ALPHA", "beta", "gamma", "delta", "EPSILON" }
vim.fn.writefile(multi_original, multi_file)
vim.cmd("edit " .. vim.fn.fnameescape(multi_file))
vim.fn.writefile(multi_changed, multi_file)
local multi_entry = edit.apply_path(multi_file, {
  tool = "edit_file",
  old = "alpha\nbeta\ngamma\ndelta\nepsilon",
  new = "ALPHA\nbeta\ngamma\ndelta\nEPSILON",
})
eq(#multi_entry.ranges, 2, "two hunks were recorded")
local multi_count, multi_reason = revert.all(multi_file)
eq(multi_count, 2, "revert.all reports both hunks: " .. tostring(multi_reason))
eq(text(lines(multi_file)), text(multi_original), "the multi-hunk file is restored")
eq(buf_text(), text(multi_original), "the buffer is restored too")

io.write(("\n%d checks, %d failures\n"):format(checks, failures))
os.exit(failures == 0 and 0 or 1)