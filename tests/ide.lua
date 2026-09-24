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
eq(reply.v, 1, "the reply carries the version the client does speak")
eq(reply.reason, "unsupported protocol version", "with the reason the spec names")
eq(wait(function() return not client4:is_connected() end), true, "the connection closes after the error")
shutdown(srv5)

io.write("\n-- a dead pid is ignored and its file is left alone\n")

local stale = vim.fn.tempname()
local stale_dir = stale .. "/ide"
entry(stale_dir, "live.json", stale .. "/live.sock", stale)
file(stale_dir, "gone.json", vim.json.encode({
  v = 1,
  pid = 999999,
  root = stale,
  socket = stale .. "/gone.sock",
  started = "2026-09-25T00:00:00Z",
}))
eq(discover.find(stale, stale_dir).socket, stale .. "/live.sock", "a dead pid is skipped even when it is the newest")
eq(vim.fn.filereadable(stale_dir .. "/gone.json"), 1, "the dead pid's file is left where the owner put it")

local tied = vim.fn.tempname()
local tied_dir = tied .. "/ide"
entry(tied_dir, "old.json", tied .. "/old.sock", tied)
file(tied_dir, "new.json", vim.json.encode({
  v = 1,
  pid = pid,
  root = tied,
  socket = tied .. "/new.sock",
  started = "2026-09-25T00:00:00Z",
}))
eq(discover.find(tied, tied_dir).socket, tied .. "/new.sock", "two sessions with one root: the newest started wins")

io.write("\n-- the backoff grows while no session answers\n")

local lonely2 = ide.setup({
  root = "/nowhere/at/all",
  dir = home .. "/never-filed",
  retry_min = 60,
  retry_max = 200,
})
eq(lonely2.link.attempts, 0, "a fresh transport has not tried yet")
lonely2:start()
eq(wait(function() return lonely2.link.attempts >= 2 end), true, "a failed lookup retries without being asked")
local grown = lonely2.link.attempts
vim.wait(120)
eq(lonely2.link.attempts >= grown, true, "and keeps trying on its own backoff")
lonely2:stop()
local stopped = lonely2.link.attempts
vim.wait(300)
eq(lonely2.link.attempts, stopped, "stop cancels the retry timer")

io.write("\n-- one of each event type decodes\n")

