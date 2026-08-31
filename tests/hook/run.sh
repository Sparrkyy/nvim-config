#!/bin/bash
# Tests for claude/nvim-follow.sh, the Claude Code hook this repository ships.
#
# Everything outside the script is faked:
#   - a mock `nvim` on PATH records the RPC calls instead of driving an editor
#   - a temporary XDG_CACHE_HOME holds a fake registry with a real unix socket
#   - every payload is a hand-written JSON fixture
# No Claude process starts, and no token is spent.

set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
# The copy in this repository, not the installed one. A fresh clone must be able
# to run the whole suite before install.sh has put anything anywhere.
HOOK="${HOOK:-$(dirname "$(dirname "$here")")/claude/nvim-follow.sh}"

pass=0
fail=0
failures=()

# ------------------------------------------------------------------ scaffold

root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT

export XDG_CACHE_HOME="$root/cache"
export PATH="$here/mock:$PATH"
export MOCK_NVIM_LOG="$root/rpc.log"

project="$root/project"
mkdir -p "$project"

# Register a fake Neovim for the project cwd. The hook checks that the entry
# names a real unix socket, so make one.
key=$(printf '%s' "$project" | shasum -a 256 | cut -d' ' -f1)
regdir="$XDG_CACHE_HOME/nvim/claude-follow/$key"
mkdir -p "$regdir"
socket="$root/nvim.sock"
python3 -c "
import socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(sys.argv[1])
s.listen(1)
" "$socket"
printf '%s' "$socket" > "$regdir/1234.server"

# ------------------------------------------------------------------- helpers

# run <json> -> stdout of the hook. Resets the RPC log first.
run() {
  : > "$MOCK_NVIM_LOG"
  printf '%s' "$1" | bash "$HOOK" 2>/dev/null
}

# The decoded JSON of the Nth RPC message the hook sent.
sent() {
  local n=${1:-1}
  local expr
  expr=$(sed -n "${n}p" "$MOCK_NVIM_LOG")
  [ -z "$expr" ] && return 1
  printf '%s' "$expr" \
    | sed -e "s/^.*handle('//" -e "s/').*$//" -e "s/^.*permission('//" \
    | base64 --decode 2>/dev/null
}

rpc_count() {
  [ -f "$MOCK_NVIM_LOG" ] || { echo 0; return; }
  # grep -c exits 1 on no match, so count with awk instead.
  awk 'NF { n++ } END { print n + 0 }' "$MOCK_NVIM_LOG"
}

ok() {
  pass=$((pass + 1))
  printf '  \033[32mok\033[0m   %s\n' "$1"
}

no() {
  fail=$((fail + 1))
  failures+=("$1")
  printf '  \033[31mFAIL\033[0m %s\n' "$1"
  [ -n "${2:-}" ] && printf '       %s\n' "$2"
}

# check <name> <expected> <actual>
check() {
  if [ "$2" = "$3" ]; then
    ok "$1"
  else
    no "$1" "expected [$2], got [$3]"
  fi
}

# check_json <name> <jq filter> <expected> <json>
check_json() {
  local actual
  actual=$(printf '%s' "$4" | jq -r "$2" 2>/dev/null)
  check "$1" "$3" "$actual"
}

payload() {
  jq -nc --arg cwd "$project" "$1"
}

echo
echo "nvim-follow.sh"
echo

# --------------------------------------------------------------------- tests

# -- guards ------------------------------------------------------------------

out=$(printf '' | bash "$HOOK" 2>/dev/null)
check "exits quietly on an empty payload" "" "$out"

out=$(run '{"cwd":"/nope","hook_event_name":""}')
check "exits quietly with no event name" "" "$out"

run "$(payload '{cwd:$cwd, hook_event_name:"PreToolUse", tool_name:"Read", tool_input:{file_path:"/x.lua"}}')" >/dev/null
first=$(sent 1)
check_json "reaches the registered Neovim" '.kind' "open" "$first"

# An unregistered cwd must send nothing.
run '{"cwd":"/no/such/project","hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"/x.lua"}}' >/dev/null
check "sends nothing when no Neovim is registered" "0" "$(rpc_count)"

