-- Shell edits: the cmdpath.go port, and the caller-supplied span path.
-- Run with: nvim --headless -u NONE -l tests/cmdedit.lua

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

local cmdedit = require("kori.cmdedit")
local config = require("kori.config")
local edit = require("kori.edit")
local marks = require("kori.marks")

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
config.setup({ root = tmp, spool_dir = tmp .. "/spool", notify = true })
marks.setup({})

local function extracted(command)
  local path, ok = cmdedit.extract(command)
  return ("%s|%s"):format(tostring(ok), tostring(path))
end

local function joined(paths)
  return table.concat(paths, ",")
end

local function payload(tool, input)
  return {
    event = "after_tool_call",
    tool = tool,
    input = vim.json.encode(input),
    result = "",
    retry = false,
  }
end

io.write("\n-- extract: the token cmdpath.go returns\n")

eq(extracted("sed -i 's/x/y/' file.go"), "true|file.go", "sed -i on a plain path")
eq(extracted("sed -i \"s/x/y/\" file.go"), "true|file.go", "sed -i with a double-quoted script")
eq(extracted("sed -i s/x/y/ file.go"), "true|file.go", "sed -i with an unquoted script")
eq(extracted("sed -i.bak 's/x/y/' file.go"), "true|file.go", "sed -i with a backup extension")
eq(extracted("sed -i '' 's/x/y/' file.go"), "true|file.go", "sed -i with an empty BSD extension")
eq(extracted("sed -i -e 's/x/y/' -e 's/a/b/' file.go"), "true|file.go", "sed -i with repeated -e")
eq(extracted("sed -i -E 's/x/y/' ./deep/file.go"), "true|./deep/file.go", "sed -i with a flag and a relative path")
eq(extracted("sed -i 's/x/y/' -- file.go"), "true|file.go", "sed -i with an end-of-options marker")
eq(extracted("perl -i -pe 's/x/y/' file.pl"), "true|file.pl", "perl -i")
eq(extracted("perl -i.bak -pe 's/x/y/' file.pl"), "true|file.pl", "perl -i with a backup extension")
eq(extracted("awk -i inplace '{print}' file.txt"), "true|file.txt", "awk -i inplace")
eq(
  extracted("perl -i -pe 's/a/b/' a.pl awk -i inplace '{print}' b.txt"),
  "true|b.txt",
  "awk is tried before perl"
)
eq(
  extracted("perl -i -pe 's/a/b/' a.pl sed -i 's/x/y/' b.go"),
  "true|b.go",
  "sed is tried before perl, whatever their order in the command"
)
eq(extracted("grep -r \"sed -i\" docs/"), "true|", "a marker inside prose yields the empty token")
eq(extracted("sed -i 's/x/y/'"), "false|nil", "a marker with no path argument yields nothing")
eq(extracted("sed  -i  's/x/y/'  file.go"), "false|nil", "the marker needs one exact space")
eq(extracted("cat f.go"), "false|nil", "an unrelated command yields nothing")

io.write("\n-- paths: what the plugin is willing to mark\n")

eq(joined(cmdedit.paths("sed -i 's/x/y/' file.go")), "file.go", "sed -i on a plain path")
eq(joined(cmdedit.paths("sed -i 's/x/y/' ./a/b.go")), "./a/b.go", "sed -i on a nested path")
eq(joined(cmdedit.paths("perl -i -pe 's/x/y/' file.pl")), "file.pl", "perl -i")
eq(joined(cmdedit.paths("perl -i.bak -pe 's/x/y/' file.pl")), "file.pl", "perl -i with a backup extension")
eq(joined(cmdedit.paths("sed -i -e 's/x/y/' file.go")), "file.go", "sed -i with flags")
eq(joined(cmdedit.paths("sed -i '' 's/x/y/' file.go")), "file.go", "sed -i with an empty extension")
eq(joined(cmdedit.paths("awk -i inplace '{print}' file.txt")), "file.txt", "awk -i inplace")
eq(joined(cmdedit.paths("grep -r \"sed -i\" docs/")), "", "the empty token is not a path")

eq(joined(cmdedit.paths("cat f.go")), "", "cat is not an in-place edit")
eq(joined(cmdedit.paths("go test ./...")), "", "go test is not an in-place edit")
eq(joined(cmdedit.paths("gofmt -w file.go")), "", "gofmt -w is not one of the ported markers")
eq(joined(cmdedit.paths("sed -n '1,5p' file.go")), "", "sed without -i is not an in-place edit")
eq(joined(cmdedit.paths("sed -i 's/x/y/'")), "", "a marker with nothing after it yields no path")
eq(joined(cmdedit.paths("")), "", "an empty command yields no path")
eq(joined(cmdedit.paths(nil)), "", "a missing command yields no path")

