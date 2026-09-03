# Tests

721 tests cover this configuration. None of them start Claude, open a network
connection, or spend a token.

## Run them

```sh
tests/run.sh                        # everything
tests/run.sh lua                    # the Neovim specs only
tests/run.sh hook                   # the hook script tests only
tests/run.sh server                 # the Flow review server tests only
tests/run.sh install                # the setup script tests only
tests/run.sh spec/panel_spec.lua    # one spec file
```

The runner exits non-zero when anything fails, so it works in a pre-commit
hook or in CI.

## Layout

| Path | Holds |
|---|---|
| `minimal_init.lua` | The Neovim setup for the specs. It loads this config and plenary, and no plugin manager. |
| `lua/helpers.lua` | Shared helpers and every mock. |
| `spec/*_spec.lua` | The Neovim specs, run by plenary. |
| `hook/run.sh` | The tests for `claude/nvim-follow.sh`, the Claude Code hook. |
| `hook/mock/nvim` | A fake `nvim` that records RPC calls. |
| `server/run.sh` | The tests for `lua/flow/web/server.js`, the plan review server. |
| `install/run.sh` | The tests for `install.sh`, run against a throwaway `HOME`. |

## What each spec covers

| Spec | Subject |
|---|---|
| `follow_pacing_spec.lua` | The jump queue: order, the gap, deduplication, the depth cap. |
| `follow_marks_spec.lua` | The change highlights on the lines Claude wrote. |
| `follow_handle_spec.lua` | Every hook payload kind, and the bad ones. |
| `follow_prompt_spec.lua` | Interrupt behavior when no Claude terminal is running. |
| `follow_registry_spec.lua` | The RPC registry, the permission prompt, the statusline. |
| `panel_spec.lua` | The plan and notes panels. |
| `context_spec.lua` | The editor state sent with each prompt. |
| `bufstack_spec.lua` | The J and K buffer stack. |
| `colorscheme_spec.lua` | The Ghostty palette and the highlight groups. |
| `session_spec.lua` | The per-directory session: save, restore, cursor. |
| `newfile_spec.lua` | `:New` and the parent directories on write. |
| `oneshot_spec.lua` | The shared session engine, including two running at once. |
| `sessions_spec.lua` | The Telescope agent manager, durable registry, tmux lifecycle, and IDE reconnection controls. |
| `tmux_spec.lua` | Private tmux names and the commands that create or attach persistent Claude TUIs. |
| `hud_spec.lua` | The job window: several jobs, trimming, colours, layout. |
| `ask_spec.lua` | One-off requests, from the cursor and from a selection. |
| `input_spec.lua` | The instruction composer: wrapping, growth, submit, cancel. |
| `fixit_spec.lua` | Diagnostic fixes, with the `claude` binary mocked. |
| `reload_spec.lua` | `:Reload`, including what it must not drop. |
| `config_spec.lua` | The plugin settings, so a preference cannot regress unseen. |
| `flow_store_spec.lua` | Flow on disk: plans, revisions, comments, steps, diffs, the undo journal. |
| `flow_job_spec.lua` | Flow's headless Claude engine: the command, the stream, the failures. |
| `flow_planner_spec.lua` | Writing the design document, and revising it from your comments. |
| `flow_ui_spec.lua` | The inline change preview and the stack panel. |
| `flow_stack_spec.lua` | The change stack: decompose, look ahead, apply, undo, staleness. |

## How Claude is mocked

Nothing reaches the real Claude CLI. These seams make that true.

1. **The terminal.** `helpers.mock_claudecode()` puts a stub in
   `package.loaded["claudecode.terminal"]`. It records every send in a table
   instead of writing to a process.
2. **The hook payloads.** The specs call `follow.handle()` with base64 JSON
   that `helpers.encode()` builds. The real hook never runs.
3. **The RPC calls.** `hook/mock/nvim` sits first on `PATH`. It writes each
   `--remote-expr` argument to `$MOCK_NVIM_LOG` and prints `$MOCK_NVIM_REPLY`.
   The hook script cannot tell it from the real thing.
