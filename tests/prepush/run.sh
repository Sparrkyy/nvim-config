#!/bin/bash
# Tests for .githooks/pre-push.
#
# The hook runs inside a throwaway repository, against a fake tests/run.sh
# that records its calls. The real suite never runs from here, so these tests
# finish in under a second. No push reaches GitHub.

set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
config=$(dirname "$(dirname "$here")")
HOOK="${PREPUSH_HOOK:-$config/.githooks/pre-push}"

pass=0
fail=0
failures=()

# ------------------------------------------------------------------ scaffold

root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT

repo="$root/repo"
mkdir -p "$repo/tests"
git -C "$repo" init -q
export MOCK_SUITE_LOG="$root/suite.log"

# Stand in for the real suite. MOCK_SUITE_EXIT decides whether it passes.
cat > "$repo/tests/run.sh" <<'MOCK'
#!/bin/bash
echo "ran" >> "$MOCK_SUITE_LOG"
exit "${MOCK_SUITE_EXIT:-0}"
MOCK
chmod +x "$repo/tests/run.sh"

# ------------------------------------------------------------------- helpers

sha="1111111111111111111111111111111111111111"
zero="0000000000000000000000000000000000000000"

# run <exit-code-of-the-suite> <stdin> -> the exit status of the hook.
# Git ends each ref line with a newline, so this adds one. The output of the
# hook goes to $out.
run() {
  : > "$MOCK_SUITE_LOG"
  out=$(cd "$repo" && printf '%s\n' "$2" | MOCK_SUITE_EXIT="$1" bash "$HOOK" 2>&1)
  return_status=$?
  return $return_status
}

# The same, with no newline after the last ref.
run_unterminated() {
  : > "$MOCK_SUITE_LOG"
  out=$(cd "$repo" && printf '%s' "$2" | MOCK_SUITE_EXIT="$1" bash "$HOOK" 2>&1)
  return_status=$?
  return $return_status
}

suite_runs() {
  [ -f "$MOCK_SUITE_LOG" ] || { echo 0; return; }
  awk 'NF { n++ } END { print n + 0 }' "$MOCK_SUITE_LOG"
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

echo
echo "pre-push"
echo

# --------------------------------------------------------------------- tests

# -- a normal push -----------------------------------------------------------

run 0 "refs/heads/main $sha refs/heads/main $zero"
check "lets the push through when the tests pass" "0" "$?"
check "runs the suite once" "1" "$(suite_runs)"

run 0 "refs/heads/main $sha refs/heads/main $zero"
case "$out" in
  *"--no-verify"*) ok "says how to skip the suite" ;;
  *) no "says how to skip the suite" "got [$out]" ;;
esac

# -- a failing suite ---------------------------------------------------------

run 1 "refs/heads/main $sha refs/heads/main $zero"
check "stops the push when the tests fail" "1" "$?"

run 1 "refs/heads/main $sha refs/heads/main $zero"
case "$out" in
  *"push stopped"*) ok "says why the push stopped" ;;
  *) no "says why the push stopped" "got [$out]" ;;
esac

# -- a branch deletion -------------------------------------------------------

run 0 "(delete) $zero refs/heads/old $sha"
check "lets a branch deletion through" "0" "$?"
check "runs no tests for a branch deletion" "0" "$(suite_runs)"

# -- several refs at once ----------------------------------------------------

run 0 "refs/heads/main $sha refs/heads/main $zero
refs/heads/topic $sha refs/heads/topic $zero"
check "runs the suite once for a push of two branches" "1" "$(suite_runs)"

run 0 "(delete) $zero refs/heads/old $sha
refs/heads/main $sha refs/heads/main $zero"
check "tests a push that deletes one branch and updates another" "1" "$(suite_runs)"

# -- an empty push -----------------------------------------------------------

run_unterminated 0 ""
check "lets a push with nothing to send through" "0" "$?"
check "runs no tests when there is nothing to send" "0" "$(suite_runs)"

# -- a last line with no newline ---------------------------------------------

run_unterminated 0 "refs/heads/main $sha refs/heads/main $zero"
check "tests a ref that arrives without a trailing newline" "1" "$(suite_runs)"

run_unterminated 0 "(delete) $zero refs/heads/old $sha"
check "reads no ref twice" "0" "$(suite_runs)"

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
