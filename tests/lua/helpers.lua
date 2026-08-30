-- Shared test helpers.
--
-- Everything Claude-facing is mocked here. No test starts the Claude CLI,
-- opens a socket, or sends a token anywhere.

local H = {}

--- Reload a module from disk, so each test starts from clean module state.
---@param name string
function H.reload(name)
  package.loaded[name] = nil
  return require(name)
end

--- Install a fake claudecode.nvim terminal.
--- Records every send instead of writing to a real terminal.
---@param opts table|nil { running = boolean }
---@return table stub with .sends, .visible_calls, .bufnr
function H.mock_claudecode(opts)
  opts = opts or {}
  local stub = {
    sends = {},
    visible_calls = 0,
    bufnr = opts.running and vim.api.nvim_create_buf(false, true) or nil,
  }

  stub.terminal = {
    get_active_terminal_bufnr = function()
      return stub.bufnr
    end,
    ensure_visible = function()
      stub.visible_calls = stub.visible_calls + 1
      -- Starting the terminal is what creates the buffer.
      if not stub.bufnr then
        stub.bufnr = vim.api.nvim_create_buf(false, true)
        vim.bo[stub.bufnr].buftype = "nofile"
      end
    end,
    send_to_terminal = function(text, o)
      table.insert(stub.sends, { text = text, opts = o or {} })
      return true
    end,
  }

  package.loaded["claudecode.terminal"] = stub.terminal
  return stub
end

function H.unmock_claudecode()
  package.loaded["claudecode.terminal"] = nil
end

--- Make the mocked terminal buffer look like Claude has drawn its prompt.
function H.render_claude_prompt(bufnr)
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
    "╭──────────────────────────────────────╮",
    "│ > ",
    "╰──────────────────────────────────────╯",
  })
end

--- Capture vim.notify calls for the duration of fn.
---@return table list of { msg, level }
function H.capture_notify(fn)
  local original = vim.notify
  local seen = {}
  vim.notify = function(msg, level)
    table.insert(seen, { msg = msg, level = level })
  end
  local ok, err = pcall(fn)
  vim.notify = original
  if not ok then
    error(err)
  end
  return seen
end

--- Answer the next vim.ui.input with `answer`. Pass nil to simulate a cancel.
function H.stub_input(answer, fn)
  local original = vim.ui.input
  vim.ui.input = function(_, cb)
    cb(answer)
  end
  local ok, err = pcall(fn)
  vim.ui.input = original
  if not ok then
    error(err)
  end
end

--- Encode a hook message the way tests/hook does, for M.handle.
function H.encode(tbl)
  return vim.base64.encode(vim.json.encode(tbl))
end

--- Resolve a path the way Neovim stores a buffer name.
--- On macOS /var is a symlink to /private/var, so a raw temp path never
--- matches the buffer name without this.
function H.resolve(path)
  return vim.fn.resolve(vim.fn.fnamemodify(path, ":p"))
end

--- A throwaway directory, removed when the test run ends.
function H.tmpdir()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  return H.resolve(dir)
end

--- Write a file and return its resolved path.
function H.write_file(dir, name, lines)
  local path = dir .. "/" .. name
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  vim.fn.writefile(lines, path)
  return H.resolve(path)
end

--- The name of the buffer in the current window, resolved.
function H.current_file()
  local name = vim.api.nvim_buf_get_name(0)
  return name == "" and "" or H.resolve(name)
end

--- Run the scheduled callbacks that follow.lua defers, then settle.
function H.settle(ms)
  vim.wait(ms or 50, function()
    return false
  end)
end

--- Close every buffer and window, so buffer-counting tests do not interfere.
function H.reset_buffers()
  vim.cmd("silent! only")
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    pcall(vim.api.nvim_buf_delete, b, { force = true })
  end
  vim.cmd("silent! enew")
end

--- Answer git for config.update, so no test spawns a command or reaches
--- GitHub. `answers` maps the first git argument to { ok = boolean, out =
--- string }. An argument that is not listed succeeds with empty output.
---@param update table the config.update module
---@param answers table|nil
---@return table stub with .calls, the argument lists git received in order
function H.stub_git(update, answers)
  local stub = { calls = {} }
  answers = answers or {}
  update.git = function(args, done)
    table.insert(stub.calls, args)
    local answer = answers[args[1]] or {}
    done(answer.ok ~= false, answer.out or "")
  end
  return stub
end

return H
