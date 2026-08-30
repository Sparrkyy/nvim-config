# Neovim configuration

A Cursor-style setup: native LSP, treesitter, telescope, and Claude Code in a
side split with diff review.

## Layout

    init.lua
    colors/        the colourscheme entry point
    lua/config/    options, keymaps, autocmds, lazy.nvim bootstrap, sync
    lua/ghostty/   the colourscheme: palette and highlight groups
    lua/plugins/   one file per area
    lua/claude/    follow mode, panels, prompt context
    tests/         the test suite

The leader key is `<space>`.

## Claude Code

Claude runs in a terminal split on the right. The plugin speaks the same
websocket protocol as the official VS Code extension. Claude sees your open
file, your cursor, and your visual selection. Claude's edits open as native
Neovim diffs.

| Key          | Action                          |
| ------------ | ------------------------------- |
| `<leader>ac` | Toggle the Claude split         |
| `<leader>af` | Focus the Claude split          |
| `<leader>ar` | Resume a previous session       |
| `<leader>aC` | Continue the last session       |
| `<leader>am` | Select the model                |
| `<leader>ab` | Add the current buffer          |
| `<leader>as` | Send the selection (visual)     |
| `<leader>as` | Add the file (in the file tree) |
| `<leader>aa` | Accept the diff                 |
| `<leader>ad` | Reject the diff                 |
| `<leader>ax` | Close all diffs                 |
| `<leader>a?` | Show the connection status      |

## Working alongside the agent

Claude runs in the right-hand split. You keep the left side.

| Key          | Action                                      |
| ------------ | ------------------------------------------- |
| `<leader>ai` | Prompt Claude from anywhere (no focus loss) |
| `<leader>ai` | Prompt about the selection (visual)         |
| `<leader>aI` | Prompt with the current file and line       |
| `<leader>ak` | Interrupt Claude mid-task                   |
| `<leader>ap` | Start Claude in plan mode                   |
| `<leader>aF` | Toggle follow mode                          |

### Follow mode

Claude Code hooks call back into this Neovim over its RPC socket. As Claude
reads and edits files, the main window follows: it opens the file and centres
on the line Claude is working on. A notification tells you when Claude
finishes or needs you. There is no status line, so the job window in the top
right is where you watch the work.

Follow mode never takes focus. It stays quiet while you are in insert mode and
while a diff is under review.

The Lua side is `lua/claude/follow.lua`. The hook script is
`~/.claude/hooks/nvim-follow.sh`. Each Neovim instance registers its RPC
address under `~/.cache/nvim/claude-follow/<cwd-hash>/<pid>.server`, so several
editors can share one project.

To debug, run Claude with `CLAUDE_NVIM_FOLLOW_DEBUG=1`. Every hook invocation
is then appended to `$TMPDIR/nvim-follow.log`.

### Reviewing every change

Claude's edits arrive as a vertical diff: the file on the left, Claude's
version on the right. The right-hand buffer is **editable**. You can correct
Claude's change before you take it.

1. Read the diff. Use `]c` and `[c` to move between hunks.
2. Edit the right side if you want something different.
3. Accept with `<leader>aa`, or with `:w` in the right-hand buffer.
4. Reject with `<leader>ad`, or with `:q` on the right-hand window.
5. To redirect instead, press `<leader>ak` and give a new instruction.

`<leader>aa` and `<leader>ad` find the proposed buffer and focus it first, so
they work from any window. `:w` and `:q` only apply in the proposed buffer.
Claude waits while the diff is open, and gets your accepted text, edits included.

Stay in the default permission mode. In `acceptEdits` or bypass mode Claude
applies edits without asking, so no diff reaches you.

### One-shot sessions

Two shortcuts run a short headless Claude session on the file in front of you.
Both are separate from the Claude in your split, so your main conversation
never sees them.

| Key | Action |
| --- | ------ |
| `<leader>ao` | A one-off request. Type an instruction. |
| `<leader>ao` (visual) | The same, about the selected lines. |
| `<leader>ae` | Fix the diagnostic under the cursor |
| `<leader>aE` | Fix every diagnostic in this file, in one session |
| `<leader>aO` | Close the progress window |

`<leader>ao` asks you for an instruction, then sends it with the file name, the
cursor line, and 40 lines of code either side. Use it for the small jobs:
rename this, extract that, add the types, write the doc comment. In visual mode
it sends the selected range instead.

The instruction goes into a composer that **wraps**, and grows downward as you
type. A long request stays on screen instead of running off the side.

| Key | In the composer |
| --- | --------------- |
| `<CR>` | Send |
| `<S-CR>`, `<C-j>` | A new line |
| `<Esc>`, `<C-c>` | Cancel |

It caps at 84 columns and 12 rows. Change that in `M.opts` in
`lua/claude/input.lua`.

