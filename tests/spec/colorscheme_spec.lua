-- The Ghostty colourscheme. These tests read the group table, then load the
-- scheme for real and read the highlights back from Neovim.

local H = require("helpers")

describe("ghostty palette", function()
  local P

  before_each(function()
    P = H.reload("ghostty.palette")
  end)

  it("keeps Ghostty's own background and foreground", function()
    assert.equals("#282c34", P.bg)
    assert.equals("#c5c8c6", P.fg)
  end)

  it("lists the sixteen ANSI colours in palette order", function()
    assert.equals(16, #P.ansi)
    assert.equals(P.black, P.ansi[1])
    assert.equals(P.red, P.ansi[2])
    assert.equals(P.white, P.ansi[8])
    assert.equals(P.bright_white, P.ansi[16])
  end)

  it("writes every colour as a six-digit hex string", function()
    for name, value in pairs(P) do
      if type(value) == "string" then
        assert.is_truthy(value:match("^#%x%x%x%x%x%x$"), name .. " is " .. value)
      end
    end
  end)
end)

describe("ghostty colourscheme", function()
  local ghostty, P

  before_each(function()
    P = H.reload("ghostty.palette")
    ghostty = H.reload("ghostty")
  end)

  it("lets the terminal through by default, so the backgrounds cannot differ", function()
    assert.is_true(ghostty.transparent())
    assert.equals("NONE", ghostty.groups(true).Normal.bg)
  end)

  it("paints Ghostty's background when you ask for one", function()
    assert.equals(P.bg, ghostty.groups(false).Normal.bg)
  end)

  it("obeys vim.g.ghostty_transparent", function()
    local saved = vim.g.ghostty_transparent
    vim.g.ghostty_transparent = false
    assert.is_false(ghostty.transparent())
    vim.g.ghostty_transparent = saved
  end)

  it("defines the groups a plugin here expects", function()
    local groups = ghostty.groups()
    for _, name in ipairs({
      "Normal", "Comment", "String", "Function", "Keyword", "Type",
      "CursorLine", "Visual", "Search", "Pmenu", "NormalFloat", "FloatBorder",
      "DiagnosticError", "DiagnosticWarn", "DiagnosticInfo", "DiagnosticHint",
      "DiagnosticOk", "DiffAdd", "DiffChange", "GitSignsAdd",
      "TelescopeSelection", "NeoTreeNormal", "BlinkCmpMenuSelection",
      "WhichKeyGroup", "IblIndent", "Title", "@variable", "@function",
    }) do
      assert.is_truthy(groups[name], "missing group: " .. name)
    end
  end)

  it("uses only palette colours, never a stray hex", function()
    local known = {}
    for _, value in pairs(P) do
      if type(value) == "string" then known[value:lower()] = true end
    end
    -- The diff and indent shades are the documented exceptions.
    for _, extra in ipairs({
      "#2c3a2e", "#2f3742", "#3a2c2e", "#3d4a5c", "#3a4c3c", "#4c3a3c", "#343841",
    }) do
      known[extra] = true
    end

    for name, spec in pairs(ghostty.groups(false)) do
      for _, key in ipairs({ "fg", "bg", "sp" }) do
        local value = spec[key]
        if type(value) == "string" and value ~= "NONE" then
          assert.is_true(known[value:lower()], name .. "." .. key .. " is " .. value)
        end
      end
    end
  end)

  it("points every link at a group it also defines", function()
    local groups = ghostty.groups()
    for name, spec in pairs(groups) do
      if spec.link then
        assert.is_truthy(groups[spec.link], name .. " links to missing " .. spec.link)
      end
    end
  end)

  it("loads without an error and names itself", function()
    vim.cmd("colorscheme ghostty")
    assert.equals("ghostty", vim.g.colors_name)
  end)

  it("gives the built-in terminal the same sixteen colours", function()
    vim.cmd("colorscheme ghostty")
    assert.equals(P.black, vim.g.terminal_color_0)
    assert.equals(P.red, vim.g.terminal_color_1)
    assert.equals(P.bright_white, vim.g.terminal_color_15)
  end)

  it("really applies the groups, not just the table", function()
    vim.cmd("colorscheme ghostty")
    local comment = vim.api.nvim_get_hl(0, { name = "Comment" })
    assert.equals(tonumber(P.comment:sub(2), 16), comment.fg)
    assert.is_true(comment.italic)
  end)
end)
