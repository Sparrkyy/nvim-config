# Neovim configuration

A Cursor-style setup: native LSP, treesitter, telescope, and Claude Code in a
side split with diff review. Everything that is not a plugin is in here — the
colourscheme, the Claude Code bridge, the planning tool, and the tests.

## Install

    git clone https://github.com/Sparrkyy/nvim-config.git ~/.config/nvim
    cd ~/.config/nvim && ./install.sh
    nvim

`install.sh` points git at `.githooks`, links the Claude Code hook into
`~/.claude/hooks/`, and registers it in your `~/.claude/settings.json`. It backs
that file up first and only ever touches entries that name `nvim-follow.sh`.
Run `./install.sh --dry-run` to see what it would do, or `--uninstall` to take
it back out. lazy.nvim installs the plugins on the first `nvim`.

It works without `claude`, `jq`, or `node`; the install script tells you which
features stay quiet.

Already have a config? `mv ~/.config/nvim ~/.config/nvim.before` first.

## Layout

    init.lua
    install.sh     sets a machine up
    colors/        the colourscheme entry point
    claude/        the Claude Code hook, and how to register it
    lua/config/    options, keymaps, autocmds, lazy.nvim bootstrap, sync
    lua/ghostty/   the colourscheme: palette and highlight groups
    lua/plugins/   one file per area
    lua/claude/    follow mode, panels, prompt context
    lua/flow/      plan, implement in a worktree, review, and squash
    tests/         the test suite

The leader key is `<space>`. Nothing outside this repository is needed except
the plugins lazy.nvim fetches. `tmux` adds persistent interactive Claude
sessions; without it, the manager still works for the current Neovim process.

## Claude Code

Claude runs inside the Telescope agent manager. Each interactive process lives
in the private `tmux -L nvim-claude` server. A hidden Neovim terminal attaches
to it and mounts the real Claude TUI in the manager's preview, so no standalone
terminal split opens. Closing Neovim detaches that client without stopping
Claude. The plugin speaks the same websocket protocol as the official VS Code
extension. Claude sees your open file, cursor, and visual selection. Claude's
edits open as native Neovim diffs.

| Key          | Action                          |
| ------------ | ------------------------------- |
| `<leader>ac` | Open the Claude manager         |
| `<leader>af` | Focus the Claude manager        |
| `<leader>ar` | Resume inside the manager       |
| `<leader>aC` | Continue inside the manager     |
| `<leader>am` | Select the model                |
| `<leader>ab` | Add the current buffer          |
| `<leader>as` | Send the selection (visual)     |
| `<leader>as` | Add the file (in the file tree) |
| `<leader>aa` | Accept the diff                 |
| `<leader>ad` | Reject the diff                 |
| `<leader>ax` | Close all diffs                 |
| `<leader>a?` | Show the connection status      |

## Working alongside the agent

Claude stays in the manager instead of changing the editor's window layout.

| Key          | Action                                      |
| ------------ | ------------------------------------------- |
| `<leader>ai` | Start a session in the agent manager        |
| `<leader>ai` | Start with the selection (visual)           |
| `<leader>aI` | Start with the current file and line        |
| `<leader>ak` | Interrupt the latest managed Claude         |
| `<leader>ap` | Start managed Claude in plan mode           |
| `<leader>aF` | Toggle follow mode                          |

### Follow mode

Claude Code hooks call back into this Neovim over its RPC socket. As Claude
reads and edits files, the main window follows: it opens the file and centres
on the line Claude is working on. A notification tells you when Claude
finishes or needs you. There is no status line, so the job window in the top
right is where you watch the work.

Follow mode is off by default. Press `<leader>aF` when you want to watch Claude
work. It never takes focus, stays quiet while you are in insert mode or reviewing
a diff, and can be turned off again with the same key. Change hunks replay one at
a time with a one-second gap, including when the next hunk is in another file.

The Lua side is `lua/claude/follow.lua`. The hook script is
`claude/nvim-follow.sh` in this repository, which `install.sh` links into
`~/.claude/hooks/`. `claude/README.md` explains the bridge and lists every event
it listens for. Each Neovim instance registers its RPC address under
`~/.cache/nvim/claude-follow/<cwd-hash>/<pid>.server`, so several editors can
share one project.

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
| `<leader>al` | Open the Claude agent manager |

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

**You watch the work.** A window in the bottom right lists every running session:

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
five seconds, then leaves the small progress window. It remains in the session
list for one hour.

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

Each session inherits the model configured for the Claude CLI. A fix can read,
search, edit, and run Bash commands so it can diagnose and verify the change.

