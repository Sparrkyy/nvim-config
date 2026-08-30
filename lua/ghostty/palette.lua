-- The Ghostty terminal palette, copied from `ghostty +show-config --default`.
--
-- Keep the sixteen ANSI colours and the two base colours exactly as Ghostty
-- reports them. Neovim then draws the same red as the shell prompt beside it.
-- If you set your own `theme` or `palette` in the Ghostty config, change the
-- values here to match, and the two stay in step.
--
-- The `shade` table below is derived, not copied. Ghostty has no colour for a
-- cursor line or a popup, so those come from the background.

local P = {}

-- What Ghostty calls background and foreground.
P.bg = "#282c34"
P.fg = "#c5c8c6" -- palette 7. Ghostty's own #ffffff is too hard for prose.

-- The sixteen ANSI colours, in palette order.
P.black = "#1d1f21"
P.red = "#cc6666"
P.green = "#b5bd68"
P.yellow = "#f0c674"
P.blue = "#81a2be"
P.magenta = "#b294bb"
P.cyan = "#8abeb7"
P.white = "#c5c8c6"

P.bright_black = "#666666"
P.bright_red = "#d54e53"
P.bright_green = "#b9ca4a"
P.bright_yellow = "#e7c547"
P.bright_blue = "#7aa6da"
P.bright_magenta = "#c397d8"
P.bright_cyan = "#70c0b1"
P.bright_white = "#eaeaea"

-- Derived greys. Each one is the background with the lightness moved, so the
-- whole editor stays on one colour axis.
P.bg_dark = "#22252b" -- the file tree and other side panes
P.bg_float = "#2f333c" -- popups, floats, the completion menu
P.bg_line = "#2e323a" -- the cursor line
P.bg_sel = "#3b414c" -- the visual selection
P.bg_hint = "#343943" -- a matching bracket, a search hit under the cursor

P.fg_dim = "#9a9ea6" -- a label you read second
P.comment = "#767b85" -- palette 8, lifted until it reads on the background
P.border = "#454a55" -- window separators and float borders

-- The ANSI list, in order, for `vim.g.terminal_color_*`.
P.ansi = {
  P.black, P.red, P.green, P.yellow,
  P.blue, P.magenta, P.cyan, P.white,
  P.bright_black, P.bright_red, P.bright_green, P.bright_yellow,
  P.bright_blue, P.bright_magenta, P.bright_cyan, P.bright_white,
}

return P
