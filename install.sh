#!/bin/bash
# Set this configuration up on a machine.
#
# Neovim finds lua/ on its own once the repository sits at ~/.config/nvim.
# Two things live outside it and this script puts them in place:
#
#   1. the git hook that runs the test suite before a push
#   2. the Claude Code hook that lets Claude drive the editor
#
# The Claude hook is installed as a symlink into ~/.claude/hooks/, so a later
# `git pull` updates it with everything else. Your ~/.claude/settings.json is
# backed up before it changes, and only the nvim-follow entries are touched.
#
#   ./install.sh              install
#   ./install.sh --dry-run    say what would change, change nothing
#   ./install.sh --uninstall  take the hook and its settings back out

set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
hook_src="$here/claude/nvim-follow.sh"
hook_dst="$HOME/.claude/hooks/nvim-follow.sh"
settings="$HOME/.claude/settings.json"

mode="install"
for arg in "$@"; do
  case "$arg" in
    --dry-run) mode="dry" ;;
    --uninstall) mode="uninstall" ;;
    -h|--help) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

say() { printf '  %s\n' "$1"; }
did() { printf '  \033[32m✓\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }
run() { [ "$mode" = "dry" ] && { say "would $1"; return 0; }; return 1; }

echo
echo "Neovim configuration setup"
echo

# ------------------------------------------------------------------ what it needs

for tool in nvim git; do
  command -v "$tool" >/dev/null 2>&1 || { warn "$tool is missing. Install it first."; exit 1; }
done
did "nvim and git are here"

for tool in jq node claude; do
  if command -v "$tool" >/dev/null 2>&1; then
    did "$tool is here"
  else
    case "$tool" in
      jq) warn "jq is missing. Claude will not be able to drive the editor." ;;
      node) warn "node is missing. Flow cannot show a plan in the browser." ;;
      claude) warn "the claude CLI is missing. The AI features stay quiet." ;;
    esac
  fi
done

# ------------------------------------------------------------------ the git hook

if [ "$(git -C "$here" config core.hooksPath 2>/dev/null)" = ".githooks" ]; then
  did "the pre-push hook is already set"
elif run "point git at .githooks"; then :; else
  git -C "$here" config core.hooksPath .githooks && did "pointed git at .githooks"
fi

# ------------------------------------------------------------------ the claude hook

if [ ! -f "$hook_src" ]; then
  warn "claude/nvim-follow.sh is missing from the repository"
  exit 1
fi

if [ "$mode" = "uninstall" ]; then
  if [ -L "$hook_dst" ] || [ -f "$hook_dst" ]; then
    rm -f "$hook_dst" && did "removed $hook_dst"
  else
    say "no hook to remove"
  fi
elif [ "$(readlink "$hook_dst" 2>/dev/null)" = "$hook_src" ]; then
  did "the Claude hook already points at this repository"
elif run "link $hook_dst -> $hook_src"; then :; else
  mkdir -p "$(dirname "$hook_dst")"
  # A real file here is someone's earlier copy. Keep it, do not silently lose it.
  if [ -f "$hook_dst" ] && [ ! -L "$hook_dst" ]; then
    mv "$hook_dst" "$hook_dst.before-install"
    warn "kept your old hook as $hook_dst.before-install"
  fi
  ln -sf "$hook_src" "$hook_dst" && did "linked the Claude hook to this repository"
fi

# ------------------------------------------------------------------ the settings

python3 - "$settings" "$here/claude/hooks.json" "$hook_dst" "$mode" <<'PY'
import json, os, shutil, sys, datetime

settings_path, fragment_path, hook_path, mode = sys.argv[1:5]

def say(icon, colour, msg):
    print(f"  \033[{colour}m{icon}\033[0m {msg}")

settings = {}
if os.path.exists(settings_path):
    try:
        settings = json.load(open(settings_path))
    except json.JSONDecodeError:
        say("!", "33", f"{settings_path} is not valid JSON. Fix it, then run this again.")
        sys.exit(1)

def is_ours(hook):
    return "nvim-follow.sh" in str(hook.get("command", ""))

# Take every nvim-follow entry out first, so running this twice is a no-op and
# a moved repository does not leave a stale command behind.
hooks = settings.get("hooks", {})
removed = 0
for event in list(hooks):
    kept = []
    for matcher in hooks[event]:
        ours = [h for h in matcher.get("hooks", []) if is_ours(h)]
        removed += len(ours)
        rest = [h for h in matcher.get("hooks", []) if not is_ours(h)]
        if rest:
            kept.append({**matcher, "hooks": rest})
    if kept:
        hooks[event] = kept
    else:
        del hooks[event]

if mode == "uninstall":
    wanted = 0
else:
    fragment = json.load(open(fragment_path))["hooks"]
    wanted = 0
    for event, matchers in fragment.items():
        for matcher in matchers:
            entry = dict(matcher)
            entry["hooks"] = [{**h, "command": hook_path} for h in matcher["hooks"]]
            hooks.setdefault(event, []).append(entry)
            wanted += len(entry["hooks"])

if hooks:
    settings["hooks"] = hooks
else:
    settings.pop("hooks", None)

if removed == wanted and mode != "uninstall":
    say("✓", "32", f"the {wanted} Claude hook entries are already registered")
    sys.exit(0)

if mode == "dry":
    verb = "remove" if mode == "uninstall" else "register"
    print(f"  would {verb} {wanted or removed} hook entries in {settings_path}")
    sys.exit(0)

os.makedirs(os.path.dirname(settings_path), exist_ok=True)
if os.path.exists(settings_path):
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    backup = f"{settings_path}.bak.{stamp}"
    shutil.copy2(settings_path, backup)
    say("✓", "32", f"backed your settings up to {os.path.basename(backup)}")

with open(settings_path, "w") as f:
    json.dump(settings, f, indent=2)
    f.write("\n")

if mode == "uninstall":
    say("✓", "32", f"removed {removed} hook entries from settings.json")
else:
    say("✓", "32", f"registered {wanted} hook entries in settings.json")
PY
status=$?

echo
if [ "$mode" = "dry" ]; then
  echo "Nothing changed. Drop --dry-run to do it."
elif [ "$mode" = "uninstall" ]; then
  echo "Removed. Restart Claude Code for it to notice."
elif [ "$status" -eq 0 ]; then
  echo "Done. Start nvim; lazy.nvim installs the plugins on the first run."
  echo "Restart Claude Code so it picks the hooks up."
fi
echo
exit "$status"
