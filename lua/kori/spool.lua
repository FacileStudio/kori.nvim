local M = {}

local uv = vim.uv or vim.loop

function M.dir(cfg)
  if cfg.spool_dir then
    return cfg.spool_dir
  end
  local xdg = vim.env.XDG_RUNTIME_DIR
  if xdg and xdg ~= "" then
    return xdg .. "/kori-nvim"
  end
  local tmp = vim.env.TMPDIR
  if not tmp or tmp == "" then
    tmp = "/tmp"
  end
  return ("%s/kori-nvim-%d"):format(tmp, uv.os_getuid())
end

local function mkdir(path)
  local ok = pcall(vim.fn.mkdir, path, "p", "0700")
  if not ok then
    return false
  end
  pcall(vim.fn.setfperm, path, "rwx------")
  return true
end

local function read_from(path, offset)
  local fd, open_err = uv.fs_open(path, "r", 420)
  if not fd then
    return nil, offset, open_err
  end
  local stat = uv.fs_fstat(fd)
  if not stat then
    uv.fs_close(fd)
    return nil, offset, "stat failed"
  end
  if stat.size < offset then
    offset = 0
  end
  if stat.size == offset then
    uv.fs_close(fd)
    return "", offset, nil
  end
  local data, read_err = uv.fs_read(fd, stat.size - offset, offset)
  uv.fs_close(fd)
  if not data then
    return nil, offset, read_err
  end
  return data, stat.size, nil
end

local function decode(chunk, on_event, on_bad)
  local ok, payload = pcall(vim.json.decode, chunk)
  if not ok or type(payload) ~= "table" then
    if on_bad then
      on_bad(chunk)
    end
    return
  end
  local ok2, err = pcall(on_event, payload)
  if not ok2 then
    vim.schedule(function()
      vim.notify("kori.nvim: " .. tostring(err), vim.log.levels.ERROR)
    end)
  end
end

local function drain(state, path, on_event, on_bad)
  local offset = state.offsets[path] or 0
  local data, new_offset, err = read_from(path, offset)
  if err then
    return
  end
  state.offsets[path] = new_offset
  if not data or data == "" then
    return
  end
  local buffered = (state.partial[path] or "") .. data
  local tail = buffered:match("([^\n]*)$")
  state.partial[path] = tail
  local complete = buffered:sub(1, #buffered - #tail)
  for line in complete:gmatch("([^\n]+)") do
    if line:match("%S") then
      decode(line, on_event, on_bad)
    end
  end
end

local function list_spools(dir)
  local found = {}
  local handle = uv.fs_scandir(dir)
  if not handle then
    return found
  end
  while true do
    local name, kind = uv.fs_scandir_next(handle)
    if not name then
      break
    end
    if kind == "file" and name:sub(-7) == ".ndjson" then
      found[#found + 1] = dir .. "/" .. name
    end
  end
  return found
end

function M.start(cfg, on_event, on_bad)
  local dir = M.dir(cfg)
  if not mkdir(dir) then
    return nil, ("cannot create spool directory %s"):format(dir)
  end

  local state = {
    dir = dir,
    offsets = {},
    partial = {},
    watched = {},
  }

  for _, path in ipairs(list_spools(dir)) do
    pcall(uv.fs_unlink, path)
  end

  local watching = pcall(function()
    local handle = uv.new_fs_event()
    handle:start(dir, {}, function()
      vim.schedule(function()
        M.poll(state, on_event, on_bad)
      end)
    end)
    state.handle = handle
  end)
  if not watching then
    state.timer = uv.new_timer()
    state.timer:start(1000, 1000, vim.schedule_wrap(function()
      M.poll(state, on_event, on_bad)
    end))
  end

  M.poll(state, on_event, on_bad)
  return state
end

function M.poll(state, on_event, on_bad)
  if not state then
    return
  end
  for _, path in ipairs(list_spools(state.dir)) do
    state.watched[path] = true
    drain(state, path, on_event, on_bad)
  end
end

function M.stop(state)
  if not state then
    return
  end
  if state.handle then
    state.handle:stop()
    if not state.handle:is_closing() then
      state.handle:close()
    end
  end
  if state.timer then
    state.timer:stop()
    if not state.timer:is_closing() then
      state.timer:close()
    end
  end
end

M._read_from = read_from
M._list_spools = list_spools

return M
