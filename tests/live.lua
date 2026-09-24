-- Live check: the watcher must notice a spool file the shim creates while the
-- plugin is already running. The unit tests replay what is on disk; this one
-- exercises the fs_event wiring, which is what makes the plugin do anything at
-- all. Run with: nvim --headless -u NONE -l tests/live.lua

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(root)

local config = require("kori.config")
local spool = require("kori.spool")

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
local spool_dir = tmp .. "/spool"
config.setup({ root = tmp, spool_dir = spool_dir })

local seen = {}
local state = spool.start(config.get(), function(payload)
  seen[#seen + 1] = payload
end)

vim.env.KORI_NVIM_SPOOL_DIR = spool_dir
local payload = vim.json.encode({
  event = "after_tool_call",
  tool = "edit_file",
  input = vim.json.encode({ path = "sample.lua", old = "b", new = "bb" }),
  result = "edited sample.lua",
  retry = false,
})
vim.fn.system({ "sh", root .. "/bin/kori-nvim", "emit" }, payload)

local waited = 0
while #seen == 0 and waited < 3000 do
  vim.wait(50)
  waited = waited + 50
end

spool.stop(state)

if #seen == 0 then
  io.write("FAIL the watcher never fired (waited " .. waited .. "ms)\n")
  os.exit(1)
end
if #seen ~= 1 then
  io.write(("FAIL expected 1 event, saw %d\n"):format(#seen))
  os.exit(1)
end
if seen[1].tool ~= "edit_file" or vim.json.decode(seen[1].input).new ~= "bb" then
  io.write("FAIL the event did not round-trip\n")
  os.exit(1)
end

io.write(("ok   the watcher fired after %dms and the payload round-tripped\n"):format(waited))
os.exit(0)