Press `<leader>al` to open the Telescope agent manager. It includes Flow
planning, AI diff reviews, one-shot work, diagnostic fixes, Flow
implementations, and Claude terminal buffers opened in Neovim. Running agents
stay at the top. Moving through the list updates a large live preview. Terminal
agents show their terminal screen; background agents show their input, tool
activity, streamed output, directory, and elapsed time. Finished and failed
scratch work stays available for one hour, then archives itself. Pinned work
does not expire.

Every preview follows the newest output instead of opening at line one.
Background-agent previews reduce the internal request to one line, keep only
recent activity, and give Claude's latest response the main reading area.

Press `<leader>ai` to create a new interactive Claude Code session without
opening a terminal split. The session starts inside the private tmux server and
the manager opens with its live terminal on the right. In visual mode, the
manager's message box starts with the selected file and line range. New and
continued interactive sessions start in `auto` permission mode; `<leader>ap`
is the explicit plan-mode exception and starts pinned. The manager stores resumable session
metadata under Neovim's state directory and rediscovers live tmux sessions when
Neovim restarts.

The Telescope prompt is the selected agent's message box. Type an instruction
and press `<CR>`. The text goes to that exact running Claude process, the prompt
clears, and the manager stays open so you can watch the response or move to
another agent.

| Key | In the agent manager |
| --- | -------------------- |
| `<C-j>`, `<C-k>` | Select the next or previous agent |
| `<CR>`, `<C-s>` | Send the prompt to the selected running agent |
| `<C-c>` | Interrupt the selected agent |
| `<C-t>`, `t` | Enter the selected agent's real Claude TUI |
| `<C-x>`, `x` | Stop the process and keep its resumable conversation |
| `p` | Pin or unpin long-term work |
| `r` | Rename the selected session |
| `<C-r>`, `R` | Reconnect a surviving process to this Neovim |
| `d` | Forget a stopped or completed entry |
| `<Esc>`, `q` | Close the manager |

Guidance reaches the selected running process through its terminal. Press
`<C-t>` when you want Claude Code's own keyboard interface instead of the
manager prompt. A stopped session resumes by its saved Claude session ID when
you send it another message. A tmux process that survived a Neovim restart
keeps working, but its editor bridge belongs to the old Neovim process; `R`
runs Claude's `/ide` reconnection flow for the current editor. The manager
never falls back to a side panel.

Background sessions use persisted UUIDs and
`CLAUDE_NVIM_FOLLOW_DISABLE=1`. Their hooks do not drive your editor, but you
can resume the conversation yourself. The engines live in
`lua/claude/oneshot.lua` and `lua/flow/job.lua`. The shared session browser is
in `lua/claude/sessions.lua`.

## What Claude sends and shows

| Hook event | Effect in Neovim |
| ---------- | ---------------- |
| `UserPromptSubmit` | Your editor state rides along with every prompt |
| `PreToolUse` | The main window follows the file Claude touches |
| `PostToolUse` | The buffer reloads; added code glows green and removed code lingers red before fading |
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

## Flow

Flow gives you an interactive plan, an autonomous implementation, and an
interactive review of the finished result. Claude does its real work in an
isolated Git worktree. It can edit, run tests, diagnose failures, and try again
without waiting for you to approve each patch.

Press `<leader>dn` and say what you want. Four phases follow.

The review workspace also works independently of a Flow plan. Run
`:FlowReview` or press `<leader>dR` anywhere inside a Git repository to review
the current branch and local worktree against their merge base with `master`.
Repositories without `master` fall back to `main`.
The review opens as one real editable Neovim buffer. Added and replaced current
lines remain normal buffer lines with diff highlights. When your cursor is on a
change, its complete removed base chunk appears directly above the current code;
other deletions stay out of the way. Replaced words receive stronger red and
green emphasis inside the softer line diff. Committed branch changes and current
local edits share the same review experience. Pass another base when needed,
for example `:FlowReview main`. Use `:FlowPlanReview` to reopen the verified
implementation review for the current Flow plan.

Flow builds an AI review map in the background while the editable diff opens.
The map groups files by behavior, explains its review order, marks advisory risk,
and maps changed behavior to test evidence. `K` and `J` follow that guided file
order when it is ready. The selected hunk shows one short AI briefing and its
specific review checks; inactive hunks stay quiet. Press `gA` to rebuild the map.
An edit marks the current map stale because its guidance describes the previous
snapshot. Cached maps are reused only when the base and every changed file still
match. Set `vim.g.flow_review_ai = false` to keep the deterministic core, tests,
and supporting-file order without starting an AI job.

1. A background Claude session runs in plan mode and writes a design document.
   Open `<leader>al` while it runs to inspect its request or send guidance.
   The plan names the new tests, the existing hot-path tests, and the exact
   targeted verification commands. It does not require a full suite unless the
   targeted tests cannot prove the change.
