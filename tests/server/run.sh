#!/bin/bash
# Tests for lua/flow/web/server.js, the plan review server.
#
# Everything outside the server is faked:
#   - a temporary state root holds hand-written plan files
#   - the mock `nvim` from tests/hook records the RPC calls it receives
# No Claude process starts, and nothing binds to a public interface.

set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
config=$(dirname "$(dirname "$here")")
SERVER="$config/lua/flow/web/server.js"

pass=0
fail=0
failures=()

# ------------------------------------------------------------------ scaffold

root=$(mktemp -d)
trap 'rm -rf "$root"; [ -n "${pid:-}" ] && kill "$pid" 2>/dev/null' EXIT

state="$root/flow"
plan="$state/home_me_project_deadbeef/20260101-120000-abcd"
mkdir -p "$plan/revisions"

cat > "$plan/meta.json" <<'JSON'
{"id":"20260101-120000-abcd","title":"Add a flag","cwd":"/home/me/project",
 "created":1767268800,"status":"review","current_revision":2,"step_cursor":1}
JSON
printf '%s' '{"n":1,"plan_md":"# Add a flag\n\n## Context\nFirst try.","created":1}' \
  > "$plan/revisions/001.json"
printf '%s' '{"n":2,"plan_md":"# Add a flag\n\n## Context\nSecond try.","created":2}' \
  > "$plan/revisions/002.json"

export MOCK_NVIM_LOG="$root/rpc.log"
export PATH="$(dirname "$here")/hook/mock:$PATH"
export FLOW_NVIM_SERVER="/tmp/fake.sock"
: > "$MOCK_NVIM_LOG"

# Start the server on a port the kernel picks, and read the line it prints.
node "$SERVER" --root "$state" --port 0 > "$root/out" 2>"$root/err" &
pid=$!

port=""
token=""
for _ in $(seq 1 50); do
  read -r _ port token < "$root/out" 2>/dev/null && [ -n "$token" ] && break
  sleep 0.1
done

if [ -z "$token" ]; then
  echo "the server never printed FLOW_READY:"
  cat "$root/err"
  exit 1
fi

BASE="http://127.0.0.1:$port"
PLAN="20260101-120000-abcd"
API="$BASE/api/plan/$PLAN"

# ------------------------------------------------------------------- helpers

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

# get <path> -> body
get() {
  curl -sS "$API$1${1/\?/&}" 2>/dev/null
}

# status <method> <url> -> the HTTP code
status() {
  curl -sS -o /dev/null -w '%{http_code}' -X "$1" "$2" 2>/dev/null
}

api() {
  curl -sS "$API$1&token=$token" 2>/dev/null
}

post() {
  curl -sS -X POST -H 'Content-Type: application/json' -d "${2:-}" \
    "$API$1?token=$token" 2>/dev/null
}

comment_count() {
  jq 'length' "$plan/comments.json" 2>/dev/null || echo 0
}

echo
echo "flow review server"
echo

# --------------------------------------------------------------------- tests

# -- the token ---------------------------------------------------------------

check "refuses an api call with no token" "403" "$(status GET "$API")"
check "refuses an api call with a wrong token" "403" "$(status GET "$API?token=nope")"
check "answers an api call with the right token" "200" "$(status GET "$API?token=$token")"

# -- reading a plan ----------------------------------------------------------

body=$(api "?")
check_json "returns the plan title" '.meta.title' "Add a flag" "$body"
check_json "returns the current revision" '.revision.n' "2" "$body"
check_json "returns the current document" '.revision.plan_md' \
  "$(printf '# Add a flag\n\n## Context\nSecond try.')" "$body"
check_json "lists every revision" '.revisions | length' "2" "$body"
check_json "starts with no comments" '.comments | length' "0" "$body"
check_json "starts with no steps" '.steps | length' "0" "$body"

body=$(api "?revision=1")
check_json "serves an older revision on request" '.revision.n' "1" "$body"
check_json "serves the older document" '.revision.plan_md' \
  "$(printf '# Add a flag\n\n## Context\nFirst try.')" "$body"

body=$(api "/revision/1?")
check_json "serves an older revision by path too" '.revision.n' "1" "$body"

body=$(api "?revision=99")
check_json "clamps a revision past the end" '.revision.n' "2" "$body"

check "404s an unknown plan" "404" "$(status GET "$BASE/api/plan/nope?token=$token")"
check "404s a plan id with a path in it" "404" \
  "$(status GET "$BASE/api/plan/..%2f..%2fetc?token=$token")"

# -- the page ----------------------------------------------------------------

check "serves the page without a token, because it has no state" "200" \
  "$(status GET "$BASE/plan/$PLAN")"
page=$(curl -sS "$BASE/plan/$PLAN" 2>/dev/null)
if printf '%s' "$page" | grep -q 'id="doc"'; then
  ok "the page holds the document element"
else
  no "the page holds the document element"
fi
if printf '%s' "$page" | grep -q 'mermaid'; then
  ok "the page loads mermaid for the diagrams"
else
  no "the page loads mermaid for the diagrams"
fi
if printf '%s' "$page" | grep -q 'verifyDiagramRendering'; then
  ok "the page verifies each Mermaid diagram produces SVG"
