-- The editor-wide autocmds. Each test fires the event and reads the result
-- back from the buffer or the window.

local H = require("helpers")

describe("config.autocmds", function()
  before_each(function()
    H.reset_buffers()
    H.reload("config.autocmds")
  end)

  it("keeps every autocmd in one group", function()
    assert.is_true(#vim.api.nvim_get_autocmds({ group = "EthanConfig" }) > 0)
  end)

  it("can load twice without stacking autocmds", function()
    local count = #vim.api.nvim_get_autocmds({ group = "EthanConfig" })
    H.reload("config.autocmds")
    assert.equals(count, #vim.api.nvim_get_autocmds({ group = "EthanConfig" }))
  end)

  it("watches for outside changes on the events Claude touches", function()
    for _, event in ipairs({ "FocusGained", "BufEnter", "CursorHold", "TermClose", "TermLeave" }) do
      local autocmds = vim.api.nvim_get_autocmds({ group = "EthanConfig", event = event })
      assert.is_true(#autocmds > 0, event .. " has no autocmd")
    end
  end)

  it("announces a buffer reloaded after a change on disk", function()
    local seen = H.capture_notify(function()
      vim.api.nvim_exec_autocmds("FileChangedShellPost", {})
    end)
    assert.equals(vim.log.levels.INFO, seen[1].level)
    assert.is_truthy(seen[1].msg:match("Buffer reloaded"))
  end)

  it("flashes the yanked lines briefly", function()
    local hl = vim.hl or vim.highlight
    local saved = hl.on_yank
    local called
    hl.on_yank = function(opts)
      called = opts
    end
    local ok, err = pcall(function()
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { "one line" })
      vim.cmd("normal! yy")
    end)
    hl.on_yank = saved
    assert(ok, err)
    assert.equals(150, called.timeout)
  end)

  it("gives web and config filetypes a two-space indent", function()
    vim.cmd("enew")
    vim.bo.filetype = "lua"
    assert.equals(2, vim.bo.shiftwidth)
    assert.equals(2, vim.bo.tabstop)
    assert.equals(2, vim.bo.softtabstop)
  end)

  it("leaves an unlisted filetype at the editor default", function()
    vim.cmd("enew")
    vim.bo.filetype = "flowtestft"
    assert.equals(8, vim.bo.shiftwidth)
  end)

  it("strips the gutter from a terminal window", function()
    vim.cmd("enew")
    vim.wo.number = true
    vim.wo.relativenumber = true
    vim.api.nvim_exec_autocmds("TermOpen", {})
    assert.is_false(vim.wo.number)
    assert.is_false(vim.wo.relativenumber)
    assert.equals("no", vim.wo.signcolumn)
  end)
end)