# -- UserPromptSubmit --------------------------------------------------------

export MOCK_NVIM_REPLY
MOCK_NVIM_REPLY=$(printf 'Cursor: a.lua line 3' | base64)
out=$(run "$(payload '{cwd:$cwd, hook_event_name:"UserPromptSubmit", prompt:"hi"}')")
check_json "injects the editor state into the prompt" \
  '.hookSpecificOutput.additionalContext' "Cursor: a.lua line 3" "$out"
check_json "names the hook event" \
  '.hookSpecificOutput.hookEventName' "UserPromptSubmit" "$out"

MOCK_NVIM_REPLY=""
out=$(run "$(payload '{cwd:$cwd, hook_event_name:"UserPromptSubmit"}')")
check "adds no context when Neovim returns nothing" "" "$out"

# -- PermissionRequest -------------------------------------------------------

MOCK_NVIM_REPLY="allow"
out=$(run "$(payload '{cwd:$cwd, hook_event_name:"PermissionRequest", tool_name:"Bash", tool_input:{command:"ls -la"}}')")
check_json "passes an allow decision back to Claude" \
  '.hookSpecificOutput.decision' "allow" "$out"

MOCK_NVIM_REPLY="deny"
out=$(run "$(payload '{cwd:$cwd, hook_event_name:"PermissionRequest", tool_name:"Bash", tool_input:{command:"rm -rf /"}}')")
check_json "passes a deny decision back to Claude" \
  '.hookSpecificOutput.decision' "deny" "$out"

MOCK_NVIM_REPLY="ask"
out=$(run "$(payload '{cwd:$cwd, hook_event_name:"PermissionRequest", tool_name:"Bash", tool_input:{command:"ls"}}')")
check "stays silent when the editor defers to the terminal" "" "$out"

MOCK_NVIM_REPLY="allow"
run "$(payload '{cwd:$cwd, hook_event_name:"PermissionRequest", tool_name:"Bash", tool_input:{command:"ls -la"}}')" >/dev/null
check_json "sends the tool and the detail to the editor" '.tool' "Bash" "$(sent 1)"
check_json "sends the command as the detail" '.detail' "ls -la" "$(sent 1)"

MOCK_NVIM_REPLY=""

# -- PostToolUseFailure ------------------------------------------------------

run "$(payload '{cwd:$cwd, hook_event_name:"PostToolUseFailure", tool_name:"Edit", error:"no such file", tool_input:{file_path:"/a.lua"}}')" >/dev/null
msg=$(sent 1)
check_json "reports a failure as a quickfix entry" '.kind' "quickfix" "$msg"
check_json "keeps the failing file path" '.path' "/a.lua" "$msg"
check_json "names the tool and the error" '.text' "Edit: no such file" "$msg"

run "$(payload '{cwd:$cwd, hook_event_name:"PostToolUseFailure", tool_name:"Edit", error:"line one\nline two", tool_input:{file_path:"/a.lua"}}')" >/dev/null
check_json "flattens a multi-line error onto one line" '.text' "Edit: line one line two" "$(sent 1)"

# -- subagents ---------------------------------------------------------------

run "$(payload '{cwd:$cwd, hook_event_name:"SubagentStart", agent_id:"a1", agent_type:"Explore"}')" >/dev/null
msg=$(sent 1)
check_json "reports a subagent start" '.event' "start" "$msg"
check_json "keeps the agent type" '.agent_type' "Explore" "$msg"

run "$(payload '{cwd:$cwd, hook_event_name:"SubagentStop", agent_id:"a1"}')" >/dev/null
check_json "reports a subagent stop" '.event' "stop" "$(sent 1)"

# -- tasks -------------------------------------------------------------------

run "$(payload '{cwd:$cwd, hook_event_name:"TaskCreated", task:{id:"t1", description:"Write tests", status:"pending"}}')" >/dev/null
msg=$(sent 1)
check_json "sends a new task" '.id' "t1" "$msg"
check_json "sends the task text" '.text' "Write tests" "$msg"
check_json "sends the task status" '.task_status' "pending" "$msg"