2. The document opens in your browser one chunk at a time. Press **Listen** to
   hear each chunk and advance through the plan automatically. Choose a voice
   and speed; Flow remembers both. Code changes reveal line by line, and
   Mermaid nodes and edges animate in flow order. **Replay motion** runs the
   current chunk again. System reduced-motion preferences disable animation.
   Select text and leave a comment. **Replan** sends the open comments back to
   Claude. Flow renders every Mermaid diagram with Mermaid 11 and confirms that
   each one produces SVG. A failed diagram blocks approval. **Repair diagrams**
   records the renderer error and sends the plan back to Claude. **Approve and
   implement** accepts only the current revision after this rendering check
   passes.
3. Flow refuses to start when the source worktree has a tracked, staged,
   untracked, or deleted change. From a clean source, it creates a `flow/...`
   branch and worktree, then opens a persistent Claude Code session in the
   agent manager.
   Flow sends `/goal go implement this plan <final plan URL>` so Claude Code's
   goal skill owns the implementation without copying the document into its
   4,000-character command. The Stop hook sends Claude back to work if it
   leaves any change uncommitted or stops before the first implementation
   commit.
4. When the implementation is clean, committed, and verified, Flow opens an
   inline review workspace in Neovim. Current code is the real implementation
   worktree buffer, with its normal LSP, completion, diagnostics, formatting,
   and code actions. Removed base lines are virtual and cannot interfere with
   editing. Flow ignores whitespace-only changes. It orders core files first,
   then tests, then supporting files. Press `<leader>o` for the compact review overview.
   Edit and save like any other buffer. Select lines and press `gc` to leave an
   anchored comment. Press `s` to send all direct edits and open comments to the
   same Claude session. Claude commits them and verifies the result before
   review resumes at the same file. Press `m` when the review is complete. Flow
   asks once, squash merges the worktree, and creates the final commit
   automatically.

### The keys

| Key | Does |
| --- | ---- |
| `<leader>dn` | Plan a change |
| `<leader>dp` | Open the plan in the browser |
| `<leader>dv` | View the plan in a split, without the browser |
| `<leader>dl` | Every plan in this directory, past and present |
| `<leader>dj`, `]c` | Review the next finished hunk |
| `<leader>dk`, `[c` | Review the previous hunk |
| `K`, `J` | Next or previous hunk inside the review only |
| `]f`, `[f` | Review the next or previous changed file |
| `<leader>o` | Toggle the ordered review overview |
| `gA` | Refresh the AI review map |
| `<leader>dr` | Send review feedback to Claude |
| `<leader>dc` | Comment on the current review line |
| `<leader>dS` | Submit review edits and comments |
| `<leader>da` | Approve a clean verified review |
| `<leader>dR` | Review this branch and worktree against `master` |
| `<leader>du` | Restore the checkpoint before the last feedback |
| `<leader>ds` | Toggle the implementation session |
| `<leader>dm` | Squash and commit the verified implementation |

While the review is open: `K` moves to the next hunk and `J` moves to the
previous hunk, with `]c` and `[c`
as alternate keys; `]f` and `[f` move
between files; `gc` comments on a line or visual selection; `]r` and `[r` move
between comments; `gC` removes the comment under the cursor; and `s` submits
direct edits and comments for verification. `a` approves a clean verified
review, `m` approves and squashes, `u` restores the previous checkpoint, `?`
shows the keys, and `q` closes the review. The bottom action bar always shows
the important commands and whether the review is verified, edited, or waiting
on comments.

The review has no file-tree split. It starts with one editable code window. For
multi-file changes, a centered review map opens first. AI groups the files into
an intentional review journey and shows its reason for each group. Until that
map is ready, Flow groups files as core, tests, and supporting changes; within
each fallback group, larger changes appear first. Press `<CR>` to open a file or
`<leader>o` to show or hide the overview at any time.

In an independent branch review, the navigation, editing, and anchored-comment
keys are the same. `s` saves edited buffers and durable local notes; Flow-only
approval, agent submission, restoration, and squash actions are hidden.

Commands: `:FlowPlan`, `:FlowOpen`, `:FlowShow`, `:FlowNext`, `:FlowPrev`,
`:FlowSession`, `:FlowReview [base]`, `:FlowPlanReview`, `:FlowFeedback`,
`:FlowComment`, `:FlowSubmit`, `:FlowApprove`, `:FlowRestore`, `:FlowMerge`,
`:FlowInterrupt`, `:FlowPlans`, `:FlowAbandon`.

### How it stays correct

