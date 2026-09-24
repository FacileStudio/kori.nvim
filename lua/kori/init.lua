local M = {}

local accept = require("kori.accept")
local approval = require("kori.approval")
local config = require("kori.config")
local context = require("kori.context")
local edit = require("kori.edit")
local ide = require("kori.ide")
local keymaps = require("kori.keymaps")
local marks = require("kori.marks")
local notify = require("kori.notify")
local pane = require("kori.pane")
local revert = require("kori.revert")
local spool = require("kori.spool")
local ui = require("kori.ui")

local runtime = { spool = nil, client = nil, session = nil, turn = nil, tool = nil, autocmds = {} }

local function warn(msg)
  vim.notify("kori.nvim: " .. msg, vim.log.levels.WARN)
end

local function tell(msg)
  local cfg = config.get()
  if not (cfg.notify and cfg.notifications.enabled) then
    return
  end
  vim.notify("kori.nvim: " .. msg, vim.log.levels.INFO)
end

local function fire(pattern, data)
  vim.api.nvim_exec_autocmds("User", { pattern = pattern, data = data })
end

local function peek_here()
  local path = context.path()
  local entry = path ~= "" and marks.of(path) or nil
  if not entry or #entry.ranges == 0 then
    vim.notify("kori.nvim: no kori edits in this buffer", vim.log.levels.INFO)
    return
  end
  ui.peek(path, entry.ranges)
end

local function revert_here()
  local path = context.path()
  if path == "" then
    warn("this buffer has no file to revert")
    return
  end
  local ok, reason = revert.buffer(0, path)
  if ok then
    vim.notify("kori.nvim: reverted the edit here", vim.log.levels.INFO)
  else
    warn(tostring(reason))
  end
end

local function attached()
  return runtime.client ~= nil and runtime.client:is_connected()
end

local function send(prompt, whole)
  if not attached() then
    warn("no kori session is attached, start one with :KoriToggle")
    return
  end
  local text = prompt
  if not text or text == "" then
    vim.ui.input({ prompt = "kori: " }, function(typed)
      if typed and typed ~= "" then
        runtime.client:send_prompt(context.payload(typed, whole))
      end
    end)
    return
  end
  runtime.client:send_prompt(context.payload(text, whole))
end

local function no_session()
  warn("no kori session is attached, start one with :KoriToggle")
  return false
end

local function open_here()
  if not attached() then
    return no_session()
  end
  local path = context.path()
  if path == "" then
    warn("this buffer has no file to show in kori")
    return false
  end
  return runtime.client:send_open({ path = path, line = vim.fn.line(".") })
end

local function cancel()
  if not attached() then
    return no_session()
  end
  return runtime.client:send_stop()
end

local function on_spool_event(payload)
  local result = edit.on_event(payload)
  if result then
    vim.schedule(function()
      accept.edit(result)
    end)
  end
end

--- The line a finished run is announced with, including what it cost when the
--- session's backend reported a price. A backend that reports none sends zero,
--- and a run is not "free", it is unpriced, so the figure is left off rather
--- than printed as $0.0000.
--- @param ev table the done event
--- @return string line
local function done_line(ev)
  local reason = ev.reason or "end_turn"
  local cost = tonumber(ev.cost)
  if not cost or cost <= 0 then
    return ("run finished (%s)"):format(reason)
  end
  return ("run finished (%s) · $%.4f"):format(reason, cost)
end

--- Give every event the protocol defines a path to the user.
---
--- hello, turn and done are announced, edit is applied and marked, approval is
--- put in front of the user as a real dialog, error is reported loudly, and
--- tool updates the runtime and fires `User KoriTool`, which is what a
--- statusline plugin listens to. Nothing is dropped: an event type the
--- protocol adds later is ignored by kori.ide before it ever reaches here.
--- @param ev table one decoded session event
--- @return nil
local function on_ide_event(ev)
  local kind = ev.t
  if kind == "hello" then
    runtime.session = ev
    local version = ev.version and (" " .. ev.version) or ""
    local model = ev.model and (" (" .. ev.model .. ")") or ""
    fire("KoriHello", ev)
    tell("attached to kori" .. version .. model)
    return
  end
  if kind == "turn" then
    runtime.turn = ev.n
    fire("KoriTurn", ev)
    tell(("turn %s started"):format(tostring(ev.n or "?")))
    return
  end
  if kind == "edit" then
    local ranges
    if type(ev.first) == "number" and type(ev.last) == "number" then
      ranges = { { first = ev.first, last = ev.last, added = ev.added, removed = ev.removed } }
    end
    local result = edit.apply_remote(ev.path, ranges, { tool = ev.tool })
    if not result then
      warn(("kori changed %s, which could not be read"):format(tostring(ev.path)))
      return
    end
    accept.edit(result)
    return
  end
  if kind == "tool" then
    runtime.tool = ev
    accept.tool(ev)
    return
  end
  if kind == "approval" then
    approval.handle(ev, function(id, allow)
      if not runtime.client then
        return false
      end
      return runtime.client:send_approval({ id = id, allow = allow })
    end)
    return
  end
  if kind == "done" then
    fire("KoriDone", ev)
    tell(done_line(ev))
    return
  end
  if kind == "error" then
    vim.notify(
      ("kori.nvim: the session reported an error: %s"):format(ev.reason or "unknown"),
      vim.log.levels.ERROR
    )
  end