`<leader>ae` needs no typing. It picks the diagnostic under the cursor, or the
nearest one, preferring the most severe on the line.

**You watch the work.** A window in the top right lists every running session:

    ╭───────────────── Claude ×2 ─────────────────╮
    │ ⠸ rename the type to Bean               12s │
    │ │ Edit · src/BeanList.tsx                   │
    │ │ The import needs the type keyword.        │
    │                                             │
    │ ✓ Fix line 2                             4s │
    │ │ Read · types.ts                           │
    │ │ Made it a type-only import.               │
    ╰─────────────────────────────────────────────╯

Each job hangs off a bar in its own colour: blue while it runs, green when it
finishes, red when it fails. The border counts the sessions that are up. The
elapsed time sits flush right. A finished job keeps its one-line summary for
five seconds, then leaves the list.

The colours are ordinary highlight groups, each linked to something your
colourscheme already defines. Override any of them:

```lua
vim.api.nvim_set_hl(0, "ClaudeHudRun", { fg = "#7aa2f7" })
```

`ClaudeHudRun`, `ClaudeHudOk`, `ClaudeHudFail`, `ClaudeHudName`,
`ClaudeHudTime`, `ClaudeHudTool`, `ClaudeHudDetail`, `ClaudeHudText`,
`ClaudeHudBorder`, `ClaudeHudTitle`.

**Several can run at once.** Start a rename, then start a fix while it runs.
Each gets its own line in the window. Four is the cap; past that the fifth is
refused rather than queued. When the list is too long to fit, the newest stay
on screen and the rest become a `+N more` count.

When a session ends, the buffer reloads and the changed lines get the same
highlight as any other Claude edit. The notification names the job, so you can
tell which of several sessions changed what.

Each session runs with `--model sonnet`, a small tool list (`Read` and `Edit`
for a fix), `--no-session-persistence`, and `CLAUDE_NVIM_FOLLOW_DISABLE=1`, so
its own hooks never drive your editor. The settings live in `M.opts` in
`lua/claude/oneshot.lua`, and the window's in `lua/claude/hud.lua`.

## What Claude sends and shows

| Hook event | Effect in Neovim |
| ---------- | ---------------- |
| `UserPromptSubmit` | Your editor state rides along with every prompt |
| `PreToolUse` | The main window follows the file Claude touches |
| `PostToolUseFailure` | The failure lands in the quickfix list |
| `TaskCreated` / `TaskCompleted` | The plan panel ticks off |
| `SubagentStart` / `SubagentStop` | Running subagents show in the job window |
| `MessageDisplay` | Claude's prose collects in the notes panel |
| `PermissionRequest` | You approve or deny inside the editor |
| `Stop` | The project check runs; failures send Claude back to work |

| Key          | Panel                     |
| ------------ | ------------------------- |
| `<leader>at` | Plan panel                |
| `<leader>an` | Notes panel               |
| `<leader>aq` | Quickfix of failures      |
| `<leader>aP` | Toggle in-editor approval |

### Editor context on every prompt

Each prompt carries your cursor file and line, the lines on screen, your open
buffers, which of them are unsaved, the diagnostics in the current file, and
the git branch. You no longer have to say what you are looking at.

### Approving in the editor

`PermissionRequest` opens a prompt in Neovim: allow, deny, or defer to the
terminal. Anything unclear defers, so you never get stuck. `<leader>aP` turns
this off.

### Keep going until green

The `Stop` hook runs `.claude/check.sh` in the project root. A non-zero exit
sends the output back to Claude and refuses to end the turn. Guards: it never
runs twice in one turn, it stops after three attempts, and it is inert unless
that file exists and is executable. Delete the file to switch it off.

For this project the check runs `tsc --noEmit` over the backend and frontend.

## Find

| Key          | Action                    |
| ------------ | ------------------------- |
| `<C-p>`      | Find files                |
| `<leader>fg` | Live grep                 |
| `<leader>fb` | Buffers                   |
| `<leader>fr` | Recent files              |
| `<leader>fw` | Grep the word under cursor|
| `<leader>fd` | Diagnostics               |
| `<leader>fk` | Keymaps                   |

## Code

| Key          | Action              |
| ------------ | ------------------- |
| `gd`         | Definition          |
| `gy`         | Type definition     |
| `gi`         | Implementation      |
| `gr`         | References          |
| `K`          | Hover documentation |
| `<leader>rn` | Rename symbol       |
| `<leader>ca` | Code action         |
| `<leader>f`  | Format              |
| `[g` / `]g`  | Previous / next diagnostic |
| `<leader>uh` | Toggle inlay hints  |

## Colours