eq(joined(cmdedit.paths("cat a | sed -i 's/x/y/' f.go")), "", "a pipeline is refused rather than guessed")
eq(joined(cmdedit.paths("sed -i s/a/b/ file.go | cat")), "", "a trailing pipe is refused")
eq(joined(cmdedit.paths("sed -i 's/x/y/' f.go > out.log")), "", "a redirect is refused rather than guessed")
eq(joined(cmdedit.paths("sed -i 's/x/y/' f.go < in.txt")), "", "an input redirect is refused")
eq(joined(cmdedit.paths("sed -i 's/x/y/' f.go; echo done")), "", "a separator is refused")
eq(joined(cmdedit.paths("cd sub && sed -i 's/a/b/' file.go")), "", "a chained command is refused")
eq(joined(cmdedit.paths("sed -i 's/x/y/' $TARGET")), "", "a variable is not a path")
eq(joined(cmdedit.paths("sed -i 's/x/y/' dir/*.go")), "", "a glob is not one path")
eq(joined(cmdedit.paths("sed -i 's/x/y/' my\\ file.go")), "", "a shell escape is not a path")
eq(
  joined(cmdedit.paths("sed -i 's/x/y/' \"file with space.go\"")),
  "with",
  "a quoted path with a space names \"with\", the token cmdpath.go returns"
)

eq(cmdedit.is_edit("sed -i 's/x/y/' file.go"), true, "is_edit accepts a sed edit")
eq(cmdedit.is_edit("go test ./..."), false, "is_edit rejects a non-edit")
eq(cmdedit.is_edit("cat a | sed -i 's/x/y/' f.go"), false, "is_edit rejects a pipeline")

io.write("\n-- apply_path with a caller-supplied span\n")

local spanned = tmp .. "/spanned.lua"
vim.fn.writefile({ "a = 1", "b = 2", "c = 3" }, spanned)
vim.cmd("edit " .. vim.fn.fnameescape(spanned))
vim.fn.writefile({ "a = 1", "b = 22", "c = 3" }, spanned)

eq(
  shape(edit.ranges_from({ "a = 1", "b = 2", "c = 3" }, { "a = 1", "b = 22", "c = 3" })),
  "2-2+1-1",
  "the span a diff would have produced"
)

local supplied = { { first = 9, last = 9, added = 0, removed = 0 } }
local told = edit.apply_path(spanned, { tool = "ide", ranges = supplied })
eq(shape(told.ranges), "9-9+0-0", "a supplied span is used instead of diffing")
eq(
  vim.api.nvim_buf_get_lines(0, 1, 2, false)[1],
  "b = 22",
  "the buffer was still reloaded from disk"
)
eq(told.stale, false, "a supplied span does not make the buffer stale")
eq(shape(marks.of(spanned).ranges), "9-9+0-0", "the supplied span reached the marks")
eq(marks.of(spanned).meta.tool, "ide", "the caller's metadata reached the marks")

local diffed = tmp .. "/diffed.lua"
vim.fn.writefile({ "a = 1", "b = 2", "c = 3" }, diffed)
vim.cmd("edit " .. vim.fn.fnameescape(diffed))
vim.fn.writefile({ "a = 1", "b = 22", "c = 3" }, diffed)
local plain = edit.apply_path(diffed, { tool = "edit_file" })
eq(shape(plain.ranges), "2-2+1-1", "without a supplied span the buffer/disk diff still runs")

local empty = tmp .. "/empty.lua"
vim.fn.writefile({ "a = 1", "b = 2" }, empty)
local without = edit.apply_path(empty, { tool = "write_file" })
eq(shape(without.ranges), "", "without a base and without a span nothing is claimed")
eq(edit.apply_path(tmp .. "/absent.lua", { tool = "ide" }), nil, "a missing file is never applied")
eq(
  edit.apply_path(tmp .. "/absent.lua", { tool = "ide", ranges = supplied }),
  nil,
  "a missing file is not marked even with a supplied span"
)

io.write("\n-- run_command reaches the same marking path\n")

local command_file = tmp .. "/cmd.go"
vim.fn.writefile({ "package main", "", "func main() {}" }, command_file)

local applied = edit.on_event(payload("run_command", { command = "sed -i 's/main/principal/' cmd.go" }))
eq(applied ~= nil, true, "a sed -i command marks a file that exists")
eq(
  applied.path,
  vim.fn.fnamemodify(command_file, ":p"):gsub("/$", ""),
  "the marked path is the file the command named"
)
eq(marks.of(command_file) ~= nil, true, "the shell edit is recorded for the changes panel")
eq(
  #marks.of(command_file).ranges,
  0,
  "a closed file edited by shell has no base to diff, so it carries no spans"
)

