local M = {}

M.defaults = {
  enabled = true,
  root = nil,
  spool_dir = nil,
  follow = "off",
  keymaps = true,
  notify = true,
  statusline = true,
  reload = {
    enabled = true,
    debounce_ms = 120,
  },
  marks = {
    enabled = true,
    signs = true,
    virtual_text = true,
  },
  notifications = {
    enabled = true,
    window_ms = 250,
  },
  ide = {
    enabled = true,
    dir = nil,
    retry_min_ms = 500,
    retry_max_ms = 10000,
  },
  ui = {
    panel_height = 10,
    term_width = 80,
  },
}

local function is_string(v)
  return type(v) == "string"
end

local function validate(cfg)
  local valid_follow = { off = true, peek = true, open = true }
  if not valid_follow[cfg.follow] then
    return nil, ("follow must be \"off\", \"peek\" or \"open\", got %q"):format(tostring(cfg.follow))
  end
  if cfg.root ~= nil and not is_string(cfg.root) then
    return nil, "root must be a string or nil"
  end
  if cfg.spool_dir ~= nil and not is_string(cfg.spool_dir) then
    return nil, "spool_dir must be a string or nil"
  end
  if type(cfg.reload.debounce_ms) ~= "number" or cfg.reload.debounce_ms < 0 then
    return nil, "reload.debounce_ms must be a non-negative number"
  end
  if type(cfg.notifications.window_ms) ~= "number" or cfg.notifications.window_ms < 0 then
    return nil, "notifications.window_ms must be a non-negative number"
  end
  if cfg.ide.dir ~= nil and not is_string(cfg.ide.dir) then
    return nil, "ide.dir must be a string or nil"
  end
  if type(cfg.ide.retry_min_ms) ~= "number" or type(cfg.ide.retry_max_ms) ~= "number" then
    return nil, "ide.retry_min_ms and ide.retry_max_ms must be numbers"
  end
  if cfg.ide.retry_max_ms < cfg.ide.retry_min_ms then
    return nil, "ide.retry_max_ms must not be smaller than ide.retry_min_ms"
  end
  return true
end

local function merge(dst, src)
  for key, value in pairs(src) do
    if type(value) == "table" and type(dst[key]) == "table" then
      merge(dst[key], value)
    else
      dst[key] = value
    end
  end
  return dst
end

local current

function M.setup(opts)
  opts = opts or {}
  if current then
    merge(current, opts)
  else
    current = merge(vim.deepcopy(M.defaults), opts)
  end
  local ok, err = validate(current)
  if not ok then
    error("kori.nvim: " .. err, 2)
  end
  if current.root == nil then
    current.root = vim.fn.getcwd()
  else
    current.root = vim.fn.fnamemodify(current.root, ":p"):gsub("/$", "")
  end
  return current
end

function M.get()
  if not current then
    return M.setup()
  end
  return current
end

function M.reset()
  current = nil
end

return M
