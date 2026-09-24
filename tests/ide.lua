local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(root)

local uv = vim.uv or vim.loop
local discover = require("kori.ide.discover")
local frame = require("kori.ide.frame")
local ide = require("kori.ide")

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

local now = "2026-09-24T16:00:00Z"
local pid = uv.os_getpid()

local function wait(fn, ms)
  return vim.wait(ms or 3000, fn, 20)
end

local function line(lines, index)
  wait(function()
    return #lines >= index
  end)
  return lines[index] and vim.json.decode(lines[index]) or {}
end

local function file(dir, name, text)
  vim.fn.mkdir(dir, "p")
  local fd = assert(io.open(dir .. "/" .. name, "w"))
  fd:write(text)
  fd:close()
end

local function entry(dir, name, socket, root)
  file(dir, name, vim.json.encode({ v = 1, pid = pid, root = root, socket = socket, started = now }))
end

local function fixture()
  local base = vim.fn.tempname()
  local dir = base .. "/ide"
  local sock = base .. "/kori.sock"
  entry(dir, "1.json", sock, base)
  return base, dir, sock
end

local function serve(path, on_conn, on_line)
  local srv = assert(uv.new_pipe(false))
  assert(srv:bind(path))
  local state = { pipe = srv, conns = {} }
  srv:listen(8, function(err)
    if err then
      return
    end
    local conn = uv.new_pipe(false)
    if not srv:accept(conn) then
      return
    end
    state.conns[#state.conns + 1] = conn
    local decoder = frame.new()
    conn:read_start(function(_, data)
      if not data then
        return
      end
      for _, text in ipairs(frame.split(decoder, data)) do
        on_line(conn, text)
      end
    end)
    on_conn(conn)
  end)
  return state
end

local function shutdown(server)
  for _, conn in ipairs(server.conns) do
    if not conn:is_closing() then
      conn:close()
    end
  end
  if not server.pipe:is_closing() then
    server.pipe:close()
  end
end

io.write("\n-- framing\n")

local decoder = frame.new()
eq(#frame.split(decoder, '{"a":1}\n{"b":'), 1, "a complete line is returned alone")
eq(decoder.tail, '{"b":', "the partial tail is kept for the next chunk")
eq(#frame.split(decoder, '2}\n'), 1, "the tail completes on the next chunk")
eq(decoder.tail, "", "the tail is drained once completed")

io.write("\n-- discovery\n")

local home = vim.fn.tempname()
local disc = home .. "/ide"
local alive_sock = home .. "/alive.sock"
entry(disc, "alive.json", alive_sock, home)
file(disc, "dead.json", vim.json.encode({ v = 1, pid = 999999, root = home, socket = home .. "/dead.sock", started = "2026-09-24T18:00:00Z" }))
file(disc, "other.json", vim.json.encode({ v = 1, pid = pid, root = home .. "/elsewhere", socket = home .. "/other.sock", started = "2026-09-24T20:00:00Z" }))
file(disc, "broken.json", "{ this is not json")
file(disc, "notes.txt", "not a session file")

eq(discover.alive(pid), true, "the current pid counts as alive")
eq(discover.alive(999999), false, "a dead pid is not alive")
eq(discover.parse(disc .. "/broken.json"), nil, "a malformed discovery file is ignored")
eq(discover.find(home, disc).socket, alive_sock, "a matching root beats a newer dead pid")
eq(discover.find(home .. "/sub", disc).socket, alive_sock, "a root below the session root still matches")
eq(discover.find("/nowhere/at/all", disc).socket, home .. "/other.sock", "without a root the newest session wins")

local states = {}
local lonely = ide.setup({
  root = "/nowhere/at/all",
  dir = home .. "/missing",
  on_status = function(value)
    states[#states + 1] = value
  end,
})
eq(lonely:connect(), false, "connect fails when no session is filed")
eq(lonely.last_error, "no kori session found", "the failure keeps its reason")
eq(wait(function() return states[#states] == "error" end), true, "an explicit connect reports the failure as an error")

io.write("\n-- connect, handshake and dispatch\n")

local base, ddir, spath = fixture()
local events, statuses, sent = {}, {}, {}
local srv = serve(spath, function(conn)
  conn:write(vim.json.encode({ v = 1, t = "hello", pid = 1234, root = base, model = "m", version = "0.76.0" }) .. "\n")
  conn:write(vim.json.encode({ v = 1, t = "edit", id = "e1", path = base .. "/a.lua", tool = "edit_file", first = 2, last = 2, added = 1, removed = 1 }) .. "\n")
  conn:write(vim.json.encode({ v = 1, t = "done", reason = "end_turn", cost = 0.01 }) .. "\n")
end, function(_, text)
  sent[#sent + 1] = text
end)

local client = ide.setup({
  root = base, dir = ddir, retry_min = 100, retry_max = 400,
  on_event = function(ev) events[#events + 1] = ev end,
  on_status = function(value) statuses[#statuses + 1] = value end,
})

eq(client:is_connected(), false, "a fresh client is not connected")
eq(client:send_hello(), false, "sending before connect is refused, not queued")
eq(client:connect(), true, "connect finds the session and starts the handshake")

local hello = line(sent, 1)
eq(hello.t, "hello", "the client greets the session on connect")
eq(hello.root, base, "the greeting carries the root")
eq(hello.pid, pid, "the greeting carries the editor pid")

eq(wait(function() return #events >= 3 end), true, "hello, edit and done all arrive")
eq(events[1].t, "hello", "the session hello is dispatched")
eq(events[2].t, "edit", "the edit is dispatched")
eq(events[2].first, 2, "the edit first line survives decoding")
eq(events[3].t, "done", "done is dispatched")
eq(events[3].reason, "end_turn", "the done reason survives")
eq(client:is_connected(), true, "the client reports itself connected")
eq(statuses[1], "connected", "connected is the first status change")

client:send_prompt({ text = "fix this", path = base .. "/a.lua", line = 12, branch = "main" })
local prompt = line(sent, 2)
eq(prompt.t, "send", "send_prompt reaches the session as a send")
eq(prompt.text, "fix this", "the prompt text is carried")
eq(prompt.line, 12, "the prompt line is carried")
eq(prompt.branch, "main", "the prompt branch is carried")
eq(prompt.v, 1, "an outgoing message carries v 1")

client:send_open({ path = base .. "/b.lua", line = 3 })
local opened = line(sent, 3)
eq(opened.t, "open", "send_open uses the open type")
eq(opened.line, 3, "the open line is carried")

client:send_approval({ id = "a1", allow = false })
local approval = line(sent, 4)
eq(approval.t, "approve", "send_approval uses the approve type")
eq(approval.id, "a1", "the approval id is carried")
eq(approval.allow, false, "a refusal is carried as false")

client:send_stop()
eq(line(sent, 5).t, "stop", "send_stop uses the stop type")

client:close()
eq(client:is_connected(), false, "close drops the socket")
eq(wait(function() return statuses[#statuses] == "disconnected" end), true, "close reports the disconnection")
shutdown(srv)

io.write("\n-- a split line, an unknown type and a malformed line\n")

local base2, ddir2, spath2 = fixture()
local events2 = {}
local srv2 = serve(spath2, function(conn)
  conn:write('{"v":1,"t":"turn","n":1}\n{"v":1,"t":"ed')
  local timer = uv.new_timer()
  timer:start(60, 0, function()
    conn:write('it","id":"e2","path":"x.lua","first":1,"last":1}\n')
    conn:write('{"v":1,"t":"future_thing","x":1}\n')
    conn:write("this is not json at all\n")
    conn:write('{"v":1,"t":"turn","n":2,"extra":{"brand":"new"}}\n')
    timer:close()
  end)
end, function() end)

local client2 = ide.setup({
  root = base2, dir = ddir2,
  on_event = function(ev) events2[#events2 + 1] = ev end,
})

eq(client2:connect(), true, "the second client connects")
eq(wait(function() return #events2 >= 3 end), true, "the events after the split line arrive")
eq(events2[1].t, "turn", "the first complete line dispatches alone")
eq(events2[2].t, "edit", "a line split across two writes is decoded whole")
eq(events2[2].path, "x.lua", "the split line carries its fields")
eq(events2[3].t, "turn", "the stream continues past the bad line")
eq(events2[3].n, 2, "the event after the malformed line arrives")
eq(events2[3].extra.brand, "new", "unknown fields are passed through")

vim.wait(200)
eq(#events2, 3, "an unknown type and a malformed line dispatch nothing")
eq(client2:is_connected(), true, "a bad line never drops the connection")
client2:close()
shutdown(srv2)

io.write("\n-- reconnect re-runs discovery\n")

local base3, ddir3 = fixture()
local spath3 = base3 .. "/old.sock"
local spath4 = base3 .. "/new.sock"
entry(ddir3, "1.json", spath3, base3)
local hellos = 0
local statuses3 = {}
local function announce(conn)
  hellos = hellos + 1
  conn:write(vim.json.encode({ v = 1, t = "hello", pid = 9, root = base3 }) .. "\n")
end

local srv3 = serve(spath3, announce, function() end)
local srv4 = serve(spath4, announce, function() end)
local client3 = ide.setup({
  root = base3, dir = ddir3, retry_min = 100, retry_max = 300,
  on_status = function(value) statuses3[#statuses3 + 1] = value end,
})

client3:start()
eq(wait(function() return hellos >= 1 end), true, "start connects and the session greets")
eq(#srv3.conns, 1, "the first session took the connection")

srv3.conns[1]:close()
entry(ddir3, "1.json", spath4, base3)
eq(wait(function() return statuses3[#statuses3] == "disconnected" end), true, "a dropped socket reports disconnected")
eq(wait(function() return hellos >= 2 end), true, "the client reconnects on its own")
eq(#srv4.conns, 1, "the retry re-ran discovery and found the new socket")
eq(#srv3.conns, 1, "the dead socket was left alone")
eq(wait(function() return client3:is_connected() end), true, "the client is connected again")

local before = #srv4.conns
client3:stop()
eq(client3:is_connected(), false, "stop drops the socket")
eq(wait(function() return statuses3[#statuses3] == "disconnected" end), true, "stop reports the disconnection")
vim.wait(600)
eq(#srv4.conns, before, "stop leaves no retry timer behind")
shutdown(srv3)
shutdown(srv4)

io.write("\n-- an unsupported protocol version\n")

local base4, ddir4, spath5 = fixture()
local back = {}
local srv5 = serve(spath5, function(conn)
  conn:write('{"v":2,"t":"hello","pid":1}\n')
end, function(_, text)
  back[#back + 1] = text
end)

local client4 = ide.setup({ root = base4, dir = ddir4 })
eq(client4:connect(), true, "the client connects before the version check")
local reply = line(back, 2)
eq(reply.t, "error", "an unsupported version is answered with an error")
eq(reply.reason, "unsupported protocol version", "with the reason the spec names")
eq(wait(function() return not client4:is_connected() end), true, "the connection closes after the error")
shutdown(srv5)

io.write(("\n%d checks, %d failures\n"):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
