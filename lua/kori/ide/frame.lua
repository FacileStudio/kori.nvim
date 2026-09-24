--- NDJSON framing for the kori IDE socket.
--- Turns a byte stream into complete lines and decodes each one, so a line
--- split across two reads is never decoded early and a partial tail is kept
--- for the next chunk.

local M = {}

--- Create the decoder state for one stream.
--- @return table state
function M.new()
  return { tail = "" }
end

--- Split a chunk into complete lines, keeping the partial tail for the next call.
--- @param state table state returned by M.new()
--- @param chunk string bytes read from the socket
--- @return string[] lines complete lines, without their newline
function M.split(state, chunk)
  local lines = {}
  local buf = state.tail .. chunk
  local start = 1
  while true do
    local nl = buf:find("\n", start, true)
    if not nl then
      break
    end
    local line = buf:sub(start, nl - 1)
    if line:sub(-1) == "\r" then
      line = line:sub(1, -2)
    end
    if line:match("%S") then
      lines[#lines + 1] = line
    end
    start = nl + 1
  end
  state.tail = buf:sub(start)
  return lines
end

--- Decode one complete NDJSON line. A line that is not a JSON object returns nil.
--- @param line string a complete line
--- @return table|nil object
function M.decode(line)
  local ok, payload = pcall(vim.json.decode, line)
  if not ok or type(payload) ~= "table" then
    return nil
  end
  return payload
end

return M
