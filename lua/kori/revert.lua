local M = {}

local marks = require("kori.marks")
local edit = require("kori.edit")

local function key(path)
  return vim.fn.fnamemodify(path, ":p")
end

local function label(path)
  return vim.fn.fnamemodify(path, ":t")
end

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

local function read_lines(path)
  if vim.fn.filereadable(path) ~= 1 then
    return nil
  end
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok or type(lines) ~= "table" then
    return nil
  end
  return lines
end

local function occurrences(text, needle)
  local positions = {}
  local from = 1
  while true do
    local s, e = text:find(needle, from, true)
    if not s then
      break
    end
    positions[#positions + 1] = s
    from = e + 1
  end
  return positions
end

local function line_of(text, position)
  local prefix = text:sub(1, position - 1)
  local _, newlines = prefix:gsub("\n", "\n")
  return newlines + 1
end

local function guard(path, meta)
  if type(meta) ~= "table" or type(meta.old) ~= "string" or type(meta.new) ~= "string" then
    return nil, "kori recorded no old and new text for this edit"
  end
  if meta.new == "" then
    return nil, "kori recorded no new text to locate"
  end
  if meta.old == meta.new then
    return nil, "kori recorded no change to revert"
  end
  local buf = buf_for(path)
  if buf and vim.api.nvim_get_option_value("modified", { buf = buf }) then
    return nil, ("%s has unsaved changes, save or reload before reverting"):format(label(path))
  end
  local lines = read_lines(path)
  if not lines then
    return nil, ("cannot read %s"):format(label(path))
  end
  local text = join(lines)
  local positions = occurrences(text, meta.new)
  if #positions == 0 then
    return nil, ("%s no longer contains the text kori wrote"):format(label(path))
  end
  if #positions > 1 then
    return nil, ("%s holds the text kori wrote in %d places, refusing"):format(label(path), #positions)
  end
  return { buf = buf, lines = lines, text = text, at = positions[1] }
end

local function write(path, lines, buf)
  if vim.fn.writefile(lines, path) ~= 0 then
    return false, ("could not write %s"):format(label(path))
  end
  if buf and vim.api.nvim_buf_is_valid(buf) then
    edit.reload(buf)
  end
  return true
end

local function internal_hunks(meta)
  local old_lines = split(meta.old)
  local new_lines = split(meta.new)
  local ok, hunks = pcall(vim.diff, join(old_lines), join(new_lines), { result_type = "indices" })
  if not ok or type(hunks) ~= "table" then
    return nil
  end
  local count = #new_lines
  local ceiling = math.max(count, 1)
  local out = {}
  for _, hunk in ipairs(hunks) do
    local start_a, removed, start_b, added = hunk[1], hunk[2], hunk[3], hunk[4]
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
    local block = {}
    for i = start_a, start_a + removed - 1 do
      block[#block + 1] = old_lines[i]
    end
    out[#out + 1] = { first = first, last = last, added = added, block = block }
  end
  return out
end

local function splice(lines, from, to, block)
  local out = {}
  for i = 1, from - 1 do
    out[#out + 1] = lines[i]
  end
  for _, line in ipairs(block) do
    out[#out + 1] = line
  end
  for i = to + 1, #lines do
    out[#out + 1] = lines[i]
  end
  return out
end

--- Revert one hunk, restoring the old text kori replaced.
--- @param path string file path
--- @param range table hunk with first and last line numbers
--- @param meta table recorded entry meta with old and new text
--- @return boolean|nil ok true on success
--- @return string|nil reason why the revert was refused
function M.hunk(path, range, meta)
  path = key(path)
  if type(range) ~= "table" or type(range.first) ~= "number" or type(range.last) ~= "number" then
    return false, "no hunk range was given to revert"
  end
  local ctx, reason = guard(path, meta)
  if not ctx then
    return false, reason
  end
  local hunks = internal_hunks(meta)
  if not hunks then
    return false, "could not diff the recorded edit"
  end
  local offset = line_of(ctx.text, ctx.at) - 1
  local target
  for _, hunk in ipairs(hunks) do
    if offset + hunk.first == range.first and offset + hunk.last == range.last then
      target = hunk
      break
    end
  end
  if not target then
    return false, "the hunk under the cursor is not one kori recorded"
  end
  local at = offset + target.first
  local to = target.added == 0 and at - 1 or offset + target.last
  if at < 1 or to > #ctx.lines then
    return false, "the recorded hunk no longer lines up with the file"
  end
  local restored = splice(ctx.lines, at, to, target.block)
  if join(restored) == ctx.text then
    return false, "reverting would change nothing"
  end
  return write(path, restored, ctx.buf)
end

--- Revert the hunk under the cursor in a buffer.
--- @param buf integer buffer handle
--- @param path string|nil file path, defaults to the buffer name
--- @return boolean|nil ok true on success
--- @return string|nil reason why the revert was refused
function M.buffer(buf, path)
  if buf == 0 then
    buf = vim.api.nvim_get_current_buf()
  end
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return false, "no valid buffer to revert"
  end
  path = path or vim.api.nvim_buf_get_name(buf)
  if not path or path == "" then
    return false, "the buffer has no file to revert"
  end
  path = key(path)
  local entry = marks.of(path)
  if not entry or #entry.ranges == 0 then
    return false, ("no kori edit is recorded for %s"):format(label(path))
  end
  local win = vim.fn.win_findbuf(buf)[1]
  if not win then
    return false, "the buffer is not shown in a window"
  end
  local cursor = vim.api.nvim_win_get_cursor(win)[1]
  for _, range in ipairs(entry.ranges) do
    if cursor >= range.first and cursor <= range.last then
      return M.hunk(path, range, entry.meta)
    end
  end
  return false, "the cursor is not on a kori edit"
end

--- Revert every hunk recorded for a file in one reverse edit.
--- @param path string file path
--- @return integer count number of hunks reverted, zero on refusal
--- @return string|nil reason why the revert was refused
function M.all(path)
  path = key(path)
  local entry = marks.of(path)
  if not entry then
    return 0, ("no kori edit is recorded for %s"):format(label(path))
  end
  if #entry.ranges == 0 then
    return 0, ("no hunks are recorded for %s"):format(label(path))
  end
  local ctx, reason = guard(path, entry.meta)
  if not ctx then
    return 0, reason
  end
  local meta = entry.meta
  local restored = ctx.text:sub(1, ctx.at - 1) .. meta.old .. ctx.text:sub(ctx.at + #meta.new)
  local lines = split(restored)
  if join(lines) == ctx.text then
    return 0, "reverting would change nothing"
  end
  local ok, why = write(path, lines, ctx.buf)
  if not ok then
    return 0, why
  end
  return #entry.ranges
end

return M