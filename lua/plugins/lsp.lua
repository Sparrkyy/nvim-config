-- Native LSP. This replaces coc.nvim.
return {
  {
    "mason-org/mason.nvim",
    cmd = { "Mason", "MasonUpdate", "MasonInstall", "MasonUninstall", "MasonLog" },
    opts = { ui = { border = "rounded" } },
  },

  {
    "neovim/nvim-lspconfig",
    event = { "BufReadPre", "BufNewFile" },
    dependencies = {
      "mason-org/mason.nvim",
      "mason-org/mason-lspconfig.nvim",
    },
    config = function()
      -- Give every server the completion capabilities of blink.cmp.
      local ok, blink = pcall(require, "blink.cmp")
      if ok then
        vim.lsp.config("*", { capabilities = blink.get_lsp_capabilities({}, false) })
      end

      -- Per-server settings. mason-lspconfig enables each installed server.
      vim.lsp.config("lua_ls", {
        settings = {
          Lua = {
            runtime = { version = "LuaJIT" },
            workspace = { checkThirdParty = false, library = vim.api.nvim_get_runtime_file("", true) },
            diagnostics = { globals = { "vim" } },
            telemetry = { enable = false },
          },
        },
      })

      vim.lsp.config("ts_ls", {
        settings = {
          typescript = {
            inlayHints = {
              includeInlayParameterNameHints = "literals",
              includeInlayFunctionLikeReturnTypeHints = true,
            },
          },
        },
      })

      require("mason-lspconfig").setup({
        ensure_installed = {
          "lua_ls", "ts_ls", "eslint", "jsonls",
          "html", "cssls", "bashls", "yamlls",
          "csharp_ls",
        },
        automatic_enable = {
          exclude = { "omnisharp" },
        },
      })

      -- Buffer-local keys. gd/gy/gi/gr/K match the old coc.nvim bindings.
      vim.api.nvim_create_autocmd("LspAttach", {
        group = vim.api.nvim_create_augroup("EthanLspAttach", { clear = true }),
        callback = function(ev)
          local function map(mode, lhs, rhs, desc)
            vim.keymap.set(mode, lhs, rhs, { buffer = ev.buf, desc = desc })
          end

          map("n", "gd", vim.lsp.buf.definition, "Go to definition")
          map("n", "gy", vim.lsp.buf.type_definition, "Go to type definition")
          map("n", "gi", vim.lsp.buf.implementation, "Go to implementation")
          map("n", "gD", vim.lsp.buf.declaration, "Go to declaration")
          map("n", "gr", function() require("telescope.builtin").lsp_references() end, "References")
          map("n", "gh", function() vim.lsp.buf.hover({ border = "rounded" }) end, "Hover docs")
          map("i", "<C-k>", function() vim.lsp.buf.signature_help({ border = "rounded" }) end, "Signature help")
          map("n", "<leader>rn", vim.lsp.buf.rename, "Rename symbol")
          map({ "n", "v" }, "<leader>ca", vim.lsp.buf.code_action, "Code action")
          map("n", "<leader>o", function() require("telescope.builtin").lsp_document_symbols() end, "Document symbols")
          map("n", "<leader>S", function() require("telescope.builtin").lsp_dynamic_workspace_symbols() end, "Workspace symbols")

          local client = vim.lsp.get_client_by_id(ev.data.client_id)
          if client and client:supports_method("textDocument/inlayHint") then
            map("n", "<leader>uh", function()
              vim.lsp.inlay_hint.enable(not vim.lsp.inlay_hint.is_enabled({ bufnr = ev.buf }), { bufnr = ev.buf })
            end, "Toggle inlay hints")
          end
        end,
      })
    end,
  },

  -- Formatting on save.
  {
    "stevearc/conform.nvim",
    event = "BufWritePre",
    cmd = "ConformInfo",
    keys = {
      { "<leader>f", function() require("conform").format({ async = true, lsp_format = "fallback" }) end,
        mode = { "n", "v" }, desc = "Format buffer" },
    },
    opts = {
      formatters_by_ft = {
        lua = { "stylua" },
        javascript = { "prettierd", "prettier", stop_after_first = true },
        javascriptreact = { "prettierd", "prettier", stop_after_first = true },
        typescript = { "prettierd", "prettier", stop_after_first = true },
        typescriptreact = { "prettierd", "prettier", stop_after_first = true },
        json = { "prettierd", "prettier", stop_after_first = true },
        yaml = { "prettierd", "prettier", stop_after_first = true },
        html = { "prettierd", "prettier", stop_after_first = true },
        css = { "prettierd", "prettier", stop_after_first = true },
        markdown = { "prettierd", "prettier", stop_after_first = true },
      },
      format_on_save = { timeout_ms = 1000, lsp_format = "fallback" },
    },
  },
}
