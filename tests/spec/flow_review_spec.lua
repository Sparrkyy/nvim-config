local H = require("helpers")

describe("flow.review", function()
  local review, review_ai, store, worktree, cwd, workdir, plan_id

  before_each(function()
    H.reset_buffers()
    store = H.reload("flow.store")
    worktree = H.reload("flow.worktree")
    review_ai = H.reload("flow.review_ai")
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
    vim.g.flow_review_ai = false
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

  it("shows the selected base deletion inline with enhanced word changes", function()
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
    H.settle()
    local saw_deleted_inline = false
    local saw_change_header = false
    local saw_old_word = false
    local saw_old_context = false
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(target, review.diff_ns, 0, -1, { details = true })) do
      for _, virtual in ipairs(mark[4].virt_lines or {}) do
        local text = ""
        for _, chunk in ipairs(virtual) do
          text = text .. tostring(chunk[1])
          saw_change_header = saw_change_header or tostring(chunk[1]):match("CHANGE 1/1 · %+1 −1") ~= nil
          saw_old_word = saw_old_word or chunk[1] == "1" and chunk[2] == "FlowReviewDeleteText"
          saw_old_context = saw_old_context or chunk[1] == "local value = " and chunk[2] == "FlowReviewDelete"
        end
        saw_deleted_inline = saw_deleted_inline or text == "local value = 1"
      end
    end
    assert.is_true(saw_deleted_inline)
    assert.is_true(saw_change_header)
    assert.is_true(saw_old_word)
    assert.is_true(saw_old_context)
    local saw_new_word = false
    local floating_windows = 0
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(target, review.diff_ns, 0, -1, { details = true })) do
      if mark[4].hl_group == "FlowReviewAddText" and mark[2] == 0 then
        saw_new_word = mark[3] == 14 and mark[4].end_col == 15
      end
    end
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      local config = vim.api.nvim_win_get_config(win)
      if config.relative ~= "" then
        floating_windows = floating_windows + 1
      end
    end
    assert.is_true(saw_new_word)
    assert.equals(0, floating_windows)
    assert.is_truthy(vim.o.statusline:match("flow.review"))
    assert.equals("reviewing", store.meta(plan_id, cwd).status)
  end)

  it("cleans source metadata and keeps long deleted code inline", function()
    local old_line = "\239\187\191local value = " .. string.rep("important_name + ", 12) .. "0"
    worktree.git = function(_, args)
      if args[1] == "diff" and args[2] == "--name-status" then
        return { ok = true, out = "M\tlua/a.lua", err = "" }
      end
      if args[1] == "diff" then
        return { ok = true, out = "@@ -1 +1 @@ change value", err = "" }
      end
      if args[1] == "show" then
        return { ok = true, out = old_line .. "\nreturn value", err = "" }
      end
      if args[1] == "ls-files" then
        return { ok = true, out = "", err = "" }
      end
      return { ok = false, out = "", err = "unexpected" }
    end
    H.capture_notify(function()
      assert.is_true(review.open(plan_id))
    end)
    H.settle()
    local target = vim.fn.bufnr(workdir .. "/lua/a.lua")
    local deleted
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(target, review.diff_ns, 0, -1, { details = true })) do
      for _, virtual in ipairs(mark[4].virt_lines or {}) do
        local text = ""
        for _, chunk in ipairs(virtual) do
          text = text .. tostring(chunk[1])
        end
        if text:match("^local value") then
          deleted = text
        end
      end
    end
    assert.equals("local value = " .. string.rep("important_name + ", 12) .. "0", deleted)
    assert.equals(1, #vim.api.nvim_tabpage_list_wins(0))
  end)

  it("shows a deleted-file label after K moves into an empty deleted file", function()
    local deleted = "src/SimpleDebitCommand.cs"
    vim.fn.mkdir(workdir .. "/src", "p")
    worktree.git = function(_, args)
      if args[1] == "diff" and args[2] == "--name-status" then
        return { ok = true, out = "M\tlua/a.lua\nD\t" .. deleted, err = "" }
      end
      if args[1] == "diff" then
        if args[#args] == deleted then
          return { ok = true, out = "@@ -1,2 +0,0 @@ deleted file", err = "" }
        end
        return { ok = true, out = "@@ -1 +1 @@ change value", err = "" }
      end
      if args[1] == "show" then
        if args[2]:match(":" .. deleted .. "$") then
          return { ok = true, out = "public sealed class SimpleDebitCommand\n}", err = "" }
        end
        return { ok = true, out = "local value = 1\nreturn value", err = "" }
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
    assert.is_true(review.overview())
    H.settle()
    assert.is_true(review.next(plan_id))
    H.settle()
    assert.is_truthy(vim.api.nvim_buf_get_name(0):match("SimpleDebitCommand%.cs$"))
    local label
    local saw_deleted_code = false
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(0, review.diff_ns, 0, -1, { details = true })) do
      if mark[4].virt_text then
        local chunks = {}
        for _, chunk in ipairs(mark[4].virt_text) do
          table.insert(chunks, chunk[1])
        end
        label = table.concat(chunks)
      end
      for _, virtual in ipairs(mark[4].virt_lines or {}) do
        local text = ""
        for _, chunk in ipairs(virtual) do
          text = text .. chunk[1]
        end
        saw_deleted_code = saw_deleted_code or text == "public sealed class SimpleDebitCommand"
      end
    end
    assert.equals("  󰆴 SimpleDebitCommand.cs was deleted", label)
    assert.is_true(saw_deleted_code)
    vim.api.nvim_buf_set_lines(0, 0, 1, false, { "public sealed class RestoredCommand {}" })
    vim.api.nvim_exec_autocmds("TextChanged", { buffer = 0 })
    H.settle()
    local still_deleted = false
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(0, review.diff_ns, 0, -1, { details = true })) do
      for _, chunk in ipairs(mark[4].virt_text or {}) do
        still_deleted = still_deleted or chunk[1]:match("was deleted") ~= nil
      end
    end
    assert.is_false(still_deleted)
  end)

  it("emphasizes renamed words without emphasizing their shared line", function()
    local old_line = "var legacyPublished = await PublishTrestleMessagesAsync(instructions, result);"
    local new_line = "var sweepPublished = await PublishTrestleMessagesAsyncV2(instructions, result);"
    H.write_file(workdir, "lua/a.lua", { new_line })
    worktree.git = function(_, args)
      if args[1] == "diff" and args[2] == "--name-status" then
        return { ok = true, out = "M\tlua/a.lua", err = "" }
      end
      if args[1] == "diff" then
        return { ok = true, out = "@@ -1 +1 @@ rename publish result", err = "" }
      end
      if args[1] == "show" then
        return { ok = true, out = old_line, err = "" }
      end
      if args[1] == "ls-files" then
        return { ok = true, out = "", err = "" }
      end
      return { ok = false, out = "", err = "unexpected" }
    end
    H.capture_notify(function()
      assert.is_true(review.open(plan_id))
    end)
    H.settle()
    local target = vim.fn.bufnr(workdir .. "/lua/a.lua")
    local old_words = {}
    local new_words = {}
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(target, review.diff_ns, 0, -1, { details = true })) do
      for _, virtual in ipairs(mark[4].virt_lines or {}) do
        for _, chunk in ipairs(virtual) do
          if chunk[2] == "FlowReviewDeleteText" then
            old_words[chunk[1]] = true
          end
        end
      end
      if mark[4].hl_group == "FlowReviewAddText" then
        new_words[new_line:sub(mark[3] + 1, mark[4].end_col)] = true
      end
    end
    assert.same({
      legacyPublished = true,
      PublishTrestleMessagesAsync = true,
    }, old_words)
    assert.same({
      sweepPublished = true,
      PublishTrestleMessagesAsyncV2 = true,
    }, new_words)
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

  it("reviews the checked out source branch instead of an open Flow worktree", function()
    H.write_file(cwd, "lua/a.lua", { "local value = 3", "return value" })
    local repository_start
    local branch_root
    worktree.repository = function(start)
      repository_start = vim.fn.resolve(vim.fn.fnamemodify(start, ":p"))
      return cwd
    end
    worktree.head = function(root)
      return root == workdir and "head" or "source-head"
    end
    worktree.branch = function(root)
      branch_root = root
      return "feature/current-checkout"
    end
    worktree.git = function(root, args)
      if args[1] == "rev-parse" then
        return { ok = true, out = "master-tip\n", err = "" }
      end
      if args[1] == "merge-base" then
        return { ok = true, out = "common-base\n", err = "" }
      end
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
      return { ok = false, out = "", err = "unexpected " .. root }
    end

    H.capture_notify(function()
      assert.is_true(review.open(plan_id))
      assert.is_true(review.open_diff("master"))
    end)

    assert.equals(vim.fn.resolve(vim.fn.fnamemodify(cwd, ":p")), repository_start)
    assert.equals(cwd, branch_root)
    assert.is_truthy(review.statusline():match("feature/current%-checkout"))
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
    assert.is_true(lifecycle.CursorMoved)
    assert.is_true(lifecycle.WinScrolled)
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
    H.settle()
    local target = vim.fn.bufnr(workdir .. "/lua/a.lua")
    local function visible_deletion()
      for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(target, review.diff_ns, 0, -1, { details = true })) do
        for _, virtual in ipairs(mark[4].virt_lines or {}) do
          local text = ""
          local deletion = false
          for _, chunk in ipairs(virtual) do
            text = text .. tostring(chunk[1])
            deletion = deletion or chunk[2] == "FlowReviewDelete" or chunk[2] == "FlowReviewDeleteText"
          end
          if deletion then
            return text
          end
        end
      end
      return nil
    end
    assert.equals("local value = 1", visible_deletion())
    assert.same({ 1, 0 }, vim.api.nvim_win_get_cursor(0))
    assert.is_true(review.next(plan_id))
    H.settle()
    assert.same({ 3, 0 }, vim.api.nvim_win_get_cursor(0))
    assert.equals("return value", visible_deletion())
    assert.is_true(review.prev(plan_id))
    H.settle()
    assert.same({ 1, 0 }, vim.api.nvim_win_get_cursor(0))
    assert.equals("local value = 1", visible_deletion())
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    vim.api.nvim_exec_autocmds("CursorMoved", {})
    H.settle()
    assert.is_nil(visible_deletion())
  end)

  it("rebuilds the active deletion block while the final code is edited", function()
    H.capture_notify(function()
      assert.is_true(review.open(plan_id))
    end)
    H.settle()
    local target = vim.fn.bufnr(workdir .. "/lua/a.lua")
    vim.api.nvim_buf_set_lines(target, 0, 1, false, { "local value = 1" })
    vim.api.nvim_exec_autocmds("TextChanged", { buffer = target })
    H.settle()
    local saw_deletion = false
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(target, review.diff_ns, 0, -1, { details = true })) do
      for _, virtual in ipairs(mark[4].virt_lines or {}) do
        for _, chunk in ipairs(virtual) do
          saw_deletion = saw_deletion or chunk[2] == "FlowReviewDelete" or chunk[2] == "FlowReviewDeleteText"
        end
      end
    end
    assert.is_false(saw_deletion)
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
    local floating_windows = 0
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if vim.api.nvim_win_get_config(win).relative ~= "" then
        floating_windows = floating_windows + 1
      end
    end
    assert.equals(1, floating_windows)
    assert.is_true(review.overview())
    H.settle()
    local target = vim.fn.bufnr(workdir .. "/lua/core_large.lua")
    local saw_active_deletion = false
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(target, review.diff_ns, 0, -1, { details = true })) do
      for _, virtual in ipairs(mark[4].virt_lines or {}) do
        local text = ""
        for _, chunk in ipairs(virtual) do
          text = text .. tostring(chunk[1])
        end
        if text == "old one" then
          saw_active_deletion = true
        end
      end
    end
    assert.is_true(saw_active_deletion)
  end)

  it("upgrades the overview and hunk navigation with an AI review journey", function()
    vim.g.flow_review_ai = true
    H.write_file(workdir, "tests/a_spec.lua", { "it('covers the new value')" })
    worktree.git = function(_, args)
      if args[1] == "diff" and args[2] == "--name-status" then
        return { ok = true, out = "M\tlua/a.lua\nM\ttests/a_spec.lua", err = "" }
      end
      if args[1] == "diff" then
        return { ok = true, out = "@@ -1 +1 @@ changed", err = "" }
      end
      if args[1] == "show" then
        if args[2]:match(":tests/a_spec%.lua$") then
          return { ok = true, out = "it('covers the old value')", err = "" }
        end
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
    review.analysis.enabled = function()
      return true
    end
    review.analysis.start = function(_, files, opts)
      local analysis = assert(review_ai.normalize({
        summary = "The value contract and its verification changed.",
        groups = {
          {
            title = "Expected behavior",
            intent = "Read the boundary example before its implementation.",
            risk = "HIGH",
            reason = "The test states the final contract.",
            files = {
              {
                path = "tests/a_spec.lua",
                summary = "Changes the expected value.",
                reason = "This defines the review target.",
                hunks = {
                  {
                    index = 1,
                    briefing = "Changes the expected value boundary.",
                    checks = { "Confirm that the implementation matches this example." },
                  },
                },
              },
            },
          },
          {
            title = "Implementation",
            intent = "Review the value change.",
            risk = "MEDIUM",
            reason = "This implements the new contract.",
            files = {
              {
                path = "lua/a.lua",
                summary = "Updates the returned value.",
                reason = "Read after the expected behavior.",
                hunks = {
                  {
                    index = 1,
                    briefing = "Updates the implementation value.",
                    checks = {},
                  },
                },
              },
            },
          },
        },
        test_map = {
          {
            behavior = "Return the new value",
            status = "COVERED",
            evidence = "tests/a_spec.lua:1",
          },
        },
      }, files))
      opts.on_done(analysis)
      return true
    end

    H.capture_notify(function()
      assert.is_true(review.open(plan_id))
    end)
    H.settle()
    local overview_lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    local test_row, implementation_row
    for row, line in ipairs(overview_lines) do
      if not test_row and line:find("tests/a_spec.lua", 1, true) then
        test_row = row
      elseif not implementation_row and line:find("lua/a.lua", 1, true) then
        implementation_row = row
      end
    end
    assert.is_true(test_row < implementation_row)
    assert.is_truthy(table.concat(overview_lines, "\n"):match("HIGH%s+Expected behavior"))
    assert.is_truthy(table.concat(overview_lines, "\n"):match("COVERED%s+Return the new value"))
    assert.is_truthy(review.statusline():match("AI map"))

    assert.is_true(review.overview())
    assert.is_true(review.next(plan_id))
    H.settle()
    assert.is_truthy(vim.api.nvim_buf_get_name(0):match("tests/a_spec%.lua$"))
    local briefing
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(0, review.diff_ns, 0, -1, { details = true })) do
      for _, virtual in ipairs(mark[4].virt_lines or {}) do
        local text = ""
        for _, chunk in ipairs(virtual) do
          text = text .. chunk[1]
        end
        if text:find("Changes the expected value boundary", 1, true) then
          briefing = text
        end
      end
    end
    assert.is_truthy(briefing:match("HIGH"))
    vim.api.nvim_buf_set_lines(0, 0, 1, false, { "it('covers an edited value')" })
    vim.api.nvim_exec_autocmds("TextChanged", { buffer = 0 })
    H.settle()
    assert.is_truthy(review.statusline():match("AI stale"))
    local stale_briefing = false
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(0, review.diff_ns, 0, -1, { details = true })) do
      for _, virtual in ipairs(mark[4].virt_lines or {}) do
        for _, chunk in ipairs(virtual) do
          stale_briefing = stale_briefing or chunk[1]:find("Changes the expected value boundary", 1, true) ~= nil
        end
      end
    end
    assert.is_false(stale_briefing)
  end)

  it("maps review navigation locally without taking the editing o key", function()
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
    assert.is_nil(active.o)
    assert.equals("Flow: refresh AI review map", active.gA)
    assert.equals("Flow: toggle review overview", active[" o"] or active["<Space>o"])

    assert.is_true(review.close())

    local closed = local_maps()
    assert.is_nil(closed.J)
    assert.is_nil(closed.K)
    assert.is_nil(closed.gA)
    assert.is_nil(closed[" o"])
    assert.is_nil(closed["<Space>o"])
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
