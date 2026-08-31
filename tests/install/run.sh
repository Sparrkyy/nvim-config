#!/bin/bash
# Tests for install.sh.
#
# Every run uses a throwaway HOME, so no test reads or writes the settings.json
# you actually use. Nothing here starts Claude or opens a network connection.

set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
config=$(dirname "$(dirname "$here")")
INSTALL="$config/install.sh"

pass=0
fail=0
failures=()

root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT

ok() { pass=$((pass + 1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
no() {
  fail=$((fail + 1))
  failures+=("$1")
  printf '  \033[31mFAIL\033[0m %s\n' "$1"
  [ -n "${2:-}" ] && printf '       %s\n' "$2"
}
check() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "expected [$2], got [$3]"; fi; }

# A fresh fake home for one case. $HOME is set for the install run only.
fresh() {
  home="$root/home-$RANDOM"
  mkdir -p "$home/.claude"
  [ -n "${1:-}" ] && printf '%s' "$1" > "$home/.claude/settings.json"
  echo "$home"
}

install_into() {
  HOME="$1" bash "$INSTALL" "${@:2}" 2>&1
}

# How many hook entries name our script.
entries() {
  python3 -c "
import json,sys
try: s=json.load(open('$1/.claude/settings.json'))
except Exception: print(0); sys.exit()
n=0
for arr in s.get('hooks',{}).values():
    for m in arr:
        n += sum(1 for h in m.get('hooks',[]) if 'nvim-follow.sh' in str(h.get('command','')))
print(n)
"
}

# Read one key out of the fake settings.
key() {
  python3 -c "
import json
try: print(json.load(open('$1/.claude/settings.json')).get('$2',''))
except Exception: print('')
"
}

echo
echo "install.sh"
echo

# -- the repository has what it installs --------------------------------------

[ -f "$config/claude/nvim-follow.sh" ] \
  && ok "the Claude hook is in the repository" \
  || no "the Claude hook is in the repository"
[ -x "$config/claude/nvim-follow.sh" ] \
  && ok "the hook is executable" \
  || no "the hook is executable"
bash -n "$config/claude/nvim-follow.sh" 2>/dev/null \
  && ok "the hook parses" \
  || no "the hook parses"
python3 -c "import json;json.load(open('$config/claude/hooks.json'))" 2>/dev/null \
  && ok "hooks.json is valid JSON" \
  || no "hooks.json is valid JSON"

# -- a machine with no Claude settings at all ---------------------------------

home=$(fresh)
out=$(install_into "$home")
check "installs onto a machine with no settings.json" "11" "$(entries "$home")"
[ -L "$home/.claude/hooks/nvim-follow.sh" ] \
  && ok "links the hook instead of copying it, so a pull updates it" \
  || no "links the hook instead of copying it, so a pull updates it"
check "the link points into the repository" \
  "$config/claude/nvim-follow.sh" "$(readlink "$home/.claude/hooks/nvim-follow.sh")"

# -- it keeps the settings you already had ------------------------------------

home=$(fresh '{"model":"opus","effortLevel":"high"}')
install_into "$home" >/dev/null
check "keeps an unrelated setting" "opus" "$(key "$home" model)"
check "keeps a second unrelated setting" "high" "$(key "$home" effortLevel)"
check "and still registers the hooks" "11" "$(entries "$home")"
ls "$home/.claude/settings.json.bak."* >/dev/null 2>&1 \
  && ok "backs the settings up before it writes" \
  || no "backs the settings up before it writes"

# -- it leaves other people's hooks alone -------------------------------------

home=$(fresh '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/opt/other.sh"}]}]}}')
install_into "$home" >/dev/null
other=$(python3 -c "
import json
s=json.load(open('$home/.claude/settings.json'))
print(sum(1 for a in s['hooks'].values() for m in a for h in m['hooks'] if h['command']=='/opt/other.sh'))
")
check "keeps a hook somebody else registered" "1" "$other"
check "and adds its own beside it" "11" "$(entries "$home")"

# -- running it twice ---------------------------------------------------------

home=$(fresh)
install_into "$home" >/dev/null
out=$(install_into "$home")
check "running it again does not double the entries" "11" "$(entries "$home")"
printf '%s' "$out" | grep -q "already registered" \
  && ok "and says so instead of writing again" \
  || no "and says so instead of writing again"
printf '%s' "$out" | grep -q "already points at this repository" \
  && ok "and leaves the link alone" \
  || no "and leaves the link alone"

# -- a stale entry from a repository that moved -------------------------------

home=$(fresh '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/old/place/nvim-follow.sh"}]}]}}')
install_into "$home" >/dev/null
stale=$(python3 -c "
import json
s=json.load(open('$home/.claude/settings.json'))
print(sum(1 for a in s['hooks'].values() for m in a for h in m['hooks'] if '/old/place/' in h['command']))
")
check "drops an entry left by a repository that moved" "0" "$stale"
check "and registers the current path" "11" "$(entries "$home")"

# -- an existing real file is kept --------------------------------------------

home=$(fresh)
mkdir -p "$home/.claude/hooks"
printf 'echo mine\n' > "$home/.claude/hooks/nvim-follow.sh"
install_into "$home" >/dev/null
[ -f "$home/.claude/hooks/nvim-follow.sh.before-install" ] \
  && ok "keeps a hook you wrote yourself instead of losing it" \
  || no "keeps a hook you wrote yourself instead of losing it"

# -- dry run ------------------------------------------------------------------

home=$(fresh)
out=$(install_into "$home" --dry-run)
check "a dry run writes no settings" "0" "$(entries "$home")"
[ ! -e "$home/.claude/hooks/nvim-follow.sh" ] \
  && ok "a dry run makes no link" \
  || no "a dry run makes no link"
printf '%s' "$out" | grep -q "would" \
  && ok "a dry run says what it would do" \
  || no "a dry run says what it would do"

# -- uninstall ----------------------------------------------------------------

home=$(fresh '{"model":"opus"}')
install_into "$home" >/dev/null
install_into "$home" --uninstall >/dev/null
check "uninstall removes every entry" "0" "$(entries "$home")"
[ ! -e "$home/.claude/hooks/nvim-follow.sh" ] \
  && ok "uninstall removes the link" \
  || no "uninstall removes the link"
check "uninstall keeps the rest of your settings" "opus" "$(key "$home" model)"

# -- broken settings ----------------------------------------------------------

home=$(fresh 'this is not json {{{')
out=$(install_into "$home")
check "refuses to touch settings it cannot parse" "1" "$?"
printf '%s' "$out" | grep -q "not valid JSON" \
  && ok "and says why" \
  || no "and says why"
check "and leaves the file alone" "this is not json {{{" "$(cat "$home/.claude/settings.json")"

# ------------------------------------------------------------------- summary

echo
printf '  %d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -gt 0 ]; then
  echo
  for f in "${failures[@]}"; do printf '  failed: %s\n' "$f"; done
  exit 1
fi
exit 0