The colourscheme is local to this repository: `colors/ghostty.lua`, with the
palette in `lua/ghostty/palette.lua` and the groups in `lua/ghostty/init.lua`.
No plugin draws it.

It takes its sixteen ANSI colours and its background from Ghostty's own
defaults, so Neovim and the shell beside it agree on what red is. The window
paints no background at all, so Ghostty's background shows through and the two
can never drift apart.

    vim.g.ghostty_transparent = false   -- paint #282c34 instead

Set that before the colourscheme loads. Use it if you run Ghostty with a
background image or with an opacity below 1.

If you change `theme` or `palette` in the Ghostty config, copy the new values
into `lua/ghostty/palette.lua`. `:Reload` picks up a colour edit at once.

## Git

`<leader>gs` stage hunk, `<leader>gr` reset hunk, `<leader>gp` preview hunk,
`<leader>gb` blame line, `<leader>gv` diff view, `[c` / `]c` move between hunks.

## Files

`<leader>t` toggles the file tree. `<leader>T` reveals the current file.

`J` walks back through the buffers you visited. `K` walks forward. The list
works like alt-tab: a normal visit puts the buffer on top, and a walk only
moves the cursor through the list.

### The session

Each directory keeps its own session. Start `nvim` there with no file
argument, and it reopens the buffer stack you left, on the line you left. `J`
and `K` walk that restored list at once.

Neovim writes the session on exit to
`~/.local/state/nvim/sessions/<slug>_<hash>.json`. A file that no longer
exists drops out. Delete the JSON file to start that directory clean. A file
argument, a directory argument, or piped input skips the restore.

The code is `lua/config/session.lua` and `lua/config/bufstack.lua`.

## Tests

Run `tests/run.sh` before you commit. It runs 376 tests in about two minutes.

    tests/run.sh              everything
    tests/run.sh lua          the Neovim specs only
    tests/run.sh hook         the hook script tests only

Nothing in the suite starts Claude, reaches the network, or spends a token.
The Claude terminal, the hook script, and the RPC calls are all mocked.

**Add a test with every change.** `tests/README.md` explains the layout, the
mocks, and how to write a new spec.

## Reloading

`:Reload`, or `<leader>R`, re-reads the configuration without a restart. It
drops every `config.*` and `claude.*` module and re-runs them in the order
`init.lua` uses.

It does **not** reload plugin options. lazy.nvim hands a plugin its `opts` once,
when the plugin loads, so a change to a `lua/plugins/*.lua` spec needs a
restart. The same goes for a new `keys` entry: reloading updates the function a
key calls, not the list of keys.

| Change | `:Reload` picks it up? |
| ------ | ---------------------- |
| `lua/claude/*.lua` | Yes |
| `lua/config/options.lua`, `keymaps.lua`, `autocmds.lua` | Yes |
| `lua/ghostty/*.lua`, the colours | Yes |
| A plugin's `opts`, or a new `keys` entry | No, restart |

A module with a syntax error is named in the message, and the rest still load.

## Two machines

This configuration is a private GitHub repository:
[Sparrkyy/nvim-config](https://github.com/Sparrkyy/nvim-config). It runs on the
personal machine and the work machine, and each one pulls the other's commits.

### Set up the second machine

    gh auth login
    mv ~/.config/nvim ~/.config/nvim.before
    git clone https://github.com/Sparrkyy/nvim-config.git ~/.config/nvim
    nvim

lazy.nvim installs the plugins on the first start. `lazy-lock.json` is in the
repository, so both machines run the same plugin versions.

### Staying in step

Neovim checks GitHub two seconds after startup. The fetch runs in the
background and nothing blocks. If the branch holds commits you do not have, a
notification says how many.

| Command | Action |
| ------- | ------ |
| `:ConfigUpdate`, `<leader>u` | Fast-forward to the GitHub branch |
| `:ConfigCheck` | Ask GitHub now, and report either way |

The pull is never automatic. A broken commit from the other machine would
break the editor you are sitting in, so you choose the moment.

`:ConfigUpdate` refuses to run over uncommitted changes, and it only
fast-forwards. Diverged history is yours to sort out with git. After a pull,
`:Reload` picks up the module changes; a plugin change needs a restart.

The startup check is silent when it fails. No network and no remote both leave
you with a working editor and no message. Use `:ConfigCheck` to see the reason.

### Pushing your changes

    cd ~/.config/nvim
    tests/run.sh
    git add -A && git commit -m "..." && git push

The code is `lua/config/update.lua`, and its spec is
`tests/spec/update_spec.lua`.

## Maintenance

- `:Lazy` manages plugins. `:Mason` manages language servers.
- `:checkhealth` reports problems.
- The previous `init.vim` is in the first commit, as
  `init.vim.bak.20260827`. Run `git show 0ac287c:init.vim.bak.20260827`.
