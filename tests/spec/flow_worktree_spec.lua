local H = require("helpers")

describe("flow.worktree", function()
  local worktree, source

  before_each(function()
    worktree = H.reload("flow.worktree")
    worktree.root = H.tmpdir() .. "/worktrees"
    source = H.tmpdir()
  end)

  local function stub(status)
    local calls = {}
    worktree.run = function(cmd)
      table.insert(calls, cmd)
      local action = cmd[4]
      if action == "status" then
        return { ok = true, code = 0, out = status or "", err = "" }
      end
      if action == "symbolic-ref" then
        return { ok = true, code = 0, out = "main", err = "" }
      end
      if action == "rev-parse" and cmd[5] == "--show-toplevel" then
        return { ok = true, code = 0, out = source, err = "" }
      end
      if action == "rev-parse" then
        return { ok = true, code = 0, out = "abc123", err = "" }
      end
      if action == "worktree" then
        return { ok = true, code = 0, out = "created", err = "" }
      end
      return { ok = false, code = 1, out = "", err = "unexpected" }
    end
    return calls
  end

  it("refuses to start from a dirty source worktree", function()
    local calls = stub(" M changed.lua")
    local info, err = worktree.prepare(source, "plan-1")
    assert.is_nil(info)
    assert.is_truthy(err:match("Commit or stash"))
    for _, cmd in ipairs(calls) do
      assert.is_not.equal("worktree", cmd[4])
    end
  end)

  it("creates a named branch and isolated worktree from HEAD", function()
    local calls = stub("")
    local info = assert(worktree.prepare(source, "Plan_1"))
    assert.equals(source, info.source_root)
    assert.equals("main", info.source_branch)
    assert.equals("abc123", info.base_head)
    assert.equals("flow/plan-1", info.worktree_branch)
    local created
    for _, cmd in ipairs(calls) do
      if cmd[4] == "worktree" then
        created = cmd
      end
    end
    assert.same({ "git", "-C", source, "worktree", "add", "-b", "flow/plan-1", info.worktree, "abc123" }, created)
  end)

  it("reports a clean worktree only for empty porcelain output", function()
    stub("")
    assert.is_true(worktree.is_clean(source))
    stub("?? new.lua")
    local clean, detail = worktree.is_clean(source)
    assert.is_false(clean)
    assert.equals("?? new.lua", detail)
  end)
end)
