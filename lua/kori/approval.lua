local M = {}

local function confirm(ev)
  local cfg = require("kori.config").get()
  local lines = {
    ("kori wants to run %s"):format(ev.tool or "a tool"),
    "",
  }
  local input = ev.input or ""
  if type(input) == "table" then
    input = vim.json.encode(input)
  end
  for _, line in ipairs(vim.split(input, "\n", { plain = true })) do
    lines[#lines + 1] = "  " .. line
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "Approve it once?"
  local choice = vim.fn.confirm(table.concat(lines, "\n"), "&Yes\n&No", 2, "Question")
  return choice == 1, cfg
end

--- Answer an approval request.
---
--- This is an approval surface, so it fails closed. Only an explicit Yes
--- approves; a closed dialog, an escape, an interrupt or any error is a
--- refusal. The input is shown exactly as received, never summarised, because
--- the whole point is that the user reads what is about to run.
---
--- @param ev table approval event with id, tool and the raw input
--- @param reply function called with the id and a boolean allow
--- @return boolean approved
function M.handle(ev, reply)
  if type(ev) ~= "table" or ev.id == nil then
    return false
  end
  local ok, approved = pcall(confirm, ev)
  if not ok then
    pcall(reply, ev.id, false)
    return false
  end
  pcall(reply, ev.id, approved)
  return approved
end

return M