else
  no "the page verifies each Mermaid diagram produces SVG"
fi
if printf '%s' "$page" | grep -q 'id="diagram-status"'; then
  ok "the page shows the Mermaid rendering gate"
else
  no "the page shows the Mermaid rendering gate"
fi
if printf '%s' "$page" | grep -q 'Repair diagrams'; then
  ok "the page can send a failed diagram back for repair"
else
  no "the page can send a failed diagram back for repair"
fi
if printf '%s' "$page" | grep -q 'id="play"'; then
  ok "the page has a narration control"
else
  no "the page has a narration control"
fi
if printf '%s' "$page" | grep -q 'id="rate"'; then
  ok "the page has a narration speed control"
else
  no "the page has a narration speed control"
fi
if printf '%s' "$page" | grep -q 'id="voice"'; then
  ok "the page has a narration voice control"
else
  no "the page has a narration voice control"
fi
if printf '%s' "$page" | grep -q 'getVoices'; then
  ok "the page chooses from the browser voices"
else
  no "the page chooses from the browser voices"
fi
if printf '%s' "$page" | grep -q 'SpeechSynthesisUtterance'; then
  ok "the page uses browser speech synthesis"
else
  no "the page uses browser speech synthesis"
fi
if printf '%s' "$page" | grep -q 'function planChunks'; then
  ok "the page turns headings into presentation chunks"
else
  no "the page turns headings into presentation chunks"
fi
if printf '%s' "$page" | grep -q 'Approve and implement'; then
  ok "the plan approval starts autonomous implementation"
else
  no "the plan approval starts autonomous implementation"
fi
check "404s anything else" "404" "$(status GET "$BASE/etc/passwd")"

# Two bugs the page had. Both are invisible until you select text, so pin them
# here: the review page has no JavaScript test harness.
app="$config/lua/flow/web/app.html"
if grep -q 'closest("#doc > \[data-anchor\]")' "$app"; then
  ok "the page anchors a comment to the block the selection starts in"
else
  no "the page anchors a comment to the block the selection starts in" \
    "commonAncestorContainer is #doc as soon as a selection spans two blocks"
fi
if grep -q 'addEventListener("selectionchange"' "$app"; then
  ok "the page offers the button on any selection, not only a mouse one"
else
  no "the page offers the button on any selection, not only a mouse one"
fi
if grep -q 'window.innerHeight' "$app"; then
  ok "the page keeps a popup inside the window"
else
  no "the page keeps a popup inside the window" \
    "a selection near the bottom would put the button below the fold"
fi

# -- comments ----------------------------------------------------------------

body=$(post "/comment" '{"anchor":"approach#1","quote":"one line","body":"use a table"}')
check_json "keeps a comment" '.comment.body' "use a table" "$body"
check_json "keeps the anchor" '.comment.anchor' "approach#1" "$body"
check_json "keeps the quoted text" '.comment.quote' "one line" "$body"
check_json "stamps the revision it was made on" '.comment.revision' "2" "$body"
check_json "leaves a new comment open" '.comment.addressed_in' "null" "$body"
check "writes the comment to disk" "1" "$(comment_count)"

cid=$(printf '%s' "$body" | jq -r '.comment.id')
body=$(api "?")
check_json "returns the comment with the plan" '.comments | length' "1" "$body"

check "refuses a comment with no body" "400" \
  "$(curl -sS -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
    -d '{"body":"  "}' "$API/comment?token=$token")"
check "still holds one comment" "1" "$(comment_count)"

check "deletes the comment you name" "200" \
  "$(status DELETE "$API/comment/$cid?token=$token")"
check "the comment is gone from disk" "0" "$(comment_count)"
check "404s a comment that is already gone" "404" \
  "$(status DELETE "$API/comment/$cid?token=$token")"

# -- calling Neovim back -----------------------------------------------------

: > "$MOCK_NVIM_LOG"
body=$(post "/replan")
check_json "reports the replan back to the page" '.action' "replan" "$body"
sent=$(sed -n '1p' "$MOCK_NVIM_LOG" | sed -e "s/^.*handle('//" -e "s/').*$//" | base64 --decode)
check_json "asks Neovim to replan" '.action' "replan" "$sent"
check_json "names the plan in the message" '.plan_id' "$PLAN" "$sent"

: > "$MOCK_NVIM_LOG"
check "refuses approval without the Mermaid rendering check" "409" \
  "$(status POST "$API/accept?token=$token")"
post "/accept" '{"revision":2,"diagram_check":"passed","diagram_count":0}' >/dev/null
sent=$(sed -n '1p' "$MOCK_NVIM_LOG" | sed -e "s/^.*handle('//" -e "s/').*$//" | base64 --decode)
check_json "asks Neovim to accept" '.action' "accept" "$sent"
check_json "sends the rendered revision to Neovim" '.revision' "2" "$sent"
check_json "sends the Mermaid rendering result to Neovim" '.diagram_check' "passed" "$sent"

check "404s an action it does not know" "404" "$(status POST "$API/explode?token=$token")"

# -- staying alive -----------------------------------------------------------

if kill -0 "$pid" 2>/dev/null; then
  ok "the server survived every request"
else
  no "the server survived every request" "$(cat "$root/err")"
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
