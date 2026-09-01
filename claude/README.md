# The Claude Code bridge

`nvim-follow.sh` lets Claude Code drive a running Neovim. It is the other half
of `lua/claude/follow.lua`, and it is the only part of this configuration that
has to live outside the repository, because Claude Code looks for its hooks in
`~/.claude/`.

`install.sh` at the top of this repository puts it there as a **symlink**, so a
`git pull` updates the hook along with everything else.

## How it works

1. Every Neovim writes its RPC address to
   `~/.cache/nvim/claude-follow/<cwd-hash>/<pid>.server` when it starts in a
   directory. Several editors can share one project.
2. Claude Code runs this script on eleven hook events, passing the payload on
   stdin.
3. The script reads the working directory out of the payload, finds the address
   registered for it, and sends a base64 JSON message over
   `nvim --server ... --remote-expr`. Base64 keeps the payload away from both
   the shell and Vim's expression parser.
4. `claude.follow.handle()` decodes it and moves the editor.

It exits quietly whenever there is nothing to do: no payload, no `jq`, no
Neovim registered for that directory. A failure here must never block Claude.

## The events it listens for

| Event | What the editor does |
| ----- | -------------------- |
| `UserPromptSubmit` | Adds your editor state to the prompt |
| `PreToolUse` | Jumps to the file Claude is about to read or change |
| `PostToolUseFailure` | Shows what went wrong |
| `PermissionRequest` | Asks you in the editor |
| `TaskCreated`, `TaskCompleted` | Tracks subagents in the job window |
| `SubagentStart`, `SubagentStop` | The same, for the ones Claude spawns |
| `MessageDisplay` | Streams Claude's prose into the notes panel |
| `Stop` | Runs the project check and sends failures back to Claude |
| `Notification` | Surfaces a permission prompt or an idle agent |

`hooks.json` holds these registrations. `install.sh` merges them into your
`~/.claude/settings.json`, rewriting `__NVIM_FOLLOW__` to the real path. It
backs the file up first, and it only ever touches entries that name
`nvim-follow.sh`.

## Environment variables

| Variable | Effect |
| -------- | ------ |
| `CLAUDE_NVIM_FOLLOW_DISABLE=1` | The session does not drive the editor. One-shot and fix sessions set this, so background work never steals your window. |
| `CLAUDE_NVIM_FOLLOW_DEBUG=1` | Appends every hook payload to `$TMPDIR/nvim-follow.log`, one JSON object per line. |
| `CLAUDE_NVIM_FLOW_ID=<plan>` | Routes a worktree session through Flow's commit and verification gate. Flow sets this itself. |

## Tests

`tests/hook/run.sh` covers this script: 59 checks over every payload kind and
every malformed one. It runs against the copy in this repository, not the
installed one, so a fresh clone can run the suite before installing anything.
A mock `nvim` on `PATH` records the RPC calls, and a temporary `XDG_CACHE_HOME`
holds a fake registry. No Claude process starts.
