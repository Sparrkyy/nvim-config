local M = {}

local store = require("flow.store")
local worktree = require("flow.worktree")

local function notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO, { title = "Flow merge" })
end

local function fail(message)
  notify(message, vim.log.levels.ERROR)
  return false
end

local function present(value)
  return value ~= nil and value ~= vim.NIL and value ~= ""
end

function M.check(plan_id)
  local meta = plan_id and store.meta(plan_id)
  if not meta or not present(meta.worktree) or not present(meta.verified_head) then
    return nil, "This plan has no verified implementation to merge."
  end
  if meta.status ~= "merge_ready" then
    return nil, "Approve the clean verified review before merging."
  end

  local source_clean, source_err = worktree.is_clean(meta.source_root)
  if not source_clean then
    return nil, "Commit or stash every source-worktree change before merging.\n\n" .. tostring(source_err or "")
  end
  local source_branch, branch_err = worktree.branch(meta.source_root)
  if not source_branch then
    return nil, branch_err
  end
  if source_branch ~= meta.source_branch then
    return nil, "Return to the source branch " .. meta.source_branch .. " before merging."
  end
  local source_head, source_head_err = worktree.head(meta.source_root)
  if not source_head then
    return nil, source_head_err
  end
  if source_head ~= meta.base_head then
    return nil, "The source branch advanced after implementation started.", "source_advanced", source_head
  end

  local review_ready, review_err = require("flow.review").ready(meta)
  if not review_ready then
    return nil, review_err
  end
  return meta, nil
end

function M.squash(plan_id, opts)
  opts = opts or {}
  plan_id = plan_id or require("flow").current()
  local meta, err, reason, source_head = M.check(plan_id)
  if not meta then
    if reason == "source_advanced" then
      return require("flow.implementation").sync(plan_id, source_head)
    end
    return fail(err)
  end

  if opts.confirm ~= false then
    local choice = vim.fn.confirm(
      "Squash the verified Flow worktree into " .. meta.source_branch .. " and create one commit?",
      "&Squash and commit\n&Cancel",
      2,
      "Question"
    )
    if choice ~= 1 then
      return false
    end
  end

  require("flow.review").close()
  store.set_meta(plan_id, { status = "merging" }, meta.cwd)
  local squashed = worktree.git(meta.source_root, { "merge", "--squash", meta.worktree_branch }, { timeout = 120000 })
  if not squashed.ok then
    store.set_meta(plan_id, { status = "merge_failed", error = squashed.err }, meta.cwd)
    return fail("Git could not squash the implementation: " .. (squashed.err ~= "" and squashed.err or squashed.out))
  end

  local subject = tostring(meta.title or "Apply Flow implementation"):gsub("[\r\n]+", " ")
  local committed = worktree.git(meta.source_root, { "commit", "-m", subject }, { timeout = 120000 })
  if not committed.ok then
    store.set_meta(plan_id, { status = "merge_failed", error = committed.err }, meta.cwd)
    return fail("The squash is staged, but Git could not create the commit: " .. (committed.err ~= "" and committed.err or committed.out))
  end

  local squash_head, head_err = worktree.head(meta.source_root)
  if not squash_head then
    store.set_meta(plan_id, { status = "merge_failed", error = head_err }, meta.cwd)
    return fail(head_err)
  end
  store.set_meta(plan_id, {
    status = "merged",
    squash_commit = squash_head,
    merged_at = os.time(),
    archive_branch = meta.worktree_branch,
    error = vim.NIL,
  }, meta.cwd)

  require("claude.follow").unregister(meta.worktree)
  require("flow.implementation").shutdown(plan_id)
  local removed, remove_err = worktree.remove(meta.source_root, meta.worktree)
  if not removed then
    store.set_meta(plan_id, { cleanup_error = remove_err }, meta.cwd)
    notify("Created " .. squash_head:sub(1, 12) .. ". The implementation worktree remains: " .. tostring(remove_err), vim.log.levels.WARN)
    return true
  end
  notify("Created squash commit " .. squash_head:sub(1, 12) .. ". The implementation history remains on " .. meta.worktree_branch .. ".")
  return true
end

return M
