local M = {
  socket = "nvim-claude",
  prefix = "claude-",
}

local function command(args)
  local cmd = { "tmux", "-L", M.socket }
  vim.list_extend(cmd, args)
  return cmd
end

local function run(args)
  local cmd = command(args)
  if vim.system then
    local result = vim.system(cmd, { text = true }):wait()
    return result.code == 0, result.stdout or "", result.stderr or ""
  end
  local output = vim.fn.system(cmd)
  return vim.v.shell_error == 0, output or "", ""
end

local function shell_command(args)
  local escaped = {}
  for _, value in ipairs(args) do
    table.insert(escaped, vim.fn.shellescape(tostring(value)))
  end
  return table.concat(escaped, " ")
end

function M.available()
  return vim.fn.executable("tmux") == 1
end

function M.name(key)
  local safe = tostring(key or "session"):lower():gsub("[^%w_-]", "-")
  return M.prefix .. safe
end

function M.has(name)
  if not M.available() or type(name) ~= "string" or name == "" then
    return false
  end
  local ok = run({ "has-session", "-t", name })
  return ok
end

function M.create_command(name, cwd, env, args)
  local cmd = command({ "new-session", "-A", "-s", name, "-c", cwd })
  local keys = vim.tbl_keys(env or {})
  table.sort(keys)
  for _, key in ipairs(keys) do
    table.insert(cmd, "-e")
    table.insert(cmd, tostring(key) .. "=" .. tostring(env[key]))
  end
  table.insert(cmd, shell_command(args))
  return cmd
end

function M.attach_command(name)
  return command({ "attach-session", "-t", name })
end

function M.configure(name, metadata)
  if not M.has(name) then
    return false
  end
  local configured, value = run({ "show-options", "-gv", "@claude_nvim_configured" })
  if not configured or vim.trim(value) ~= "1" then
    run({ "set-option", "-g", "allow-passthrough", "on" })
    run({ "set-option", "-s", "extended-keys", "on" })
    run({ "set-option", "-g", "history-limit", "100000" })
    run({ "set-option", "-as", "terminal-features", "xterm*:extkeys" })
    run({ "set-option", "-g", "@claude_nvim_configured", "1" })
  end
  if metadata then
    local encoded = vim.base64.encode(vim.json.encode(metadata))
    run({ "set-option", "-t", name, "@claude_nvim_meta", encoded })
  end
  return true
end

function M.list()
  if not M.available() then
    return {}
  end
  local ok, output = run({ "list-sessions", "-F", "#{session_name}\t#{@claude_nvim_meta}" })
  if not ok then
    return {}
  end
  local found = {}
  for _, line in ipairs(vim.split(output, "\n", { plain = true, trimempty = true })) do
    local name, encoded = line:match("^([^\t]+)\t?(.*)$")
    if name and name:sub(1, #M.prefix) == M.prefix then
      local metadata
      if encoded and encoded ~= "" then
        pcall(function()
          metadata = vim.json.decode(vim.base64.decode(encoded))
        end)
      end
      table.insert(found, { name = name, metadata = metadata })
    end
  end
  return found
end

function M.kill(name)
  if not M.has(name) then
    return true
  end
  local ok = run({ "kill-session", "-t", name })
  return ok
end

return M