end

local function install_keymaps()
  keymaps.install({
    marks = marks,
    toggle = function()
      pane.toggle()
    end,
    changes = function()
      ui.changes()
    end,
    peek = peek_here,
    revert = revert_here,
    send = function()
      send(nil, false)
    end,
  })
end

local function drop_runtime()
  if runtime.spool then
    spool.stop(runtime.spool)
    runtime.spool = nil
  end
  if runtime.client then
    runtime.client:stop()
    runtime.client = nil
  end
  notify.cancel()
  for _, id in ipairs(runtime.autocmds) do
    pcall(vim.api.nvim_del_autocmd, id)
  end
  runtime.autocmds = {}
end

local function watch_spool(cfg)
  local state, err = spool.start(cfg, on_spool_event)
  if err then
    vim.notify("kori.nvim: " .. err, vim.log.levels.ERROR)
    return
  end
  runtime.spool = state
end

local function attach_ide(cfg)
  if not cfg.ide.enabled then
    return
  end
  runtime.client = ide.setup({
    root = cfg.root,
    dir = cfg.ide.dir,
    retry_min = cfg.ide.retry_min_ms,
    retry_max = cfg.ide.retry_max_ms,
    on_event = on_ide_event,
    on_status = function(state)
      vim.api.nvim_exec_autocmds("User", { pattern = "KoriStatus", data = { state = state } })
    end,
  })
  runtime.client:start()
end

--- Attach to a session, or resume looking for one after a detach.
--- @return boolean started
local function attach()
  local cfg = config.get()
  if not cfg.ide.enabled then
    warn("the IDE socket is off: ide.enabled is false")
    return false
  end
  if attached() then
    tell("already attached to a session")
    return true
  end
  if runtime.client then
    runtime.client:start()
  else
    attach_ide(cfg)
  end
  tell("looking for a kori session")
  return true
end

--- Stop reconnecting and drop the socket, leaving the pane and kori alone.
--- @return boolean detached
local function detach()
  if not runtime.client then
    warn("no kori session is attached")
    return false
  end
  runtime.client:stop()
  tell("detached; kori keeps running")
  return true
end

--- Configure the plugin and start watching for kori's edits.
--- @param opts table|nil options, merged over the defaults
--- @return table the effective configuration
function M.setup(opts)
  local cfg = config.setup(opts)

  marks.setup(cfg.marks)
  notify.setup({
    enabled = cfg.notify and cfg.notifications.enabled,
    window_ms = cfg.notifications.window_ms,
    root = cfg.root,
  })

  drop_runtime()
  install_keymaps()

  runtime.autocmds[#runtime.autocmds + 1] = vim.api.nvim_create_autocmd("BufReadPost", {
    callback = accept.refresh_current_buffer,
    desc = "kori: reapply edit marks",
  })

  if not cfg.enabled then
    return cfg
  end

  watch_spool(cfg)
  attach_ide(cfg)
  return cfg
end

--- Show the files and hunks kori changed.
--- @return nil
function M.changes()
  ui.changes()
end

--- Forget every recorded edit.
--- @return nil
function M.clear()
  marks.clear()
  edit.forget_all()
end

--- Send a prompt to the attached session, using the current editor context.
--- @param text string|nil the prompt, or nil to ask interactively
--- @param whole boolean|nil send the whole buffer rather than the selection
--- @return nil
function M.send(text, whole)
  send(text, whole)
end

--- Ask the attached session to scroll its own view to the cursor's line.
--- @return boolean sent
function M.open()
  return open_here()
end

--- Cancel the run in progress in the attached session.
--- @return boolean sent
function M.cancel()
  return cancel()
end

--- Attach to a session, or resume looking for one after |:KoriDetach|.
--- @return boolean started
function M.attach()
  return attach()
end

--- Stop reconnecting and drop the IDE socket. The pane keeps running.
--- @return boolean detached
function M.detach()
  return detach()
end

--- Revert the kori edit under the cursor.
--- @return boolean reverted, string|nil reason
function M.revert()
  return revert.buffer(0, context.path())
end

--- Whether an IDE session is attached.
--- @return boolean
function M.connected()
  return attached()
end

--- A statusline fragment describing kori's recent edits.
--- @return string
function M.statusline()
  return ui.status()
end

--- Open the chat pane.
--- @param cmd table|nil command and arguments, defaulting to kori
--- @return boolean opened
function M.start(cmd)
  return pane.start(cmd)
end

--- Open the pane if closed, close it if open.
--- @param cmd table|nil command and arguments, defaulting to kori
--- @return boolean open afterwards
function M.toggle(cmd)
  return pane.toggle(cmd)
end

--- The window holding the pane, or nil.
--- @return integer|nil win
function M.pane()
  return pane.pane()
end

--- Whether the pane is on screen.
--- @return boolean
function M.is_open()
  return pane.is_open()
end

--- Close the pane window, leaving kori running.
--- @return boolean closed
function M.hide()
  return pane.hide()
end

--- The live runtime state, for tests and health checks.
--- @return table with spool, client, session, turn, tool and pane
function M._runtime()
  return {
    spool = runtime.spool,
    client = runtime.client,
    session = runtime.session,
    turn = runtime.turn,
    tool = runtime.tool,
    pane = pane.state(),
  }
end

return M