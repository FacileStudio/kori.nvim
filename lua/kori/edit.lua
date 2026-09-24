local M = {}

local config = require("kori.config")
local marks = require("kori.marks")

local snapshots = {}

local function join(lines)
  if #lines == 0 then
    return ""
  end
  return table.concat(lines, "\n") .. "\n"
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

function M.apply_path(path, meta)
  local lines = read_lines(path)
  if not lines then
    return nil
  end
  local buf = buf_for(path)
  local stale = buf ~= nil and vim.api.nvim_get_option_value("modified", { buf = buf })
  local ranges

  if stale then
    local snapshot = snapshots[path]
    ranges = snapshot and M.ranges_from(snapshot, lines) or {}
  elseif buf then
    ranges = M.ranges_from(vim.api.nvim_buf_get_lines(buf, 0, -1, false), lines)
    if config.get().reload.enabled then
      M.reload(buf)
    end
  else
    local snapshot = snapshots[path]
    ranges = snapshot and M.ranges_from(snapshot, lines) or {}
  end

  snapshots[path] = lines
  marks.record(path, ranges, meta)
  return { path = path, ranges = ranges, stale = stale, had_buffer = buf ~= nil }
end

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
  local path = resolve(cfg.root, input.path)
  if not path then
    return nil
  end
  return M.apply_path(path, { tool = payload.tool })
end

function M.forget(path)
  snapshots[path] = nil
end

function M.forget_all()
  snapshots = {}
end

return M
