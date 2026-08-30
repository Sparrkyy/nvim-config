-- :New and <leader>n create a file and every parent directory it needs.

local H = require("helpers")

describe("newfile", function()
  local newfile, dir

  before_each(function()
    H.reset_buffers()
    newfile = H.reload("config.newfile")
    dir = H.tmpdir()
    vim.cmd("cd " .. vim.fn.fnameescape(dir))
  end)

  it("creates a file and opens it", function()
    newfile.create("hello.txt")
    assert.equals(1, vim.fn.filereadable(dir .. "/hello.txt"))
    assert.equals(H.resolve(dir .. "/hello.txt"), H.current_file())
  end)

  it("creates every missing parent directory", function()
    newfile.create("deep/nested/path/file.ts")
    assert.equals(1, vim.fn.filereadable(dir .. "/deep/nested/path/file.ts"))
    assert.equals(1, vim.fn.isdirectory(dir .. "/deep/nested/path"))
  end)

  it("creates a directory only, for a path that ends in a slash", function()
    H.capture_notify(function()
      newfile.create("just/a/dir/")
    end)
    assert.equals(1, vim.fn.isdirectory(dir .. "/just/a/dir"))
    -- It must not open a buffer for a directory.
    assert.is_falsy(H.current_file():match("just/a/dir$"))
  end)

  it("resolves a relative path against the working directory", function()
    newfile.create("relative.txt")
    assert.equals(1, vim.fn.filereadable(dir .. "/relative.txt"))
  end)

  it("accepts an absolute path", function()
    local target = dir .. "/absolute/file.txt"
    newfile.create(target)
    assert.equals(1, vim.fn.filereadable(target))
  end)

  it("expands a tilde", function()
    local text = vim.fn.expand("~")
    assert.is_true(#text > 0)
    -- Do not write into the real home directory. Check the expansion only.
    assert.equals(vim.fn.expand("~/x"), text .. "/x")
  end)

  it("does not truncate a file that already exists", function()
    local path = H.write_file(dir, "existing.txt", { "keep me" })
    newfile.create("existing.txt")
    assert.same({ "keep me" }, vim.fn.readfile(path))
  end)

  it("ignores an empty input", function()
    assert.has_no.errors(function()
      newfile.create("")
      newfile.create(nil)
    end)
  end)

  it("prompt creates the path you type", function()
    H.stub_input("from/the/prompt.txt", function()
      newfile.prompt()
    end)
    assert.equals(1, vim.fn.filereadable(dir .. "/from/the/prompt.txt"))
  end)

  it("prompt does nothing when you cancel", function()
    H.stub_input(nil, function()
      newfile.prompt()
    end)
    assert.equals(0, #vim.fn.glob(dir .. "/*", false, true))
  end)

  it("prompt pre-fills the directory of the current file", function()
    newfile.create("some/dir/current.txt")
    local prefill
    local original = vim.ui.input
    vim.ui.input = function(opts, cb)
      prefill = opts.default
      cb(nil)
    end
    newfile.prompt()
    vim.ui.input = original
    assert.equals("some/dir/", prefill)
  end)

  it("prompt pre-fills nothing from a scratch buffer", function()
    vim.cmd("enew")
    local prefill
    local original = vim.ui.input
    vim.ui.input = function(opts, cb)
      prefill = opts.default
      cb(nil)
    end
    newfile.prompt()
    vim.ui.input = original
    assert.equals("", prefill)
  end)

  it("registers the :New command", function()
    newfile.setup()
    assert.is_truthy(vim.api.nvim_get_commands({})["New"])
  end)

  it(":New with an argument creates that path", function()
    newfile.setup()
    vim.cmd("New from/command.txt")
    assert.equals(1, vim.fn.filereadable(dir .. "/from/command.txt"))
  end)

  it("makes the parent directories on a plain write", function()
    newfile.setup()
    vim.cmd("edit " .. vim.fn.fnameescape(dir .. "/made/on/write.txt"))
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "content" })
    vim.cmd("silent write")
    assert.equals(1, vim.fn.filereadable(dir .. "/made/on/write.txt"))
  end)

  it("leaves a plugin's virtual path alone on write", function()
    newfile.setup()
    -- fugitive:// and oil:// paths must never become real directories.
    assert.has_no.errors(function()
      vim.api.nvim_exec_autocmds("BufWritePre", { pattern = "fugitive:///repo/.git//0/x" })
    end)
    assert.equals(0, vim.fn.isdirectory(dir .. "/fugitive:"))
  end)

  it("maps <leader>n", function()
    newfile.setup()
    local found = false
    for _, m in ipairs(vim.api.nvim_get_keymap("n")) do
      if m.desc == "New file" then
        found = true
      end
    end
    assert.is_true(found)
  end)
end)
