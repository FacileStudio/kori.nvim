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

vim.api.nvim_create_user_command("KoriChanges", function()
  kori.changes()
end, { desc = "kori: files and hunks kori changed" })

vim.api.nvim_create_user_command("KoriClear", function()
  kori.clear()
end, { desc = "kori: forget every recorded edit" })

vim.api.nvim_create_user_command("KoriStart", function(args)
  kori.start(vim.split(args.args, "%s+", { trim = true }))
end, { nargs = "*", desc = "kori: open kori in a right-hand split" })

vim.api.nvim_create_user_command("KoriPeek", function()
  local path = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":p")
  local marks = require("kori.marks")
  local entry = marks.of(path)
  if entry then
    require("kori.ui").peek(path, entry.ranges)
  end
end, { desc = "kori: peek the last edit in this buffer" })

vim.api.nvim_create_user_command("KoriHealth", function()
  require("kori.health").check()
end, { desc = "kori: run the health check" })
