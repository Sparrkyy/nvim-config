-- The buffer visit stack. J walks back, K walks forward, like alt-tab.

local H = require("helpers")

describe("bufstack", function()
  local bufstack, dir

  local function open(path)
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    return vim.api.nvim_get_current_buf()
  end

  before_each(function()
    H.reset_buffers()
    bufstack = H.reload("config.bufstack")
    bufstack.setup()
    dir = H.tmpdir()
  end)

  it("puts the newest visit at the top of the stack", function()
    local a = open(H.write_file(dir, "a.lua", { "a" }))
    local b = open(H.write_file(dir, "b.lua", { "b" }))
    local state = bufstack.state()
    assert.equals(b, state.stack[1])
    assert.equals(a, state.stack[2])
  end)

  it("walks back through the visited buffers", function()
    local a = open(H.write_file(dir, "a.lua", { "a" }))
    open(H.write_file(dir, "b.lua", { "b" }))

    bufstack.back()
    assert.equals(a, vim.api.nvim_get_current_buf())
  end)

  it("walks forward again after walking back", function()
    open(H.write_file(dir, "a.lua", { "a" }))
    local b = open(H.write_file(dir, "b.lua", { "b" }))

    bufstack.back()
    bufstack.forward()
    assert.equals(b, vim.api.nvim_get_current_buf())
  end)

  it("does not reorder the stack while you cycle", function()
    local a = open(H.write_file(dir, "a.lua", { "a" }))
    local b = open(H.write_file(dir, "b.lua", { "b" }))
    local c = open(H.write_file(dir, "c.lua", { "c" }))

    bufstack.back()
    bufstack.back()
    assert.equals(a, vim.api.nvim_get_current_buf())
    assert.same({ c, b, a }, bufstack.state().stack)
  end)

  it("commits the cycle on the next natural visit", function()
    open(H.write_file(dir, "a.lua", { "a" }))
    open(H.write_file(dir, "b.lua", { "b" }))
    open(H.write_file(dir, "c.lua", { "c" }))

    bufstack.back() -- now on b
    local d = open(H.write_file(dir, "d.lua", { "d" }))

    local state = bufstack.state()
    assert.equals(d, state.stack[1])
    assert.equals(1, state.idx)
  end)

  it("stops at the oldest buffer instead of wrapping", function()
    local a = open(H.write_file(dir, "a.lua", { "a" }))
    open(H.write_file(dir, "b.lua", { "b" }))

    bufstack.back()
    bufstack.back()
    bufstack.back()
    assert.equals(a, vim.api.nvim_get_current_buf())
  end)

  it("stops at the newest buffer instead of wrapping", function()
    open(H.write_file(dir, "a.lua", { "a" }))
    local b = open(H.write_file(dir, "b.lua", { "b" }))

    bufstack.forward()
    assert.equals(b, vim.api.nvim_get_current_buf())
  end)

  it("does not track a terminal or scratch buffer", function()
    local a = open(H.write_file(dir, "a.lua", { "a" }))
    local scratch = vim.api.nvim_create_buf(true, true)
    vim.bo[scratch].buftype = "nofile"
    vim.api.nvim_set_current_buf(scratch)

    local state = bufstack.state()
    assert.equals(a, state.stack[1])
    for _, b in ipairs(state.stack) do
      assert.is_not.equal(scratch, b)
    end
  end)

  it("drops a deleted buffer from the stack", function()
    local a = open(H.write_file(dir, "a.lua", { "a" }))
    open(H.write_file(dir, "b.lua", { "b" }))

    vim.api.nvim_buf_delete(a, { force = true })
    local state = bufstack.state()
    for _, b in ipairs(state.stack) do
      assert.is_not.equal(a, b)
    end
  end)

  it("keeps the stack within its depth limit", function()
    for i = 1, 40 do
      open(H.write_file(dir, "n" .. i .. ".lua", { "x" }))
    end
    assert.is_true(#bufstack.state().stack <= 30)
  end)

  it("survives a walk with an empty stack", function()
    H.reset_buffers()
    assert.has_no.errors(function()
      bufstack.back()
      bufstack.forward()
    end)
  end)

  it("state returns a copy, so a caller cannot corrupt the stack", function()
    open(H.write_file(dir, "a.lua", { "a" }))
    local state = bufstack.state()
    local before = #state.stack
    table.insert(state.stack, 9999)
    assert.equals(before, #bufstack.state().stack)
  end)

  it("reports the stack as file paths for a session file", function()
    local a = H.write_file(dir, "a.lua", { "a" })
    local b = H.write_file(dir, "b.lua", { "b" })
    open(a)
    open(b)

    local saved = bufstack.files()
    assert.equals(b, H.resolve(saved.files[1]))
    assert.equals(a, H.resolve(saved.files[2]))
    assert.equals(1, saved.idx)
  end)

  it("rebuilds the stack from file paths", function()
    local a = H.write_file(dir, "a.lua", { "a" })
    local b = H.write_file(dir, "b.lua", { "b" })
    H.reset_buffers()

    assert.is_true(bufstack.restore({ b, a }, 1))
    assert.equals(b, H.current_file())
    bufstack.back()
    assert.equals(a, H.current_file())
  end)

  it("rebuilds the stack at the saved index", function()
    local a = H.write_file(dir, "a.lua", { "a" })
    local b = H.write_file(dir, "b.lua", { "b" })
    H.reset_buffers()

    assert.is_true(bufstack.restore({ b, a }, 2))
    assert.equals(a, H.current_file())
    assert.equals(2, bufstack.state().idx)
  end)

  it("restores nothing from an empty list", function()
    assert.is_false(bufstack.restore({}, 1))
    assert.is_false(bufstack.restore(nil, 1))
  end)

  -- `nvim_set_current_buf` reads an unloaded buffer with no BufReadPre and no
  -- FileType, so the LSP and treesitter never start on a restored file.
  it("fires the file-read events for a restored buffer", function()
    local a = H.write_file(dir, "a.lua", { "a" })
    H.reset_buffers()

    local seen = {}
    local group = vim.api.nvim_create_augroup("BufstackSpecEvents", { clear = true })
    vim.api.nvim_create_autocmd({ "BufReadPre", "BufReadPost", "FileType" }, {
      group = group,
      callback = function(ev)
        seen[ev.event] = true
      end,
    })

    assert.is_true(bufstack.restore({ a }, 1))
    vim.api.nvim_del_augroup_by_id(group)

    assert.is_true(seen.BufReadPre)
    assert.is_true(seen.BufReadPost)
  end)

  it("fires the file-read events for a buffer reached with J", function()
    local a = H.write_file(dir, "a.lua", { "a" })
    local b = H.write_file(dir, "b.lua", { "b" })
    H.reset_buffers()

    -- Only the first file loads on restore. `b` stays unloaded until J.
    assert.is_true(bufstack.restore({ a, b }, 1))

    local seen = {}
    local group = vim.api.nvim_create_augroup("BufstackSpecEvents", { clear = true })
    vim.api.nvim_create_autocmd({ "BufReadPre", "BufReadPost" }, {
      group = group,
      callback = function(ev)
        seen[ev.event] = true
      end,
    })

    bufstack.back()
    vim.api.nvim_del_augroup_by_id(group)

    assert.equals(b, H.current_file())
    assert.is_true(seen.BufReadPre)
    assert.is_true(seen.BufReadPost)
  end)

  it("maps J and K in normal mode", function()
    local maps = {}
    for _, m in ipairs(vim.api.nvim_get_keymap("n")) do
      maps[m.lhs] = m.desc
    end
    assert.is_truthy(maps["J"])
    assert.is_truthy(maps["K"])
  end)
end)
