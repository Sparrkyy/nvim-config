-- Completion. Tab and Enter accept, Ctrl-n and Ctrl-p cycle, Ctrl-Space triggers.
-- These are the same keys the old coc.nvim setup used.
return {
  {
    "saghen/blink.cmp",
    event = "InsertEnter",
    version = "*",
    opts = {
      keymap = {
        preset = "enter",
        ["<Tab>"] = { "select_and_accept", "snippet_forward", "fallback" },
        ["<S-Tab>"] = { "select_prev", "snippet_backward", "fallback" },
        ["<C-space>"] = { "show", "show_documentation", "hide_documentation" },
        ["<C-f>"] = { "scroll_documentation_down", "fallback" },
        ["<C-b>"] = { "scroll_documentation_up", "fallback" },
      },
      appearance = { nerd_font_variant = "mono" },
      completion = {
        list = { selection = { preselect = false, auto_insert = true } },
        documentation = { auto_show = true, auto_show_delay_ms = 200 },
        ghost_text = { enabled = true },
      },
      signature = { enabled = true },
      sources = { default = { "lsp", "path" } },
      fuzzy = { implementation = "prefer_rust_with_warning" },
    },
    opts_extend = { "sources.default" },
  },

  -- Auto-close pairs. This replaces pear-tree.
  {
    "windwp/nvim-autopairs",
    event = "InsertEnter",
    opts = {},
  },
}
