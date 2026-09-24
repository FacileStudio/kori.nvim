local M = {}

--- The current branch of the repository containing a path.
--- @param path string absolute path, or "" to use the working directory
--- @return string branch, or "" when there is none
function M.branch(path)
  local cwd = path ~= "" and vim.fn.fnamemodify(path, ":h") or vim.fn.getcwd()
  if vim.fn.executable("git") ~= 1 then
    return ""
  end
  local out = vim.fn.system({ "git", "-C", cwd, "rev-parse", "--abbrev-ref", "HEAD" })
  if vim.v.shell_error ~= 0 then
    return ""
  end
  local branch = vim.trim(out or "")
  if branch == "HEAD" then
    return ""
  end
  return branch
end

--- The lines a visual selection covers, or nil when there is no selection.
--- @return string|nil text
function M.selected()
  local start_line = vim.fn.getpos("'<")[2]
  local end_line = vim.fn.getpos("'>")[2]
  if start_line == 0 or end_line == 0 or start_line > end_line then
    return nil
  end
  local buf = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(buf, start_line - 1, end_line, false)
  if #lines == 0 then
    return nil
  end
  return table.concat(lines, "\n")
end

--- The whole current buffer, for when there is no selection.
--- @return string
function M.buffer_text()
  return table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
end

--- The current file path, or "" for a scratch buffer.
--- @return string
function M.path()
  local name = vim.api.nvim_buf_get_name(0)
  if name == "" then
    return ""
  end
  return vim.fn.fnamemodify(name, ":p")
end

--- Build the payload a session can act on: the prompt plus where it came from.
--- @param text string what the user asked
--- @param whole_buffer boolean send the buffer instead of just the selection
--- @return table payload with text, path, line and branch
function M.payload(text, whole_buffer)
  local path = M.path()
  local body = text or ""
  local excerpt = whole_buffer and M.buffer_text() or M.selected()
  if excerpt and excerpt ~= "" then
    body = ("%s\n\n%s:%d\n%s"):format(body, path, vim.fn.line("."), excerpt)
  end
  return {
    text = body,
    path = path,
    line = vim.fn.line("."),
    branch = M.branch(path),
  }
end

return M