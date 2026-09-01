#!/bin/bash
# Bridges Claude Code and a running Neovim.
#
# Reads a hook payload on stdin, finds the Neovim RPC address registered for
# the session cwd, and drives the editor. Exits quietly when no Neovim is
# registered. Some events also write JSON to stdout to steer Claude.

set -uo pipefail

payload=$(cat)

if [ -n "${CLAUDE_NVIM_FOLLOW_DEBUG:-}" ]; then
  # One JSON object per line, so the log stays readable with jq.
  printf '%s' "$payload" | jq -c --arg t "$(date +%T)" '. + {logged_at: $t}' \
    >> "${TMPDIR:-/tmp}/nvim-follow.log" 2>/dev/null
fi

[ -z "$payload" ] && exit 0
command -v jq >/dev/null 2>&1 || exit 0

# A one-shot fix session must not drive the editor. lua/claude/fixit.lua sets
# this, so its jumps, panels, and Stop checks never reach your main window.
[ -n "${CLAUDE_NVIM_FOLLOW_DISABLE:-}" ] && exit 0

cwd=$(printf '%s' "$payload" | jq -r '.cwd // empty')
event=$(printf '%s' "$payload" | jq -r '.hook_event_name // empty')
[ -z "$event" ] && exit 0

# ---------------------------------------------------------------- nvim lookup

