return {
  {
    "lewis6991/gitsigns.nvim",
    event = { "BufReadPre", "BufNewFile" },
    opts = {
      signs = {
        add = { text = "▎" },
        change = { text = "▎" },
        delete = { text = "" },
        topdelete = { text = "" },
        changedelete = { text = "▎" },
      },
      on_attach = function(bufnr)
        local gs = require("gitsigns")
        local function map(mode, lhs, rhs, desc)
          vim.keymap.set(mode, lhs, rhs, { buffer = bufnr, desc = desc })
        end

        map("n", "]c", function() gs.nav_hunk("next") end, "Next hunk")
        map("n", "[c", function() gs.nav_hunk("prev") end, "Previous hunk")
        map("n", "<leader>gs", gs.stage_hunk, "Stage hunk")
        map("n", "<leader>gr", gs.reset_hunk, "Reset hunk")
        map("v", "<leader>gs", function() gs.stage_hunk({ vim.fn.line("."), vim.fn.line("v") }) end, "Stage selection")
        map("v", "<leader>gr", function() gs.reset_hunk({ vim.fn.line("."), vim.fn.line("v") }) end, "Reset selection")
        map("n", "<leader>gp", gs.preview_hunk, "Preview hunk")
        map("n", "<leader>gb", function() gs.blame_line({ full = true }) end, "Blame line")
        map("n", "<leader>gd", gs.diffthis, "Diff this file")
      end,
    },
  },

  {
    "sindrets/diffview.nvim",
    cmd = { "DiffviewOpen", "DiffviewClose", "DiffviewFileHistory" },
    keys = {
      { "<leader>gv", "<cmd>DiffviewOpen<cr>", desc = "Open diff view" },
      { "<leader>gh", "<cmd>DiffviewFileHistory %<cr>", desc = "File history" },
    },
    opts = {
      enhanced_diff_hl = true,
      show_help_hints = false,
      view = {
        default = {
          layout = "diff2_horizontal",
          disable_diagnostics = false,
          winbar_info = false,
        },
      },
      file_panel = {
        listing_style = "tree",
        tree_options = {
          flatten_dirs = true,
          folder_statuses = "only_folded",
        },
        win_config = {
          position = "left",
          width = 32,
          win_opts = {
            cursorline = true,
            number = false,
            relativenumber = false,
            signcolumn = "no",
            winhighlight = "Normal:NormalFloat,WinSeparator:FlowBorder",
          },
        },
      },
    },
  },
}
