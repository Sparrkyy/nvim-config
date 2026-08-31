-- Leaving a buffer writes it to disk.

local H = require("helpers")

local function read_file(path)
  return vim.fn.readfile(path)
end

describe("autosave", function()
  local autosave, dir

  before_each(function()
    H.reset_buffers()
    autosave = H.reload("config.autosave")
    dir = H.tmpdir()
  end)

  it("writes a modified file buffer", function()
    local path = H.write_file(dir, "note.txt", { "one" })
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "two" })

    assert.is_true(autosave.save(0))
    assert.same({ "two" }, read_file(path))
    assert.is_false(vim.bo.modified)
  end)

  it("does nothing for a buffer with no changes", function()
    local path = H.write_file(dir, "clean.txt", { "one" })
    vim.cmd("edit " .. vim.fn.fnameescape(path))

    assert.is_false(autosave.save(0))
    assert.same({ "one" }, read_file(path))
  end)

  it("does not write a buffer that has no file name", function()
    vim.cmd("enew")
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "scratch" })

    assert.is_false(autosave.should_save(0))
    assert.is_false(autosave.save(0))
  end)

  it("does not write a terminal or scratch buffer", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "nofile" })

    assert.is_false(autosave.should_save(buf))
  end)

  it("does not write a read-only buffer", function()
    local path = H.write_file(dir, "locked.txt", { "one" })
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "two" })
    vim.bo.readonly = true

    assert.is_false(autosave.should_save(0))
    assert.same({ "one" }, read_file(path))
  end)

  it("does not fail on an invalid buffer", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_delete(buf, { force = true })

    assert.is_false(autosave.save(buf))
  end)

  it("saves on BufLeave, which is the whole point", function()
    local group = vim.api.nvim_create_augroup("AutosaveSpec", { clear = true })
    autosave.setup(group)

    local path = H.write_file(dir, "leave.txt", { "one" })
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "left" })
    -- Moving to another buffer fires BufLeave.
    vim.cmd("edit " .. vim.fn.fnameescape(H.write_file(dir, "other.txt", { "x" })))

    assert.same({ "left" }, read_file(path))
    vim.api.nvim_del_augroup_by_id(group)
  end)
end)
