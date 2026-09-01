local H = require("helpers")

describe("flow.implementation", function()
  local implementation, store, worktree, cwd, workdir, plan_id, sent

  before_each(function()
    H.reset_buffers()
    store = H.reload("flow.store")
    worktree = H.reload("flow.worktree")
    implementation = H.reload("flow.implementation")
    H.flow_root(store)
    cwd = H.tmpdir()
    workdir = H.tmpdir()
    plan_id = store.create({ title = "Add the feature", cwd = cwd })
    store.add_revision(plan_id, { plan_md = "# Add the feature\n\n## Verification\nRun the focused test." }, cwd)
    store.set_meta(plan_id, { status = "review" }, cwd)

    worktree.prepare = function()
      return {
        source_root = cwd,
        source_branch = "main",
        base_head = "base123",
        worktree = workdir,
        worktree_branch = "flow/test",
      }
    end
    worktree.git = function()
      return { ok = false, code = 1, out = "", err = "" }
    end
    implementation.spawn_terminal = function(_, opts)
      local buf = vim.api.nvim_create_buf(false, true)
      vim.b[buf].flow_plan_id = opts.plan_id
      return { buf = buf, channel = 17 }
    end
    sent = {}
    implementation.send_terminal = function(_, text)
      table.insert(sent, text)
      return true
    end
  end)

  after_each(function()
    H.reset_buffers()
  end)

  it("makes Claude commit heavily and run targeted verification", function()
    local prompt = implementation.prompt("# Plan")
    assert.is_truthy(prompt:match("Commit each coherent implementation step"))
    assert.is_truthy(prompt:match("existing targeted tests"))
    assert.is_truthy(prompt:match("Do not run the full test suite"))
    assert.is_truthy(prompt:match("worktree is clean") == nil)
    assert.is_truthy(prompt:match("uncommitted or untracked"))
    assert.is_truthy(prompt:match("Mermaid content"))
    assert.is_truthy(prompt:match("produces SVG"))
  end)

  it("starts a persistent session in the owned worktree", function()
    H.capture_notify(function()
      assert.is_true(implementation.begin(plan_id))
    end)
    local meta = store.meta(plan_id, cwd)
    assert.equals("implementing", meta.status)
    assert.equals(workdir, meta.worktree)
    assert.equals("base123", meta.base_head)
    assert.is_truthy(meta.session_id:match("^[0-9a-f]+%-[0-9a-f]+%-4"))
  end)

  it("leaves the plan in review when worktree creation is refused", function()
    worktree.prepare = function()
      return nil, "Commit or stash every change"
    end
    local seen = H.capture_notify(function()
      assert.is_false(implementation.begin(plan_id))
    end)
    assert.equals("review", store.meta(plan_id, cwd).status)
    assert.is_truthy(seen[1].msg:match("Commit or stash"))
  end)

  local function started()
    H.capture_notify(function()
      implementation.begin(plan_id)
    end)
    return store.meta(plan_id, cwd)
  end

  it("refuses to let Claude stop with uncommitted changes", function()
    local meta = started()
    worktree.is_clean = function()
      return false, " M file.lua"
    end
    local answer = implementation.stop(H.encode({ plan_id = plan_id, cwd = workdir, session_id = meta.session_id }))
    assert.is_truthy(answer:match("^continue:"))
    assert.is_truthy(answer:match("Commit every"))
    assert.equals("implementing", store.meta(plan_id, cwd).status)
  end)

  it("refuses to let the initial turn stop without a commit", function()
    local meta = started()
    worktree.is_clean = function()
      return true
    end
    worktree.head = function()
      return "base123"
    end
    local answer = implementation.stop(H.encode({ plan_id = plan_id, cwd = workdir, session_id = meta.session_id }))
    assert.is_truthy(answer:match("^continue:"))
    assert.is_truthy(answer:match("no committed implementation"))
  end)

  it("refuses an empty commit that changes no repository content", function()
    local meta = started()
    worktree.is_clean = function()
      return true
    end
    worktree.head = function()
      return "empty456"
    end
    worktree.git = function()
      return { ok = true, code = 0, out = "", err = "" }
    end
    local answer = implementation.stop(H.encode({ plan_id = plan_id, cwd = workdir, session_id = meta.session_id }))
    assert.is_truthy(answer:match("^continue:"))
    assert.is_truthy(answer:match("do not change the repository"))
  end)

  it("pins verification to the clean committed HEAD", function()
    local meta = started()
    worktree.is_clean = function()
      return true
    end
    worktree.head = function()
      return "verified456"
    end
    local answer
    H.capture_notify(function()
      answer = implementation.stop(H.encode({ plan_id = plan_id, cwd = workdir, session_id = meta.session_id }))
    end)
    local saved = store.meta(plan_id, cwd)
    assert.equals("ready", answer)
    assert.equals("review_ready", saved.status)
    assert.equals("verified456", saved.verified_head)
  end)

  it("checkpoints review feedback and sends it to the same session", function()
    started()
    worktree.is_clean = function()
      return true
    end
    worktree.head = function()
      return "verified456"
    end
    store.set_meta(plan_id, { status = "reviewing", verified_head = "verified456" }, cwd)
    package.loaded["flow.review"] = { close = function() end }
    H.capture_notify(function()
      assert.is_true(implementation.feedback(plan_id, "remove the feature flag"))
    end)
    local feedback = store.last_feedback(plan_id, cwd)
    assert.equals("verified456", feedback.checkpoint)
    assert.equals("remove the feature flag", feedback.body)
    assert.equals("revising", store.meta(plan_id, cwd).status)
    assert.equals(1, #sent)
    assert.is_truthy(sent[1]:match("repository%-wide"))
  end)

  it("checkpoints feedback typed directly into the Flow terminal", function()
    local meta = started()
    worktree.is_clean = function()
      return true
    end
    worktree.head = function()
      return "verified456"
    end
    store.set_meta(plan_id, { status = "reviewing", verified_head = "verified456" }, cwd)
    package.loaded["flow.review"] = { close = function() end }
    local answer = implementation.prompt_submitted(H.encode({
      plan_id = plan_id,
      cwd = workdir,
      prompt = "remove the feature flag",
      session_id = meta.session_id,
    }))
    assert.equals("checkpointed", answer)
    local feedback = store.last_feedback(plan_id, cwd)
    assert.equals("terminal", feedback.source)
    assert.equals("verified456", feedback.checkpoint)
    assert.equals("revising", store.meta(plan_id, cwd).status)
  end)

  it("integrates an advanced source commit and moves the review base", function()
    local meta = started()
    local current = "verified456"
    worktree.is_clean = function()
      return true
    end
    worktree.head = function()
      return current
    end
    worktree.git = function(_, args)
      assert.equals("merge-base", args[1])
      return { ok = true, out = "", err = "" }
    end
    store.set_meta(plan_id, { status = "merge_ready", verified_head = current }, cwd)
    package.loaded["flow.review"] = { close = function() end }
    H.capture_notify(function()
      assert.is_true(implementation.sync(plan_id, "newbase789"))
    end)
    assert.is_truthy(sent[1]:match("newbase789"))
    assert.is_truthy(sent[1]:match("Do not rebase"))
    current = "merged999"
    local answer
    H.capture_notify(function()
      answer = implementation.stop(H.encode({ plan_id = plan_id, cwd = workdir, session_id = meta.session_id }))
    end)
    assert.equals("ready", answer)
    local saved = store.meta(plan_id, cwd)
    assert.equals("newbase789", saved.base_head)
    assert.equals("merged999", saved.verified_head)
  end)
end)
