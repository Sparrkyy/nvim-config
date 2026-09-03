local H = require("helpers")

describe("flow.picker", function()
  local store, picker, original_select

  before_each(function()
    store = H.reload("flow.store")
    H.flow_root(store)
    picker = H.reload("flow.picker")
    original_select = vim.ui.select
  end)

  after_each(function()
    vim.ui.select = original_select
  end)

  it("shows plans from every working directory", function()
    local first = H.tmpdir()
    local second = H.tmpdir()
    store.create({ title = "first repo", cwd = first })
    store.create({ title = "second repo", cwd = second })
    local shown
    vim.ui.select = function(items)
      shown = items
    end

    picker.plans()

    assert.equals(2, #shown)
    assert.is_truthy(picker.label(shown[1]):match("%[" .. vim.pesc(vim.fn.fnamemodify(shown[1].cwd, ":t")) .. "%]"))
  end)
end)
