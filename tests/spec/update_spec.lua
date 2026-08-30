-- The startup check and :ConfigUpdate. Every git call is stubbed here, so no
-- test reaches GitHub. The one exception runs `git` against a temporary
-- directory, which stays on this machine.

local H = require("helpers")

describe("update", function()
  local update

  before_each(function()
    update = H.reload("config.update")
  end)

  describe("check", function()
    it("fetches before it counts", function()
      local git = H.stub_git(update, { ["rev-list"] = { out = "0" } })
      update.check()
      assert.equals("fetch", git.calls[1][1])
      assert.equals("rev-list", git.calls[2][1])
    end)

    it("counts against the tracked branch, not a named remote", function()
      local git = H.stub_git(update, { ["rev-list"] = { out = "0" } })
      update.check()
      assert.is_true(vim.tbl_contains(git.calls[2], "HEAD..@{upstream}"))
    end)

    it("says how many commits wait on GitHub", function()
      H.stub_git(update, { ["rev-list"] = { out = "3" } })
      local seen = H.capture_notify(function()
        update.check()
      end)
      assert.equals(1, #seen)
      assert.is_truthy(seen[1].msg:match("3 new commits"))
      assert.is_truthy(seen[1].msg:match(":ConfigUpdate"))
      assert.equals(vim.log.levels.WARN, seen[1].level)
    end)

    it("says commit, not commits, for one", function()
      H.stub_git(update, { ["rev-list"] = { out = "1" } })
      local seen = H.capture_notify(function()
        update.check()
      end)
      assert.is_truthy(seen[1].msg:match("1 new commit%f[%A]"))
    end)

    it("stays silent when there is nothing new", function()
      H.stub_git(update, { ["rev-list"] = { out = "0" } })
      local seen = H.capture_notify(function()
        update.check()
      end)
      assert.equals(0, #seen)
    end)

    it("records how far behind it is", function()
      H.stub_git(update, { ["rev-list"] = { out = "2" } })
      H.capture_notify(function()
        update.check()
      end)
      assert.equals(2, update.behind)
    end)

    it("never pulls on its own", function()
      local git = H.stub_git(update, { ["rev-list"] = { out = "5" } })
      H.capture_notify(function()
        update.check()
      end)
      for _, call in ipairs(git.calls) do
        assert.is_not.equal("pull", call[1])
      end
    end)

    it("stays silent when GitHub is unreachable", function()
      H.stub_git(update, { fetch = { ok = false, out = "could not resolve host" } })
      local seen = H.capture_notify(function()
        update.check()
      end)
      assert.equals(0, #seen)
    end)

    it("does not count when the fetch failed", function()
      local git = H.stub_git(update, { fetch = { ok = false, out = "no network" } })
      update.check()
      assert.equals(1, #git.calls)
      assert.is_nil(update.behind)
    end)

    it("stays silent when there is no upstream branch", function()
      H.stub_git(update, { ["rev-list"] = { ok = false, out = "no upstream configured" } })
      local seen = H.capture_notify(function()
        update.check()
      end)
      assert.equals(0, #seen)
      assert.is_nil(update.behind)
    end)
  end)

  describe("check, when you ask for it", function()
    it("confirms that nothing is waiting", function()
      H.stub_git(update, { ["rev-list"] = { out = "0" } })
      local seen = H.capture_notify(function()
        update.check({ loud = true })
      end)
      assert.equals(1, #seen)
      assert.is_truthy(seen[1].msg:match("up to date"))
    end)

    it("reports a failed fetch", function()
      H.stub_git(update, { fetch = { ok = false, out = "could not resolve host" } })
      local seen = H.capture_notify(function()
        update.check({ loud = true })
      end)
      assert.equals(vim.log.levels.ERROR, seen[1].level)
      assert.is_truthy(seen[1].msg:match("could not resolve host"))
    end)

    it("reports a missing upstream branch", function()
      H.stub_git(update, { ["rev-list"] = { ok = false, out = "no upstream configured" } })
      local seen = H.capture_notify(function()
        update.check({ loud = true })
      end)
      assert.equals(vim.log.levels.ERROR, seen[1].level)
      assert.is_truthy(seen[1].msg:match("no upstream configured"))
    end)
  end)

  describe("update", function()
    it("fast-forwards a clean tree", function()
      local git = H.stub_git(update)
      H.capture_notify(function()
        update.update()
      end)
      assert.equals("status", git.calls[1][1])
      assert.equals("pull", git.calls[2][1])
      assert.is_true(vim.tbl_contains(git.calls[2], "--ff-only"))
    end)

    it("tells you what to do after a pull", function()
      H.stub_git(update)
      local seen = H.capture_notify(function()
        update.update()
      end)
      assert.is_truthy(seen[1].msg:match("updated"))
      assert.is_truthy(seen[1].msg:match(":Reload"))
    end)

    it("clears the behind count after a pull", function()
      update.behind = 4
      H.stub_git(update)
      H.capture_notify(function()
        update.update()
      end)
      assert.equals(0, update.behind)
    end)

    it("refuses to pull over uncommitted changes", function()
      local git = H.stub_git(update, { status = { out = " M lua/config/options.lua" } })
      local seen = H.capture_notify(function()
        update.update()
      end)
      assert.equals(1, #git.calls)
      assert.equals(vim.log.levels.ERROR, seen[1].level)
      assert.is_truthy(seen[1].msg:match("uncommitted changes"))
    end)

    it("reports a pull that will not fast-forward", function()
      H.stub_git(update, { pull = { ok = false, out = "not possible to fast-forward" } })
      local seen = H.capture_notify(function()
        update.update()
      end)
      assert.equals(vim.log.levels.ERROR, seen[1].level)
      assert.is_truthy(seen[1].msg:match("fast%-forward"))
    end)
  end)

  describe("the git seam", function()
    it("reports a failure instead of throwing", function()
      -- A directory that is not a repository. This runs on this machine only.
      update.dir = H.tmpdir()
      local result
      update.git({ "rev-parse", "--git-dir" }, function(ok, out)
        result = { ok = ok, out = out }
      end)
      vim.wait(5000, function()
        return result ~= nil
      end)
      assert.is_table(result)
      assert.is_false(result.ok)
    end)
  end)

  describe("setup", function()
    before_each(function()
      update.setup()
    end)

    it("registers :ConfigUpdate", function()
      assert.is_truthy(vim.api.nvim_get_commands({})["ConfigUpdate"])
    end)

    it("registers :ConfigCheck", function()
      assert.is_truthy(vim.api.nvim_get_commands({})["ConfigCheck"])
    end)

    it("maps <leader>u", function()
      local found = false
      for _, m in ipairs(vim.api.nvim_get_keymap("n")) do
        if m.desc == "Update config from GitHub" then
          found = true
        end
      end
      assert.is_true(found)
    end)

    it("checks once, on VimEnter", function()
      local autocmds = vim.api.nvim_get_autocmds({ group = "EthanConfigUpdate" })
      assert.equals(1, #autocmds)
      assert.equals("VimEnter", autocmds[1].event)
      assert.is_true(autocmds[1].once)
    end)

    it("survives a second setup, so :Reload works", function()
      assert.has_no.errors(function()
        update.setup()
      end)
      assert.equals(1, #vim.api.nvim_get_autocmds({ group = "EthanConfigUpdate" }))
    end)
  end)
end)
