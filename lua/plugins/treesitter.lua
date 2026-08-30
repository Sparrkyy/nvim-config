-- Treesitter. Neovim 0.12 provides the engine; this plugin installs parsers and queries.
return {
  {
    "nvim-treesitter/nvim-treesitter",
    branch = "main",
    lazy = false,
    build = ":TSUpdate",
    config = function()
      require("nvim-treesitter").setup()

      local parsers = {
        "lua", "luadoc", "vim", "vimdoc", "query",
        "typescript", "tsx", "javascript", "jsdoc",
        "json", "yaml", "toml",
        "html", "css", "sql",
        "bash", "python", "dockerfile",
        "markdown", "markdown_inline", "diff", "gitcommit", "git_rebase",
      }

      local installed = require("nvim-treesitter.config").get_installed()
      local missing = vim.tbl_filter(function(p)
        return not vim.tbl_contains(installed, p)
      end, parsers)
      if #missing > 0 then
        require("nvim-treesitter").install(missing)
      end

      -- Start highlighting and indenting for any filetype with a parser.
      vim.api.nvim_create_autocmd("FileType", {
        group = vim.api.nvim_create_augroup("EthanTreesitter", { clear = true }),
        callback = function(args)
          local lang = vim.treesitter.language.get_lang(vim.bo[args.buf].filetype)
          if lang and pcall(vim.treesitter.start, args.buf, lang) then
            vim.bo[args.buf].indentexpr = "v:lua.require'nvim-treesitter'.indentexpr()"
          end
        end,
      })
    end,
  },
}