server=""
if [ -n "$cwd" ]; then
  key=$(printf '%s' "$cwd" | shasum -a 256 | cut -d' ' -f1)
  registry_dir="${XDG_CACHE_HOME:-$HOME/.cache}/nvim/claude-follow/${key}"
  if [ -d "$registry_dir" ]; then
    # Several editors may sit in one project. Drop stale entries, take the newest.
    for entry in "$registry_dir"/*.server; do
      [ -f "$entry" ] || continue
      candidate=$(cat "$entry" 2>/dev/null)
      if [ -z "$candidate" ] || [ ! -S "$candidate" ]; then
        rm -f "$entry"
        continue
      fi
      server="$candidate"
    done
  fi
fi

have_nvim() { [ -n "$server" ] && command -v nvim >/dev/null 2>&1; }

# Fire a message at Neovim. Never blocks Claude on a slow editor.
send() {
  have_nvim || return 0
  local encoded
  encoded=$(printf '%s' "$1" | base64 | tr -d '\n')
  nvim --server "$server" --remote-expr \
    "v:lua.require'claude.follow'.handle('${encoded}')" >/dev/null 2>&1
}

# Ask Neovim a question and print the answer.
ask() {
  have_nvim || return 1
  nvim --server "$server" --remote-expr "$1" 2>/dev/null
}

# ------------------------------------------------------------------- dispatch

case "$event" in

  UserPromptSubmit)
    if [ -n "${CLAUDE_NVIM_FLOW_ID:-}" ]; then
      message=$(printf '%s' "$payload" | jq -c --arg p "$CLAUDE_NVIM_FLOW_ID" '{
        plan_id: $p,
        cwd: (.cwd // ""),
        prompt: (.prompt // "")
      }')
      encoded=$(printf '%s' "$message" | base64 | tr -d '\n')
      ask "v:lua.require'flow.implementation'.prompt_submitted('${encoded}')" >/dev/null || true
      exit 0
    fi
    # Give Claude the editor state with every prompt.
    encoded=$(ask "v:lua.require'claude.context'.gather_encoded()") || exit 0
    [ -z "$encoded" ] && exit 0
    context=$(printf '%s' "$encoded" | base64 --decode 2>/dev/null)
    [ -z "$context" ] && exit 0
    jq -n --arg c "$context" '{
      hookSpecificOutput: {
        hookEventName: "UserPromptSubmit",
        additionalContext: $c
      }
    }'
    exit 0
    ;;

  PermissionRequest)
    # Decide inside the editor. Anything unclear falls back to the terminal.
    have_nvim || exit 0
    detail=$(printf '%s' "$payload" | jq -r '
      .tool_input.command
      // .tool_input.file_path
      // (.tool_input | tostring)
      // ""' | head -c 400)
    tool=$(printf '%s' "$payload" | jq -r '.tool_name // "a tool"')
    msg=$(jq -nc --arg t "$tool" --arg d "$detail" '{tool:$t, detail:$d}')
    encoded=$(printf '%s' "$msg" | base64 | tr -d '\n')
    decision=$(ask "v:lua.require'claude.follow'.permission('${encoded}')")
    case "$decision" in
      allow|deny)
        jq -n --arg d "$decision" '{
          hookSpecificOutput: { hookEventName: "PermissionRequest", decision: $d }
        }'
        ;;
      *) exit 0 ;;
    esac
    exit 0
    ;;

  PostToolUseFailure)
    path=$(printf '%s' "$payload" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty')
    text=$(printf '%s' "$payload" | jq -r '(.tool_name // "tool") + ": " + ((.error // "failed") | gsub("\n"; " "))' | head -c 400)
    send "$(jq -nc --arg p "$path" --arg t "$text" '{kind:"quickfix", path:(if $p=="" then null else $p end), line:1, text:$t}')"
    exit 0
    ;;

  SubagentStart|SubagentStop)
    ev=start; [ "$event" = "SubagentStop" ] && ev=stop
    send "$(printf '%s' "$payload" | jq -c --arg e "$ev" '{kind:"agent", event:$e, id:(.agent_id // "?"), agent_type:(.agent_type // "agent")}')"
    exit 0
    ;;

  TaskCreated|TaskCompleted)
    # Field names here are not documented; try the likely shapes in turn.
    st=pending; [ "$event" = "TaskCompleted" ] && st=completed
    send "$(printf '%s' "$payload" | jq -c --arg s "$st" '{
      kind: "task",
      id: (.task.id // .task_id // .id // .task.description // .description // "task"),
      text: (.task.description // .description // .task.title // .title // .task.content // .prompt // "task"),
      task_status: (.task.status // $s)
    }')"
    exit 0
    ;;

  MessageDisplay)
    # `//` treats false as absent, so `.final // true` would turn every
    # streaming chunk into a final one. Test for the key instead.
    send "$(printf '%s' "$payload" | jq -c '{
      kind: "message",
      id: (.message_id // "msg"),
      delta: (.delta // ""),
      final: (if has("final") then .final else true end)
    }')"
    exit 0
    ;;

  PreToolUse|PostToolUse)
    have_nvim || exit 0
    tool=$(printf '%s' "$payload" | jq -r '.tool_name // empty')

    if [ "$tool" = "Bash" ]; then
      # Agents also edit through the shell. Follow those, but only on a write.
      cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // empty')
      case "$cmd" in
        *"sed -i"*|*tee\ *|*" > "*|*" >> "*|*python*\<\<*|*cat\ \<\<*|*mv\ *|*cp\ *) ;;
        *) exit 0 ;;
      esac
      target=""
      for word in $cmd; do
        word=${word%%\'*}; word=${word#\'}
        word=${word%%\"*}; word=${word#\"}
        case "$word" in -*|*\**) continue ;; esac
        if [ -f "$cwd/$word" ]; then target="$cwd/$word"; break; fi
        if [ -f "$word" ]; then target="$word"; break; fi
      done
      [ -z "$target" ] && exit 0
      send "$(jq -nc --arg p "$target" '{kind:"open", tool:"Bash", path:$p, line:null, needle:null}')"
      exit 0
    fi

    # "added" carries the new text, so Neovim can highlight what changed. Send
    # it only after the write, when the text is actually on disk.
    message=$(printf '%s' "$payload" | jq -c --arg ev "$event" '{
      kind: "open",
      event: $ev,
      tool: .tool_name,
      path: (.tool_input.file_path // .tool_input.notebook_path // empty),
      line: (.tool_input.offset // null),
      needle: (.tool_input.old_string // (.tool_input.edits[0].old_string? // null)),
      added: (
        if $ev != "PostToolUse" then []
        elif (.tool_input.edits? | type) == "array"
          then (.tool_input.edits | map(.new_string // empty) | .[0:16])
        elif (.tool_input.new_string? // null) != null then [.tool_input.new_string]
        elif (.tool_input.content? // null) != null then [.tool_input.content]
        else [] end
      )
    }')
    [ "$(printf '%s' "$message" | jq -r '.path // empty')" = "" ] && exit 0
    send "$message"
    exit 0
    ;;

  Stop)
    if [ -n "${CLAUDE_NVIM_FLOW_ID:-}" ]; then
      message=$(printf '%s' "$payload" | jq -c --arg p "$CLAUDE_NVIM_FLOW_ID" '{
        plan_id: $p,
        cwd: (.cwd // ""),
        session_id: (.session_id // ""),
        summary: (.last_assistant_message // .message // "")
      }')
      encoded=$(printf '%s' "$message" | base64 | tr -d '\n')
      decision=$(ask "v:lua.require'flow.implementation'.stop('${encoded}')") || exit 0
      case "$decision" in
        continue:*)
          reason=${decision#continue:}
          jq -n --arg reason "$reason" '{
            hookSpecificOutput: { hookEventName: "Stop", permissionDecision: "deny" },
            systemMessage: $reason
          }'
          ;;
      esac
      exit 0
    fi

    send "$(jq -nc '{kind:"status", status:"idle", level:"INFO", message:"Claude finished."}')"

    # Keep going until green. Opt in by adding an executable .claude/check.sh
    # to the project. Without that file this is inert.
    check="$cwd/.claude/check.sh"
    [ -x "$check" ] || exit 0

    # Never loop: stop_hook_active means a Stop hook already continued the turn.
    active=$(printf '%s' "$payload" | jq -r '.stop_hook_active // false')
    [ "$active" = "true" ] && exit 0

    session=$(printf '%s' "$payload" | jq -r '.session_id // "none"')
    counter="${TMPDIR:-/tmp}/claude-check-${session}.count"
    tries=$(cat "$counter" 2>/dev/null || echo 0)
    if [ "$tries" -ge 3 ]; then
      rm -f "$counter"
      exit 0
    fi

    output=$(cd "$cwd" && "$check" 2>&1)
    if [ $? -eq 0 ]; then
      rm -f "$counter"
      send "$(jq -nc '{kind:"status", status:"idle", level:"INFO", message:"Checks passed."}')"
      exit 0
    fi

    echo $((tries + 1)) > "$counter"
    send "$(jq -nc '{kind:"status", status:"working", level:"WARN", message:"Checks failed. Claude is continuing."}')"
    jq -n --arg o "$(printf '%s' "$output" | tail -c 4000)" '{
      hookSpecificOutput: { hookEventName: "Stop", permissionDecision: "deny" },
      systemMessage: ("The project check script failed. Fix these errors, then stop.\n\n" + $o)
    }'
    exit 0
    ;;

  Notification)
    send "$(printf '%s' "$payload" | jq -c '{kind:"status", status:"working", level:"WARN", message:("Claude needs you: " + (.notification_type // "input"))}')"
    exit 0
    ;;

esac

exit 0
