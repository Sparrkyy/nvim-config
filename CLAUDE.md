# Working in this Neovim configuration

## Tests are required

This configuration has a test suite. Every change needs a test.

1. Run `tests/run.sh` before you report a change as done.
2. Add or update a spec for what you changed. A change with no test is not
   finished.
3. Never weaken a test to make it pass. If a test fails, either the code is
   wrong or the test states the wrong thing. Decide which, then say so.

    tests/run.sh                        # everything, about a minute
    tests/run.sh lua                    # the Neovim specs only
    tests/run.sh hook                   # the Claude hook script tests only
    tests/run.sh prepush                # the git pre-push hook tests only
    tests/run.sh spec/panel_spec.lua    # one spec file

The `.githooks/pre-push` hook runs the suite before every push. Never push
with `--no-verify` to get past a failing test.

`tests/README.md` explains the layout, the mocks, and how to write a spec.

## Never spend tokens in a test

No test may start the Claude CLI, run the real hook, or open a network
connection. Use the existing seams:

- `helpers.mock_claudecode()` for the Claude terminal.
- `helpers.encode()` plus `follow.handle()` for a hook payload.
- `tests/hook/mock/nvim` for the RPC calls the hook script makes.
- `helpers.stub_git(update, answers)` for anything in `config.update` that
  would otherwise reach GitHub.
- `helpers.stub_input` and `helpers.capture_notify` for anything that would
  block on you.

If a new feature needs a seam that does not exist, add the seam to
`tests/lua/helpers.lua`. Do not reach for the real thing.

## Style

- Match the comment style already in the file. Comments explain why, not what.
- Write in Simplified Technical English: short sentences, active voice, one
  idea per sentence.
- Keep a public function's behaviour on failure quiet and safe. The hook calls
  into `claude.follow` over RPC, so an error there must never block Claude.
