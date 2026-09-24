--- Discovery of running kori sessions from the per process files written under
--- ~/.kori/ide. A file whose pid is dead is ignored but never deleted, since the
--- owner may still be starting up.

local M = {}

local uv = vim.uv or vim.loop

local function trim(path)
  return (path:gsub("/+$", ""))
end

local function base(dir)
  return dir or M.dir()
end

--- Default directory holding the per process discovery files.
--- @return string path
function M.dir()
  local home = vim.env.HOME
  if not home or home == "" then
    home = vim.fn.expand("~")
  end
  return home .. "/.kori/ide"
end

--- Whether a pid is still running.
---
--- `vim.uv.kill(pid, 0)` cannot answer this: in this build it returns nil for a
--- live process and never raises for a dead one, so the check reported false
--- for every session that was not this process. The kernel's own view is used
--- instead, which is what the liveness check is actually asking.
--- @param pid any the pid field of a discovery entry
--- @return boolean alive
function M.alive(pid)
  if type(pid) ~= "number" or pid <= 0 then
    return false
  end
  if uv.fs_stat("/proc/" .. pid) then
    return true
  end
  if vim.fn.isdirectory("/proc") == 1 then
    return false
  end
  local out = vim.fn.system({ "ps", "-p", tostring(pid), "-o", "pid=" })
  return vim.v.shell_error == 0 and trim(out or "") ~= ""
end

--- Parse one discovery file. A malformed or partial file returns nil.
--- @param path string path to a discovery file
--- @return table|nil entry
function M.parse(path)
  local read_ok, lines = pcall(vim.fn.readfile, path)
  if not read_ok or type(lines) ~= "table" then
    return nil
  end
  local decode_ok, payload = pcall(vim.json.decode, table.concat(lines, "\n"))
  if not decode_ok or type(payload) ~= "table" then
    return nil
  end
  if type(payload.pid) ~= "number" then
    return nil
  end
  if type(payload.root) ~= "string" or type(payload.socket) ~= "string" then
    return nil
  end
  return payload
end

--- Read every live session entry under a directory, ignoring malformed files.
--- @param dir string|nil discovery directory, defaults to M.dir()
--- @return table[] entries
function M.scan(dir)
  local found = {}
  local where = base(dir)
  local handle = uv.fs_scandir(where)
  if not handle then
    return found
  end
  while true do
    local name = uv.fs_scandir_next(handle)
    if not name then
      break
    end
    if name:sub(-5) == ".json" then
      local entry = M.parse(where .. "/" .. name)
      if entry and M.alive(entry.pid) then
        found[#found + 1] = entry
      end
    end
  end
  return found
end

local function score(entry, root)
  if not root then
    return 0
  end
  local session = trim(entry.root)
  local wanted = trim(root)
  if session == wanted then
    return 2
  end
  if wanted:sub(1, #session + 1) == session .. "/" then
    return 1
  end
  return 0
end

local function newer(entry, best)
  return tostring(entry.started or "") > tostring(best.started or "")
end

--- Pick the session whose root matches best.
---
--- A root that matches nothing picks nothing, rather than the newest session
--- anywhere on the machine. Attaching across projects is not a convenience: a
--- prompt typed here runs in that session's agent, in that session's root, so
--- the fallback would run work somewhere the user was not looking. Only a
--- caller with no root in mind passes nil, and that is the one case where any
--- session is as good as any other.
--- @param entries table[] entries returned by M.scan()
--- @param root string|nil root to match
--- @return table|nil entry
function M.pick(entries, root)
  local best, best_score
  for _, entry in ipairs(entries) do
    local current = score(entry, root)
    if not best then
      best, best_score = entry, current
    elseif current > best_score or (current == best_score and newer(entry, best)) then
      best, best_score = entry, current
    end
  end
  if root and best_score == 0 then
    return nil
  end
  return best
end

--- Find the best session for a root.
--- @param root string|nil root to match
--- @param dir string|nil discovery directory, defaults to M.dir()
--- @return table|nil entry
function M.find(root, dir)
  return M.pick(M.scan(dir), root)
end

return M
