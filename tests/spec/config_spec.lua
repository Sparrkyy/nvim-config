-- The plugin specs are plain Lua tables. These tests read them directly, so
-- no plugin is installed and lazy.nvim never runs.

local H = require("helpers")

--- Find one plugin spec by its repository name.
local function spec_for(module, repo)
  for _, entry in ipairs(H.reload("plugins." .. module)) do
    if entry[1] == repo then
      return entry
    end
  end
  return nil
end

describe("completion config", function()
  local blink

  before_each(function()
    blink = spec_for("completion", "saghen/blink.cmp")
  end)

  it("declares blink.cmp", function()
    assert.is_truthy(blink)
  end)

  it("takes completions from the LSP and from paths only", function()
    assert.same({ "lsp", "path" }, blink.opts.sources.default)
  end)

  it("does not use the buffer source, which suggests every word on screen", function()
    for _, source in ipairs(blink.opts.sources.default) do
      assert.is_not.equal("buffer", source)
      assert.is_not.equal("snippets", source)
    end
  end)

  it("does not depend on friendly-snippets", function()
    for _, dep in ipairs(blink.dependencies or {}) do
      assert.is_not.equal("rafamadriz/friendly-snippets", dep)
    end
  end)

  it("makes Tab accept the completion", function()
    assert.equals("select_and_accept", blink.opts.keymap["<Tab>"][1])
  end)

  it("keeps Tab working inside a snippet", function()
    assert.same({ "select_and_accept", "snippet_forward", "fallback" }, blink.opts.keymap["<Tab>"])
    assert.same({ "select_prev", "snippet_backward", "fallback" }, blink.opts.keymap["<S-Tab>"])
  end)

  it("uses the enter preset, so Enter also accepts", function()
    assert.equals("enter", blink.opts.keymap.preset)
  end)
end)

describe("telescope config", function()
  local telescope

  before_each(function()
    telescope = spec_for("telescope", "nvim-telescope/telescope.nvim")
  end)

  it("declares telescope", function()
    assert.is_truthy(telescope)
  end)

  it("loads only when a Telescope command runs", function()
    assert.equals("Telescope", telescope.cmd)
  end)

  it("binds the pickers you use most", function()
    local lhs = {}
    for _, k in ipairs(telescope.keys) do
      lhs[k[1]] = true
    end
    assert.is_true(lhs["<C-p>"])
    assert.is_true(lhs["<leader>ff"])
    assert.is_true(lhs["<leader>fg"])
  end)
end)

describe("editor options", function()
  it("hides the sign column, so nothing sits left of the text", function()
    H.reload("config.options")
    assert.equals("no", vim.o.signcolumn)
  end)

  it("hides the line numbers, so the text starts at the window edge", function()
    H.reload("config.options")
    assert.is_false(vim.o.number)
    assert.is_false(vim.o.relativenumber)
  end)

  it("hides the tildes after the last line", function()
    H.reload("config.options")
    assert.is_truthy(vim.o.fillchars:find("eob: "))
  end)

  it("shows no status line at all", function()
    H.reload("config.options")
    assert.equals(0, vim.o.laststatus)
  end)
end)

describe("status line", function()
  it("declares no status line plugin", function()
    for _, entry in ipairs(H.reload("plugins.ui")) do
      assert.is_not.equal("nvim-lualine/lualine.nvim", entry[1])
    end
  end)
end)

describe("diff review config", function()
  local diffview

  before_each(function()
    diffview = spec_for("git", "sindrets/diffview.nvim")
  end)

  it("gives Flow a quiet readable file panel and enhanced change highlights", function()
    assert.is_true(diffview.opts.enhanced_diff_hl)
    assert.is_false(diffview.opts.show_help_hints)
    assert.equals("diff2_horizontal", diffview.opts.view.default.layout)
    assert.is_false(diffview.opts.view.default.disable_diagnostics)
    assert.equals("left", diffview.opts.file_panel.win_config.position)
    assert.equals(32, diffview.opts.file_panel.win_config.width)
  end)
end)

describe("claude keymaps", function()
  local claude

  before_each(function()
    for _, entry in ipairs(H.reload("plugins.claude")) do
      if entry[1] == "coder/claudecode.nvim" then
        claude = entry
      end
    end
  end)

  it("declares claudecode.nvim", function()
    assert.is_truthy(claude)
  end)

  it("never lets claudecode.nvim open a terminal window", function()
    assert.equals("none", claude.opts.terminal.provider)
    assert.is_false(claude.opts.diff_opts.auto_resize_terminal)
  end)

  local function has_desc(text)
    for _, k in ipairs(claude.keys) do
      if k.desc == text then
        return true
      end
    end
    return false
  end

  it("binds the follow-pacing controls", function()
    assert.is_true(has_desc("Next queued jump"))
    assert.is_true(has_desc("Drop queued jumps"))
    assert.is_true(has_desc("Set follow pace"))
  end)

  it("binds the one-shot fix keys", function()
    assert.is_true(has_desc("Fix the error under the cursor"))
    assert.is_true(has_desc("Fix every error in this file"))
  end)

  it("binds the one-off request keys", function()
    assert.is_true(has_desc("One-off request"))
    assert.is_true(has_desc("One-off request on the selection"))
    assert.is_true(has_desc("Close the progress window"))
    assert.is_true(has_desc("Manage Claude agents"))
  end)

  it("binds the change-highlight controls", function()
    assert.is_true(has_desc("Toggle change highlights"))
    assert.is_true(has_desc("Clear change highlights"))
  end)

  it("binds prompting and diff review", function()
    assert.is_true(has_desc("New persistent Claude session"))
    assert.is_true(has_desc("New persistent Claude session with context"))
    assert.is_true(has_desc("Open Claude manager"))
    assert.is_true(has_desc("Resume in Claude manager"))
    assert.is_true(has_desc("Continue in Claude manager"))
    assert.is_true(has_desc("Start pinned Claude plan session"))
    assert.is_true(has_desc("Accept diff"))
    assert.is_true(has_desc("Reject diff"))
  end)

  it("uses no key twice in the same mode", function()
    local seen = {}
    for _, k in ipairs(claude.keys) do
      local mode = k.mode or "n"
      local key = tostring(mode) .. " " .. k[1]
      assert.is_nil(seen[key], "duplicate mapping: " .. key)
      seen[key] = true
    end
  end)
end)
