-- A colourscheme built from the Ghostty palette.
--
-- The point is that Neovim and the terminal around it look like one program.
-- `transparent` is on, so the window paints no background at all and Ghostty's
-- own background shows through. The two can then never drift apart, whatever
-- you set in the Ghostty config.
--
-- Set `vim.g.ghostty_transparent = false` before the colourscheme loads to
-- paint the background instead. Use that if you run Ghostty with an image or
-- with a background opacity below 1.

local P = require("ghostty.palette")

local M = {}

M.palette = P

--- True unless you asked for a painted background.
function M.transparent()
  return vim.g.ghostty_transparent ~= false
end

--- Every highlight group this colourscheme sets.
---@param transparent boolean|nil defaults to M.transparent()
---@return table<string, table>
function M.groups(transparent)
  if transparent == nil then transparent = M.transparent() end

  -- The window background. NONE lets Ghostty through.
  local bg = transparent and "NONE" or P.bg
  local bg_side = transparent and "NONE" or P.bg_dark

  return {
    ---- The editor ----------------------------------------------------------
    Normal = { fg = P.fg, bg = bg },
    NormalNC = { fg = P.fg, bg = bg },
    NormalFloat = { fg = P.fg, bg = P.bg_float },
    FloatBorder = { fg = P.border, bg = P.bg_float },
    FloatTitle = { fg = P.bright_yellow, bg = P.bg_float, bold = true },
    Cursor = { fg = P.bg, bg = P.fg },
    lCursor = { fg = P.bg, bg = P.fg },
    CursorLine = { bg = P.bg_line },
    CursorColumn = { bg = P.bg_line },
    ColorColumn = { bg = P.bg_line },
    Conceal = { fg = P.comment },
    Directory = { fg = P.blue },
    EndOfBuffer = { fg = bg == "NONE" and P.bg or bg },
    ErrorMsg = { fg = P.bright_red, bold = true },
    WarningMsg = { fg = P.yellow },
    MoreMsg = { fg = P.green },
    ModeMsg = { fg = P.fg, bold = true },
    MsgArea = { fg = P.fg_dim },
    LineNr = { fg = P.comment },
    CursorLineNr = { fg = P.bright_yellow, bold = true },
    SignColumn = { bg = bg },
    Folded = { fg = P.comment, bg = P.bg_line },
    FoldColumn = { fg = P.comment, bg = bg },
    MatchParen = { bg = P.bg_hint, bold = true },
    NonText = { fg = P.border },
    Whitespace = { fg = P.border },
    SpecialKey = { fg = P.border },
    Search = { fg = P.bg, bg = P.yellow },
    IncSearch = { fg = P.bg, bg = P.bright_yellow },
    CurSearch = { fg = P.bg, bg = P.bright_yellow },
    Substitute = { fg = P.bg, bg = P.bright_red },
    Visual = { bg = P.bg_sel },
    VisualNOS = { bg = P.bg_sel },
    Question = { fg = P.green },
    QuickFixLine = { bg = P.bg_line, bold = true },
    Title = { fg = P.bright_blue, bold = true },
    WinSeparator = { fg = P.border, bg = bg },
    VertSplit = { fg = P.border, bg = bg },

    StatusLine = { fg = P.fg_dim, bg = P.bg_float },
    StatusLineNC = { fg = P.comment, bg = P.bg_dark },
    TabLine = { fg = P.comment, bg = P.bg_dark },
    TabLineFill = { bg = bg_side },
    TabLineSel = { fg = P.fg, bg = P.bg_float, bold = true },
    WinBar = { fg = P.fg_dim, bg = bg },
    WinBarNC = { fg = P.comment, bg = bg },

    Pmenu = { fg = P.fg, bg = P.bg_float },
    PmenuSel = { fg = P.bg, bg = P.blue, bold = true },
    PmenuKind = { fg = P.magenta, bg = P.bg_float },
    PmenuKindSel = { fg = P.bg, bg = P.blue },
    PmenuExtra = { fg = P.comment, bg = P.bg_float },
    PmenuExtraSel = { fg = P.bg, bg = P.blue },
    PmenuSbar = { bg = P.bg_float },
    PmenuThumb = { bg = P.border },
    WildMenu = { fg = P.bg, bg = P.blue },

    ---- Syntax --------------------------------------------------------------
    Comment = { fg = P.comment, italic = true },
    Constant = { fg = P.bright_yellow },
    String = { fg = P.green },
    Character = { fg = P.green },
    Number = { fg = P.bright_yellow },
    Boolean = { fg = P.bright_yellow },
    Float = { fg = P.bright_yellow },

    Identifier = { fg = P.fg },
    Function = { fg = P.blue },

    Statement = { fg = P.magenta },
    Conditional = { fg = P.magenta },
    Repeat = { fg = P.magenta },
    Label = { fg = P.magenta },
    Operator = { fg = P.cyan },
    Keyword = { fg = P.magenta },
    Exception = { fg = P.magenta },

    PreProc = { fg = P.cyan },
    Include = { fg = P.magenta },
    Define = { fg = P.magenta },
    Macro = { fg = P.cyan },
    PreCondit = { fg = P.cyan },

    Type = { fg = P.yellow },
    StorageClass = { fg = P.magenta },
    Structure = { fg = P.yellow },
    Typedef = { fg = P.yellow },

    Special = { fg = P.cyan },
    SpecialChar = { fg = P.bright_red },
    Tag = { fg = P.red },
    Delimiter = { fg = P.fg_dim },
    SpecialComment = { fg = P.fg_dim, italic = true },
    Debug = { fg = P.bright_red },

    Underlined = { underline = true },
    Bold = { bold = true },
    Italic = { italic = true },
    Ignore = { fg = P.comment },
    Error = { fg = P.bright_red },
    Todo = { fg = P.bg, bg = P.yellow, bold = true },

    ---- Treesitter ----------------------------------------------------------
    ["@variable"] = { fg = P.fg },
    ["@variable.builtin"] = { fg = P.red },
    ["@variable.parameter"] = { fg = P.fg_dim },
    ["@variable.member"] = { fg = P.red },
    ["@constant"] = { fg = P.bright_yellow },
    ["@constant.builtin"] = { fg = P.bright_yellow },
    ["@module"] = { fg = P.yellow },
    ["@string"] = { fg = P.green },
    ["@string.escape"] = { fg = P.bright_red },
    ["@string.special.url"] = { fg = P.cyan, underline = true },
    ["@character"] = { fg = P.green },
    ["@boolean"] = { fg = P.bright_yellow },
    ["@number"] = { fg = P.bright_yellow },
    ["@function"] = { fg = P.blue },
    ["@function.builtin"] = { fg = P.bright_blue },
    ["@function.call"] = { fg = P.blue },
    ["@function.method"] = { fg = P.blue },
    ["@function.method.call"] = { fg = P.blue },
    ["@constructor"] = { fg = P.yellow },
    ["@operator"] = { fg = P.cyan },
    ["@keyword"] = { fg = P.magenta },
    ["@keyword.return"] = { fg = P.magenta },
    ["@keyword.import"] = { fg = P.magenta },
    ["@keyword.exception"] = { fg = P.magenta },
    ["@punctuation.delimiter"] = { fg = P.fg_dim },
    ["@punctuation.bracket"] = { fg = P.fg_dim },
    ["@punctuation.special"] = { fg = P.cyan },
    ["@comment"] = { fg = P.comment, italic = true },
    ["@comment.error"] = { fg = P.bg, bg = P.bright_red, bold = true },
    ["@comment.warning"] = { fg = P.bg, bg = P.yellow, bold = true },
    ["@comment.todo"] = { fg = P.bg, bg = P.cyan, bold = true },
    ["@comment.note"] = { fg = P.bg, bg = P.blue, bold = true },
    ["@type"] = { fg = P.yellow },
    ["@type.builtin"] = { fg = P.yellow },
    ["@attribute"] = { fg = P.cyan },
    ["@property"] = { fg = P.red },
    ["@label"] = { fg = P.magenta },
    ["@tag"] = { fg = P.red },
    ["@tag.attribute"] = { fg = P.yellow },
    ["@tag.delimiter"] = { fg = P.fg_dim },
    ["@markup.heading"] = { fg = P.bright_blue, bold = true },
    ["@markup.strong"] = { bold = true },
    ["@markup.italic"] = { italic = true },
    ["@markup.link"] = { fg = P.cyan },
    ["@markup.link.url"] = { fg = P.cyan, underline = true },
    ["@markup.raw"] = { fg = P.green },
    ["@markup.list"] = { fg = P.magenta },
    ["@diff.plus"] = { fg = P.green },
    ["@diff.minus"] = { fg = P.bright_red },

    ---- LSP -----------------------------------------------------------------
    ["@lsp.type.namespace"] = { link = "@module" },
    ["@lsp.type.type"] = { link = "@type" },
    ["@lsp.type.class"] = { link = "@type" },
    ["@lsp.type.enum"] = { link = "@type" },
    ["@lsp.type.interface"] = { link = "@type" },
    ["@lsp.type.parameter"] = { link = "@variable.parameter" },
    ["@lsp.type.variable"] = { link = "@variable" },
    ["@lsp.type.property"] = { link = "@property" },
    ["@lsp.type.function"] = { link = "@function" },
    ["@lsp.type.method"] = { link = "@function.method" },
    ["@lsp.type.decorator"] = { link = "@attribute" },
    ["@lsp.mod.readonly"] = { link = "@constant" },
    LspInlayHint = { fg = P.comment, bg = P.bg_line, italic = true },
    LspReferenceText = { bg = P.bg_hint },
    LspReferenceRead = { bg = P.bg_hint },
    LspReferenceWrite = { bg = P.bg_hint, underline = true },
    LspSignatureActiveParameter = { fg = P.bright_yellow, bold = true },
    LspCodeLens = { fg = P.comment, italic = true },

    ---- Diagnostics ---------------------------------------------------------
    DiagnosticError = { fg = P.bright_red },
    DiagnosticWarn = { fg = P.yellow },
    DiagnosticInfo = { fg = P.blue },
    DiagnosticHint = { fg = P.cyan },
    DiagnosticOk = { fg = P.green },
    DiagnosticVirtualTextError = { fg = P.bright_red, bg = P.bg_line },
    DiagnosticVirtualTextWarn = { fg = P.yellow, bg = P.bg_line },
    DiagnosticVirtualTextInfo = { fg = P.blue, bg = P.bg_line },
    DiagnosticVirtualTextHint = { fg = P.cyan, bg = P.bg_line },
    DiagnosticVirtualTextOk = { fg = P.green, bg = P.bg_line },
    DiagnosticUnderlineError = { sp = P.bright_red, undercurl = true },
    DiagnosticUnderlineWarn = { sp = P.yellow, undercurl = true },
    DiagnosticUnderlineInfo = { sp = P.blue, undercurl = true },
    DiagnosticUnderlineHint = { sp = P.cyan, undercurl = true },
    DiagnosticUnderlineOk = { sp = P.green, undercurl = true },
    DiagnosticUnnecessary = { fg = P.comment },
    DiagnosticDeprecated = { fg = P.comment, strikethrough = true },

    ---- Diffs and git -------------------------------------------------------
    DiffAdd = { bg = "#2c3a2e" },
    DiffChange = { bg = "#2f3742" },
    DiffDelete = { bg = "#3a2c2e" },
    DiffText = { bg = "#3d4a5c" },
    Added = { fg = P.green },
    Changed = { fg = P.blue },
    Removed = { fg = P.bright_red },
    GitSignsAdd = { fg = P.green },
    GitSignsChange = { fg = P.blue },
    GitSignsDelete = { fg = P.bright_red },
    GitSignsAddInline = { bg = "#3a4c3c" },
    GitSignsDeleteInline = { bg = "#4c3a3c" },

    ---- Telescope -----------------------------------------------------------
    TelescopeNormal = { fg = P.fg, bg = P.bg_float },
    TelescopeBorder = { fg = P.border, bg = P.bg_float },
    TelescopeTitle = { fg = P.bg, bg = P.blue, bold = true },
    TelescopePromptNormal = { fg = P.fg, bg = P.bg_sel },
    TelescopePromptBorder = { fg = P.bg_sel, bg = P.bg_sel },
    TelescopePromptTitle = { fg = P.bg, bg = P.magenta, bold = true },
    TelescopePromptPrefix = { fg = P.magenta },
    TelescopeSelection = { bg = P.bg_sel, bold = true },
    TelescopeSelectionCaret = { fg = P.magenta, bg = P.bg_sel },
    TelescopeMatching = { fg = P.bright_yellow, bold = true },
    TelescopeMultiSelection = { fg = P.cyan },

    ---- Neo-tree ------------------------------------------------------------
    NeoTreeNormal = { fg = P.fg_dim, bg = bg_side },
    NeoTreeNormalNC = { fg = P.fg_dim, bg = bg_side },
    NeoTreeWinSeparator = { fg = P.border, bg = bg_side },
    NeoTreeEndOfBuffer = { fg = P.bg_dark, bg = bg_side },
    NeoTreeRootName = { fg = P.bright_blue, bold = true },
    NeoTreeDirectoryName = { fg = P.blue },
    NeoTreeDirectoryIcon = { fg = P.blue },
    NeoTreeFileName = { fg = P.fg },
    NeoTreeFileNameOpened = { fg = P.bright_yellow },
    NeoTreeIndentMarker = { fg = P.border },
    NeoTreeGitAdded = { fg = P.green },
    NeoTreeGitModified = { fg = P.blue },
    NeoTreeGitDeleted = { fg = P.bright_red },
    NeoTreeGitIgnored = { fg = P.comment },
    NeoTreeGitUntracked = { fg = P.magenta },
    NeoTreeTitleBar = { fg = P.bg, bg = P.blue },

    ---- blink.cmp -----------------------------------------------------------
    BlinkCmpMenu = { fg = P.fg, bg = P.bg_float },
    BlinkCmpMenuBorder = { fg = P.border, bg = P.bg_float },
    BlinkCmpMenuSelection = { fg = P.bg, bg = P.blue, bold = true },
    BlinkCmpLabel = { fg = P.fg },
    BlinkCmpLabelMatch = { fg = P.bright_yellow, bold = true },
    BlinkCmpLabelDeprecated = { fg = P.comment, strikethrough = true },
    BlinkCmpKind = { fg = P.magenta },
    BlinkCmpSource = { fg = P.comment },
    BlinkCmpDoc = { fg = P.fg, bg = P.bg_float },
    BlinkCmpDocBorder = { fg = P.border, bg = P.bg_float },
    BlinkCmpSignatureHelp = { fg = P.fg, bg = P.bg_float },
    BlinkCmpSignatureHelpActiveParameter = { fg = P.bright_yellow, bold = true },

    ---- which-key -----------------------------------------------------------
    WhichKey = { fg = P.magenta },
    WhichKeyGroup = { fg = P.blue },
    WhichKeyDesc = { fg = P.fg },
    WhichKeySeparator = { fg = P.comment },
    WhichKeyFloat = { bg = P.bg_float },
    WhichKeyBorder = { fg = P.border, bg = P.bg_float },
    WhichKeyTitle = { fg = P.bright_blue, bold = true },

    ---- indent-blankline and todo-comments ----------------------------------
    IblIndent = { fg = "#343841" },
    IblScope = { fg = P.border },
    TodoBgTODO = { fg = P.bg, bg = P.blue, bold = true },
    TodoFgTODO = { fg = P.blue },
    TodoBgFIX = { fg = P.bg, bg = P.bright_red, bold = true },
    TodoFgFIX = { fg = P.bright_red },
    TodoBgNOTE = { fg = P.bg, bg = P.green, bold = true },
    TodoFgNOTE = { fg = P.green },
    TodoBgHACK = { fg = P.bg, bg = P.yellow, bold = true },
    TodoFgHACK = { fg = P.yellow },
    TodoBgWARN = { fg = P.bg, bg = P.yellow, bold = true },
    TodoFgWARN = { fg = P.yellow },
    TodoBgPERF = { fg = P.bg, bg = P.magenta, bold = true },
    TodoFgPERF = { fg = P.magenta },

    ---- The Claude windows --------------------------------------------------
    -- The modules link their own groups to these, so only the bases go here.
    ClaudeFollow = { fg = P.bright_yellow },
    ClaudeAdded = { bg = "#2c3a2e" },
    ClaudeAddedLabel = { fg = P.green, bg = "#2c3a2e", bold = true },
    ClaudeCodeDiffAccept = { fg = P.green, bold = true },
    ClaudeCodeDiffDeny = { fg = P.bright_red, bold = true },
  }
end

--- Apply the colourscheme.
function M.load(transparent)
  if vim.g.colors_name then
    vim.cmd("highlight clear")
  end
  if vim.fn.exists("syntax_on") == 1 then
    vim.cmd("syntax reset")
  end

  vim.o.background = "dark"
  vim.o.termguicolors = true
  vim.g.colors_name = "ghostty"

  for name, spec in pairs(M.groups(transparent)) do
    vim.api.nvim_set_hl(0, name, spec)
  end

  -- `:terminal` inside Neovim gets the same sixteen colours as Ghostty.
  for i, colour in ipairs(P.ansi) do
    vim.g["terminal_color_" .. (i - 1)] = colour
  end
end

return M