local snapshotted = tmp .. "/snapshotted.go"
vim.fn.writefile({ "package main", "", "func main() {}" }, snapshotted)
edit.on_event({
  event = "before_tool_call",
  tool = "run_command",
  input = vim.json.encode({ command = "sed -i 's/main/principal/' snapshotted.go" }),
})
vim.fn.writefile({ "package main", "", "func principal() {}" }, snapshotted)
local shell_edit = edit.on_event({
  event = "after_tool_call",
  tool = "run_command",
  input = vim.json.encode({ command = "sed -i 's/main/principal/' snapshotted.go" }),
})
eq(shell_edit ~= nil, true, "the shell edit is still applied")
eq(shell_edit.had_buffer, false, "the file is still not open in a buffer")
eq(shape(shell_edit.ranges), "3-3+1-1", "a shell edit of a closed file is diffed against its pre-image")

edit.on_event({
  event = "before_tool_call",
  tool = "run_command",
  input = vim.json.encode({ command = "cat a | sed -i 's/x/y/' snapshotted.go" }),
})
vim.fn.writefile({ "package main", "", "func principal() { changed }" }, snapshotted)
local refused = edit.on_event({
  event = "after_tool_call",
  tool = "run_command",
  input = vim.json.encode({ command = "cat a | sed -i 's/x/y/' snapshotted.go" }),
})
eq(refused, nil, "a refused command is still refused when a before event preceded it")

local ghost = tmp .. "/ghost.go"
eq(
  edit.on_event(payload("run_command", { command = "sed -i 's/x/y/' ghost.go" })),
  nil,
  "a command naming a file that does not exist marks nothing"
)
eq(marks.of(ghost), nil, "the missing file did not enter the marks")

eq(
  edit.on_event(payload("run_command", { command = "cat a | sed -i 's/x/y/' cmd.go" })),
  nil,
  "a piped shell edit marks nothing"
)
eq(
  edit.on_event(payload("run_command", { command = "sed -i 's/x/y/' cmd.go > out.log" })),
  nil,
  "a redirected shell edit marks nothing"
)
eq(
  edit.on_event(payload("run_command", { command = "go test ./..." })),
  nil,
  "a command that is not an edit marks nothing"
)
eq(#marks.of(command_file).ranges, 0, "refused commands left the marks alone")

local opened = tmp .. "/opened.go"
vim.fn.writefile({ "package main", "", "func main() {}" }, opened)
vim.cmd("edit " .. vim.fn.fnameescape(opened))
vim.fn.writefile({ "package main", "", "func principal() {}" }, opened)
local visible = edit.on_event(payload("run_command", { command = "sed -i 's/main/principal/' opened.go" }))
eq(visible ~= nil, true, "a shell edit of an open buffer is applied")
eq(visible.had_buffer, true, "the open buffer was found")
eq(shape(visible.ranges), "3-3+1-1", "the shell edit was diffed against the buffer")
eq(
  vim.api.nvim_buf_get_lines(0, 2, 3, false)[1],
  "func principal() {}",
  "the open buffer was reloaded"
)

local payload_file = tmp .. "/payload.go"
vim.fn.writefile({ "one", "TWO" }, payload_file)
local edit_file = edit.on_event(payload("edit_file", { path = "payload.go", old = "two", new = "TWO" }))
eq(edit_file ~= nil, true, "edit_file still resolves its path from the payload")
eq(shape(edit_file.ranges), "2-2+1-1", "edit_file still diffs the payload's old/new")
eq(
  edit.on_event(payload("write_file", { path = "ghost-file.go", content = "x" })),
  nil,
  "write_file of a file that does not exist marks nothing"
)

io.write("\n-- apply_remote, the socket entry point\n")

local remote = tmp .. "/remote.go"
vim.fn.writefile({ "x", "y" }, remote)
local direct = edit.apply_remote(remote, { { first = 2, last = 2, added = 1, removed = 1 } }, { tool = "ide" })
eq(shape(direct.ranges), "2-2+1-1", "apply_remote uses the caller's span")
eq(marks.of(remote).meta.tool, "ide", "apply_remote records its metadata")

vim.fn.writefile({ "x", "z" }, remote)
local fallback = edit.apply_remote(remote, nil, { tool = "ide" })
eq(shape(fallback.ranges), "2-2+1-1", "apply_remote without ranges still diffs")

local relative = edit.apply_remote("remote.go", { { first = 1, last = 1, added = 0, removed = 0 } }, {})
eq(relative ~= nil, true, "apply_remote resolves a root-relative path")
eq(shape(relative.ranges), "1-1+0-0", "the root-relative span is used verbatim")
eq(
  edit.apply_remote("absent.go", { { first = 1, last = 1, added = 1, removed = 0 } }, {}),
  nil,
  "apply_remote leaves a missing file alone"
)

io.write(("\n%d checks, %d failures\n"):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
