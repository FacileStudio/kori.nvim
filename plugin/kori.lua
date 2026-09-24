if vim.g.loaded_kori_nvim == 1 then
  return
end
vim.g.loaded_kori_nvim = 1

if vim.g.kori_nvim_no_defaults then
  return
end

local ok, kori = pcall(require, "kori")
if not ok then
  vim.notify("kori.nvim: " .. tostring(kori), vim.log.levels.ERROR)
  return
end

kori.setup()

local function warn(msg)
  vim.notify("kori.nvim: " .. msg, vim.log.levels.WARN)
end

vim.api.nvim_create_user_command("KoriToggle", function()
  kori.toggle()
end, { desc = "kori: toggle the chat pane" })

vim.api.nvim_create_user_command("KoriStart", function(args)
  local argv = vim.split(args.args, "%s+", { trim = true })
  kori.start(#argv > 0 and argv or nil)
end, { nargs = "*", desc = "kori: open the chat pane, optionally with another command" })

vim.api.nvim_create_user_command("KoriChanges", function()
  kori.changes()
end, { desc = "kori: files and hunks kori changed" })

vim.api.nvim_create_user_command("KoriPeek", function()
  require("kori.ui").peek(
    require("kori.context").path(),
    (require("kori.marks").of(require("kori.context").path()) or { ranges = {} }).ranges
  )
end, { desc = "kori: peek the last edit in this buffer" })

vim.api.nvim_create_user_command("KoriRevert", function()
  local done, reason = kori.revert()
  if not done then
    warn(tostring(reason))
  end
end, { desc = "kori: revert the kori edit under the cursor" })

vim.api.nvim_create_user_command("KoriRevertAll", function()
  local path = require("kori.context").path()
  if path == "" then
    warn("this buffer has no file to revert")
    return
  end
  local count, reason = require("kori.revert").all(path)
  if count == 0 then
    warn(tostring(reason))
    return
  end
  vim.notify(("kori.nvim: reverted %d hunk(s)"):format(count), vim.log.levels.INFO)
end, { desc = "kori: revert every kori edit in this file" })

vim.api.nvim_create_user_command("KoriSend", function(args)
  kori.send(args.args ~= "" and args.args or nil, false)
end, { nargs = "?", desc = "kori: send the selection and context to the session" })

vim.api.nvim_create_user_command("KoriAsk", function(args)
  kori.send(args.args ~= "" and args.args or nil, true)
end, { nargs = "?", desc = "kori: send this buffer and context to the session" })

vim.api.nvim_create_user_command("KoriOpen", function()
  kori.open()
end, { desc = "kori: ask the session to scroll its view to this line" })

vim.api.nvim_create_user_command("KoriCancel", function()
  kori.cancel()
end, { desc = "kori: cancel the run in progress" })

vim.api.nvim_create_user_command("KoriAttach", function()
  kori.attach()
end, { desc = "kori: attach to a kori session over the IDE socket" })

vim.api.nvim_create_user_command("KoriDetach", function()
  kori.detach()
end, { desc = "kori: stop reconnecting and drop the IDE socket" })

vim.api.nvim_create_user_command("KoriStatus", function()
  local state = kori._runtime()
  local session = state.session
  local tool = state.tool and ("%s/%s"):format(state.tool.name or "?", state.tool.status or "?") or "-"
  print(("kori.nvim: pane=%s session=%s root=%s turn=%s tool=%s"):format(
    kori.is_open() and "open" or "closed",
    kori.connected() and "attached" or "detached",
    session and (session.root or "") or "none",
    state.turn and tostring(state.turn) or "-",
    tool
  ))
end, { desc = "kori: report the pane, the session and the root" })

vim.api.nvim_create_user_command("KoriClear", function()
  kori.clear()
end, { desc = "kori: forget every recorded edit" })

vim.api.nvim_create_user_command("KoriHealth", function()
  require("kori.health").check()
end, { desc = "kori: run the health check" })
