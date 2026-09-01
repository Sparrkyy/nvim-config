local H = require("helpers")

describe("Flow Git integration", function()
  local store, worktree, source, plan_id

  local function git(root, args)
    local result = worktree.git(root, args)
    assert.is_true(result.ok, result.err)
    return vim.trim(result.out)
  end

  before_each(function()
    H.reset_buffers()
    store = H.reload("flow.store")
    worktree = H.reload("flow.worktree")
    H.flow_root(store)
    worktree.root = H.tmpdir() .. "/worktrees"
    source = H.tmpdir()
    assert.is_true(worktree.run({ "git", "init", source }).ok)
    git(source, { "config", "user.email", "flow@example.test" })
    git(source, { "config", "user.name", "Flow Test" })
    H.write_file(source, "value.txt", { "one" })
    git(source, { "add", "value.txt" })
    git(source, { "commit", "-m", "Initial" })
    plan_id = store.create({ title = "Change the value", cwd = source })
    store.add_revision(plan_id, { plan_md = "# Change the value\n\n## Verification\nRead the value." }, source)
    store.set_meta(plan_id, { status = "review" }, source)
  end)

  after_each(function()
    pcall(function()
      require("flow.review").close()
    end)
    H.reset_buffers()
  end)

  it("creates, reviews, squashes, commits, and archives a real worktree", function()
    local prepared = assert(worktree.prepare(source, plan_id))
    H.write_file(prepared.worktree, "value.txt", { "two" })
    git(prepared.worktree, { "add", "value.txt" })
    git(prepared.worktree, { "commit", "-m", "Change value" })
    local verified = assert(worktree.head(prepared.worktree))
    store.set_meta(plan_id, vim.tbl_extend("force", prepared, {
      status = "review_ready",
      verified_head = verified,
      review_cursor = 1,
    }), source)

    local review = H.reload("flow.review")
    local hunks = assert(review.hunks(plan_id))
    assert.equals(1, #hunks)
    assert.equals("value.txt", hunks[1].file)

    local feedback_id = store.push_feedback(plan_id, {
      body = "Use three instead",
      checkpoint = verified,
      review_cursor = 1,
      status = "verified",
    }, source)
    H.write_file(prepared.worktree, "value.txt", { "three" })
    git(prepared.worktree, { "add", "value.txt" })
    git(prepared.worktree, { "commit", "-m", "Apply review feedback" })
    local feedback_head = assert(worktree.head(prepared.worktree))
    store.update_feedback(plan_id, feedback_id, { status = "verified", head = feedback_head }, source)
    store.set_meta(plan_id, { status = "review_ready", verified_head = feedback_head }, source)
    local open = review.open
    review.open = function()
      return true
    end
    H.capture_notify(function()
      assert.is_true(review.restore(plan_id))
    end)
    review.open = open
    assert.same({ "two" }, vim.fn.readfile(prepared.worktree .. "/value.txt"))
    assert.equals("restored", store.last_feedback(plan_id, source).status)
    H.capture_notify(function()
      assert.is_true(review.approve(plan_id))
    end)
    assert.equals("merge_ready", store.meta(plan_id, source).status)

    local merge = H.reload("flow.merge")
    H.capture_notify(function()
      assert.is_true(merge.squash(plan_id, { confirm = false }))
    end)
    assert.same({ "two" }, vim.fn.readfile(source .. "/value.txt"))
    assert.equals("Change the value", git(source, { "log", "-1", "--format=%s" }))
    assert.equals("merged", store.meta(plan_id, source).status)
    assert.equals(0, vim.fn.isdirectory(prepared.worktree))
    assert.equals(prepared.worktree_branch, git(source, { "branch", "--list", prepared.worktree_branch }):gsub("^%*?%s*", ""))
  end)
end)
