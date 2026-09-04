local H = require("helpers")

describe("claude.sessions", function()
  local sessions
  local telescope_names = {
    "telescope.pickers",
    "telescope.finders",
    "telescope.previewers",
    "telescope.config",
    "telescope.sorters",
    "telescope.actions",
    "telescope.actions.state",
    "telescope.pickers.entry_display",
  }
  local saved_telescope

  before_each(function()
    H.reset_buffers()
    saved_telescope = {}
    for _, name in ipairs(telescope_names) do
      saved_telescope[name] = package.loaded[name]
    end
    sessions = H.reload("claude.sessions")
    sessions.reset()
    sessions.opts.state_path = H.tmpdir() .. "/claude-sessions.json"
    sessions.tmux = {
      socket = "test-claude",
      available = function()
        return false
      end,
      name = function(key)
        return "claude-" .. tostring(key)
      end,
      has = function()
        return false
      end,
      list = function()
        return {}
      end,
      create_command = function()
        error("tmux should not start in this test")
      end,
      attach_command = function()
        error("tmux should not attach in this test")
      end,
      configure = function()
        return true
      end,
      kill = function()
        return true
      end,
    }
  end)

  after_each(function()
    sessions.reset()
    for _, name in ipairs(telescope_names) do
      package.loaded[name] = saved_telescope[name]
    end
    H.reset_buffers()
  end)

  it("lists active and recently finished sessions", function()
    local running = sessions.start({
      title = "Plan the change",
      kind = "Flow plan",
      prompt = "Add the feature",
      cwd = "/tmp/project",
    })
    local finished = sessions.start({ title = "Fix line 8", kind = "one-shot" })
    sessions.finish(finished, true, "Fixed the import")

    local text = table.concat(sessions.panel_lines(), "\n")
    assert.is_truthy(text:match("1 running"))
    assert.is_truthy(text:match("1 recent"))
    assert.is_truthy(text:match("Plan the change"))
    assert.is_truthy(text:match("Fix line 8"))
    assert.equals("running", sessions.get(running).status)
  end)

  it("orders running agents first and makes their context searchable", function()
    local finished = sessions.start({
      title = "Review the API",
      kind = "AI review",
      prompt = "Map the risky changes",
      cwd = "/tmp/service",
      session_id = "review-session",
    })
    sessions.tool(finished, "Read", "src/api.lua")
    sessions.finish(finished, true, "The boundary changed")
    local running = sessions.start({
      title = "Fix the tests",
      kind = "terminal",
      prompt = "Repair the contract test",
      cwd = "/tmp/service",
      channel = 42,
      buf = vim.api.nvim_create_buf(false, true),
    })

    local records = sessions.manager_records()
    assert.equals(running, records[1].id)
    assert.equals(finished, records[2].id)
    local searchable = sessions.search_text(records[2])
    assert.is_truthy(searchable:match("Review the API"))
    assert.is_truthy(searchable:match("Map the risky changes"))
    assert.is_truthy(searchable:match("src/api%.lua"))
    assert.is_truthy(searchable:match("boundary changed"))
  end)

  it("keeps running machine-only jobs out of the TUI manager", function()
    local id = sessions.start({
      title = "Build review map",
      kind = "AI review",
      session_id = "background-review",
    })

    assert.same({}, sessions.manager_records())
    sessions.finish(id, true, "Review map ready")
    assert.equals(id, sessions.manager_records()[1].id)
  end)

  it("builds a live preview for the selected agent", function()
    local id = sessions.start({
      title = "Review the API",
      kind = "AI review",
      prompt = "Map the risky changes",
      cwd = "/tmp/service",
      send = function()
        return true
      end,
    })
    sessions.tool(id, "Grep", "public function")
    sessions.append(id, "Checking the call sites")

    local shown = table.concat(sessions.detail_lines(id), "\n")
    assert.is_truthy(shown:match("# Review the API"))
    assert.is_truthy(shown:match("Running"))
    assert.is_truthy(shown:match("Map the risky changes"))
    assert.is_truthy(shown:match("Grep · public function"))
    assert.is_truthy(shown:match("Checking the call sites"))
    assert.is_truthy(shown:match("Claude · latest response"))
    assert.is_truthy(shown:match("Type below"))
  end)

  it("summarizes internal prompt scaffolding instead of dumping it", function()
    local prompt = "Review the changed behavior." .. string.rep(" hidden implementation detail", 200)
    local id = sessions.start({ title = "Review", kind = "AI review", prompt = prompt })
    sessions.finish(id, true, "The public behavior is safe.")

    local shown = table.concat(sessions.detail_lines(id), "\n")
    assert.is_truthy(shown:match("### Current request"))
    assert.is_truthy(shown:match("Review the changed behavior"))
    assert.is_truthy(shown:match("chars"))
    assert.is_truthy(shown:match("## Claude · latest response"))
    assert.is_truthy(shown:match("The public behavior is safe"))
    assert.is_true(#shown < #prompt)
  end)

  it("shows a terminal agent's live screen in the manager", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "Claude Code", "Thinking about the tests…" })
    local id = sessions.start({
      title = "Interactive Claude",
      kind = "terminal",
      buf = buf,
      channel = 42,
    })

    assert.same({ "Claude Code", "Thinking about the tests…" }, sessions.preview_lines(id))
  end)

  it("positions every preview at the latest output", function()
    local buf = vim.api.nvim_get_current_buf()
    local lines = {}
    for index = 1, 100 do
      table.insert(lines, "message " .. index)
    end
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.api.nvim_win_set_cursor(0, { 1, 0 })

    assert.is_true(sessions.focus_latest(0, buf))
    assert.equals(100, vim.api.nvim_win_get_cursor(0)[1])
    assert.is_true(vim.fn.line("w0") > 1)
  end)

  it("bounds large AI prompts in the Telescope search index", function()
    local id = sessions.start({
      title = "Large review",
      prompt = string.rep("a", 20000) .. " final-anchor",
    })

    local searchable = sessions.search_text(sessions.get(id))
    assert.is_true(#searchable < 7000)
    assert.is_truthy(searchable:match("final%-anchor"))
  end)

  it("keeps the complete input and conclusion for inspection", function()
    local id = sessions.start({ title = "Fix it", prompt = "Fix the diagnostic" })
    sessions.tool(id, "Read", "index.ts")
    sessions.append(id, "Looking at the import")
    sessions.finish(id, true, "Changed the import")

    local shown = table.concat(sessions.detail_lines(id), "\n")
    assert.is_truthy(shown:match("Fix the diagnostic"))
    assert.is_truthy(shown:match("Read · index%.ts"))
    assert.is_truthy(shown:match("Changed the import"))
  end)

  it("sends guidance into a running background session", function()
    local sent = {}
    local id = sessions.start({
      title = "Planning",
      prompt = "Start here",
      send = function(text)
        table.insert(sent, text)
        return true
      end,
    })

    assert.is_true(sessions.send(id, "Keep this in the API layer"))
    assert.same({ "Keep this in the API layer" }, sent)
    assert.same({ "Start here", "Keep this in the API layer" }, sessions.get(id).prompts)
  end)

  it("submits terminal guidance after Claude processes the paste", function()
    local sent = {}
    local original = vim.fn.chansend
    vim.fn.chansend = function(channel, text)
      table.insert(sent, { channel, text })
      return 1
    end
    local id = sessions.start({ title = "Interactive", kind = "terminal", channel = 42, auto_title = true })

    assert.is_true(sessions.send(id, "Explain this line"))
    assert.equals(1, #sent)
    H.settle(150)
    vim.fn.chansend = original

    assert.same({ 42, "Explain this line" }, sent[1])
    assert.same({ 42, "\r" }, sent[2])
    assert.equals("Explain this line", sessions.get(id).prompts[1])
    assert.equals("Explain this line", sessions.get(id).title)
  end)

  it("resumes a finished session in an interactive terminal", function()
    local spawned
    sessions.spawn_terminal = function(cmd, opts)
      spawned = { cmd = cmd, opts = opts }
      local buf = vim.api.nvim_create_buf(false, true)
      return { buf = buf, channel = 42 }
    end
    local id = sessions.start({
      title = "Flow plan",
      cwd = "/tmp/project",
      session_id = "1234-session",
      resume_args = { "--permission-mode", "plan" },
    })
    sessions.finish(id, true, "Done")

    assert.is_true(sessions.open(id))
    assert.equals("claude", spawned.cmd[1])
    assert.equals("--resume", spawned.cmd[2])
    assert.equals("1234-session", spawned.cmd[3])
    assert.is_true(vim.tbl_contains(spawned.cmd, "plan"))
    assert.equals("/tmp/project", spawned.opts.cwd)
    assert.equals("running", sessions.get(id).status)
    assert.is_true(sessions.get(id).persistent)
    assert.equals("claude-" .. sessions.get(id).key, sessions.get(id).tmux_name)
  end)

  it("creates a hidden terminal session and opens it in the manager", function()
    local spawned
    local opened
    local terminal_buf = vim.api.nvim_create_buf(false, true)
    sessions.spawn_terminal = function(cmd, opts)
      spawned = { cmd = cmd, opts = opts }
      return { buf = terminal_buf, channel = 42 }
    end
    sessions.open_telescope = function(opts)
      opened = opts
      return true
    end

    local id = sessions.new_terminal_session({
      title = "New review agent",
      cwd = "/tmp/project",
      default_text = "Check cancellation ",
    })

    local record = sessions.get(id)
    assert.equals("terminal", record.kind)
    assert.equals("running", record.status)
    assert.equals(terminal_buf, record.buf)
    assert.equals(42, record.channel)
    assert.equals("claude", spawned.cmd[1])
    assert.equals("--session-id", spawned.cmd[2])
    assert.equals(record.session_id, spawned.cmd[3])
    assert.equals("--name", spawned.cmd[4])
    assert.equals("New review agent", spawned.cmd[5])
    assert.equals("--permission-mode", spawned.cmd[6])
    assert.equals("auto", spawned.cmd[7])
    assert.equals("--ide", spawned.cmd[8])
    assert.same({ "--permission-mode", "auto" }, record.resume_args)
    assert.equals("/tmp/project", spawned.opts.cwd)
    assert.equals("true", spawned.opts.env.ENABLE_IDE_INTEGRATION)
    assert.equals("true", spawned.opts.env.FORCE_CODE_TERMINAL)
    assert.equals("Check cancellation ", opened.default_text)
    assert.equals(-1, vim.fn.bufwinid(terminal_buf))
  end)

  it("carries Flow metadata and hook variables into a managed terminal", function()
    local spawned
    sessions.spawn_terminal = function(cmd, opts)
      spawned = { cmd = cmd, opts = opts }
      return { buf = vim.api.nvim_create_buf(false, true), channel = 42 }
    end
    sessions.open_telescope = function()
      return true
    end

    local id = sessions.new_terminal_session({
      key = "flow-plan-1",
      title = "Flow plan",
      kind = "Flow plan",
      prompt = "Write the plan",
      session_id = "flow-session",
      cmd = { "claude", "Write the plan" },
      resume_args = { "--permission-mode", "plan" },
      env_overrides = { CLAUDE_NVIM_FLOW_PLAN_ID = "plan-1" },
    })

    local record = sessions.get(id)
    assert.equals("Flow plan", record.kind)
    assert.equals("Write the plan", record.prompt)
    assert.same({ "--permission-mode", "plan" }, record.resume_args)
    assert.equals("plan-1", record.env_overrides.CLAUDE_NVIM_FLOW_PLAN_ID)
    assert.equals("plan-1", spawned.opts.env.CLAUDE_NVIM_FLOW_PLAN_ID)
    assert.equals("true", spawned.opts.env.ENABLE_IDE_INTEGRATION)
  end)

  it("runs interactive Claude inside the private tmux namespace", function()
    local wrapped
    local configured
    sessions.tmux.available = function()
      return true
    end
    sessions.tmux.create_command = function(name, cwd, env, args)
      wrapped = { name = name, cwd = cwd, env = env, args = args }
      return { "tmux", "new" }
    end
    sessions.tmux.configure = function(name, metadata)
      configured = { name = name, metadata = metadata }
      return true
    end
    sessions.spawn_terminal = function(cmd)
      assert.same({ "tmux", "new" }, cmd)
      return { buf = vim.api.nvim_create_buf(false, true), channel = 42 }
    end
    sessions.open_telescope = function()
      return true
    end

    local id = sessions.new_terminal_session({ title = "Persistent review", cwd = "/tmp/project" })
    local record = sessions.get(id)

    assert.is_true(record.persistent)
    assert.equals(record.tmux_name, wrapped.name)
    assert.equals("/tmp/project", wrapped.cwd)
    assert.equals("1", wrapped.env.CLAUDE_CODE_TMUX_TRUECOLOR)
    assert.equals("claude", wrapped.args[1])
    assert.is_true(vim.tbl_contains(wrapped.args, "--ide"))
    assert.equals(record.session_id, configured.metadata.session_id)
    assert.equals("Persistent review", configured.metadata.title)
  end)

  it("persists pinned session metadata across module reloads", function()
    local path = sessions.opts.state_path
    local id = sessions.start({
      title = "Architecture plan",
      kind = "terminal",
      cwd = "/tmp/project",
      session_id = "persistent-session",
      tmux_name = "claude-persistent-session",
      persistent = true,
      pinned = true,
      env_overrides = { CLAUDE_NVIM_FLOW_PLAN_ID = "plan-1" },
    })
    sessions.finish(id, true, "Ready to continue")
    assert.equals(1, vim.fn.filereadable(path))
    sessions.reset()

    sessions = H.reload("claude.sessions")
    sessions.opts.state_path = path
    sessions.tmux = {
      socket = "test-claude",
      available = function()
        return false
      end,
      list = function()
        return {}
      end,
    }

    assert.equals(1, sessions.load_state())
    local restored = sessions.list()[1]
    assert.equals("Architecture plan", restored.title)
    assert.equals("persistent-session", restored.session_id)
    assert.equals("finished", restored.status)
    assert.is_true(restored.pinned)
    assert.equals("plan-1", restored.env_overrides.CLAUDE_NVIM_FLOW_PLAN_ID)
  end)

  it("upgrades legacy Flow records into persistent pinned TUI sessions", function()
    local id = sessions.start({
      title = "Plan the migration",
      kind = "Flow plan",
      cwd = "/tmp/project",
      session_id = "legacy-flow-session",
      resume_args = { "--permission-mode", "plan" },
    })

    assert.equals(1, sessions.upgrade_legacy_flow_records())
    local record = sessions.get(id)
    assert.is_true(record.persistent)
    assert.is_true(record.pinned)
    assert.equals("claude-" .. record.key, record.tmux_name)
    assert.same({ "--permission-mode", "plan" }, record.resume_args)
    assert.equals(0, sessions.upgrade_legacy_flow_records())
  end)

  it("opens a finished Flow record as a tmux-backed Claude TUI", function()
    local wrapped
    sessions.tmux.available = function()
      return true
    end
    sessions.tmux.create_command = function(name, cwd, env, args)
      wrapped = { name = name, cwd = cwd, env = env, args = args }
      return { "tmux", "new" }
    end
    sessions.spawn_terminal = function(cmd)
      assert.same({ "tmux", "new" }, cmd)
      return { buf = vim.api.nvim_create_buf(false, true), channel = 42 }
    end
    local id = sessions.start({
      title = "Implement the migration",
      kind = "Flow implementation",
      cwd = "/tmp/project",
      session_id = "legacy-implementation",
      resume_args = { "--permission-mode", "auto" },
    })
    sessions.finish(id, true, "Done")
    sessions.upgrade_legacy_flow_records()

    assert.is_true(sessions.ensure_tui(id))
    assert.equals("running", sessions.get(id).status)
    assert.equals("claude", wrapped.args[1])
    assert.equals("--resume", wrapped.args[2])
    assert.equals("legacy-implementation", wrapped.args[3])
    assert.equals("/tmp/project", wrapped.cwd)
  end)

  it("reattaches a live tmux session after Neovim restarts", function()
    local path = sessions.opts.state_path
    sessions.start({
      title = "Long-running migration",
      kind = "terminal",
      cwd = "/tmp/project",
      session_id = "live-session",
      tmux_name = "claude-live-session",
      persistent = true,
    })
    sessions.reset()

    sessions = H.reload("claude.sessions")
    sessions.opts.state_path = path
    sessions.tmux = {
      socket = "test-claude",
      available = function()
        return true
      end,
      has = function(name)
        return name == "claude-live-session"
      end,
      list = function()
        return { { name = "claude-live-session" } }
      end,
      attach_command = function(name)
        return { "tmux", "attach", name }
      end,
      configure = function()
        return true
      end,
    }
    local launched
    sessions.spawn_terminal = function(cmd)
      launched = cmd
      return { buf = vim.api.nvim_create_buf(false, true), channel = 42 }
    end

    sessions.hydrate()
    local restored = sessions.list()[1]
    assert.equals("running", restored.status)
    assert.is_true(restored.detached)
    assert.is_true(restored.ide_reconnect)
    assert.is_true(sessions.attach(restored.id))
    assert.same({ "tmux", "attach", "claude-live-session" }, launched)
    assert.equals(42, sessions.get(restored.id).channel)
  end)

  it("pins long-term work and hibernates scratch sessions without losing conversation history", function()
    local killed
    sessions.tmux.available = function()
      return true
    end
    sessions.tmux.has = function()
      return true
    end
    sessions.tmux.configure = function()
      return true
    end
    sessions.tmux.kill = function(name)
      killed = name
      return true
    end
    local buf = vim.api.nvim_create_buf(false, true)
    local id = sessions.start({
      title = "Investigate cache invalidation",
      kind = "terminal",
      session_id = "scratch-session",
      tmux_name = "claude-scratch-session",
      persistent = true,
      buf = buf,
      channel = 42,
    })

    assert.is_true(sessions.rename(id, "Cache planning"))
    assert.equals("Cache planning", sessions.get(id).title)
    assert.is_true(sessions.pin(id))
    assert.is_true(sessions.get(id).pinned)
    assert.is_true(sessions.stop(id))
    assert.equals("claude-scratch-session", killed)
    assert.equals("saved", sessions.get(id).status)
    assert.equals("scratch-session", sessions.get(id).session_id)
    assert.equals(0, sessions.reap(sessions.get(id).finished_at + sessions.opts.archive_ms))
    assert.is_true(sessions.archive(id))
    assert.is_nil(sessions.get(id))
  end)

  it("starts resume, continue, and plan sessions inside the manager", function()
    local commands = {}
    sessions.spawn_terminal = function(cmd)
      table.insert(commands, cmd)
      return { buf = vim.api.nvim_create_buf(false, true), channel = 42 }
    end
    sessions.show_manager = function()
      return true
    end

    local resumed = sessions.resume_session()
    local continued = sessions.continue_session()
    local planned = sessions.plan_session()

    assert.same({ "claude", "--resume", "--permission-mode", "auto", "--ide" }, commands[1])
    assert.same({ "claude", "--continue", "--permission-mode", "auto", "--ide" }, commands[2])
    assert.is_nil(sessions.get(resumed).session_id)
    assert.is_nil(sessions.get(continued).session_id)
    assert.is_truthy(vim.tbl_contains(commands[3], "--permission-mode"))
    assert.is_truthy(vim.tbl_contains(commands[3], "plan"))
    assert.is_false(vim.tbl_contains(commands[3], "auto"))
    assert.is_truthy(sessions.get(planned).session_id)
    assert.is_true(sessions.get(planned).pinned)
  end)

  it("interrupts the latest managed terminal", function()
    local sent = {}
    local original = vim.fn.chansend
    vim.fn.chansend = function(channel, text)
      table.insert(sent, { channel, text })
      return 1
    end
    sessions.start({
      title = "Older",
      kind = "terminal",
      channel = 11,
      buf = vim.api.nvim_create_buf(false, true),
    })
    local latest = sessions.start({
      title = "Latest",
      kind = "terminal",
      channel = 22,
      buf = vim.api.nvim_create_buf(false, true),
    })

    assert.is_true(sessions.interrupt())
    vim.fn.chansend = original

    assert.same({ { 22, "\27" } }, sent)
    assert.equals("Interrupted by you", sessions.get(latest).activity[1])
  end)

  it("reconnects a surviving tmux process through Claude's IDE picker", function()
    local sent = {}
    local original = vim.fn.chansend
    vim.fn.chansend = function(channel, text)
      table.insert(sent, { channel, text })
      return 1
    end
    local id = sessions.start({
      title = "Detached review",
      kind = "terminal",
      channel = 42,
      status = "running",
      persistent = true,
      tmux_name = "claude-detached-review",
      ide_reconnect = true,
    })

    assert.is_true(sessions.reconnect_ide(id))
    assert.equals("pending", sessions.get(id).ide_reconnect)
    H.settle(150)
    vim.fn.chansend = original

    assert.same({ 42, "/ide" }, sent[1])
    assert.same({ 42, "\r" }, sent[2])
  end)

  it("builds a manager prompt from a visual line range", function()
    local buf = vim.api.nvim_get_current_buf()
    local cwd = vim.fn.getcwd()
    vim.api.nvim_buf_set_name(buf, cwd .. "/src/api.lua")

    assert.equals("@src/api.lua (lines 3-8) ", sessions.selection_reference(8, 3))
  end)

  it("builds a manager prompt from the current file and line", function()
    local buf = vim.api.nvim_get_current_buf()
    local cwd = vim.fn.getcwd()
    vim.api.nvim_buf_set_name(buf, cwd .. "/src/api.lua")
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "one", "two", "three" })
    vim.api.nvim_win_set_cursor(0, { 2, 0 })

    assert.equals("@src/api.lua (line 2) ", sessions.context_reference())
  end)

  it("registers one terminal once and marks it finished on exit", function()
    local buf = vim.api.nvim_create_buf(false, true)
    local first = sessions.register_terminal({ title = "Flow implementation", buf = buf, channel = 9 })
    local second = sessions.register_terminal({ title = "Flow implementation", buf = buf, channel = 9 })
    assert.equals(first, second)
    assert.equals(1, (sessions.count()))

    sessions.terminal_closed(buf, 0)
    assert.equals("finished", sessions.get(first).status)
  end)

  it("archives finished sessions after one hour", function()
    local id = sessions.start({ title = "Old session" })
    sessions.finish(id, true, "Done")
    local record = sessions.get(id)
    assert.equals(0, sessions.reap(record.finished_at + sessions.opts.archive_ms - 1))
    assert.equals(1, sessions.reap(record.finished_at + sessions.opts.archive_ms))
    assert.is_nil(sessions.get(id))
  end)

  it("does not fall back to a side panel without Telescope", function()
    sessions.open_telescope = function()
      return false
    end
    sessions.start({ title = "Visible session" })
    H.capture_notify(function()
      assert.is_false(sessions.toggle())
    end)
    assert.is_false(sessions.is_open())
    assert.equals(-1, vim.fn.bufnr("claude://sessions"))
  end)

  it("prefers the Telescope agent manager", function()
    local opened = 0
    sessions.open_telescope = function()
      opened = opened + 1
      return true
    end

    assert.is_true(sessions.toggle())
    assert.equals(1, opened)
    assert.equals(-1, vim.fn.bufnr("claude://sessions"))
  end)

  it("keeps agent input and the live terminal inside the Telescope manager", function()
    local sent = {}
    local terminal_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(terminal_buf, 0, -1, false, { "Claude Code", "Ready for input" })
    local id = sessions.start({
      title = "Review the API",
      kind = "terminal",
      prompt = "Map the risky changes",
      buf = terminal_buf,
      channel = 42,
      send = function(text)
        table.insert(sent, text)
        return true
      end,
    })
    sessions.append(id, "Checking the call sites")

    local mappings = {}
    local selected
    local picker_spec
    local default_action
    local prompt_buf
    local prompt_text = "Consider cancellation"
    local cleared_prompt
    local preview_buf = vim.api.nvim_create_buf(false, true)
    local preview_win = vim.api.nvim_get_current_win()
    local select_default = {}
    function select_default:replace(fn)
      default_action = fn
    end

    package.loaded["telescope.finders"] = {
      new_table = function(spec)
        local entries = {}
        for _, record in ipairs(spec.results) do
          table.insert(entries, spec.entry_maker(record))
        end
        selected = entries[1]
        return { entries = entries }
      end,
    }
    package.loaded["telescope.previewers"] = {
      new_buffer_previewer = function(spec)
        return spec
      end,
    }
    package.loaded["telescope.sorters"] = {
      new = function(spec)
        return spec
      end,
    }
    package.loaded["telescope.actions"] = {
      select_default = select_default,
      close = function(buf)
        if vim.api.nvim_buf_is_valid(buf) then
          vim.api.nvim_buf_delete(buf, { force = true })
        end
      end,
    }
    package.loaded["telescope.actions.state"] = {
      get_selected_entry = function()
        return selected
      end,
      get_current_line = function()
        return prompt_text
      end,
    }
    package.loaded["telescope.pickers.entry_display"] = {
      create = function()
        return function(values)
          return values
        end
      end,
    }
    package.loaded["telescope.pickers"] = {
      new = function(_, spec)
        picker_spec = spec
        return {
          set_prompt = function(_, text)
            cleared_prompt = text
            prompt_text = text
          end,
          refresh = function(_, finder)
            selected = finder.entries[1]
          end,
          find = function()
            prompt_buf = vim.api.nvim_create_buf(false, true)
            spec.attach_mappings(prompt_buf, function(mode, lhs, action)
              mappings[mode .. ":" .. lhs] = action
            end)
            spec.previewer.define_preview(
              { state = { bufnr = preview_buf } },
              selected,
              { preview_win = preview_win }
            )
          end,
        }
      end,
    }

    assert.is_true(sessions.open_telescope())
    assert.equals("Message agent · <CR> send · <C-t> TUI", picker_spec.prompt_title)
    assert.is_truthy(picker_spec.results_title:match("1 running"))
    assert.equals("row", picker_spec.selection_strategy)
    assert.equals(0.66, picker_spec.layout_config.horizontal.preview_width)
    assert.is_function(mappings["i:<C-s>"])
    assert.is_function(mappings["i:<C-c>"])
    assert.is_function(mappings["i:<C-x>"])
    assert.is_function(mappings["i:<C-r>"])
    assert.is_function(mappings["i:<C-t>"])
    assert.is_function(mappings["n:p"])
    assert.is_function(mappings["n:r"])
    assert.is_function(mappings["n:R"])
    assert.is_function(default_action)
    local preview = table.concat(vim.api.nvim_buf_get_lines(preview_buf, 0, -1, false), "\n")
    assert.is_truthy(preview:match("Claude Code"))
    H.settle()
    assert.equals(terminal_buf, vim.api.nvim_win_get_buf(preview_win))
    assert.equals(2, vim.api.nvim_win_get_cursor(preview_win)[1])

    default_action()
    assert.same({ "Consider cancellation" }, sent)
    assert.equals("", cleared_prompt)
    assert.equals(id, selected.value.id)
    assert.is_true(sessions.is_open())
  end)
end)