run "$(payload '{cwd:$cwd, hook_event_name:"TaskCompleted", task_id:"t1", description:"Write tests"}')" >/dev/null
check_json "defaults a completed task to the completed status" '.task_status' "completed" "$(sent 1)"

run "$(payload '{cwd:$cwd, hook_event_name:"TaskCreated"}')" >/dev/null
check_json "falls back to a placeholder when the shape is unknown" '.id' "task" "$(sent 1)"

# -- messages ----------------------------------------------------------------

run "$(payload '{cwd:$cwd, hook_event_name:"MessageDisplay", message_id:"m1", delta:"hello", final:false}')" >/dev/null
msg=$(sent 1)
check_json "streams a message delta" '.delta' "hello" "$msg"
check_json "keeps the streaming flag" '.final' "false" "$msg"

# -- edits -------------------------------------------------------------------

run "$(payload '{cwd:$cwd, hook_event_name:"PreToolUse", tool_name:"Edit", tool_input:{file_path:"/a.lua", old_string:"before"}}')" >/dev/null
msg=$(sent 1)
check_json "follows an edit to its file" '.path' "/a.lua" "$msg"
check_json "sends the old string as the search anchor" '.needle' "before" "$msg"
check_json "sends no added text before the write" '.added | length' "0" "$msg"

run "$(payload '{cwd:$cwd, hook_event_name:"PostToolUse", tool_name:"Edit", tool_input:{file_path:"/a.lua", old_string:"before", new_string:"after one\nafter two"}}')" >/dev/null
msg=$(sent 1)
check_json "sends the added text after the write" '.added[0]' "after one
after two" "$msg"
check_json "marks the event as PostToolUse" '.event' "PostToolUse" "$msg"

run "$(payload '{cwd:$cwd, hook_event_name:"PostToolUse", tool_name:"Write", tool_input:{file_path:"/new.lua", content:"fresh content"}}')" >/dev/null
check_json "sends the whole content of a Write" '.added[0]' "fresh content" "$(sent 1)"

run "$(payload '{cwd:$cwd, hook_event_name:"PostToolUse", tool_name:"Edit", tool_input:{file_path:"/a.lua", edits:[{old_string:"a", new_string:"one"},{old_string:"b", new_string:"two"}]}}')" >/dev/null
msg=$(sent 1)
check_json "sends every edit of a MultiEdit" '.added | length' "2" "$msg"
check_json "keeps the second edit" '.added[1]' "two" "$msg"

run "$(payload '{cwd:$cwd, hook_event_name:"PostToolUse", tool_name:"Read", tool_input:{file_path:"/a.lua", offset:42}}')" >/dev/null
check_json "follows a Read to its offset" '.line' "42" "$(sent 1)"

run "$(payload '{cwd:$cwd, hook_event_name:"PreToolUse", tool_name:"Grep", tool_input:{pattern:"x"}}')" >/dev/null
check "sends nothing for a tool with no file" "0" "$(rpc_count)"

# -- bash edits --------------------------------------------------------------

printf 'x' > "$project/edited.txt"
run "$(payload '{cwd:$cwd, hook_event_name:"PostToolUse", tool_name:"Bash", tool_input:{command:("sed -i \"\" s/a/b/ " + $cwd + "/edited.txt")}}')" >/dev/null
check_json "follows an in-place sed to its file" '.tool' "Bash" "$(sent 1)"

run "$(payload '{cwd:$cwd, hook_event_name:"PostToolUse", tool_name:"Bash", tool_input:{command:"ls -la"}}')" >/dev/null
check "ignores a read-only shell command" "0" "$(rpc_count)"

run "$(payload '{cwd:$cwd, hook_event_name:"PostToolUse", tool_name:"Bash", tool_input:{command:"git status"}}')" >/dev/null
check "ignores git status" "0" "$(rpc_count)"

# -- Stop --------------------------------------------------------------------

out=$(run "$(payload '{cwd:$cwd, hook_event_name:"Stop", session_id:"s1"}')")
check "stays silent with no project check script" "" "$out"
check_json "still tells the editor Claude finished" '.message' "Claude finished." "$(sent 1)"

