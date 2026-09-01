local H = require("helpers")

describe("flow.review", function()
  local review, store, worktree, cwd, workdir, plan_id

  before_each(function()
    H.reset_buffers()
    store = H.reload("flow.store")
    worktree = H.reload("flow.worktree")
    review = H.reload("flow.review")
    H.flow_root(store)
    cwd = H.tmpdir()
    workdir = H.tmpdir()
    H.write_file(workdir, "lua/a.lua", { "local value = 2", "return value" })
    plan_id = store.create({ title = "Change value", cwd = cwd })
    store.set_meta(plan_id, {
      status = "review_ready",
      source_root = cwd,
      source_branch = "main",
      base_head = "base",
      worktree = workdir,
      worktree_branch = "flow/test",
      verified_head = "head",
      review_cursor = 1,
    }, cwd)
    worktree.is_clean = function()
      return true
    end
    worktree.head = function()
      return "head"
    end
    worktree.git = function(_, args)
      if args[1] == "diff" and args[2] == "--name-status" then
        return { ok = true, out = "M\tlua/a.lua", err = "" }
      end
      if args[1] == "diff" then
        return { ok = true, out = "@@ -1 +1 @@ change value", err = "" }
      end
      if args[1] == "show" then
        return { ok = true, out = "local value = 1\nreturn value", err = "" }
      end
      if args[1] == "log" then
        return { ok = true, out = "Change the value", err = "" }
      end
      return { ok = false, out = "", err = "unexpected" }
    end
  end)

  after_each(function()
    review.close()
    H.reset_buffers()
  end)

  it("builds review entries from the real committed Git diff", function()
    local hunks = assert(review.hunks(plan_id))
    assert.equals(1, #hunks)
    assert.equals("lua/a.lua", hunks[1].file)
    assert.equals(1, hunks[1].old_start)
    assert.equals(1, hunks[1].new_start)
  end)

  it("gives review feedback the current real diff as context", function()
    local context = review.context(plan_id)
    assert.is_truthy(context:match("Reviewed hunk 1 of 1"))
    assert.is_truthy(context:match("@@ %-1 %+1 @@"))
    assert.is_truthy(context:match("lua/a%.lua"))
  end)

  it("opens a native diff against the verified worktree file", function()
    H.capture_notify(function()
      assert.is_true(review.open(plan_id))
    end)
    local diff_windows = 0
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if vim.wo[win].diff then
        diff_windows = diff_windows + 1
      end
    end
    assert.equals(2, diff_windows)
    local target = vim.fn.bufnr(workdir .. "/lua/a.lua")
    assert.is_true(target > 0)
    assert.is_false(vim.bo[target].modifiable)
    assert.equals("reviewing", store.meta(plan_id, cwd).status)
  end)

  it("refuses a diff whose worktree changed after verification", function()
    worktree.head = function()
      return "later"
    end
    local hunks, err = review.hunks(plan_id)
    assert.is_nil(hunks)
    assert.is_truthy(err:match("changed after"))
  end)
end)
