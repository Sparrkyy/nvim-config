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
      if args[1] == "ls-files" then
        return { ok = true, out = "", err = "" }
      end
      if args[1] == "log" then
        return { ok = true, out = "Change the value", err = "" }
      end
      return { ok = false, out = "", err = "unexpected" }
    end
  end)

  after_each(function()
    review.close()
    package.loaded["flow.implementation"] = nil
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
    assert.is_truthy(context:match("Reviewed lua/a.lua near line 1"))
    assert.is_truthy(context:match("@@ %-1 %+1 @@"))
  end)

  it("opens one editable buffer with the base deletion rendered inline", function()
    local diffopt = vim.o.diffopt
    H.capture_notify(function()
      assert.is_true(review.open(plan_id))
    end)
    assert.equals(diffopt, vim.o.diffopt)
    local normal_windows = 0
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if vim.api.nvim_win_get_config(win).relative == "" then
        normal_windows = normal_windows + 1
        assert.is_false(vim.wo[win].diff)
        assert.is_true(vim.wo[win].number)
        assert.equals("yes:1", vim.wo[win].signcolumn)
        assert.is_truthy(vim.wo[win].winbar:match("CORE"))
      end
    end
    assert.equals(1, normal_windows)
    local target = vim.fn.bufnr(workdir .. "/lua/a.lua")
    assert.is_true(target > 0)
    assert.is_true(vim.bo[target].modifiable)
    assert.is_false(vim.bo[target].readonly)
    local saw_deleted = false
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(target, review.diff_ns, 0, -1, { details = true })) do
      for _, virtual in ipairs(mark[4].virt_lines or {}) do
        for _, chunk in ipairs(virtual) do
          saw_deleted = saw_deleted or tostring(chunk[1]):match("local value = 1") ~= nil
        end
      end
    end
    assert.is_true(saw_deleted)
    assert.is_truthy(vim.o.statusline:match("flow.review"))
    assert.equals("reviewing", store.meta(plan_id, cwd).status)
  end)

  it("reviews the current branch and local files against the merge base with master", function()
    worktree.repository = function()
      return workdir
    end
    worktree.branch = function()
      return "feature/review-ui"
    end
    worktree.git = function(_, args)
      if args[1] == "rev-parse" then
        return { ok = true, out = "master-tip\n", err = "" }
      end
      if args[1] == "merge-base" then
        return { ok = true, out = "common-base\n", err = "" }
      end
      if args[1] == "diff" and args[2] == "--name-status" then
        assert.equals("--ignore-all-space", args[4])
        assert.equals("common-base", args[5])
        return { ok = true, out = "M\tlua/a.lua", err = "" }
      end
      if args[1] == "diff" then
        return { ok = true, out = "@@ -1 +1 @@ change value", err = "" }
      end
      if args[1] == "show" then
        return { ok = true, out = "local value = 1\nreturn value", err = "" }
      end
      if args[1] == "ls-files" then
        return { ok = true, out = "", err = "" }
      end
      return { ok = false, out = "", err = "unexpected" }
    end

    H.capture_notify(function()
      assert.is_true(review.open_diff("master", workdir))
    end)

    assert.is_truthy(review.statusline():match("feature/review%-ui"))
    assert.is_truthy(review.statusline():match("LIVE DIFF"))
    assert.is_false(vim.wo.diff)
    local target = vim.fn.bufnr(workdir .. "/lua/a.lua")
    H.capture_notify(function()
      assert.is_true(review.comment(nil, "Check this branch change", {
        buf = target,
        start_line = 1,
        end_line = 1,
      }))
      assert.is_true(review.submit())
    end)
    local review_id = "diff-" .. vim.fn.sha256("feature/review-ui\0master"):sub(1, 16)
    local comments = store.open_review_comments(review_id, workdir)
    assert.equals(1, #comments)
    assert.equals("Check this branch change", comments[1].body)
    assert.equals("review_ready", store.meta(plan_id, cwd).status)
  end)

  it("falls back to main when the repository has no master ref", function()
    worktree.repository = function()
      return workdir
    end
    worktree.branch = function()
      return "feature/review-ui"
    end
    worktree.git = function(_, args)
      if args[1] == "rev-parse" then
        if args[3] == "main^{commit}" then
          return { ok = true, out = "main-tip\n", err = "" }
        end
        return { ok = false, out = "", err = "missing" }
      end
      if args[1] == "merge-base" then
        assert.equals("main", args[2])
        return { ok = true, out = "common-base\n", err = "" }
      end
      if args[1] == "diff" then
        return { ok = true, out = "M\tlua/a.lua", err = "" }
      end
      if args[1] == "show" then
        return { ok = true, out = "local value = 1\nreturn value", err = "" }
      end
      if args[1] == "ls-files" then
        return { ok = true, out = "", err = "" }
      end
      return { ok = false, out = "", err = "unexpected" }
    end

    H.capture_notify(function()
      assert.is_true(review.open_diff("master", workdir))
    end)

    assert.is_truthy(review.statusline():match("main"))
  end)

  it("omits a file whose only changes are whitespace", function()
    local function git(args)
      local cmd = { "git", "-C", workdir }
      vim.list_extend(cmd, args)
      local result = worktree.run(cmd)
      assert.is_true(result.ok, result.err)
      return result
    end
    git({ "init", "-b", "master" })
    git({ "config", "user.email", "flow@example.test" })
    git({ "config", "user.name", "Flow Test" })
    git({ "add", "lua/a.lua" })
    git({ "commit", "-m", "Initial" })
    H.write_file(workdir, "lua/a.lua", { "local  value = 2", "return value" })
    worktree.git = function(_, args)
      return git(args)
    end
    worktree.repository = function()
      return workdir
    end
    worktree.head = function()
      return vim.trim(git({ "rev-parse", "HEAD" }).out)
    end
    worktree.branch = function()
      return "master"
    end

    local notices = H.capture_notify(function()
      assert.is_false(review.open_diff("master", workdir))
    end)

    assert.is_truthy(notices[1].msg:match("no changes"))
  end)

  it("restores the normal editor chrome when its tab is closed directly", function()
    local laststatus = vim.o.laststatus
    local statusline = vim.o.statusline
    local diffopt = vim.o.diffopt
    H.capture_notify(function()
      assert.is_true(review.open(plan_id))
    end)
    vim.cmd("tabclose")
    H.settle()
    assert.equals(laststatus, vim.o.laststatus)
    assert.equals(statusline, vim.o.statusline)
    assert.equals(diffopt, vim.o.diffopt)
    assert.equals("", review.statusline())
  end)

  it("uses normal buffer lifecycle events without Diffview autocmds", function()
    H.capture_notify(function()
      assert.is_true(review.open(plan_id))
    end)
    local lifecycle = {}
    for _, autocmd in ipairs(vim.api.nvim_get_autocmds({ group = "EthanFlowReview" })) do
      lifecycle[autocmd.event] = true
    end
    assert.is_true(lifecycle.BufEnter)
    assert.is_true(lifecycle.BufWritePost)
    assert.is_nil(lifecycle.User)
  end)

  it("moves K forward and J backward through inline changes", function()
    H.write_file(workdir, "lua/a.lua", {
      "local value = 2",
      "local middle = true",
      "return value + 1",
    })
    worktree.git = function(_, args)
      if args[1] == "diff" and args[2] == "--name-status" then
        return { ok = true, out = "M\tlua/a.lua", err = "" }
      end
      if args[1] == "diff" then
        return { ok = true, out = "@@ -1 +1 @@ first\n@@ -3 +3 @@ last", err = "" }
      end
      if args[1] == "show" then
        return { ok = true, out = "local value = 1\nlocal middle = true\nreturn value", err = "" }
      end
      if args[1] == "ls-files" then
        return { ok = true, out = "", err = "" }
      end
      return { ok = false, out = "", err = "unexpected" }
    end
    H.capture_notify(function()
      assert.is_true(review.open(plan_id))
    end)
    assert.same({ 1, 0 }, vim.api.nvim_win_get_cursor(0))
    assert.is_true(review.next(plan_id))
    assert.same({ 3, 0 }, vim.api.nvim_win_get_cursor(0))
    assert.is_true(review.prev(plan_id))
    assert.same({ 1, 0 }, vim.api.nvim_win_get_cursor(0))
  end)

  it("opens a core-first overview without adding a file-tree split", function()
    H.write_file(workdir, "lua/core_large.lua", { "new one", "new two", "new three", "new four" })
    H.write_file(workdir, "lua/core_small.lua", { "new" })
    H.write_file(workdir, "tests/run.sh", { "new test" })
    H.write_file(workdir, "README.md", { "new docs" })
    worktree.git = function(_, args)
      if args[1] == "diff" and args[2] == "--name-status" then
        return { ok = true, out = table.concat({
          "M\tREADME.md",
          "M\ttests/run.sh",
          "M\tlua/core_small.lua",
          "M\tlua/core_large.lua",
        }, "\n"), err = "" }
      end
      if args[1] == "diff" then
        return { ok = true, out = "@@ -1 +1 @@ changed", err = "" }
      end
      if args[1] == "show" then
        local file = args[2]:match(":(.*)$")
        local content = {
          ["lua/core_large.lua"] = "old one\nold two\nold three",
          ["lua/core_small.lua"] = "old",
          ["tests/run.sh"] = "old test",
          ["README.md"] = "old docs",
        }
        return { ok = true, out = content[file], err = "" }
      end
      if args[1] == "ls-files" then
        return { ok = true, out = "", err = "" }
      end
      return { ok = false, out = "", err = "unexpected" }
    end
    H.capture_notify(function()
      assert.is_true(review.open(plan_id))
    end)
    assert.equals("flowreview", vim.bo.filetype)
    local positions = {}
    for index, line in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
      for _, file in ipairs({ "lua/core_large.lua", "lua/core_small.lua", "tests/run.sh", "README.md" }) do
        if line:find(file, 1, true) then
          positions[file] = index
        end
      end
    end
    assert.is_true(positions["lua/core_large.lua"] < positions["lua/core_small.lua"])
    assert.is_true(positions["lua/core_small.lua"] < positions["tests/run.sh"])
    assert.is_true(positions["tests/run.sh"] < positions["README.md"])
    local normal_windows = 0
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if vim.api.nvim_win_get_config(win).relative == "" then
        normal_windows = normal_windows + 1
      end
    end
    assert.equals(1, normal_windows)
  end)

  it("maps J and K only inside review buffers and removes the overrides on close", function()
    H.capture_notify(function()
      assert.is_true(review.open(plan_id))
    end)
    local target = vim.fn.bufnr(workdir .. "/lua/a.lua")
    local function local_maps()
      local found = {}
      for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(target, "n")) do
        found[mapping.lhs] = mapping.desc
      end
      return found
    end
    local active = local_maps()
    assert.equals("Flow: previous changed hunk", active.J)
    assert.equals("Flow: next changed hunk", active.K)

    assert.is_true(review.close())

    local closed = local_maps()
    assert.is_nil(closed.J)
    assert.is_nil(closed.K)
  end)

  it("anchors comments in the editable buffer", function()
    H.capture_notify(function()
      assert.is_true(review.open(plan_id))
    end)
    local target = vim.fn.bufnr(workdir .. "/lua/a.lua")
    H.capture_notify(function()
      assert.is_true(review.comment(plan_id, "Use the shared helper", {
        buf = target,
        start_line = 1,
        end_line = 1,
      }))
    end)
    local comments = store.open_review_comments(plan_id, cwd)
    assert.equals(1, #comments)
    assert.equals("lua/a.lua", comments[1].file)
    assert.equals("local value = 2", comments[1].quote)
    assert.equals(1, #vim.api.nvim_buf_get_extmarks(target, review.ns, 0, -1, {}))
    assert.is_truthy(review.statusline():match("1 comment"))
  end)

  it("marks direct editor changes as pending verification", function()
    H.capture_notify(function()
      assert.is_true(review.open(plan_id))
    end)
    local target = vim.fn.bufnr(workdir .. "/lua/a.lua")
    vim.api.nvim_buf_set_lines(target, 0, 1, false, { "local value = 3" })
    vim.api.nvim_buf_call(target, function()
      vim.cmd("write")
    end)
    assert.equals("review_dirty", store.meta(plan_id, cwd).status)
    assert.is_truthy(review.statusline():match("CHANGES PENDING"))
  end)

  it("submits direct edits and queued comments together", function()
    H.capture_notify(function()
      assert.is_true(review.open(plan_id))
    end)
    local target = vim.fn.bufnr(workdir .. "/lua/a.lua")
    H.capture_notify(function()
      review.comment(plan_id, "Keep this name", { buf = target, start_line = 1, end_line = 1 })
    end)
    worktree.is_clean = function()
      return false, " M lua/a.lua"
    end
    local submitted
    package.loaded["flow.implementation"] = {
      submit_review = function(id, opts)
        submitted = { id = id, opts = opts }
        return true
      end,
    }
    assert.is_true(review.submit(plan_id))
    assert.equals(plan_id, submitted.id)
    assert.is_true(submitted.opts.direct_edits)
    assert.equals(1, #submitted.opts.comment_ids)
    assert.is_truthy(submitted.opts.text:match("Preserve the reviewer's direct"))
    assert.is_truthy(submitted.opts.text:match("Keep this name"))
  end)

  it("approves only a clean verified review without open comments", function()
    H.capture_notify(function()
      assert.is_true(review.open(plan_id))
    end)
    local target = vim.fn.bufnr(workdir .. "/lua/a.lua")
    H.capture_notify(function()
      review.comment(plan_id, "Keep this name", { buf = target, start_line = 1, end_line = 1 })
    end)
    H.capture_notify(function()
      assert.is_false(review.approve(plan_id))
    end)
    vim.api.nvim_set_current_buf(target)
    H.capture_notify(function()
      assert.is_true(review.remove_comment(plan_id))
    end)
    H.capture_notify(function()
      assert.is_true(review.approve(plan_id))
    end)
    assert.equals("merge_ready", store.meta(plan_id, cwd).status)
    assert.is_truthy(review.statusline():match("APPROVED"))
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
