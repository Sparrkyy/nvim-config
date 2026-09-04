local M = {}

local state = {
  buf = nil,
  win = nil,
  root = nil,
  branches = {},
}

local function notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO, { title = "Git" })
end

function M.git(args, done, dir)
  local cmd = vim.list_extend({ "git", "-C", dir or state.root or vim.fn.getcwd() }, args)
  local ok, err = pcall(vim.system, cmd, { text = true }, function(result)
    local output = vim.trim((result.stdout or "") .. (result.stderr or ""))
    vim.schedule(function()
      done(result.code == 0, output)
    end)
  end)
  if not ok then
    vim.schedule(function()
      done(false, tostring(err))
    end)
  end
end

function M.parse_branches(output)
  local branches = {}
  for _, line in ipairs(vim.split(output or "", "\n", { plain = true, trimempty = true })) do
    local ref, name, head, updated, symref = line:match("^([^\t]+)\t([^\t]+)\t([^\t]*)\t([^\t]*)\t?(.*)$")
    if ref and symref == "" then
      table.insert(branches, {
        name = name,
        current = head == "*",
        remote = vim.startswith(ref, "refs/remotes/"),
        updated = tonumber(updated) or 0,
      })
    end
  end

  table.sort(branches, function(left, right)
    if left.updated ~= right.updated then
      return left.updated > right.updated
    end
    if left.remote ~= right.remote then
      return not left.remote
    end
    return left.name < right.name
  end)
  return branches
end

local function display_line(branch)
  local marker = branch.current and "●" or " "
  local remote = branch.remote and "  (remote)" or ""
  return string.format("  %s %s%s", marker, branch.name, remote)
end

local function popup_lines()
  local lines = {}
  if #state.branches == 0 then
    table.insert(lines, "  No branches yet")
  else
    for _, branch in ipairs(state.branches) do
      table.insert(lines, display_line(branch))
    end
  end
  table.insert(lines, "")
  table.insert(lines, "  Keys")
  table.insert(lines, "  Enter  switch branch")
  table.insert(lines, "  n      new branch")
  table.insert(lines, "  f      fetch all remotes")
  table.insert(lines, "  q/Esc  close")
  return lines
end

local function draw()
  if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then
    return
  end

  local lines = popup_lines()
  vim.bo[state.buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
  vim.bo[state.buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(state.buf, -1, 0, -1)

  for index, branch in ipairs(state.branches) do
    if branch.current then
      vim.api.nvim_buf_add_highlight(state.buf, -1, "Title", index - 1, 0, -1)
    end
  end
  for index = #lines - 4, #lines do
    vim.api.nvim_buf_add_highlight(state.buf, -1, "Comment", index - 1, 0, -1)
  end

  local width = 44
  for _, line in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(line) + 2)
  end
  width = math.min(width, math.max(20, vim.o.columns - 4))
  local height = math.min(#lines, math.max(3, vim.o.lines - 4))

  if state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_win_set_config(state.win, {
      relative = "editor",
      row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
      col = math.max(0, math.floor((vim.o.columns - width) / 2)),
      width = width,
      height = height,
    })
  end
end

function M.close()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_win_close(state.win, true)
  end
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    vim.api.nvim_buf_delete(state.buf, { force = true })
  end
  state.win = nil
  state.buf = nil
end

function M.is_open()
  return state.win ~= nil and vim.api.nvim_win_is_valid(state.win)
end

function M.lines()
  if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then
    return {}
  end
  return vim.api.nvim_buf_get_lines(state.buf, 0, -1, false)
end

local function selected_branch()
  if not M.is_open() then
    return nil
  end
  return state.branches[vim.api.nvim_win_get_cursor(state.win)[1]]
end

function M.refresh()
  M.git({
    "for-each-ref",
    "--format=%(refname)%09%(refname:short)%09%(HEAD)%09%(committerdate:unix)%09%(symref)",
    "refs/heads",
    "refs/remotes",
  }, function(ok, output)
    if not ok then
      notify("Could not list branches: " .. output, vim.log.levels.ERROR)
      return
    end
    state.branches = M.parse_branches(output)
    draw()
    if M.is_open() then
      local current = 1
      for index, branch in ipairs(state.branches) do
        if branch.current then
          current = index
          break
        end
      end
      pcall(vim.api.nvim_win_set_cursor, state.win, { current, 0 })
    end
  end, state.root)
end

function M.switch(branch)
  branch = branch or selected_branch()
  if not branch then
    return
  end
  if branch.current then
    notify("Already on " .. branch.name)
    return
  end

  local args = branch.remote and { "switch", "--track", branch.name } or { "switch", branch.name }
  M.git(args, function(ok, output)
    if not ok then
      notify("Could not switch to " .. branch.name .. ": " .. output, vim.log.levels.ERROR)
      return
    end
    pcall(vim.cmd, "checktime")
    notify("Switched to " .. branch.name)
    M.refresh()
  end, state.root)
end

function M.fetch()
  notify("Fetching all remotes…")
  M.git({ "fetch", "--all", "--prune" }, function(ok, output)
    if not ok then
      notify("Fetch failed: " .. output, vim.log.levels.ERROR)
      return
    end
    notify("Fetched all remotes")
    M.refresh()
  end, state.root)
end

function M.create()
  vim.ui.input({ prompt = "New branch name: " }, function(name)
    name = name and vim.trim(name) or ""
    if name == "" then
      return
    end
    M.git({ "switch", "-c", name }, function(ok, output)
      if not ok then
        notify("Could not create " .. name .. ": " .. output, vim.log.levels.ERROR)
        return
      end
      pcall(vim.cmd, "checktime")
      notify("Created and switched to " .. name)
      M.refresh()
    end, state.root)
  end)
end

local function open_popup()
  M.close()
  state.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[state.buf].buftype = "nofile"
  vim.bo[state.buf].bufhidden = "wipe"
  vim.bo[state.buf].swapfile = false
  vim.bo[state.buf].filetype = "gitbranches"

  state.win = vim.api.nvim_open_win(state.buf, true, {
    relative = "editor",
    row = 2,
    col = 2,
    width = 44,
    height = 3,
    style = "minimal",
    border = "rounded",
    title = " Git branches ",
    title_pos = "center",
  })
  vim.wo[state.win].cursorline = true
  vim.wo[state.win].wrap = false

  local function map(lhs, rhs, description)
    vim.keymap.set("n", lhs, rhs, {
      buffer = state.buf,
      nowait = true,
      silent = true,
      desc = description,
    })
  end
  map("<CR>", M.switch, "Switch branch")
  map("f", M.fetch, "Fetch all remotes")
  map("n", M.create, "Create branch")
  map("q", M.close, "Close Git branches")
  map("<Esc>", M.close, "Close Git branches")
end

function M.open()
  local cwd = vim.fn.getcwd()
  M.git({ "rev-parse", "--show-toplevel" }, function(ok, output)
    if not ok or output == "" then
      notify("The current directory is not a Git repository", vim.log.levels.ERROR)
      return
    end
    state.root = output
    state.branches = {}
    open_popup()
    M.refresh()
  end, cwd)
end

function M.setup()
  vim.api.nvim_create_user_command("GitBranches", M.open, {
    desc = "Open the small Git branch picker",
    force = true,
  })
  vim.keymap.set("n", "<leader>gg", M.open, { desc = "Git branches" })
end

return M
