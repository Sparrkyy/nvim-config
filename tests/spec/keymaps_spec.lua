-- The global keymaps. Visual J and K stay unmapped, so J joins the selection.

local H = require("helpers")

describe("keymaps", function()
  local function lhs_set(mode)
    local maps = {}
    for _, m in ipairs(vim.api.nvim_get_keymap(mode)) do
      maps[m.lhs] = m.desc or true
    end
    return maps
  end

  local function feed(keys)
    local codes = vim.api.nvim_replace_termcodes(keys, true, false, true)
    vim.api.nvim_feedkeys(codes, "mx", false)
  end

  before_each(function()
    H.reload("config.keymaps")
  end)

  it("leaves J and K free in visual mode", function()
    for _, mode in ipairs({ "v", "x" }) do
      local maps = lhs_set(mode)
      assert.is_nil(maps["J"])
      assert.is_nil(maps["K"])
    end
  end)

  it("joins the selected lines with J", function()
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "one", "two", "three" })

    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    vim.cmd("normal VjjJ")

    assert.same({ "one two three" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
  end)

  it("maps a comment toggle in visual and normal mode", function()
    for _, mode in ipairs({ "x", "n" }) do
      local maps = lhs_set(mode)
      assert.equals("Toggle comment", maps[" /"])
      assert.equals("Toggle comment", maps["<C-_>"])
    end
  end)

  it("comments and uncomments the selected lines", function()
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_set_current_buf(buf)
    vim.bo[buf].commentstring = "-- %s"
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "one", "two", "three" })

    local function toggle()
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      feed("Vj<Leader>/")
    end

    toggle()
    assert.same({ "-- one", "-- two", "three" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))

    toggle()
    assert.same({ "one", "two", "three" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
  end)
end)
