-- Writing the design doc, and revising it from your comments.

local H = require("helpers")

describe("flow.planner", function()
  local planner, store, job, cwd

  before_each(function()
    store = H.reload("flow.store")
    job = H.reload("flow.job")
    planner = H.reload("flow.planner")
    H.flow_root(store)
    cwd = H.tmpdir()
  end)

  local DOC = "# Add a verbose flag\n\n## Context\nThe CLI is quiet.\n"

  --- Prompts ---------------------------------------------------------------

  it("puts your request in the first prompt", function()
    local prompt = planner.first_prompt("make the CLI louder")
    assert.is_truthy(prompt:match("make the CLI louder"))
    assert.is_truthy(prompt:match("<request>"))
  end)

  it("tells the first job not to change a file", function()
    assert.is_truthy(planner.first_prompt("x"):match("Do not change any file"))
  end)

  it("asks for Simplified Technical English in the contract", function()
    assert.is_truthy(planner.DOC_CONTRACT:match("ASD%-STE100"))
    assert.is_truthy(planner.DOC_CONTRACT:match("active voice"))
  end)

  it("asks for mermaid diagrams in the contract", function()
    assert.is_truthy(planner.DOC_CONTRACT:match("mermaid"))
    assert.is_truthy(planner.DOC_CONTRACT:match("Mermaid 11"))
    assert.is_truthy(planner.DOC_CONTRACT:match("render it as SVG"))
    assert.is_truthy(planner.DOC_CONTRACT:match("blocks approval"))
  end)

  it("asks for language that works when the browser narrates it", function()
    assert.is_truthy(planner.DOC_CONTRACT:match("reads one section aloud"))
    assert.is_truthy(planner.DOC_CONTRACT:match("Define each technical term"))
    assert.is_truthy(planner.DOC_CONTRACT:match("reading order"))
  end)

  it("makes targeted verification part of the approved contract", function()
    assert.is_truthy(planner.DOC_CONTRACT:match("new test"))
    assert.is_truthy(planner.DOC_CONTRACT:match("changed hot path"))
    assert.is_truthy(planner.DOC_CONTRACT:match("exact command"))
    assert.is_truthy(planner.DOC_CONTRACT:match("Do not require the full suite"))
  end)

  it("names every section it expects, so the page can rely on them", function()
    for _, heading in ipairs({ "Context", "Approach", "Diagrams", "Changes", "Verification", "Risks" }) do
      assert.is_truthy(planner.DOC_CONTRACT:match("## " .. heading))
    end
  end)

  it("takes the title from the first heading", function()
    assert.equals("Add a verbose flag", planner.title_of(DOC))
  end)

  it("falls back to a title when the document has no heading", function()
    assert.equals("Untitled plan", planner.title_of("just prose"))
    assert.equals("Untitled plan", planner.title_of(nil))
  end)

  --- A first plan ----------------------------------------------------------

  it("refuses an empty request", function()
    assert.is_nil(planner.start(""))
    assert.is_nil(planner.start(nil))
  end)

  it("stores the finished document as revision one", function()
    H.stub_flow_job(job, DOC)
    local id = planner.start("make it louder", { cwd = cwd })
    -- The stored document is trimmed, because a model often adds a blank line.
    assert.equals(vim.trim(DOC), store.revision(id, nil, cwd).plan_md)
    assert.equals(1, store.meta(id, cwd).current_revision)
  end)

  it("names the plan after the document", function()
    H.stub_flow_job(job, DOC)
    local id = planner.start("make it louder", { cwd = cwd })
    assert.equals("Add a verbose flag", store.meta(id, cwd).title)
    assert.equals("review", store.meta(id, cwd).status)
  end)

  it("runs the plan job in plan mode, with no write tool", function()
    local stub = H.stub_flow_job(job, DOC)
    planner.start("x", { cwd = cwd })
    local spec = stub.specs[1]
    assert.equals("plan", spec.permission_mode)
    assert.is_falsy(spec.tools:match("Write"))
    assert.is_falsy(spec.tools:match("Edit"))
  end)

  it("keeps the session id and the cost", function()
    H.stub_flow_job(job, DOC)
    local id = planner.start("x", { cwd = cwd })
    assert.equals("test-session", store.revision(id, nil, cwd).session_id)
    assert.equals(0.01, store.revision(id, nil, cwd).cost)
  end)

  it("unwraps a document the model put in a fence", function()
    H.stub_flow_job(job, "```markdown\n" .. DOC .. "\n```")
    local id = planner.start("x", { cwd = cwd })
    assert.is_truthy(store.revision(id, nil, cwd).plan_md:match("^# Add a verbose flag"))
  end)

  it("fires FlowPlanReady when a document lands", function()
    local seen = {}
    vim.api.nvim_create_autocmd("User", {
      pattern = "FlowPlanReady",
      once = true,
      callback = function(ev)
        table.insert(seen, ev.data.plan_id)
      end,
    })
    H.stub_flow_job(job, DOC)
    local id = planner.start("x", { cwd = cwd })
    assert.same({ id }, seen)
  end)

  it("records the reason when the job fails, and writes no revision", function()
    job.run = function(spec)
      spec.on_done(false, nil, { detail = "claude exploded" })
    end
    local id = planner.start("x", { cwd = cwd })
    assert.equals(0, store.meta(id, cwd).current_revision)
    assert.equals("claude exploded", store.meta(id, cwd).error)
    assert.equals("review", store.meta(id, cwd).status)
  end)

  it("treats an empty document as a failure", function()
    H.stub_flow_job(job, "   ")
    local id = planner.start("x", { cwd = cwd })
    assert.equals(0, store.meta(id, cwd).current_revision)
  end)

  --- Replanning ------------------------------------------------------------

  it("puts every comment in the replan prompt", function()
    local prompt = planner.replan_prompt(DOC, {
      { id = "c1", anchor = "approach#2", quote = "one line", body = "use a table" },
    })
    assert.is_truthy(prompt:match("c1"))
    assert.is_truthy(prompt:match("approach#2"))
    assert.is_truthy(prompt:match("one line"))
    assert.is_truthy(prompt:match("use a table"))
    assert.is_truthy(prompt:match("Add a verbose flag"))
  end)

  it("asks for the whole document back, not a diff", function()
    local prompt = planner.replan_prompt(DOC, { { id = "c1", body = "x" } })
    assert.is_truthy(prompt:match("complete revised document"))
    assert.is_truthy(prompt:match("Do not return a diff"))
  end)

  it("will not replan without a comment", function()
    H.stub_flow_job(job, DOC)
    local id = planner.start("x", { cwd = cwd })
    local seen = H.capture_notify(function()
      assert.is_false(planner.replan(id, { cwd = cwd }))
    end)
    assert.is_truthy(seen[1].msg:match("No new comments"))
  end)

  it("will not replan a plan that has no document", function()
    local id = store.create({ cwd = cwd })
    assert.is_false(planner.replan(id, { cwd = cwd }))
  end)

  it("writes the answer as the next revision", function()
    H.stub_flow_job(job, DOC)
    local id = planner.start("x", { cwd = cwd })
    store.add_comment(id, { body = "use a table" }, cwd)

    H.stub_flow_job(job, "# Add a verbose flag\n\n## Context\nRewritten.\n")
    assert.is_true(planner.replan(id, { cwd = cwd }))
    assert.equals(2, store.meta(id, cwd).current_revision)
    assert.is_truthy(store.revision(id, nil, cwd).plan_md:match("Rewritten"))
  end)

  it("stamps the comments the new revision answered", function()
    H.stub_flow_job(job, DOC)
    local id = planner.start("x", { cwd = cwd })
    local cid = store.add_comment(id, { body = "use a table" }, cwd)

    H.stub_flow_job(job, DOC)
    planner.replan(id, { cwd = cwd })

    assert.equals(0, #store.open_comments(id, cwd))
    assert.equals(2, store.comments(id, cwd)[1].addressed_in)
    assert.equals(cid, store.revision(id, nil, cwd).addressed_comments[1])
  end)

  it("leaves a comment made after the replan open", function()
    H.stub_flow_job(job, DOC)
    local id = planner.start("x", { cwd = cwd })
    store.add_comment(id, { body = "first" }, cwd)
    H.stub_flow_job(job, DOC)
    planner.replan(id, { cwd = cwd })

    store.add_comment(id, { body = "second" }, cwd)
    assert.equals(1, #store.open_comments(id, cwd))
    assert.equals("second", store.open_comments(id, cwd)[1].body)
  end)
end)
