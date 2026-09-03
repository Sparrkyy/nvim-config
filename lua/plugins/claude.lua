-- Claude Code, in the Telescope agent manager.
-- The plugin speaks the same websocket protocol as the official IDE extensions.
-- It gives Claude your open file, your visual selection, and your diagnostics,
-- and it opens Claude's edits as native Neovim diffs that you accept or reject.
return {
  {
    "coder/claudecode.nvim",
    dependencies = { "folke/snacks.nvim" },
    cmd = {
      "ClaudeCode", "ClaudeCodeFocus", "ClaudeCodeSelectModel",
      "ClaudeCodeAdd", "ClaudeCodeSend", "ClaudeCodeTreeAdd",
      "ClaudeCodeStatus", "ClaudeCodeStart", "ClaudeCodeStop",
      "ClaudeCodeOpen", "ClaudeCodeClose",
      "ClaudeCodeDiffAccept", "ClaudeCodeDiffDeny", "ClaudeCodeCloseAllDiffs",
    },
    opts = {
      auto_start = true,
      -- Resolve the CLI path so nvim finds it even with a minimal PATH.
      terminal_cmd = vim.fn.exepath("claude") ~= "" and vim.fn.exepath("claude") or nil,
      track_selection = true,
      focus_after_send = false,
      terminal = {
        provider = "none",
      },
      diff_opts = {
        layout = "vertical",
        open_in_new_tab = false,
        auto_resize_terminal = false,
      },
    },
    keys = {
      { "<leader>a", nil, desc = "AI / Claude Code" },
      { "<leader>ac", function() require("claude.sessions").show_manager() end, desc = "Open Claude manager" },
      { "<leader>af", function() require("claude.sessions").show_manager() end, desc = "Focus Claude manager" },
      { "<leader>ar", function() require("claude.sessions").resume_session() end, desc = "Resume in Claude manager" },
      { "<leader>aC", function() require("claude.sessions").continue_session() end, desc = "Continue in Claude manager" },
      { "<leader>am", "<cmd>ClaudeCodeSelectModel<cr>", desc = "Select model" },
      { "<leader>ab", "<cmd>ClaudeCodeAdd %<cr>", desc = "Add current buffer" },
      { "<leader>as", function() require("claude.follow").send_selection() end, mode = "v", desc = "Send selection" },
      {
        "<leader>as",
        "<cmd>ClaudeCodeTreeAdd<cr>",
        desc = "Add file from tree",
        ft = { "neo-tree", "NvimTree", "oil", "minifiles", "netrw", "snacks_picker_list" },
      },
      -- Diff review. These work in the diff buffers Claude opens.
      { "<leader>aa", function() require("claude.follow").accept() end, desc = "Accept diff" },
      { "<leader>ad", function() require("claude.follow").reject() end, desc = "Reject diff" },
      { "<leader>ax", "<cmd>ClaudeCodeCloseAllDiffs<cr>", desc = "Close all diffs" },
      { "<leader>a?", "<cmd>ClaudeCodeStatus<cr>", desc = "Connection status" },

      -- Working alongside the agent.
      { "<leader>ai", function() require("claude.sessions").new_terminal_session() end, desc = "New persistent Claude session" },
      {
        "<leader>aI",
        function()
          local sessions = require("claude.sessions")
          sessions.new_terminal_session({ default_text = sessions.context_reference() })
        end,
        desc = "New persistent Claude session with context",
      },
      {
        "<leader>ai",
        function()
          local sessions = require("claude.sessions")
          sessions.new_terminal_session({ default_text = sessions.selection_reference() })
        end,
        mode = "v",
        desc = "New persistent Claude session with selection",
      },
      { "<leader>ak", function() require("claude.sessions").interrupt() end, desc = "Interrupt managed Claude" },
      { "<leader>ap", function() require("claude.sessions").plan_session() end, desc = "Start pinned Claude plan session" },
      { "<leader>aF", function() require("claude.follow").toggle() end, desc = "Toggle follow mode" },
      { "<leader>aj", function() require("claude.follow").next() end, desc = "Next queued jump" },
      { "<leader>aJ", function() require("claude.follow").clear_queue() end, desc = "Drop queued jumps" },
      { "<leader>aw", function() require("claude.follow").set_pace() end, desc = "Set follow pace" },
      { "<leader>ae", function() require("claude.fixit").fix() end, desc = "Fix the error under the cursor" },
      { "<leader>aE", function() require("claude.fixit").fix_all() end, desc = "Fix every error in this file" },
      { "<leader>ao", function() require("claude.ask").ask() end, desc = "One-off request" },
      { "<leader>ao", function() require("claude.ask").ask_selection() end, mode = "v", desc = "One-off request on the selection" },
      { "<leader>aO", function() require("claude.hud").close() end, desc = "Close the progress window" },
      { "<leader>al", function() require("claude.sessions").toggle() end, desc = "Manage Claude agents" },
      { "<leader>ah", function() require("claude.follow").toggle_marks() end, desc = "Toggle change highlights" },
      { "<leader>aH", function() require("claude.follow").clear_marks() end, desc = "Clear change highlights" },

      -- Panels and controls.
      { "<leader>at", function() require("claude.panel").toggle_plan() end, desc = "Toggle plan panel" },
      { "<leader>an", function() require("claude.panel").toggle_notes() end, desc = "Toggle notes panel" },
      { "<leader>aq", "<cmd>copen<cr>", desc = "Claude failures (quickfix)" },
      { "<leader>aP", function()
          local f = require("claude.follow")
          f.permission_enabled = not f.permission_enabled
          vim.notify("Permission prompts in Neovim " .. (f.permission_enabled and "on" or "off"),
            vim.log.levels.INFO, { title = "Claude Code" })
        end, desc = "Toggle in-editor permissions" },
    },
  },

  -- snacks.nvim supplies the terminal window and the model picker.
  {
    "folke/snacks.nvim",
    priority = 1000,
    lazy = false,
    opts = {
      bigfile = { enabled = true },
      quickfile = { enabled = true },
      input = { enabled = true },
      notifier = { enabled = true, timeout = 2500 },
      terminal = { enabled = true },
    },
  },
}
