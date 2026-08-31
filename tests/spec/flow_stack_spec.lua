-- The change stack: break the plan into steps, then apply them one at a time.

local H = require("helpers")

describe("flow.stack", function()
  local stack, store, job, ui, dir

  local DOC = "# Add a flag\n\n## Context\nThe CLI is quiet.\n"

  local STEPS = {
    steps = {
      { id = "add-flag", title = "Add the flag.", file = "cli.lua", kind = "edit", hint = "in parse" },
      { id = "use-flag", title = "Read the flag.", file = "main.lua", kind = "edit", hint = "in run" },
    },
  }

  local FILE = { "local M = {}", "", "function M.go()", "  return 1", "end", "", "return M" }

  before_each(function()
    H.reset_buffers()
    store = H.reload("flow.store")
    job = H.reload("flow.job")
    ui = H.reload("flow.ui")
    H.reload("flow.planner")
    stack = H.reload("flow.stack")
    stack.reset()
    ui.clear()
    ui.close_panel()

    H.flow_root(store)
    dir = H.tmpdir()
    vim.fn.writefile(FILE, dir .. "/cli.lua")
    vim.fn.writefile(FILE, dir .. "/main.lua")
  end)

  after_each(function()
    ui.clear()
    ui.close_panel()
    stack.reset()
  end)

  --- A plan that is ready to accept.
  local function accepted()
    local id = store.create({ title = "Add a flag", cwd = dir })
    store.add_revision(id, { plan_md = DOC }, dir)
    store.set_meta(id, { status = "review" }, dir)
    return id
  end

  --- Answer the decompose job with STEPS and every diff job with `edits`.
  local function stub(edits, rationale)
    return H.stub_flow_job(job, function(spec)
      if spec.json_schema and spec.json_schema.properties.steps then
        return STEPS
      end
      return { edits = edits or {}, rationale = rationale or "Do the thing." }
    end)
  end

  local function begin()
    local id = accepted()
    stub({ { old_string = "  return 1", new_string = "  return 2" } })
    H.capture_notify(function()
      stack.begin(id)
    end)
    return id
  end

  --- Decomposing -----------------------------------------------------------

  it("asks for one idea in each step", function()
    assert.is_truthy(stack.decompose_prompt(DOC):match("One idea in each step"))
    assert.is_truthy(stack.decompose_prompt(DOC):match("ASD%-STE100"))
    assert.is_truthy(stack.decompose_prompt(DOC):match("Add a flag"))
  end)

  it("turns the plan into an ordered stack", function()
    local id = begin()
    local steps = store.steps(id, dir)
    assert.equals(2, #steps)
    assert.equals("add-flag", steps[1].id)
    assert.equals("pending", steps[1].status)
    assert.equals("applying", store.meta(id, dir).status)
    assert.equals(1, store.meta(id, dir).step_cursor)
  end)

  it("gives two steps that claim one id their own diff file", function()
    local id = accepted()
    H.stub_flow_job(job, function(spec)
      if spec.json_schema and spec.json_schema.properties.steps then
        return {
          steps = {
            { id = "same", title = "One.", file = "cli.lua", kind = "edit", hint = "a" },
            { id = "same", title = "Two.", file = "cli.lua", kind = "edit", hint = "b" },
          },
        }
      end
      return { edits = {}, rationale = "x" }
    end)
    H.capture_notify(function()
      stack.begin(id)
    end)
    local steps = store.steps(id, dir)
    assert.is_not.equal(steps[1].id, steps[2].id)
  end)

  it("goes back to review when the plan will not decompose", function()
    local id = accepted()
    H.stub_flow_job(job, "not json")
    H.capture_notify(function()
      stack.begin(id)
    end)
    assert.equals("review", store.meta(id, dir).status)
  end)

  it("refuses a plan with no document", function()
    local id = store.create({ cwd = dir })
    local seen = H.capture_notify(function()
      stack.begin(id)
    end)
    assert.is_truthy(seen[1].msg:match("no document"))
  end)

  --- Generating ahead ------------------------------------------------------

  it("tells the diff job to read the file before it edits", function()
    local step = { title = "Add the flag.", file = "cli.lua", kind = "edit", hint = "in parse" }
    local prompt = stack.diff_prompt(DOC, step)
    assert.is_truthy(prompt:match("Read the file first"))
    assert.is_truthy(prompt:match("match the file on disk"))
    assert.is_truthy(prompt:match("Never write code the file already has"))
    assert.is_truthy(prompt:match("ONLY when the file does not exist"))
    assert.is_truthy(prompt:match("cli%.lua"))
  end)

  it("passes your words back when you revise a change", function()
    local step = { title = "t", file = "f", kind = "edit", hint = "h" }
    assert.is_truthy(stack.diff_prompt(DOC, step, "use a table"):match("use a table"))
    assert.is_falsy(stack.diff_prompt(DOC, step):match("<feedback>"))
  end)

  it("builds the diffs for the steps in front of you", function()
    local id = begin()
    assert.is_table(store.diff(id, "add-flag", dir))
    assert.is_table(store.diff(id, "use-flag", dir))
  end)

  it("never builds more than the lookahead", function()
    local id = accepted()
    local many = {}
    for i = 1, 40 do
      table.insert(many, {
        id = "s" .. i,
        title = "Step " .. i,
        file = "cli.lua",
        kind = "edit",
        hint = "h",
      })
    end
    local diffs = 0
    H.stub_flow_job(job, function(spec)
      if spec.json_schema and spec.json_schema.properties.steps then
        return { steps = many }
      end
      diffs = diffs + 1
      return { edits = {}, rationale = "x" }
    end)
    H.capture_notify(function()
      stack.begin(id)
    end)
    assert.is_true(diffs <= stack.opts.lookahead)
  end)

  it("stamps each diff with the generation of its file", function()
    local id = begin()
    assert.equals(0, store.diff(id, "add-flag", dir).file_generation)
  end)

  it("marks a step Flow could not build, instead of retrying forever", function()
    local id = accepted()
    H.stub_flow_job(job, function(spec)
      if spec.json_schema and spec.json_schema.properties.steps then
        return STEPS
      end
      return "sorry, no"
    end)
    H.capture_notify(function()
      stack.begin(id)
    end)
    assert.is_truthy(store.steps(id, dir)[1].error)
  end)

  --- Staleness -------------------------------------------------------------

  it("calls a diff fresh while its file has not moved", function()
    local id = begin()
    local meta = store.meta(id, dir)
    assert.equals("fresh", stack.diff_state(id, store.steps(id, dir)[1], meta, dir))
  end)

  it("calls a diff stale once its file changes under it", function()
    local id = begin()
    H.capture_notify(function()
      stack.apply(1, id, { advance = false })
    end)
    -- Step two is in another file, so it is still good.
    local meta = store.meta(id, dir)
    assert.equals("fresh", stack.diff_state(id, store.steps(id, dir)[2], meta, dir))

    -- A second step in the same file is not.
    local steps = store.steps(id, dir)
    steps[2].file = "cli.lua"
    store.set_steps(id, steps, dir)
    meta = store.meta(id, dir)
    assert.equals("stale", stack.diff_state(id, store.steps(id, dir)[2], meta, dir))
  end)

  it("calls a missing diff missing", function()
    local id = begin()
    local meta = store.meta(id, dir)
    assert.equals("missing", stack.diff_state(id, { id = "nope", file = "x" }, meta, dir))
  end)

  --- Applying --------------------------------------------------------------

  it("writes the change to the file", function()
    local id = begin()
    H.capture_notify(function()
      stack.apply(1, id, { advance = false })
    end)
    assert.equals("  return 2", vim.fn.readfile(dir .. "/cli.lua")[4])
    assert.equals("done", store.steps(id, dir)[1].status)
  end)

  it("keeps the file as it was, so undo is exact", function()
    local id = begin()
    H.capture_notify(function()
      stack.apply(1, id, { advance = false })
    end)
    assert.same(FILE, store.applied(id, dir)[1].before)
  end)

  it("puts the file back exactly on undo", function()
    local id = begin()
    H.capture_notify(function()
      stack.apply(1, id, { advance = false })
      stack.undo(id)
    end)
    assert.same(FILE, vim.fn.readfile(dir .. "/cli.lua"))
    assert.equals("pending", store.steps(id, dir)[1].status)
    assert.equals(1, store.meta(id, dir).step_cursor)
  end)

  it("says so when there is nothing to undo", function()
    local id = begin()
    local seen = H.capture_notify(function()
      stack.undo(id)
    end)
    assert.is_truthy(seen[1].msg:match("Nothing to undo"))
  end)

  it("deletes a file that undo brings back to not existing", function()
    local id = begin()
    local new_file = dir .. "/fresh.lua"
    local steps = store.steps(id, dir)
    steps[1].file = "fresh.lua"
    store.set_steps(id, steps, dir)
    store.set_diff(id, "add-flag", {
      edits = { { old_string = "", new_string = "local M = {}\nreturn M" } },
      rationale = "A new file.",
      file_generation = 0,
    }, dir)

    H.capture_notify(function()
      stack.apply(1, id, { advance = false })
    end)
    assert.equals(1, vim.fn.filereadable(new_file))

    H.capture_notify(function()
      stack.undo(id)
    end)
    assert.equals(0, vim.fn.filereadable(new_file))
  end)

  it("applies several edits in one step without moving the others", function()
    local id = accepted()
    stub({
      { old_string = "local M = {}", new_string = "local M = {}\nlocal x = 1" },
      { old_string = "return M", new_string = "return M, x" },
    })
    H.capture_notify(function()
      stack.begin(id)
      stack.apply(1, id, { advance = false })
    end)
    local after = vim.fn.readfile(dir .. "/cli.lua")
    assert.equals("local x = 1", after[2])
    assert.equals("return M, x", after[#after])
  end)

  --- Any notification matching `pattern`. The order changes as the retry
  --- path calls back into itself, so never index the list.
  local function said(seen, pattern)
    for _, n in ipairs(seen) do
      if n.msg:match(pattern) then
        return n
      end
    end
    return nil
  end

  it("builds the change again when it no longer fits the file", function()
    local id = begin()
    vim.fn.writefile({ "the file changed under us" }, dir .. "/cli.lua")
    local seen = H.capture_notify(function()
      stack.apply(1, id, { advance = false })
    end)
    assert.is_truthy(said(seen, "no longer fits"))
    assert.is_not.equal("done", store.steps(id, dir)[1].status)
  end)

  it("gives up instead of paying for the same wrong answer forever", function()
    local id = begin()
    vim.fn.writefile({ "the file changed under us" }, dir .. "/cli.lua")

    -- The model keeps answering with an edit that is not in the file.
    local builds = 0
    H.stub_flow_job(job, function(spec)
      if spec.json_schema and spec.json_schema.properties.steps then
        return STEPS
      end
      builds = builds + 1
      return { edits = { { old_string = "  return 1", new_string = "  return 2" } }, rationale = "x" }
    end)

    local seen = H.capture_notify(function()
      stack.apply(1, id, { advance = false })
    end)

    assert.is_true(builds <= stack.opts.max_retries)
    assert.is_truthy(said(seen, "still does not fit"))
    assert.is_truthy(store.steps(id, dir)[1].error)
  end)

  it("will not show a step it gave up on", function()
    local id = begin()
    stack.mark(id, "add-flag", { error = "Flow could not fit this change to the file." })
    local seen = H.capture_notify(function()
      stack.show(1, id)
    end)
    assert.is_truthy(said(seen, "could not fit"))
    assert.is_false(ui.is_open())
  end)

  it("clears the count once a change lands, so later trouble gets its own tries", function()
    local id = begin()
    stack.mark(id, "add-flag", { attempts = 2 })
    H.capture_notify(function()
      stack.apply(1, id, { advance = false })
    end)
    assert.is_nil(store.steps(id, dir)[1].attempts)
  end)

  it("applies an edit that ends at the end of the file", function()
    local id = accepted()
    -- The bug: old_string ends with a newline, and the block it names is the
    -- last thing in the file. Nothing can follow the phantom empty line.
    stub({ { old_string = "end\n\nreturn M\n", new_string = "end\n\nreturn M, 2\n" } })
    H.capture_notify(function()
      stack.begin(id)
      stack.apply(1, id, { advance = false })
    end)
    assert.equals("done", store.steps(id, dir)[1].status)
    assert.equals("return M, 2", vim.fn.readfile(dir .. "/cli.lua")[7])
  end)

  it("marks a step done when the model says the file already has it", function()
    local id = accepted()
    stub({})
    H.capture_notify(function()
      stack.begin(id)
      stack.apply(1, id, { advance = false })
    end)
    assert.equals("done", store.steps(id, dir)[1].status)
    assert.same(FILE, vim.fn.readfile(dir .. "/cli.lua"))
  end)

  --- Building against a file that is about to change ------------------------

  it("waits before building a step whose file an earlier step still changes", function()
    local id = accepted()
    local built = {}
    H.stub_flow_job(job, function(spec)
      if spec.json_schema and spec.json_schema.properties.steps then
        return { steps = {
          { id = "one", title = "First.", file = "cli.lua", kind = "edit", hint = "a" },
          { id = "two", title = "Second.", file = "cli.lua", kind = "edit", hint = "b" },
          { id = "far", title = "Elsewhere.", file = "main.lua", kind = "edit", hint = "c" },
        } }
      end
      table.insert(built, spec.title)
      return { edits = { { old_string = "  return 1", new_string = "  return 2" } }, rationale = "x" }
    end)
    H.capture_notify(function()
      stack.begin(id)
    end)

    -- Step two reads cli.lua, which step one is about to change. Step three is
    -- in another file, so it goes ahead.
    assert.is_table(store.diff(id, "one", dir))
    assert.is_nil(store.diff(id, "two", dir))
    assert.is_table(store.diff(id, "far", dir))
  end)

  it("reports a waiting step as waiting, not as ready", function()
    local id = accepted()
    store.set_steps(id, {
      { id = "one", title = "First.", file = "cli.lua", status = "pending" },
      { id = "two", title = "Second.", file = "cli.lua", status = "pending" },
    }, dir)
    store.set_meta(id, { status = "applying", step_cursor = 1 }, dir)
    local view = stack.view(id)
    assert.equals("waiting", view.status_of(view.steps[2], 2))
  end)

  it("builds a step again once the earlier one in its file lands", function()
    local id = accepted()
    store.set_steps(id, {
      { id = "one", title = "First.", file = "cli.lua", status = "done" },
      { id = "two", title = "Second.", file = "cli.lua", status = "pending" },
    }, dir)
    store.set_meta(id, { status = "applying", step_cursor = 2 }, dir)
    stub({ { old_string = "  return 1", new_string = "  return 2" } })
    stack.pump(id)
    assert.is_table(store.diff(id, "two", dir))
  end)

  it("rebuilds a diff the file outgrew, even when the counter says it is fresh", function()
    local id = begin()
    -- The counter only knows what Flow applied. Change the file behind its back.
    vim.fn.writefile({ "something else entirely" }, dir .. "/cli.lua")
    local meta = store.meta(id, dir)
    local step = store.steps(id, dir)[1]
    assert.equals("fresh", stack.diff_state(id, step, meta, dir))
    assert.is_false(stack.fits(step, store.diff(id, step.id, dir), dir))
  end)

  --- Moving ----------------------------------------------------------------

  it("applies the change and opens the next one, so one key walks the stack", function()
    local id = begin()
    H.capture_notify(function()
      stack.next(id)
      -- What <CR> does in the preview.
      stack.apply(1, id)
    end)
    assert.equals("done", store.steps(id, dir)[1].status)
    assert.equals(2, store.meta(id, dir).step_cursor)
    assert.is_true(ui.is_open())
    assert.equals(H.resolve(dir .. "/main.lua"), H.current_file())
  end)

  it("stops at the end instead of opening nothing", function()
    local id = begin()
    H.capture_notify(function()
      stack.apply(1, id, { advance = false })
      stack.apply(2, id)
    end)
    assert.equals("done", store.meta(id, dir).status)
    assert.is_false(ui.is_open())
  end)

  it("shows the first change when you start", function()
    local id = begin()
    H.capture_notify(function()
      stack.next(id)
    end)
    assert.is_true(ui.is_open())
    assert.equals(H.resolve(dir .. "/cli.lua"), H.current_file())
  end)

  it("skips the changes that are already applied", function()
    local id = begin()
    H.capture_notify(function()
      stack.apply(1, id, { advance = false })
      stack.next(id)
    end)
    assert.equals(2, store.meta(id, dir).step_cursor)
  end)

  it("finishes the plan when every change is applied", function()
    local id = begin()
    local seen = H.capture_notify(function()
      stack.apply(1, id, { advance = false })
      stack.apply(2, id, { advance = false })
      stack.next(id)
    end)
    assert.equals("done", store.meta(id, dir).status)
    assert.is_truthy(seen[#seen].msg:match("Every change is applied"))
  end)

  it("goes back one change", function()
    local id = begin()
    store.set_meta(id, { step_cursor = 2 }, dir)
    H.capture_notify(function()
      stack.prev(id)
    end)
    assert.equals(1, store.meta(id, dir).step_cursor)
  end)

  it("refuses to go back past the first change", function()
    local id = begin()
    local seen = H.capture_notify(function()
      stack.prev(id)
    end)
    assert.is_truthy(seen[1].msg:match("first change"))
  end)

  it("does nothing until the plan is accepted", function()
    local id = accepted()
    local seen = H.capture_notify(function()
      stack.next(id)
    end)
    assert.is_truthy(seen[1].msg:match("not accepted yet"))
  end)

  --- The panel and the statusline ------------------------------------------

  it("reports progress in the statusline while a stack runs", function()
    local id = begin()
    H.capture_notify(function()
      stack.apply(1, id, { advance = false })
    end)
    assert.is_truthy(stack.statusline(id):match("1/2"))
  end)

  it("says nothing in the statusline until a plan is accepted", function()
    assert.equals("", stack.statusline(accepted()))
    assert.equals("", stack.statusline(nil))
  end)

  it("builds a view the panel can draw", function()
    local id = begin()
    local view = stack.view(id)
    assert.equals("Add a flag", view.title)
    assert.equals(2, #view.steps)
    assert.equals("current", view.status_of(view.steps[1], 1))
    assert.equals("ready", view.status_of(view.steps[2], 2))
  end)

  it("shows an applied step as done", function()
    local id = begin()
    H.capture_notify(function()
      stack.apply(1, id, { advance = false })
    end)
    local view = stack.view(id)
    assert.equals("done", view.status_of(view.steps[1], 1))
  end)
end)