mkdir -p "$project/.claude"
cat > "$project/.claude/check.sh" <<'CHECK'
#!/bin/bash
exit 0
CHECK
chmod +x "$project/.claude/check.sh"

out=$(run "$(payload '{cwd:$cwd, hook_event_name:"Stop", session_id:"s2"}')")
check "lets Claude stop when the checks pass" "" "$out"
check_json "reports the passing checks" '.message' "Checks passed." "$(sent 2)"

cat > "$project/.claude/check.sh" <<'CHECK'
#!/bin/bash
echo "3 type errors"
exit 1
CHECK
chmod +x "$project/.claude/check.sh"

rm -f "${TMPDIR:-/tmp}/claude-check-s3.count"
out=$(run "$(payload '{cwd:$cwd, hook_event_name:"Stop", session_id:"s3"}')")
check_json "blocks the stop when the checks fail" \
  '.hookSpecificOutput.permissionDecision' "deny" "$out"
check "passes the failure output to Claude" "yes" \
  "$(printf '%s' "$out" | jq -r 'if (.systemMessage | test("3 type errors")) then "yes" else "no" end')"

# Three failures in a row, then it must give up.
out=$(run "$(payload '{cwd:$cwd, hook_event_name:"Stop", session_id:"s3"}')")
out=$(run "$(payload '{cwd:$cwd, hook_event_name:"Stop", session_id:"s3"}')")
out=$(run "$(payload '{cwd:$cwd, hook_event_name:"Stop", session_id:"s3"}')")
check "gives up after three failed check runs" "" "$out"
rm -f "${TMPDIR:-/tmp}/claude-check-s3.count"

out=$(run "$(payload '{cwd:$cwd, hook_event_name:"Stop", session_id:"s4", stop_hook_active:true}')")
check "never loops on itself" "" "$out"

rm -rf "$project/.claude"

# -- notifications -----------------------------------------------------------

run "$(payload '{cwd:$cwd, hook_event_name:"Notification", notification_type:"permission"}')" >/dev/null
check_json "passes a notification to the editor" '.message' "Claude needs you: permission" "$(sent 1)"

# -- the one-shot fix session -----------------------------------------------

# lua/claude/fixit.lua runs `claude -p` in the same project. Its hooks must
# not drive the editor, or a side fix would hijack your main window.
: > "$MOCK_NVIM_LOG"
printf '%s' "$(payload '{cwd:$cwd, hook_event_name:"PreToolUse", tool_name:"Edit", tool_input:{file_path:"/a.lua"}}')" \
  | CLAUDE_NVIM_FOLLOW_DISABLE=1 bash "$HOOK" >/dev/null 2>&1
check "sends nothing when a fix session sets the disable flag" "0" "$(rpc_count)"

: > "$MOCK_NVIM_LOG"
out=$(printf '%s' "$(payload '{cwd:$cwd, hook_event_name:"UserPromptSubmit"}')" \
  | CLAUDE_NVIM_FOLLOW_DISABLE=1 bash "$HOOK" 2>/dev/null)
check "injects no context into a fix session prompt" "" "$out"

# -- robustness --------------------------------------------------------------

out=$(printf '%s' 'not json at all' | bash "$HOOK" 2>/dev/null)
check "survives a payload that is not JSON" "" "$out"

out=$(run "$(payload '{cwd:$cwd, hook_event_name:"CompletelyUnknownEvent"}')")
check "ignores an event it does not know" "" "$out"

# A dead socket entry must be pruned, and nothing sent.
printf '%s' "$root/missing.sock" > "$regdir/9999.server"
run "$(payload '{cwd:$cwd, hook_event_name:"PreToolUse", tool_name:"Read", tool_input:{file_path:"/x.lua"}}')" >/dev/null
if [ -f "$regdir/9999.server" ]; then
  no "prunes a registry entry whose socket is gone"
else
  ok "prunes a registry entry whose socket is gone"
fi

# ------------------------------------------------------------------- summary

echo
printf '  %d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -gt 0 ]; then
  echo
  for f in "${failures[@]}"; do
    printf '  failed: %s\n' "$f"
  done
  exit 1
fi
exit 0
