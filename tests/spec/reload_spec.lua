-- :Reload drops the config modules and re-runs them.

local H = require("helpers")

describe("reload", function()
  local reload

  before_each(function()
    H.reset_buffers()
    reload = H.reload("config.reload")
  end)

  it("returns the modules it dropped", function()
    require("claude.panel")
    require("config.bufstack")
    local cleared = H.capture_notify(function()
      local names = reload.reload()
      assert.is_true(vim.tbl_contains(names, "claude.panel"))
      assert.is_true(vim.tbl_contains(names, "config.bufstack"))
    end)
    assert.is_table(cleared)
  end)

  it("drops the colourscheme modules too, so a colour edit shows up", function()
    require("ghostty")
    local names = reload.reload()
    assert.is_true(vim.tbl_contains(names, "ghostty"))
  end)

  it("re-applies the colourscheme", function()
    vim.g.colors_name = nil
    reload.reload()
    assert.equals("ghostty", vim.g.colors_name)
  end)

  it("runs the session setup, so the stack still saves after a reload", function()
    reload.reload()
    local groups = vim.api.nvim_get_autocmds({ group = "EthanSession" })
    assert.is_true(#groups > 0)
  end)

  it("gives you a fresh module table", function()
    local before = require("claude.panel")
    reload.reload()
    local after = require("claude.panel")
    assert.is_not.equal(before, after)
  end)

  it("keeps config.lazy, because lazy.setup runs once per session", function()
    package.loaded["config.lazy"] = { marker = true }
    reload.reload()
    assert.is_table(package.loaded["config.lazy"])
    assert.is_true(package.loaded["config.lazy"].marker)
    package.loaded["config.lazy"] = nil
  end)

  it("keeps itself loaded while it runs", function()
    reload.reload()
    assert.is_table(package.loaded["config.reload"])
  end)

  it("leaves an unrelated module alone", function()
    package.loaded["some.other.plugin"] = { marker = true }
    reload.reload()
    assert.is_true(package.loaded["some.other.plugin"].marker)
    package.loaded["some.other.plugin"] = nil
  end)

  it("re-runs the setup of the modules that have one", function()
    reload.reload()
    -- bufstack.setup creates this augroup and maps J.
    assert.is_number(vim.api.nvim_create_augroup("EthanBufStack", { clear = false }))
    local found = false
    for _, m in ipairs(vim.api.nvim_get_keymap("n")) do
      if m.lhs == "J" then
        found = true
      end
    end
    assert.is_true(found)
  end)

  it("re-registers the update check, so :ConfigUpdate survives a reload", function()
    reload.reload()
    assert.is_truthy(vim.api.nvim_get_commands({})["ConfigUpdate"])
  end)

  it("re-registers follow mode with the hook", function()
    reload.reload()
    -- follow.setup registers on VimEnter and DirChanged, so fire one.
    assert.has_no.errors(function()
      vim.api.nvim_exec_autocmds("DirChanged", { pattern = "global" })
    end)
  end)

  it("drops the follow queue and marks before it reloads", function()
    local follow = require("claude.follow")
    local dir = H.tmpdir()
    follow.pace_ms = 5000
    for i = 1, 3 do
      follow.open(H.write_file(dir, "r" .. i .. ".lua", { "x" }), 1)
    end
    assert.is_true(follow.queue_length() > 0)

    reload.reload()

    -- The new module starts clean.
    assert.equals(0, require("claude.follow").queue_length())
  end)

  it("re-registers the flow commands, so :FlowPlan survives a reload", function()
    reload.reload()
    assert.is_truthy(vim.api.nvim_get_commands({})["FlowPlan"])
    assert.is_truthy(vim.api.nvim_get_commands({})["FlowNext"])
    assert.is_truthy(vim.api.nvim_get_commands({})["FlowSession"])
    assert.is_truthy(vim.api.nvim_get_commands({})["FlowFeedback"])
    assert.is_truthy(vim.api.nvim_get_commands({})["FlowMerge"])
  end)

  it("drops the flow modules too", function()
    require("flow.store")
    require("flow.ui")
    local names = reload.reload()
    assert.is_true(vim.tbl_contains(names, "flow.store"))
    assert.is_true(vim.tbl_contains(names, "flow.ui"))
    assert.is_true(vim.tbl_contains(names, "flow"))
  end)

  it("takes down a flow preview before its module disappears", function()
    local dir = H.tmpdir()
    local file = H.write_file(dir, "sample.lua", { "local x = 1", "return x" })
    local ui = require("flow.ui")
    H.capture_notify(function()
      ui.preview({
        file = file,
        edits = { { old_string = "local x = 1", new_string = "local x = 2" } },
        rationale = "Change it.",
        title = "Change it",
      })
    end)
    local buf = vim.api.nvim_get_current_buf()
    assert.is_true(ui.is_open())

    reload.reload()

    -- The extmarks and the buffer-local keys go with it.
    local ns = require("flow.ui").ns
    assert.equals(0, #vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {}))
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
      assert.is_not.equal("r", m.lhs)
    end
  end)

  it("reports a module that will not load, instead of throwing", function()
    package.loaded["config.options"] = nil
    package.preload["config.options"] = function()
      error("deliberate syntax error")
    end

    local names, failures = reload.reload()
    package.preload["config.options"] = nil

    assert.is_table(names)
    assert.equals(1, #failures)
    assert.equals("config.options", failures[1].module)
    assert.is_truthy(failures[1].err:match("deliberate syntax error"))
  end)

  it("run reports the count on success", function()
    local seen = H.capture_notify(function()
      reload.run()
    end)
    assert.equals(1, #seen)
    assert.is_truthy(seen[1].msg:match("Reloaded %d+ modules"))
    assert.is_truthy(seen[1].msg:match("Plugin options need a restart"))
  end)

  it("run reports a failure at error level", function()
    package.loaded["config.keymaps"] = nil
    package.preload["config.keymaps"] = function()
      error("broken on purpose")
    end

    local seen = H.capture_notify(function()
      reload.run()
    end)
    package.preload["config.keymaps"] = nil

    assert.equals(vim.log.levels.ERROR, seen[1].level)
    assert.is_truthy(seen[1].msg:match("config%.keymaps"))
    assert.is_truthy(seen[1].msg:match("1 failed"))
  end)

  it("registers the :Reload command", function()
    reload.setup()
    assert.is_truthy(vim.api.nvim_get_commands({})["Reload"])
  end)

  it("maps <leader>R", function()
    reload.setup()
    local found = false
    for _, m in ipairs(vim.api.nvim_get_keymap("n")) do
      if m.desc == "Reload config" then
        found = true
      end
    end
    assert.is_true(found)
  end)

  it("survives being run twice in a row", function()
    assert.has_no.errors(function()
      reload.reload()
      reload.reload()
    end)
  end)
end)
