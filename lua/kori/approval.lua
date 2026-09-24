--- An approval surface for the kori IDE protocol.
---
--- Anything that renders an approval is a security boundary, so this module
--- follows the protocol's rules literally. The tool's own input is shown
--- exactly as it arrived: same bytes, same order, same lines, never summarised,
--- indented or re-serialised. The answer fails closed, so only an explicit Yes
--- approves, and a closed dialog, an escape, an interrupt or any error is a
--- refusal.
---
--- The input goes into a scratch buffer rather than into the dialog's own
--- message, because `vim.fn.confirm` puts that message on the command line,
--- which truncates a long tool input at the screen edge without saying so. A
--- buffer wraps and holds every line, so what the user reads is what will run.
---
--- `vim.fn.confirm` blocks the editor until it is answered. That is the right
--- trade here: an approval is a modal decision, and the protocol gives the
--- timeout to the session ("the session's own timeout decides, and it denies"),
--- so the block cannot become an implicit yes. An interrupted dialog returns 0
--- or raises, and both paths send a refusal.

local M = {}

local HEADER = "Approve this tool call?"

--- The lines the surface puts in front of the user, with the tool's input
--- verbatim: the same text, in the same order, on the same lines.
--- @param ev table approval event with tool and input
--- @return string[] lines
function M.body(ev)
  local input = ev.input
  if type(input) ~= "string" then
    input = input == nil and "" or vim.json.encode(input)
  end
  local lines = { ("kori wants to run %s"):format(ev.tool or "a tool"), "" }
  for _, line in ipairs(vim.split(input, "\n", { plain = true })) do
    lines[#lines + 1] = line
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "Approve it once?"
  return lines
end

--- Show the lines in a scratch buffer, in a bottom split that closes with it.
--- @param lines string[] what M.body() built
--- @return integer win
local function show(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
  vim.api.nvim_set_option_value("filetype", "kori", { buf = buf })
  vim.cmd("botright split")
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  pcall(vim.api.nvim_win_set_height, win, math.max(3, math.min(#lines, 15)))
  return win
end

--- Show the call and ask for an answer. Overridable, so the test suite can pin
--- the fail-closed rules without a UI.
--- @param ev table approval event with id, tool and the raw input
--- @return boolean approved
function M.ask(ev)
  local win = show(M.body(ev))
  local ok, choice = pcall(vim.fn.confirm, HEADER, "&Yes\n&No", 2, "Question")
  if vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_close(win, true)
  end
  return ok and choice == 1
end

--- Answer an approval request.
---
--- The reply is sent on every path, the failure one included, so a session
--- waiting on this approval is told no rather than left to its own timeout.
--- A reply that cannot be delivered is reported, because a lost Yes is exactly
--- the silent failure this surface exists to prevent.
--- @param ev table approval event with id, tool and the raw input
--- @param reply function called with the id and a boolean allow
--- @return boolean approved
function M.handle(ev, reply)
  if type(ev) ~= "table" or ev.id == nil then
    return false
  end
  local ok, approved = pcall(M.ask, ev)
  local allow = ok and approved == true
  local sent, delivered = pcall(reply, ev.id, allow)
  if not sent or delivered == false then
    vim.notify(
      "kori.nvim: the approval answer could not be sent; the session will deny it",
      vim.log.levels.WARN
    )
  end
  return allow
end

return M
