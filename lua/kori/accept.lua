local M = {}

local config = require("kori.config")
local marks = require("kori.marks")
local notify = require("kori.notify")
local ui = require("kori.ui")

--- Find the loaded buffer showing a path, if there is one.
--- @param path string absolute path
--- @return integer|nil buf
function M.buffer_for(path)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.api.nvim_buf_get_name(buf) ~= "" then
      if vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":p") == path then
        return buf
      end
    end
  end
  return nil
end

local function focus(path, ranges)
  local cfg = config.get()
  if cfg.follow == "off" then
    return
  end
  if cfg.follow == "peek" then
    ui.peek(path, ranges)
    return
  end
  ui.open(path, ranges, M.buffer_for(path))
end

--- React to one applied edit: report it, then move focus only as configured.
--- @param result table path, ranges, stale, had_buffer
--- @return boolean announced
function M.edit(result)
  if not result then
    return false
  end
  if result.stale then
    vim.notify(
      ("kori changed %s, but the buffer has unsaved changes"):format(vim.fn.fnamemodify(result.path, ":t")),
      vim.log.levels.WARN
    )
    return false
  end
  notify.record(result.path, result.ranges)
  focus(result.path, result.ranges)
  vim.api.nvim_exec_autocmds("User", { pattern = "KoriEdit", data = result })
  return true
end

--- Report that kori started or finished a non-editing tool.
--- @param ev table tool event with name and status
--- @return nil
function M.tool(ev)
  if not config.get().statusline then
    return
  end
  vim.api.nvim_exec_autocmds("User", { pattern = "KoriTool", data = ev })
end

--- Reapply the recorded marks to whatever buffer is current.
--- @return nil
function M.refresh_current_buffer()
  local name = vim.api.nvim_buf_get_name(0)
  if name == "" then
    return
  end
  local path = vim.fn.fnamemodify(name, ":p")
  local entry = marks.state[path]
  if entry and not vim.api.nvim_get_option_value("modified", { buf = 0 }) then
    marks.apply(0, entry)
  end
end

return M