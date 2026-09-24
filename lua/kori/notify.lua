local M = {}

local uv = vim.uv or vim.loop

local defaults = {
  enabled = true,
  window_ms = 250,
  root = nil,
  notify = nil,
}

local accepted = { enabled = true, window_ms = true, root = true, notify = true }

local options = {
  enabled = defaults.enabled,
  window_ms = defaults.window_ms,
  root = defaults.root,
  notify = defaults.notify,
}

local pending = {}
local order = {}

local function display(path)
  local root = options.root
  if root and root ~= "" and path:sub(1, #root) == root then
    return path:sub(#root + 2)
  end
  return vim.fn.fnamemodify(path, ":~")
end

local function lines_of(path)
  local ok, content = pcall(vim.fn.readfile, path)
  if not ok or type(content) ~= "table" then
    return nil
  end
  return #content
end

local function summary(path, entry)
  local added, removed = 0, 0
  for _, range in ipairs(entry.ranges) do
    added = added + (range.added or 0)
    removed = removed + (range.removed or 0)
  end
  local where = #entry.ranges == 1 and ("line " .. entry.ranges[1].first) or (#entry.ranges .. " places")
  local count = lines_of(path)
  if not count then
    return ("kori changed %s (%s, +%d -%d)"):format(display(path), where, added, removed)
  end
  local noun = count == 1 and "line" or "lines"
  return ("kori changed %s (%s, %d %s, +%d -%d)"):format(display(path), where, count, noun, added, removed)
end

local function emit(message, level)
  if not options.enabled then
    return false
  end
  local target = options.notify or vim.notify
  target(message, level)
  return true
end

local function disarm(timer)
  if not timer then
    return
  end
  timer:stop()
  if not timer:is_closing() then
    timer:close()
  end
end

local function forget(path)
  pending[path] = nil
  for index, candidate in ipairs(order) do
    if candidate == path then
      table.remove(order, index)
      break
    end
  end
end

local function arm(path, timer)
  disarm(timer)
  local handle = uv.new_timer()
  handle:start(options.window_ms, 0, vim.schedule_wrap(function()
    M.flush(path)
  end))
  return handle
end

local function snapshot(range)
  return {
    first = range.first,
    last = range.last,
    added = range.added,
    removed = range.removed,
  }
end

local function refused(opts)
  if opts.window_ms ~= nil and (type(opts.window_ms) ~= "number" or opts.window_ms < 0) then
    return "window_ms must be a non-negative number"
  end
  if opts.enabled ~= nil and type(opts.enabled) ~= "boolean" then
    return "enabled must be a boolean"
  end
  if opts.root ~= nil and type(opts.root) ~= "string" then
    return "root must be a string or nil"
  end
  if opts.notify ~= nil and type(opts.notify) ~= "function" then
    return "notify must be a function(message, level)"
  end
  return nil
end

--- Set the coalescing window, the path display root and the notification sink.
--- @param opts table|nil `enabled`, `window_ms`, `root`, `notify(message, level)`
--- @return table the effective options
function M.setup(opts)
  opts = opts or {}
  local why = refused(opts)
  if why then
    error("kori.notify: " .. why, 2)
  end
  for key, value in pairs(opts) do
    if accepted[key] then
      options[key] = value
    end
  end
  local effective = {}
  for key, value in pairs(options) do
    effective[key] = value
  end
  return effective
end

--- Queue an edit for a path, coalescing it with whatever is already pending for that file.
--- @param path string absolute path of the file kori edited
--- @param ranges table list of `{ first, last, added, removed }` from one edit event
--- @return boolean true when the edit was queued, false when it was refused
function M.record(path, ranges)
  if not options.enabled or type(path) ~= "string" or path == "" then
    return false
  end
  if type(ranges) ~= "table" or #ranges == 0 then
    return false
  end
  local entry = pending[path]
  if not entry then
    entry = { ranges = {}, timer = nil }
    pending[path] = entry
    order[#order + 1] = path
  end
  for _, range in ipairs(ranges) do
    entry.ranges[#entry.ranges + 1] = snapshot(range)
  end
  entry.timer = arm(path, entry.timer)
  return true
end

--- Deliver pending summaries now instead of waiting for the window to close.
--- @param path string|nil one file to deliver, or nil for every pending file
--- @return integer number of notifications delivered
function M.flush(path)
  local targets = path and { path } or vim.deepcopy(order)
  local delivered = 0
  for _, target in ipairs(targets) do
    local entry = pending[target]
    if entry then
      disarm(entry.timer)
      local message = summary(target, entry)
      forget(target)
      if emit(message, vim.log.levels.INFO) then
        delivered = delivered + 1
      end
    end
  end
  return delivered
end

--- Drop every pending summary and stop its timer. Call this on teardown.
--- @return integer number of pending summaries dropped, each with one timer
function M.cancel()
  local dropped = 0
  for _, target in ipairs(vim.deepcopy(order)) do
    local entry = pending[target]
    if entry then
      disarm(entry.timer)
      forget(target)
      dropped = dropped + 1
    end
  end
  return dropped
end

--- List the files with a summary waiting to be delivered, in first-seen order.
--- @return table list of absolute paths
function M._pending()
  return vim.deepcopy(order)
end

return M