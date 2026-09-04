local H = require("helpers")

describe("git branch UI", function()
  local ui

  local function stub_git(answers)
    local stub = { calls = {} }
    answers = answers or {}
    ui.git = function(args, done, dir)
      table.insert(stub.calls, { args = args, dir = dir })
      local answer = answers[args[1]] or {}
      done(answer.ok ~= false, answer.out or "")
    end
    return stub
  end

  local function branch_output(current)
    return table.concat({
      "refs/heads/main\tmain\t" .. (current == "main" and "*" or "") .. "\t100\t",
      "refs/heads/topic\ttopic\t" .. (current == "topic" and "*" or "") .. "\t200\t",
      "refs/remotes/origin/HEAD\torigin/HEAD\t\t300\trefs/remotes/origin/main",
      "refs/remotes/origin/new\torigin/new\t\t300\t",
    }, "\n")
  end

  local function open(answers)
    answers = answers or {}
    answers["rev-parse"] = answers["rev-parse"] or { out = "/work/repo" }
    answers["for-each-ref"] = answers["for-each-ref"] or { out = branch_output("main") }
    local git = stub_git(answers)
    ui.open()
    return git
  end

  before_each(function()
    H.reset_buffers()
    ui = H.reload("config.git_ui")
  end)

  after_each(function()
    ui.close()
  end)

  it("sorts local and remote branches by their latest commit and skips remote HEAD", function()
    local branches = ui.parse_branches(branch_output("topic"))
    assert.equals(3, #branches)
    assert.same({ name = "origin/new", current = false, remote = true, updated = 300 }, branches[1])
    assert.same({ name = "topic", current = true, remote = false, updated = 200 }, branches[2])
    assert.same({ name = "main", current = false, remote = false, updated = 100 }, branches[3])
  end)

  it("sorts equal timestamps consistently", function()
    local branches = ui.parse_branches(table.concat({
      "refs/remotes/origin/same\torigin/same\t\t100\t",
      "refs/heads/zebra\tzebra\t\t100\t",
      "refs/heads/alpha\talpha\t*\t100\t",
    }, "\n"))
    assert.same({ "alpha", "zebra", "origin/same" }, vim.tbl_map(function(branch)
      return branch.name
    end, branches))
  end)

  it("opens a branch list for the current repository", function()
    local git = open()
    assert.is_true(ui.is_open())
    assert.equals("rev-parse", git.calls[1].args[1])
    assert.equals("for-each-ref", git.calls[2].args[1])
    assert.equals("/work/repo", git.calls[2].dir)
    local shown = table.concat(ui.lines(), "\n")
    assert.is_truthy(shown:match("● main"))
    assert.is_truthy(shown:match("origin/new  %(remote%)"))
    assert.is_truthy(shown:match("Keys"))
    assert.is_truthy(shown:match("Enter  switch branch"))
    assert.is_truthy(shown:match("n      new branch"))
    assert.is_truthy(shown:match("f      fetch all remotes"))
    assert.is_truthy(shown:match("q/Esc  close"))
  end)

  it("does not open outside a repository", function()
    stub_git({ ["rev-parse"] = { ok = false, out = "not a git repository" } })
    local seen = H.capture_notify(ui.open)
    assert.is_false(ui.is_open())
    assert.equals(vim.log.levels.ERROR, seen[1].level)
    assert.is_truthy(seen[1].msg:match("not a Git repository"))
  end)

  it("switches to a local branch and refreshes the list", function()
    local git = open()
    H.capture_notify(function()
      ui.switch({ name = "topic", current = false, remote = false })
    end)
    assert.same({ "switch", "topic" }, git.calls[3].args)
    assert.equals("for-each-ref", git.calls[4].args[1])
  end)

  it("tracks a selected remote branch", function()
    local git = open()
    H.capture_notify(function()
      ui.switch({ name = "origin/new", current = false, remote = true })
    end)
    assert.same({ "switch", "--track", "origin/new" }, git.calls[3].args)
  end)

  it("reports a branch switch conflict", function()
    local git = open({ switch = { ok = false, out = "local changes would be overwritten" } })
    local seen = H.capture_notify(function()
      ui.switch({ name = "topic", current = false, remote = false })
    end)
    assert.equals(3, #git.calls)
    assert.equals(vim.log.levels.ERROR, seen[1].level)
    assert.is_truthy(seen[1].msg:match("local changes"))
  end)

  it("fetches every remote, prunes, and refreshes", function()
    local git = open()
    local seen = H.capture_notify(ui.fetch)
    assert.same({ "fetch", "--all", "--prune" }, git.calls[3].args)
    assert.equals("for-each-ref", git.calls[4].args[1])
    assert.is_truthy(seen[#seen].msg:match("Fetched all remotes"))
  end)

  it("creates and switches to a branch from HEAD", function()
    local git = open()
    H.stub_input("new-work", function()
      H.capture_notify(ui.create)
    end)
    assert.same({ "switch", "-c", "new-work" }, git.calls[3].args)
    assert.equals("for-each-ref", git.calls[4].args[1])
  end)

  it("does nothing when branch creation is cancelled", function()
    local git = open()
    H.stub_input(nil, ui.create)
    assert.equals(2, #git.calls)
  end)

  it("switches the branch under the cursor with Enter", function()
    local git = open()
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    H.capture_notify(function()
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)
    end)
    assert.same({ "switch", "topic" }, git.calls[3].args)
  end)

  describe("setup", function()
    before_each(function()
      ui.setup()
    end)

    it("registers the command", function()
      assert.is_truthy(vim.api.nvim_get_commands({})["GitBranches"])
    end)

    it("maps the picker", function()
      local description
      for _, mapping in ipairs(vim.api.nvim_get_keymap("n")) do
        if mapping.lhs == " gg" then
          description = mapping.desc
        end
      end
      assert.equals("Git branches", description)
    end)

    it("can set up twice", function()
      assert.has_no.errors(ui.setup)
    end)
  end)
end)
