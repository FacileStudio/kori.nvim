local M = {}

local cmdedit = require("kori.cmdedit")
local config = require("kori.config")
local marks = require("kori.marks")

local snapshots = {}

local function join(lines)
  if #lines == 0 then
    return ""
  end
  return table.concat(lines, "\n") .. "\n"
end

local function split(text)
  if text == "" then
    return {}
  end
  local trimmed = text:sub(-1) == "\n" and text:sub(1, -2) or text
  return vim.split(trimmed, "\n", { plain = true })
end

local function before_lines(lines, meta)
  if type(meta) ~= "table" or type(meta.old) ~= "string" or type(meta.new) ~= "string" then
    return nil
  end
  if meta.new == "" then
    return nil
  end
  local text = join(lines)
  local from, to = text:find(meta.new, 1, true)
  if not from then
    return nil
  end
  return split(text:sub(1, from - 1) .. meta.old .. text:sub(to + 1))
end

local function decode_input(input)
  if type(input) == "table" then
    return input
  end
  if type(input) ~= "string" or input == "" then
    return nil
  end
  local ok, decoded = pcall(vim.json.decode, input)
  if not ok or type(decoded) ~= "table" then
    return nil
  end
  return decoded
end

local function resolve(root, path)
  if type(path) ~= "string" or path == "" then
    return nil
  end
  local full
  if path:sub(1, 1) == "/" or path:match("^%a:[/\\]") then
    full = path
  else
    full = root .. "/" .. path
  end
  return vim.fn.fnamemodify(vim.fn.simplify(full), ":p"):gsub("/$", "")
end

local function read_lines(path)
  if vim.fn.filereadable(path) ~= 1 then
    return nil
  end
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok or type(lines) ~= "table" then
    return nil
  end
  for _, line in ipairs(lines) do
    if line:find("\0", 1, true) then
      return nil
    end
  end
  return lines
end

function M.ranges_from(old_lines, new_lines)
  local ok, hunks = pcall(vim.diff, join(old_lines), join(new_lines), { result_type = "indices" })
  if not ok or type(hunks) ~= "table" then
    return {}
  end
  local count = #new_lines
  local ceiling = math.max(count, 1)
  local ranges = {}
  for _, hunk in ipairs(hunks) do
    local removed, start_b, added = hunk[2], hunk[3], hunk[4]
    local first, last
    if added > 0 then
      first, last = start_b, start_b + added - 1
    else
      first, last = start_b + 1, start_b + 1
    end
    if count == 0 then
      first, last = 1, 1
    end
    first = math.max(1, math.min(first, ceiling))
    last = math.max(first, math.min(last, ceiling))
    ranges[#ranges + 1] = { first = first, last = last, added = added, removed = removed }
  end
  return ranges
end

local function buf_for(path)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.api.nvim_buf_get_name(buf) ~= "" then
      if vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":p") == path then
        return buf
      end
    end
  end
  return nil
end

function M.reload(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return false
  end
  if vim.api.nvim_get_option_value("buftype", { buf = buf }) ~= "" then
    return false
  end
  if vim.api.nvim_get_option_value("modified", { buf = buf }) then
    return false
  end
  local views = {}
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    views[win] = vim.api.nvim_win_call(win, vim.fn.winsaveview)
  end
  local ok = pcall(vim.api.nvim_buf_call, buf, function()
    vim.cmd("silent! keepalt edit!")
  end)
  for win, view in pairs(views) do
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_call(win, function()
        vim.fn.winrestview(view)
      end)
    end
  end
  return ok
end

local function supplied_ranges(meta)
  if type(meta) ~= "table" or type(meta.ranges) ~= "table" then
    return nil
  end
  return meta.ranges
end

local function base_of(path, buf, stale, lines, meta)
  if buf and not stale then
    return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  end
  if snapshots[path] then
    return snapshots[path]
  end
  if meta then
    return before_lines(lines, meta)
  end
  return nil
end

--- Apply a change to one file: reload its buffer, mark the changed spans.
---
--- The spans come from a caller-supplied meta.ranges when it has them, and are
--- then used verbatim with no diff run at all. Without them the buffer, the
--- previous snapshot or the payload's old/new text is the base, and the spans
--- are diffed out of it as before. A buffer holding unsaved changes is never
--- reloaded and carries no marks while it disagrees with disk.
--- @param path string absolute path of the file kori changed
--- @param meta table|nil { tool, old, new, ranges } describing the change
--- @return table|nil { path, ranges, stale, had_buffer }, nil when unreadable
function M.apply_path(path, meta)
  local lines = read_lines(path)
  if not lines then
    return nil
  end
  local buf = buf_for(path)
  local stale = buf ~= nil and vim.api.nvim_get_option_value("modified", { buf = buf })
  local given = supplied_ranges(meta)

  local ranges
  if given then
    ranges = given
  else
    local base = base_of(path, buf, stale, lines, meta)
    ranges = base and M.ranges_from(base, lines) or {}
  end

  if buf and not stale and config.get().reload.enabled then
    M.reload(buf)
  end

  snapshots[path] = lines
  marks.record(path, ranges, meta)
  return { path = path, ranges = ranges, stale = stale, had_buffer = buf ~= nil }
end

--- Apply a change to an explicit path, with an optional caller-supplied span.
---
--- The IDE socket calls this when kori itself reports what it changed, so the
--- caller knows the lines and they are used verbatim instead of being diffed.
--- Ranges are optional: without them the buffer/disk diff is the fallback, as
--- for a hook event. A path that does not exist or cannot be read is not
--- marked and returns nil.
--- @param path string absolute or root-relative path of the changed file
--- @param ranges table|nil list of { first, last, added, removed } spans
--- @param meta table|nil extra metadata stored with the marks, e.g. { tool = "ide" }
--- @return table|nil the apply_path result, nil when the path is unusable
function M.apply_remote(path, ranges, meta)
  local full = resolve(config.get().root, path)
  if not full then
    return nil
  end
  local extra = type(meta) == "table" and vim.deepcopy(meta) or {}
  if type(ranges) == "table" then
    extra.ranges = ranges
  end
  return M.apply_path(full, extra)
end

local function apply_each(root, candidates, meta)
  local first
  for _, candidate in ipairs(candidates) do
    local path = resolve(root, candidate)
    if path then
      local result = M.apply_path(path, meta)
      if not first then
        first = result
      end
    end
  end
  return first
end

--- Handle one after_tool_call payload from the shim.
---
--- edit_file and write_file name their file in `path`; run_command names none,
--- so the command is parsed for the file it edits in place. Every candidate
--- that exists and is readable is marked and reloaded, and a candidate that
--- does not exist is left alone. Only the first applied result is returned,
--- which is the single result init.lua's callback expects.
--- @param payload table decoded { event, tool, input, result, retry }
--- @return table|nil the result of the first path that existed and was readable
function M.on_event(payload)
  local cfg = config.get()
  if not cfg.enabled then
    return nil
  end
  if payload.event ~= "after_tool_call" then
    return nil
  end
  local input = decode_input(payload.input)
  if not input then
    return nil
  end
  if payload.tool == "run_command" then
    return apply_each(cfg.root, cmdedit.paths(input.command), { tool = payload.tool })
  end
  local path = resolve(cfg.root, input.path)
  if not path then
    return nil
  end
  return M.apply_path(path, { tool = payload.tool, old = input.old, new = input.new })
end

function M.forget(path)
  snapshots[path] = nil
end

function M.forget_all()
  snapshots = {}
end

return M
