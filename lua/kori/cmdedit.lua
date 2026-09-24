--- Which files a shell command edits in place.
---
--- Ported from kori's internal/diff/cmdpath.go, which is the authority on which
--- commands count. The markers are "sed -i", "awk -i" and "perl -i", matched as
--- plain substrings and tried in that order, so a command carrying several of
--- them is attributed to the earliest marker in the list, not to the earliest
--- one in the command. `extract` is that port, token for token.
---
--- `paths` filters the result: a token the shell itself would rewrite, or a
--- command whose pipeline, redirection or separator leaves the target in doubt,
--- yields no paths at all rather than a guess.

local M = {}

local MARKERS = { "sed -i", "awk -i", "perl -i" }
local OPERATORS = "|&;<>`$()"
local UNPLAIN = "|&;<>`$()\"'*\\"

local function fields(text)
  local out = {}
  for field in text:gmatch("%S+") do
    out[#out + 1] = field
  end
  return out
end

local function trim_quotes(field)
  local head = field:gsub("^[\"']+", "")
  return (head:gsub("[\"']+$", ""))
end

local function is_first_arg_extension(field)
  if field == "''" or field == '""' then
    return true
  end
  local head = field:sub(1, 1)
  return head ~= "-" and head ~= "'" and head ~= '"'
end

local function is_path_token(field)
  local head = field:sub(1, 1)
  if head == "-" or field == "inplace" then
    return false
  end
  if #field > 2 and (head == "'" or head == '"') then
    return false
  end
  return true
end

local function after_marker(command)
  for _, marker in ipairs(MARKERS) do
    local _, stop = command:find(marker, 1, true)
    if stop then
      return command:sub(stop + 1)
    end
  end
  return nil
end

local function first_path_arg(after)
  for i, field in ipairs(fields(after)) do
    local skipped = i == 1 and is_first_arg_extension(field)
    if not skipped and is_path_token(field) then
      return trim_quotes(field)
    end
  end
  return nil
end

local function has_shell_structure(command)
  local quote
  local i = 1
  while i <= #command do
    local char = command:sub(i, i)
    if char == "\\" and quote ~= "'" then
      i = i + 2
    elseif char == quote then
      quote = nil
      i = i + 1
    elseif not quote and (char == "'" or char == '"') then
      quote = char
      i = i + 1
    elseif not quote and (char == "\n" or char == "\r" or OPERATORS:find(char, 1, true)) then
      return true
    else
      i = i + 1
    end
  end
  return false
end

local function is_plain_path(path)
  for i = 1, #path do
    local char = path:sub(i, i)
    if char:find("[%s]") or UNPLAIN:find(char, 1, true) then
      return false
    end
  end
  return true
end

--- Extract the token a marker command names, the way cmdpath.go does.
---
--- The token can be the empty string, which is what the Go code returns for a
--- marker the shell would never run as an edit, such as the "sed -i" inside
--- `grep -r "sed -i" docs/`. The boolean is false whenever no token came back.
--- @param command string the raw shell command from the run_command input
--- @return string|nil path the token as written, empty when nothing named it
--- @return boolean extracted whether a token was found at all
function M.extract(command)
  if type(command) ~= "string" or command == "" then
    return nil, false
  end
  local after = after_marker(command)
  if not after then
    return nil, false
  end
  local path = first_path_arg(after)
  if path == nil then
    return nil, false
  end
  return path, true
end

--- List the paths a shell command appears to modify in place.
---
--- Returns one path at most, because cmdpath.go resolves a command to a single
--- file. Anything it cannot determine returns an empty list: a non-string or
--- empty command, no in-place marker, no path token after the marker, a token
--- carrying shell syntax, or a command with a pipe, a redirection, a separator
--- or a newline, where the token is no longer provably the file that changed.
--- @param command string the raw shell command from the run_command input
--- @return table list of zero or one path, as written in the command
function M.paths(command)
  local path, extracted = M.extract(command)
  if not extracted or path == "" then
    return {}
  end
  if has_shell_structure(command) or not is_plain_path(path) then
    return {}
  end
  return { path }
end

--- Say whether a shell command appears to edit a file in place.
--- @param command string the raw shell command from the run_command input
--- @return boolean edits true when paths returns at least one path
function M.is_edit(command)
  return #M.paths(command) > 0
end

return M
