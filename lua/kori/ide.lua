--- Editor side client for the kori IDE socket.
--- It decodes the session's events, dispatches them to the caller's handler and
--- sends hello, send, open, approve and stop back. Discovery, framing and the
--- reconnection backoff live in kori.ide.socket.
--- Options are injected at setup; the module never reads a global config.

local M = {}

local uv = vim.uv or vim.loop
local frame = require("kori.ide.frame")
local socket = require("kori.ide.socket")

local VERSION = 1

local EVENTS = {
  hello = true,
  turn = true,
  tool = true,
  edit = true,
  approval = true,
  done = true,
  error = true,
}

local Client = {}
Client.__index = Client

local function call(opts, name, value, detail)
  local fn = opts[name]
  if type(fn) ~= "function" then
    return
  end
  vim.schedule(function()
    pcall(fn, value, detail)
  end)
end

function Client._status(self, state, detail)
  if self.state == state and detail == nil then
    return
  end
  self.state = state
  self.last_error = detail or self.last_error
  call(self.opts, "on_status", state, detail)
end

function Client._dispatch(self, line)
  local payload = frame.decode(line)
  if not payload then
    return
  end
  if type(payload.v) == "number" and payload.v ~= VERSION then
    self:_send({ t = "error", reason = "unsupported protocol version" })
    self:close()
    return
  end
  if not EVENTS[payload.t] then
    return
  end
  call(self.opts, "on_event", payload)
end

function Client._send(self, obj)
  obj.v = VERSION
  local ok, line = pcall(vim.json.encode, obj)
  if not ok then
    return false
  end
  return self.link:write(line)
end

--- Connect once to the discovered session. A failure is reported as an error status.
--- @return boolean ok
--- @return string|nil err
function Client.connect(self)
  return self.link:connect(true)
end

--- Enable reconnection and connect now. A missing session is not an error here.
--- @return boolean ok
--- @return string|nil err
function Client.start(self)
  return self.link:start()
end

--- Drop the socket and cancel the retry timer, leaving nothing running.
--- @return nil
function Client.close(self)
  self.link:close()
end

--- Stop reconnecting and close everything. The client can still be started again.
--- @return nil
function Client.stop(self)
  self.link:stop()
end

--- Whether a live socket is attached.
--- @return boolean connected
function Client.is_connected(self)
  return self.link:is_connected()
end

--- Send the editor hello handshake. It is also sent automatically on connect.
--- @return boolean sent
function Client.send_hello(self)
  return self:_send({ t = "hello", root = self.opts.root, pid = uv.os_getpid() })
end

--- Run a prompt in the session, with the editor context attached.
--- @param prompt table text, path, line, branch
--- @return boolean sent
function Client.send_prompt(self, prompt)
  prompt = prompt or {}
  return self:_send({
    t = "send",
    text = prompt.text,
    path = prompt.path,
    line = prompt.line,
    branch = prompt.branch,
  })
end

--- Ask the session to scroll its own view to a place.
--- @param target table path, line
--- @return boolean sent
function Client.send_open(self, target)
  target = target or {}
  return self:_send({ t = "open", path = target.path, line = target.line })
end

--- Answer an approval request. allow false is a refusal, never an implicit yes.
--- @param answer table id, allow
--- @return boolean sent
function Client.send_approval(self, answer)
  answer = answer or {}
  return self:_send({ t = "approve", id = answer.id, allow = answer.allow })
end

--- Cancel the current run.
--- @return boolean sent
function Client.send_stop(self)
  return self:_send({ t = "stop" })
end

--- Create a client. Every option is injected, none is read from a global config.
--- @param opts table|nil root, dir, on_event, on_status, retry_min, retry_max
--- @return table client
function M.setup(opts)
  opts = opts or {}
  local client = setmetatable({
    opts = {
      root = opts.root,
      dir = opts.dir,
      on_event = opts.on_event,
      on_status = opts.on_status,
    },
    state = "disconnected",
  }, Client)
  client.link = socket.new({
    root = opts.root,
    dir = opts.dir,
    retry_min = opts.retry_min,
    retry_max = opts.retry_max,
    on_line = function(line)
      client:_dispatch(line)
    end,
    on_status = function(state, detail)
      client:_status(state, detail)
    end,
    on_connected = function()
      client:send_hello()
    end,
  })
  return client
end

--- The default discovery directory, ~/.kori/ide.
--- @return string path
function M.dir()
  return require("kori.ide.discover").dir()
end

return M
