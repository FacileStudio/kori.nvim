local M = {}

local function jump(marks, direction, label)
  return function()
    if not marks.jump(0, direction) then
      vim.notify("kori.nvim: no kori edits in this buffer", vim.log.levels.INFO)
    end
  end
end

local function apply(map, lhs, rhs, desc)
  if vim.fn.maparg(lhs, "n") ~= "" then
    return
  end
  map(lhs, rhs, desc)
end

--- Install the plugin's default mappings, never replacing one that exists.
--- @param actions table handlers supplied by the caller
--- @return nil
function M.install(actions)
  local cfg = require("kori.config").get()
  if not cfg.keymaps then
    return
  end

  local function map(lhs, rhs, desc)
    vim.keymap.set("n", lhs, rhs, { desc = desc })
  end

  apply(map, "]r", jump(actions.marks, 1), "kori: next edit")
  apply(map, "[r", jump(actions.marks, -1), "kori: previous edit")
  apply(map, "<leader>ko", actions.toggle, "kori: toggle chat pane")
  apply(map, "<leader>kc", actions.changes, "kori: changes")
  apply(map, "<leader>kp", actions.peek, "kori: peek last edit")
  apply(map, "<leader>kr", actions.revert, "kori: revert the edit here")
  apply(map, "<leader>ks", actions.send, "kori: send selection to kori")
end

return M