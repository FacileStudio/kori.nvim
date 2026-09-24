--- Unix socket transport for the kori IDE protocol.
--- It owns the pipe, the newline framing, the session lookup and the bounded
--- backoff that reconnects when the socket drops. Message semantics live in
--- kori.ide, not here.

local M = {}

local uv = vim.uv or vim.loop
local frame = require("kori.ide.frame")
local discover = require("kori.ide.discover")

local RETRY_MIN = 250
local RETRY_MAX = 8000

local Transport = {}
Transport.__index = Transport

local function teardown(self)
  if self.sock then
    pcall(self.sock.read_stop, self.sock)
    if not self.sock:is_closing() then
      self.sock:close()
    end
    self.sock = nil
  end
  self.connected = false
  self.frames = frame.new()
end

local function clear_timer(self)
  local timer = self.timer
  if not timer then
    return
  end
  self.timer = nil
  pcall(timer.stop, timer)
  if not timer:is_closing() then
    timer:close()
  end
end

local function status(self, state, detail)
  self.state = state
  if self.on_status then
    self.on_status(state, detail)
  end
end

local function retry(self)
  if not self.autostart or self.timer or self.sock then
    return
  end
  local delay = math.min(self.retry_max, self.retry_min * 2 ^ self.attempts)
  self.attempts = self.attempts + 1
  local timer = uv.new_timer()
  self.timer = timer
  timer:start(delay, 0, vim.schedule_wrap(function()
    clear_timer(self)
    self:_attempt(false)
  end))
end

local function drop(self, state, detail)
  local was = self.connected
  teardown(self)
  if was or detail then
    status(self, state, detail)
  end
  retry(self)
end

local function fail(self, loud, reason)
  self.last_error = reason
  if loud then
    status(self, "error", reason)
  end
  retry(self)
end

local function read(self, sock, err, data)
  if self.sock ~= sock then
    return
  end
  if err then
    drop(self, "error", err)
    return
  end
  if not data then
    drop(self, "disconnected")
    return
  end
  for _, line in ipairs(frame.split(self.frames, data)) do
    if self.sock ~= sock then
      return
    end
    if self.on_line then
      self.on_line(line)
    end
  end
end

local function ready(self, sock)
  self.connected = true
  self.attempts = 0
  sock:read_start(function(err, data)
    vim.schedule(function()
      read(self, sock, err, data)
    end)
  end)
  if self.on_connected then
    self.on_connected()
  end
  status(self, "connected")
end

function Transport._attempt(self, loud)
  if self.sock then
    return true
  end
  local entry = discover.find(self.root, self.dir)
  if not entry then
    fail(self, loud, "no kori session found")
    return false, "no kori session found"
  end
  local sock = uv.new_pipe(false)
  if not sock then
    fail(self, loud, "cannot create socket")
    return false, "cannot create socket"
  end
  self.sock = sock
  self.frames = frame.new()
  local ok = pcall(sock.connect, sock, entry.socket, function(err)
    vim.schedule(function()
      if self.sock ~= sock then
        return
      end
      if err then
        teardown(self)
        fail(self, loud, err)
        return
      end
      ready(self, sock)
    end)
  end)
  if not ok then
    teardown(self)
    fail(self, loud, "cannot connect " .. entry.socket)
    return false, "cannot connect"
  end
  return true
end

--- Connect once. A failure is reported through on_status only when loud is set.
--- @param loud boolean
--- @return boolean ok
--- @return string|nil err
function Transport.connect(self, loud)
  return self:_attempt(loud == true)
end

--- Enable reconnection and connect now. A missing session is not an error here.
--- @return boolean ok
--- @return string|nil err
function Transport.start(self)
  self.autostart = true
  return self:_attempt(false)
end

--- Drop the socket and cancel any pending retry timer.
--- @return nil
function Transport.close(self)
  local was = self.connected
  teardown(self)
  clear_timer(self)
  if was then
    status(self, "disconnected")
  end
end

--- Stop reconnecting and close everything. The transport can be started again.
--- @return nil
function Transport.stop(self)
  self.autostart = false
  self.attempts = 0
  self:close()
end

--- Write one complete line, newline included.
--- @param line string
--- @return boolean written
function Transport.write(self, line)
  if not self:is_connected() then
    return false
  end
  local written, err = self.sock:write(line .. "\n")
  if not written then
    drop(self, "error", err)
    return false
  end
  return true
end

--- Whether a live socket is attached.
--- @return boolean connected
function Transport.is_connected(self)
  return self.connected == true and self.sock ~= nil
end

--- Create a transport.
--- @param opts table|nil root, dir, retry_min, retry_max, on_line, on_status, on_connected
--- @return table transport
function M.new(opts)
  opts = opts or {}
  return setmetatable({
    root = opts.root,
    dir = opts.dir,
    retry_min = opts.retry_min or RETRY_MIN,
    retry_max = opts.retry_max or RETRY_MAX,
    on_line = opts.on_line,
    on_status = opts.on_status,
    on_connected = opts.on_connected,
    state = "disconnected",
    connected = false,
    autostart = false,
    attempts = 0,
    frames = frame.new(),
  }, Transport)
end

return M