4. **The registry.** The hook tests set `XDG_CACHE_HOME` to a temporary
   directory and register a real unix socket there, so the lookup succeeds
   without an editor behind it.
5. **The `claude` binary.** `hook/mock/claude` stands in for the CLI that
   `claude.fixit` spawns. It records its arguments, rewrites one line of a
   file the way a real fix would, and prints the JSON that
   `claude -p --output-format json` prints. Point `fixit.opts.command` at it.
   It emits the same `stream-json` events the real CLI emits, so the streaming
   path is exercised, not bypassed. Its behaviour comes from
   `MOCK_CLAUDE_FILE`, `MOCK_CLAUDE_LINE`, `MOCK_CLAUDE_TEXT`,
   `MOCK_CLAUDE_RESULT`, `MOCK_CLAUDE_THINK`, `MOCK_CLAUDE_TOOL`,
   `MOCK_CLAUDE_DELAY`, `MOCK_CLAUDE_EXIT`, and `MOCK_CLAUDE_STDERR`.
   `MOCK_CLAUDE_DELAY` is what lets a test hold two sessions in flight at
   once.

6. **Flow's engine.** `helpers.stub_flow_spawn(job, result)` replaces
   `flow.job.spawn`, the one call that reaches a process. It feeds the module a
   canned `stream-json` stream, so the parsing runs for real. Use
   `helpers.stub_flow_job(job, answer)` instead when only the prompt matters:
   it replaces `flow.job.run` outright, and `answer` may be a function of the
   spec, so one stub can answer a decompose job and a diff job differently.
7. **Flow's state.** `helpers.flow_root(store)` points `flow.store.root` at a
   throwaway directory. Call it in every `before_each`, or a spec writes into
   the plans you are really working on.
8. **Flow's review server.** `server/run.sh` starts the real `server.js` on a
   temporary state root and a port the kernel picks, and puts `hook/mock/nvim`
   on `PATH`. So the HTTP routes and the call back into Neovim are both tested
   against the real server, with nothing real behind it.

`vim.ui.input` and `vim.notify` are stubbed too, by `helpers.stub_input` and
`helpers.capture_notify`. No test blocks waiting for you.

## Write a new test

Add `spec/<name>_spec.lua`:

```lua
local H = require("helpers")

describe("my feature", function()
  local mod

  before_each(function()
    H.reset_buffers()
    mod = H.reload("claude.mymodule")  -- fresh module state each test
  end)

  it("does the thing", function()
    assert.equals("expected", mod.thing())
  end)
end)
```

Rules that keep the suite fast and honest:

- Call `H.reload` in `before_each`. Modules hold state between tests.
- Use `H.tmpdir()` and `H.write_file()`. Never write into the real config.
- Compare paths with `H.resolve()`. On macOS `/var` is a symlink to
  `/private/var`, so a raw temp path never matches a buffer name.
- Never call a real Claude command. Use `H.mock_claudecode()`.

## Add a test to the hook suite

Add a case to `hook/run.sh`:

```sh
run "$(payload '{cwd:$cwd, hook_event_name:"YourEvent", field:"value"}')" >/dev/null
check_json "describes the behaviour" '.kind' "expected" "$(sent 1)"
```

- `run` feeds a payload to the hook and clears the RPC log first.
- `sent N` decodes the Nth message the hook sent to Neovim.
- `check`, `check_json`, and `rpc_count` do the asserting.

## Bugs these tests found

Writing them caught four real defects:

1. `panel.ensure_buf` threw `E95` when a buffer with the panel name already
   existed. It now reuses that buffer.
2. `render_notes` split each streamed chunk onto its own line, so a delta that
   ended mid-word broke across lines. It now joins first, then splits.
3. The hook wrote `final: (.final // true)`. In jq, `false // true` gives
   `true`, so every streaming chunk was marked final. It now tests for the key.
4. `claude_terminal` indexed the module without checking its type. A module
   that loaded but was not a table crashed the prompt.
