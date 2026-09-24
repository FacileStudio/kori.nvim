local M = {}

local ns = vim.api.nvim_create_namespace("kori.nvim")

M.state = {}

local function define_highlights()
  vim.api.nvim_set_hl(0, "KoriEditSign", { link = "DiffAdd", default = true })
  vim.api.nvim_set_hl(0, "KoriEditVirt", { link = "Comment", default = true })
  vim.api.nvim_set_hl(0, "KoriEditMark", { link = "DiffAdd", default = true })
end

local function define_sign()
  vim.fn.sign_define("KoriEdit", {
    text = "\u{258e}",
    texthl = "KoriEditSign",
    linehl = "",
    numhl = "",
  })
end

function M.setup(opts)
  opts = opts or {}
  M.signtext = opts.signs ~= false
  M.virtual_text = opts.virtual_text ~= false
  define_highlights()
  define_sign()
end

local function key(path)
  return vim.fn.fnamemodify(path, ":p")
end

function M.record(path, ranges, meta)
  local k = key(path)
  local entry = M.state[k]
  if not entry then
    entry = { path = k, ranges = {}, at = os.time(), reviewed = {} }
    M.state[k] = entry
  end
  entry.ranges = ranges or {}
  entry.at = os.time()
  entry.meta = meta
  M.apply_all(k)
  return entry
end

local function bufs_for(path)
  local found = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      local name = vim.api.nvim_buf_get_name(buf)
      if name ~= "" and vim.fn.fnamemodify(name, ":p") == path then
        found[#found + 1] = buf
      end
    end
  end
  return found
end

function M.apply(buf, entry)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  local line_count = vim.api.nvim_buf_line_count(buf)
  for _, range in ipairs(entry.ranges) do
    local lnum = math.max(0, math.min(range.first - 1, line_count - 1))
    local shape = { hl_group = "KoriEditMark" }
    if M.signtext then
      shape.sign_text = "\u{258e}"
      shape.sign_hl_group = "KoriEditSign"
    end
    if M.virtual_text and (range.added or range.removed) then
      shape.virt_text = { { ("+%d -%d"):format(range.added or 0, range.removed or 0), "KoriEditVirt" } }
      shape.virt_text_pos = "eol"
    end
    pcall(vim.api.nvim_buf_set_extmark, buf, ns, lnum, 0, shape)
  end
end

function M.apply_all(path)
  local entry = M.state[path]
  if not entry then
    return
  end
  for _, buf in ipairs(bufs_for(path)) do
    if vim.api.nvim_get_option_value("modified", { buf = buf }) then
      vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    else
      M.apply(buf, entry)
    end
  end
end

function M.of(path)
  return M.state[key(path)]
end

function M.starts(path)
  local entry = M.state[key(path)]
  if not entry then
    return {}
  end
  local starts = {}
  for _, range in ipairs(entry.ranges) do
    starts[#starts + 1] = range.first
  end
  table.sort(starts)
  return starts
end

function M.jump(buf, direction)
  local path = vim.api.nvim_buf_get_name(buf)
  if path == "" then
    return false
  end
  local starts = M.starts(path)
  if #starts == 0 then
    return false
  end
  local cursor = vim.api.nvim_win_get_cursor(0)[1]
  local target
  if direction > 0 then
    for _, line in ipairs(starts) do
      if line > cursor then
        target = line
        break
      end
    end
    target = target or starts[1]
  else
    for i = #starts, 1, -1 do
      if starts[i] < cursor then
        target = starts[i]
        break
      end
    end
    target = target or starts[#starts]
  end
  vim.api.nvim_win_set_cursor(0, { target, 0 })
  vim.cmd("normal! zz")
  return true
end

function M.clear()
  for path in pairs(M.state) do
    for _, buf in ipairs(bufs_for(path)) do
      vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    end
  end
  M.state = {}
end

function M.count()
  local n = 0
  for _, entry in pairs(M.state) do
    if #entry.ranges > 0 then
      n = n + 1
    end
  end
  return n
end

return M
