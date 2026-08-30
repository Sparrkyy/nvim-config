-- The per-directory session. It saves the buffer stack on exit and reopens
-- it on the next start. No real Neovim restart happens here: the test saves,
-- clears every buffer, then restores.

local H = require("helpers")

describe("session", function()
  local session, bufstack, dir, state_dir

  local function open(path)
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    return vim.api.nvim_get_current_buf()
  end

  before_each(function()
    H.reset_buffers()
    bufstack = H.reload("config.bufstack")
    bufstack.setup()
    session = H.reload("config.session")
    dir = H.tmpdir()
    state_dir = H.tmpdir()
    session.dir = state_dir
  end)

  it("gives each directory its own session file", function()
    assert.is_not.equal(session.file("/one/project"), session.file("/two/project"))
  end)

  it("gives one directory the same file every time", function()
    assert.equals(session.file("/one/project"), session.file("/one/project"))
  end)

  it("saves nothing readable for a directory it never saw", function()
    assert.is_nil(session.load(dir))
  end)

  it("saves the stack newest first", function()
    local a = H.write_file(dir, "a.lua", { "a" })
    local b = H.write_file(dir, "b.lua", { "b" })
    open(a)
    open(b)

    session.save(dir)
    local data = session.load(dir)
    assert.equals(b, H.resolve(data.files[1]))
    assert.equals(a, H.resolve(data.files[2]))
  end)

  it("reopens the file you left, in the same directory", function()
    local a = H.write_file(dir, "a.lua", { "a" })
    open(a)
    session.save(dir)

    H.reset_buffers()
    assert.is_true(session.restore(dir))
    assert.equals(a, H.current_file())
  end)

  it("reopens the whole stack, so J still walks back", function()
    local a = H.write_file(dir, "a.lua", { "a" })
    local b = H.write_file(dir, "b.lua", { "b" })
    open(a)
    open(b)
    session.save(dir)

    H.reset_buffers()
    bufstack = H.reload("config.bufstack")
    bufstack.setup()
    session = H.reload("config.session")
    session.dir = state_dir

    assert.is_true(session.restore(dir))
    assert.equals(b, H.current_file())
    bufstack.back()
    assert.equals(a, H.current_file())
  end)

  it("keeps the place in the stack, so a saved walk survives", function()
    local a = H.write_file(dir, "a.lua", { "a" })
    open(a)
    open(H.write_file(dir, "b.lua", { "b" }))
    bufstack.back() -- now on a, at index 2
    session.save(dir)

    local data = session.load(dir)
    assert.equals(2, data.idx)

    H.reset_buffers()
    assert.is_true(session.restore(dir))
    assert.equals(a, H.current_file())
  end)

  it("puts the cursor back on the line you left", function()
    local a = H.write_file(dir, "a.lua", { "one", "two", "three", "four" })
    open(a)
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    session.save(dir)

    H.reset_buffers()
    session.restore(dir)
    assert.equals(3, vim.api.nvim_win_get_cursor(0)[1])
  end)

  it("clamps the cursor when the file got shorter", function()
    local a = H.write_file(dir, "a.lua", { "one", "two", "three", "four" })
    open(a)
    vim.api.nvim_win_set_cursor(0, { 4, 0 })
    session.save(dir)

    vim.fn.writefile({ "one" }, a)
    H.reset_buffers()
    session.restore(dir)
    assert.equals(1, vim.api.nvim_win_get_cursor(0)[1])
  end)

  it("drops a file that no longer exists", function()
    local a = H.write_file(dir, "a.lua", { "a" })
    local gone = H.write_file(dir, "gone.lua", { "x" })
    open(a)
    open(gone)
    session.save(dir)

    vim.fn.delete(gone)
    H.reset_buffers()
    assert.is_true(session.restore(dir))
    assert.equals(a, H.current_file())
  end)

  it("restores nothing when every saved file is gone", function()
    local gone = H.write_file(dir, "gone.lua", { "x" })
    open(gone)
    session.save(dir)

    vim.fn.delete(gone)
    H.reset_buffers()
    assert.is_false(session.restore(dir))
  end)

  it("survives a session file that is not JSON", function()
    vim.fn.mkdir(state_dir, "p")
    vim.fn.writefile({ "not json at all" }, session.file(dir))
    assert.has_no.errors(function()
      assert.is_nil(session.load(dir))
      assert.is_false(session.restore(dir))
    end)
  end)

  it("skips an unnamed buffer, because it holds no file", function()
    open(H.write_file(dir, "a.lua", { "a" }))
    vim.cmd("enew")
    session.save(dir)

    for _, path in ipairs(session.load(dir).files) do
      assert.is_not.equal("", path)
    end
  end)
end)