local function say(server, obj)
  local conn = server.conns[#server.conns]
  if conn then
    conn:write(vim.json.encode(obj) .. "\n")
  end
end

local base6, ddir6, spath6 = fixture()
local events6, back6 = {}, {}
local srv6 = serve(spath6, function() end, function(_, text)
  back6[#back6 + 1] = text
end)
local client6 = ide.setup({
  root = base6,
  dir = ddir6,
  on_event = function(ev)
    events6[#events6 + 1] = ev
  end,
})

eq(client6:connect(), true, "the client connects for the full event check")
eq(wait(function() return #back6 >= 1 end), true, "the client greets before the session answers")

say(srv6, { v = 1, t = "hello", pid = 7, root = base6, session = "/tmp/s.jsonl", model = "m", version = "0.76.0" })
say(srv6, { v = 1, t = "turn", n = 3 })
say(srv6, { v = 1, t = "tool", id = "t1", name = "bash", status = "start", path = "a.lua" })
say(srv6, { v = 1, t = "tool", id = "t1", name = "bash", status = "done", ok = false })
say(srv6, { v = 1, t = "edit", id = "e1", path = "a.lua", tool = "edit_file", first = 4, last = 6, added = 3, removed = 1, diff = "@@ -1 +1 @@" })
say(srv6, { v = 1, t = "approval", id = "ap1", tool = "run_command", input = '{"command":"rm x"}' })
say(srv6, { v = 1, t = "done", reason = "cancelled", cost = 0.02 })
say(srv6, { v = 1, t = "error", reason = "boom" })

eq(wait(function() return #events6 >= 8 end), true, "all eight lines arrive")
local kinds = {}
for _, ev in ipairs(events6) do
  kinds[#kinds + 1] = ev.t
end
eq(table.concat(kinds, ","), "hello,turn,tool,tool,edit,approval,done,error", "every event type is decoded, in order")
eq(events6[1].session, "/tmp/s.jsonl", "the hello carries the session file")
eq(events6[2].n, 3, "the turn carries its number")
eq(events6[3].status, "start", "the tool start is decoded")
eq(events6[4].ok, false, "the tool failure is decoded")
eq(events6[5].first, 4, "the edit span is decoded")
eq(events6[5].last, 6, "the edit span keeps its last line")
eq(events6[5].diff, "@@ -1 +1 @@", "the optional diff survives decoding")
eq(events6[6].input, '{"command":"rm x"}', "the approval input arrives verbatim")
eq(events6[7].reason, "cancelled", "the done reason is decoded")
eq(events6[8].reason, "boom", "the error reason is decoded")
client6:close()
shutdown(srv6)

io.write("\n-- the approval surface shows the input verbatim, and fails closed\n")

local approval = require("kori.approval")

local raw = '{\n  "command": "rm -rf ./build",\n  "cwd": "/tmp"\n}'
local shown = approval.body({ tool = "run_command", input = raw })
eq(table.concat(shown, "\n"):find(raw, 1, true) ~= nil, true, "the raw input appears whole, newlines and all")
eq(shown[4], '  "command": "rm -rf ./build",', "the input's own indentation is the indentation shown")
eq(shown[1], "kori wants to run run_command", "the surface names the tool")
eq(shown[#shown], "Approve it once?", "the surface asks for a decision")

local notices, fired = {}, {}
local real_notify = vim.notify
vim.notify = function(msg, level)
  notices[#notices + 1] = { msg = msg, level = level }
end

local function notice(fragment)
  for _, item in ipairs(notices) do
    if item.msg:find(fragment, 1, true) then
      return true
    end
  end
  return false
end

local function level_of(fragment)
  for _, item in ipairs(notices) do
    if item.msg:find(fragment, 1, true) then
      return item.level
    end
  end
end

local answered = {}
local function recorder(id, allow)
  answered[#answered + 1] = { id = id, allow = allow }
end

local real_ask = approval.ask

approval.ask = function()
  return true
end
eq(approval.handle({ id = "a1", tool = "bash", input = "{}" }, recorder), true, "an explicit yes approves")
eq(answered[1].id, "a1", "the answer names the approval")
eq(answered[1].allow, true, "yes is sent as allow true")

approval.ask = function()
  return false
end
eq(approval.handle({ id = "a2", tool = "bash", input = "{}" }, recorder), false, "a no refuses")
eq(answered[2].allow, false, "no is sent as allow false")

approval.ask = function()
  error("interrupted")
end
eq(approval.handle({ id = "a3", tool = "bash", input = "{}" }, recorder), false, "an interrupt refuses")
eq(answered[3].allow, false, "the refusal is sent even so, rather than nothing")

eq(
  approval.handle({ id = "a4", tool = "bash", input = "{}" }, function()
    return false
  end),
  false,
  "a reply that cannot be delivered fails closed"
)
eq(notice("could not be sent"), true, "and the user is told the answer was lost")

approval.ask = real_ask
eq(approval.ask({ id = "a5", tool = "bash", input = "{}" }), false, "a dialog with nothing behind it is a refusal")

io.write("\n-- the plugin, end to end against a fake session\n")

local base7, ddir7, spath7 = fixture()
local root7 = vim.fn.fnamemodify(base7, ":p"):gsub("/$", "")
local back7 = {}
local srv7 = serve(spath7, function() end, function(_, text)
  back7[#back7 + 1] = vim.json.decode(text)
end)

local function sent7(kind)
  local found = {}
  for _, msg in ipairs(back7) do
    if msg.t == kind then
      found[#found + 1] = msg
    end
  end
  return found
end

local function listed(name)
  for _, item in ipairs(fired) do
    if item.name == name then
      return true
    end
  end
  return false
end

for _, name in ipairs({ "KoriHello", "KoriTurn", "KoriTool", "KoriEdit", "KoriDone" }) do
  vim.api.nvim_create_autocmd("User", {
    pattern = name,
    callback = function(args)
      fired[#fired + 1] = { name = name, data = args.data }
    end,
  })
end

local kori = require("kori")
local config = require("kori.config")
local marks = require("kori.marks")
kori.setup({
  root = base7,
  spool_dir = base7 .. "/spool",
  keymaps = false,
  ide = { dir = ddir7, retry_min_ms = 100, retry_max_ms = 300 },
})

eq(wait(function() return #back7 >= 1 end), true, "the plugin attaches by itself and greets the session")
eq(back7[1].t, "hello", "its first line is the hello handshake")
eq(back7[1].v, 1, "the handshake carries v 1")
eq(back7[1].root, root7, "the handshake carries the root the plugin is working in")

say(srv7, { v = 1, t = "hello", pid = 7, root = base7, session = base7 .. "/s.jsonl", model = "opus", version = "0.76.0" })
eq(wait(function() return kori._runtime().session ~= nil end), true, "the session hello is recorded")
eq(kori._runtime().session.model, "opus", "the model is kept for :KoriStatus")
eq(kori._runtime().session.version, "0.76.0", "the version is kept too")
eq(notice("attached to kori 0.76.0 (opus)"), true, "attaching is announced to the user")
eq(listed("KoriHello"), true, "User KoriHello fires")

say(srv7, { v = 1, t = "turn", n = 2 })
eq(wait(function() return kori._runtime().turn == 2 end), true, "the turn is recorded")
eq(notice("turn 2 started"), true, "the turn is announced, not dropped")
eq(listed("KoriTurn"), true, "User KoriTurn fires")

say(srv7, { v = 1, t = "tool", id = "t9", name = "bash", status = "start", path = "a.lua" })
eq(wait(function() return kori._runtime().tool ~= nil end), true, "the tool is recorded")
eq(kori._runtime().tool.name, "bash", "the tool name is kept for :KoriStatus")
eq(listed("KoriTool"), true, "User KoriTool fires")

local edited = base7 .. "/edited.lua"
vim.fn.writefile({ "local a = 1", "local b = 2", "local c = 3" }, edited)
say(srv7, { v = 1, t = "edit", id = "e9", path = "edited.lua", tool = "edit_file", first = 2, last = 3, added = 2, removed = 1 })
eq(wait(function() return marks.of(edited) ~= nil end), true, "the edit is applied from a root-relative path")
eq(marks.of(edited).ranges[1].first, 2, "the mark uses the event's first line")
eq(marks.of(edited).ranges[1].last, 3, "the mark uses the event's last line")
eq(marks.of(edited).ranges[1].added, 2, "the added count is carried into the mark")
eq(marks.of(edited).meta.tool, "edit_file", "the tool that made the edit is recorded")
eq(listed("KoriEdit"), true, "User KoriEdit fires")

approval.ask = function()
  return true
end
say(srv7, { v = 1, t = "approval", id = "ap9", tool = "run_command", input = '{"command":"echo hi"}' })
eq(wait(function() return #sent7("approve") >= 1 end), true, "the approval is answered over the socket")
eq(sent7("approve")[1].id, "ap9", "the answer names the approval it answers")
eq(sent7("approve")[1].allow, true, "yes reaches the session as allow true")

approval.ask = function()
  error("interrupted")
end
say(srv7, { v = 1, t = "approval", id = "ap10", tool = "write_file", input = '{"path":"x","content":"y"}' })
eq(wait(function() return #sent7("approve") >= 2 end), true, "an interrupted dialog still answers")
eq(sent7("approve")[2].id, "ap10", "the second answer names its own id")
eq(sent7("approve")[2].allow, false, "an interrupt reaches the session as a refusal")
approval.ask = real_ask

say(srv7, { v = 1, t = "approval", id = "ap11", tool = "write_file", input = '{"path":"x","content":"z"}' })
eq(wait(function() return #sent7("approve") >= 3 end), true, "the real surface answers through the socket too")
eq(sent7("approve")[3].id, "ap11", "the third answer names its own id")
eq(sent7("approve")[3].allow, false, "and a dialog nothing can answer refuses")

say(srv7, { v = 1, t = "done", reason = "end_turn", cost = 0.5 })
eq(wait(function() return listed("KoriDone") end), true, "User KoriDone fires")
eq(notice("run finished (end_turn)"), true, "the end of the run is announced")

vim.cmd("edit " .. vim.fn.fnameescape(edited))
vim.api.nvim_win_set_cursor(0, { 2, 0 })
eq(kori.open(), true, ":KoriOpen reaches the session")
eq(wait(function() return #sent7("open") >= 1 end), true, "the open arrives")
eq(sent7("open")[1].path, edited, "the open carries the buffer's path")
eq(sent7("open")[1].line, 2, "the open carries the cursor's line")

eq(kori.cancel(), true, ":KoriCancel reaches the session")
eq(wait(function() return #sent7("stop") >= 1 end), true, "the cancel arrives as a stop")

kori.send("look at this")
eq(wait(function() return #sent7("send") >= 1 end), true, "a prompt reaches the session")
eq(sent7("send")[1].text:sub(1, 12), "look at this", "the prompt text is carried")
eq(sent7("send")[1].path, edited, "the prompt carries the file as context")
eq(sent7("send")[1].line, 2, "the prompt carries the line as context")
eq(type(sent7("send")[1].branch), "string", "the prompt carries a branch field")

eq(kori.detach(), true, ":KoriDetach stops the attachment")
eq(kori.connected(), false, "detaching drops the socket")
eq(kori.attach(), true, ":KoriAttach resumes looking")
eq(wait(function() return kori.connected() end), true, "attaching reconnects to the session")
eq(wait(function() return #srv7.conns >= 2 end), true, "and it took a fresh connection")

local progress = #notices
config.setup({ notify = false })
say(srv7, { v = 1, t = "turn", n = 9 })
eq(wait(function() return kori._runtime().turn == 9 end), true, "a turn is recorded even with notifications off")
vim.wait(80)
eq(#notices, progress, "a progress notification is suppressed by notify = false")

say(srv7, { v = 1, t = "error", reason = "the session gave up" })
eq(wait(function() return notice("the session gave up") end), true, "a protocol error is announced even so")
eq(level_of("the session gave up"), vim.log.levels.ERROR, "a session error is reported at ERROR level")
config.setup({ notify = true })

kori.detach()
vim.notify = real_notify
shutdown(srv7)

io.write(("\n%d checks, %d failures\n"):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
