local H = require("helpers")

describe("flow.merge", function()
  local merge, store, worktree, cwd, workdir, plan_id, calls

  before_each(function()
    store = H.reload("flow.store")
    worktree = H.reload("flow.worktree")
    H.flow_root(store)
    cwd = H.tmpdir()
    workdir = H.tmpdir()
    plan_id = store.create({ title = "Add the feature", cwd = cwd })
    store.set_meta(plan_id, {
      status = "merge_ready",
      source_root = cwd,
      source_branch = "main",
      base_head = "base",
      worktree = workdir,
      worktree_branch = "flow/test",
      verified_head = "verified",
    }, cwd)

    worktree.is_clean = function()
      return true
    end
    worktree.branch = function()
      return "main"
    end
    local source_heads = 0
    worktree.head = function(root)
      if root == workdir then
        return "verified"
      end
      source_heads = source_heads + 1
      return source_heads == 1 and "base" or "squashed"
    end
    calls = {}
    worktree.git = function(_, args)
      table.insert(calls, args)
      return { ok = true, out = "ok", err = "" }
    end
    worktree.remove = function()
      return true
    end
    package.loaded["flow.review"] = {
      ready = function()
        return true
      end,
      close = function() end,
    }
    package.loaded["claude.follow"] = { unregister = function() end }
    merge = H.reload("flow.merge")
  end)

  it("squashes the implementation branch and creates one commit", function()
    H.capture_notify(function()
      assert.is_true(merge.squash(plan_id, { confirm = false }))
    end)
    assert.same({ "merge", "--squash", "flow/test" }, calls[1])
    assert.same({ "commit", "-m", "Add the feature" }, calls[2])
    local meta = store.meta(plan_id, cwd)
    assert.equals("merged", meta.status)
    assert.equals("squashed", meta.squash_commit)
    assert.equals("flow/test", meta.archive_branch)
  end)

  it("refuses to merge over source-worktree changes", function()
    worktree.is_clean = function(root)
      if root == cwd then
        return false, " M local.lua"
      end
      return true
    end
    local seen = H.capture_notify(function()
      assert.is_false(merge.squash(plan_id, { confirm = false }))
    end)
    assert.is_truthy(seen[1].msg:match("Commit or stash"))
    assert.equals(0, #calls)
  end)

  it("requires the clean verified review to be approved", function()
    store.set_meta(plan_id, { status = "reviewing" }, cwd)
    local seen = H.capture_notify(function()
      assert.is_false(merge.squash(plan_id, { confirm = false }))
    end)
    assert.is_truthy(seen[1].msg:match("Approve the clean verified review"))
    assert.equals(0, #calls)
  end)

  it("sends an advanced source branch back through Claude and verification", function()
    worktree.head = function(root)
      return root == workdir and "verified" or "newbase"
    end
    local synced = {}
    package.loaded["flow.implementation"] = {
      sync = function(id, head)
        table.insert(synced, { id = id, head = head })
        return true
      end,
    }
    assert.is_true(merge.squash(plan_id, { confirm = false }))
    assert.same({ { id = plan_id, head = "newbase" } }, synced)
    assert.equals(0, #calls)
  end)
end)
