local M = {}

local config = require("kori.config")
local spool = require("kori.spool")

function M.check()
  vim.health.start("kori.nvim")

  if vim.fn.has("nvim-0.10") == 1 then
    vim.health.ok("Neovim " .. tostring(vim.version()))
  else
    vim.health.error("Neovim 0.10 or newer is required", { "Upgrade Neovim" })
  end

  if vim.fn.exists(":terminal") == 2 then
    vim.health.ok("`:terminal` is available for `:KoriStart`")
  end

  if vim.fn.executable("kori") == 1 then
    vim.health.ok("kori found at " .. vim.fn.exepath("kori"))
  else
    vim.health.warn("kori is not on $PATH", { "Install kori: https://github.com/FacileStudio/kori" })
  end

  if vim.fn.executable("kori-nvim") == 1 then
    vim.health.ok("kori-nvim shim found at " .. vim.fn.exepath("kori-nvim"))
  else
    vim.health.error("kori-nvim shim is not on $PATH", {
      "The shim is what kori's hook runs to report edits.",
      "Add the repository's bin/ directory to $PATH, or symlink bin/kori-nvim into ~/.local/bin.",
    })
  end

  local dir = spool.dir(config.get())
  if vim.fn.isdirectory(dir) == 1 then
    local perm = vim.fn.getfperm(dir)
    if perm:sub(4) == "------" then
      vim.health.ok("spool directory " .. dir .. " (" .. perm .. ")")
    else
      vim.health.warn("spool directory " .. dir .. " is " .. perm, {
        "The spool holds file content that kori edited.",
        "It should be private to you: chmod 700 " .. dir,
      })
    end
  else
    vim.health.info("spool directory " .. dir .. " does not exist yet")
  end

  local hooks = vim.fn.expand("~/.kori.yml")
  if vim.fn.filereadable(hooks) == 1 then
    local body = table.concat(vim.fn.readfile(hooks), "\n")
    if body:find("kori.nvim", 1, true) or body:find("kori%-nvim") then
      vim.health.ok("~/.kori.yml mentions the kori.nvim hook")
    else
      vim.health.warn("~/.kori.yml has no kori.nvim hook", {
        "Add the hooks block from the kori.nvim README, or nothing will be reported.",
        "Hooks are trusted per project: kori will ask before running one for the first time.",
      })
    end
  else
    vim.health.info("no ~/.kori.yml found")
  end
end

return M
