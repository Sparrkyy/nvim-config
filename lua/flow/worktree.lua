local M = {}

M.root = vim.fn.stdpath("state") .. "/flow-worktrees"

local function raw(text)
  return tostring(text or "")
end

local function without_final_newline(text)
  return raw(text):gsub("[\r\n]+$", "")
end

function M.run(cmd, opts)
  opts = opts or {}
  local ok, proc = pcall(vim.system, cmd, {
    text = true,
    stdin = opts.stdin,
    cwd = opts.cwd,
  })
  if not ok then
    return { ok = false, code = -1, out = "", err = tostring(proc) }
  end
  local waited, result = pcall(proc.wait, proc, opts.timeout or 30000)
  if not waited then
    return { ok = false, code = -1, out = "", err = tostring(result) }
  end
  return {
    ok = result.code == 0,
    code = result.code,
    out = raw(result.stdout),
    err = raw(result.stderr),
  }
end

function M.git(root, args, opts)
  local cmd = { "git", "-C", root }
  vim.list_extend(cmd, args or {})
  return M.run(cmd, opts)
end

local function answer(result, fallback)
  if result.ok then
    return vim.trim(result.out), nil
  end
  local stderr = vim.trim(result.err)
  local stdout = vim.trim(result.out)
  local detail = stderr ~= "" and stderr or stdout
  return nil, detail ~= "" and detail or fallback
end

function M.repository(cwd)
  local result = M.git(cwd, { "rev-parse", "--show-toplevel" })
  local root, err = answer(result, "This directory is not a Git repository.")
  if not root then
    return nil, err
  end
  return vim.fn.resolve(vim.fn.fnamemodify(root, ":p")), nil
end

function M.status(root)
  local result = M.git(root, { "status", "--porcelain=v1", "--untracked-files=all" })
  if not result.ok then
    return nil, result.err ~= "" and result.err or "Git status failed."
  end
  return without_final_newline(result.out), nil
end

function M.is_clean(root)
  local status, err = M.status(root)
  if status == nil then
    return false, err
  end
  return status == "", status == "" and nil or status
end

function M.head(root)
  return answer(M.git(root, { "rev-parse", "HEAD" }), "Git could not read HEAD.")
end

function M.branch(root)
  return answer(M.git(root, { "symbolic-ref", "--quiet", "--short", "HEAD" }), "Flow needs a checked-out branch.")
end

function M.path(plan_id, source_root)
  local project = vim.fn.sha256(vim.fn.resolve(source_root)):sub(1, 12)
  return M.root .. "/" .. project .. "/" .. tostring(plan_id)
end

function M.branch_name(plan_id)
  local safe = tostring(plan_id):lower():gsub("[^%w%-]", "-"):sub(1, 80)
  return "flow/" .. safe
end

function M.prepare(cwd, plan_id)
  local root, root_err = M.repository(cwd)
  if not root then
    return nil, root_err
  end

  local clean, clean_err = M.is_clean(root)
  if not clean then
    local suffix = clean_err and clean_err ~= "" and "\n\n" .. clean_err or ""
    return nil, "Commit or stash every change before Flow starts implementation." .. suffix
  end

  local branch, branch_err = M.branch(root)
  if not branch then
    return nil, branch_err
  end
  local head, head_err = M.head(root)
  if not head then
    return nil, head_err
  end

  local path = M.path(plan_id, root)
  local worktree_branch = M.branch_name(plan_id)
  if vim.fn.isdirectory(path) == 1 then
    return nil, "The Flow worktree already exists: " .. path
  end
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")

  local created = M.git(root, { "worktree", "add", "-b", worktree_branch, path, head }, { timeout = 120000 })
  if not created.ok then
    local detail = created.err ~= "" and created.err or created.out
    return nil, "Git could not create the Flow worktree: " .. detail
  end

  return {
    source_root = root,
    source_branch = branch,
    base_head = head,
    worktree = vim.fn.resolve(vim.fn.fnamemodify(path, ":p")),
    worktree_branch = worktree_branch,
  }, nil
end

function M.remove(source_root, path)
  local result = M.git(source_root, { "worktree", "remove", path }, { timeout = 120000 })
  if result.ok then
    return true, nil
  end
  return false, result.err ~= "" and result.err or result.out
end

return M
