#!/bin/bash
# Run every test.
#
#   tests/run.sh              everything
#   tests/run.sh lua          the Neovim specs only
#   tests/run.sh hook         the Claude hook script tests only
#   tests/run.sh server       the Flow review server tests only
#   tests/run.sh install      the setup script tests only
#   tests/run.sh prepush      the git pre-push hook tests only
#   tests/run.sh spec/x.lua   one spec file
#
# Nothing here starts Claude, opens a network connection, or spends a token.
# The Claude terminal, the hook, and the RPC calls are all mocked.

set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
config=$(dirname "$here")
target="${1:-all}"

lua_status=0
hook_status=0
server_status=0
install_status=0
prepush_status=0

run_lua() {
  local file="$1"
  nvim --headless --noplugin -u "$here/minimal_init.lua" \
    -c "lua require('plenary.busted').run('$file')" -c "qa!" 2>&1
  return "${PIPESTATUS[0]}"
}

run_lua_suite() {
  echo
  echo "=== Neovim specs ==="
  local failed=0
  for spec in "$here"/spec/*_spec.lua; do
    local output
    output=$(run_lua "$spec")
    printf '%s\n' "$output"
    printf '%s' "$output" | grep -qE "Failed *: *[1-9]|Errors *: *[1-9]|Tests Failed" && failed=1
  done
  return "$failed"
}

case "$target" in
  all)
    run_lua_suite || lua_status=1
    bash "$here/hook/run.sh" || hook_status=1
    bash "$here/server/run.sh" || server_status=1
    bash "$here/install/run.sh" || install_status=1
    bash "$here/prepush/run.sh" || prepush_status=1
    ;;
  lua)
    run_lua_suite || lua_status=1
    ;;
  hook)
    bash "$here/hook/run.sh" || hook_status=1
    ;;
  server)
    bash "$here/server/run.sh" || server_status=1
    ;;
  install)
    bash "$here/install/run.sh" || install_status=1
    ;;
  prepush)
    bash "$here/prepush/run.sh" || prepush_status=1
    ;;
  *)
    # A single spec file, relative to tests/ or absolute.
    if [ -f "$target" ]; then
      run_lua "$target" || lua_status=1
    elif [ -f "$here/$target" ]; then
      run_lua "$here/$target" || lua_status=1
    else
      echo "No such spec: $target" >&2
      exit 2
    fi
    ;;
esac

echo
if [ "$lua_status" -eq 0 ] && [ "$hook_status" -eq 0 ] && [ "$server_status" -eq 0 ] \
  && [ "$install_status" -eq 0 ] && [ "$prepush_status" -eq 0 ]; then
  printf '\033[32mAll tests passed.\033[0m\n'
  exit 0
fi
printf '\033[31mTests failed.\033[0m\n'
exit 1
