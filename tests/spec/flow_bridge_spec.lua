local H = require("helpers")

describe("flow.bridge", function()
  local bridge, store, cwd, plan_id

  before_each(function()
    store = H.reload("flow.store")
    H.flow_root(store)
    cwd = H.tmpdir()
    plan_id = store.create({ title = "Plan", cwd = cwd })
    store.set_meta(plan_id, { status = "review" }, cwd)
    bridge = H.reload("flow.bridge")
  end)

  it("starts autonomous implementation when the browser approves a plan", function()
    local started = {}
    package.loaded["flow.implementation"] = {
      begin = function(id)
        table.insert(started, id)
        return true
      end,
    }
    assert.equals("implementing", bridge.dispatch("accept", plan_id, {
      revision = 0,
      diagram_check = "passed",
    }))
    assert.same({ plan_id }, started)
  end)

  it("refuses approval before the Mermaid render check passes", function()
    assert.equals(
      "accept refused: Mermaid rendering check has not passed",
      bridge.dispatch("accept", plan_id, { revision = 0 })
    )
  end)

  it("refuses approval of a stale revision", function()
    assert.equals(
      "accept refused: open the current plan revision",
      bridge.dispatch("accept", plan_id, { revision = 1, diagram_check = "passed" })
    )
  end)

  it("reports when the clean-worktree gate refuses implementation", function()
    package.loaded["flow.implementation"] = { begin = function() return false end }
    store.set_meta(plan_id, { error = "source is dirty" }, cwd)
    assert.equals("implementation refused: source is dirty", bridge.dispatch("accept", plan_id, {
      revision = 0,
      diagram_check = "passed",
    }))
  end)
end)