Flow records the source branch, source commit, worktree branch, Claude session,
verified commit, review cursor, and every feedback checkpoint. A verification
belongs to one exact commit. Review feedback clears that verification until
Claude commits and finishes the next targeted test run.

The final merge checks both worktrees again. It refuses a dirty source, a dirty
implementation, a different source branch, an implementation changed after
verification, or a source branch that advanced after the worktree was created.
It never silently reviews one commit and merges another one.

### What is on disk

The plan, its revisions, plan comments, anchored implementation comments,
session identity, Git identities, and review feedback live under
`~/.local/state/nvim/flow/<directory>/<plan>/`. Worktrees live under
`~/.local/state/nvim/flow-worktrees/`. The final squash removes the worktree,
but keeps its `flow/...` branch. That branch preserves Claude's full
implementation and review history after the target branch receives one commit.

### Needs

`node`, for the review server, and the `claude` binary. `:checkhealth flow`
checks both, and reports where the state lives.

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

### Autosave

Leaving a buffer writes it to disk. Claude Code reads files from disk, so an
unsaved buffer hides your latest edit from the agent. The write is quiet. A
scratch buffer, a terminal, and a read-only buffer stay untouched.

The code is `lua/config/autosave.lua`.

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

Run `tests/run.sh` before you commit. It runs more than 600 tests in about four minutes.
The pre-push hook runs it for you. See "Two machines".

    tests/run.sh              everything
    tests/run.sh lua          the Neovim specs only
    tests/run.sh hook         the Claude hook script tests only
    tests/run.sh server       the Flow review server tests only
    tests/run.sh install      the setup script tests only
    tests/run.sh prepush      the git pre-push hook tests only

Nothing in the suite starts Claude, reaches the network, or spends a token.
The Claude terminal, the hook script, and the RPC calls are all mocked, and the
setup tests run against a throwaway `HOME`.

It passes on a fresh clone, before you install anything: the hook tests run
against `claude/nvim-follow.sh` in the repository, not against the copy in
`~/.claude/`.

**Add a test with every change.** `tests/README.md` explains the layout, the
mocks, and how to write a new spec.

## Reloading

`:Reload`, or `<leader>R`, re-reads the configuration without a restart. It
drops every `config.*`, `claude.*`, and `flow.*` module and re-runs them in the
order `init.lua` uses.

It does **not** reload plugin options. lazy.nvim hands a plugin its `opts` once,
when the plugin loads, so a change to a `lua/plugins/*.lua` spec needs a
restart. The same goes for a new `keys` entry: reloading updates the function a
key calls, not the list of keys.

| Change | `:Reload` picks it up? |
| ------ | ---------------------- |
| `lua/claude/*.lua`, `lua/flow/*.lua` | Yes |
| `lua/config/options.lua`, `keymaps.lua`, `autocmds.lua` | Yes |
| `lua/ghostty/*.lua`, the colours | Yes |
| A plugin's `opts`, or a new `keys` entry | No, restart |

A module with a syntax error is named in the message, and the rest still load.

## Two machines

This configuration runs on more than one machine, and each pulls the other's
commits. Because the Claude hook is a symlink into this repository, a `git pull`
updates it too — there is nothing to install twice.

### Staying in step

Neovim checks the remote two seconds after startup. The fetch runs in the
background and nothing blocks. If the branch holds commits you do not have, a
notification says how many.

| Command | Action |
| ------- | ------ |
| `:ConfigUpdate`, `<leader>u` | Fast-forward to the remote branch |
| `:ConfigCheck` | Ask now, and report either way |

The pull is never automatic. A broken commit from the other machine would break
the editor you are sitting in, so you choose the moment.

`:ConfigUpdate` refuses to run over uncommitted changes, and it only
fast-forwards. Diverged history is yours to sort out with git. After a pull,
`:Reload` picks up the module changes; a plugin change needs a restart.

The startup check is silent when it fails. No network and no remote both leave
you with a working editor and no message. Use `:ConfigCheck` to see the reason.

**If you forked this**, point the remote at your own repository first:

    git remote set-url origin https://github.com/<you>/nvim-config.git

Otherwise `<leader>u` fast-forwards you onto someone else's commits.

### Pushing your changes

    git add -A && git commit -m "..." && git push

`.githooks/pre-push` runs the whole test suite first. It refuses the push when
anything fails. Never use `--no-verify` to get past a failing test: decide
whether the code or the test is wrong, then fix that.

## Maintenance

- `:Lazy` manages plugins. `:Mason` manages language servers.
- `:checkhealth` reports problems.
- The previous `init.vim` is in the first commit, as
  `init.vim.bak.20260827`. Run `git show 0ac287c:init.vim.bak.20260827`.
