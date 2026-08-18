#!/usr/bin/env bash
# Remove per-project Claude Code account switching.
#
# By default this removes only the *integration* — shell hook and VSCode setting.
# Your profiles and their logins in ~/.claude-profiles are left alone, as is your
# default account in ~/.claude.
#
#   ./uninstall.sh            remove integration, keep all profile data
#   ./uninstall.sh --purge    also delete ~/.claude-profiles (logins included)
#
# Conversation history is never deleted: profiles hold symlinks to
# ~/.claude/{projects,file-history,session-env}, and removing a symlink does not
# touch its target.

set -euo pipefail

PROFILE_ROOT="${CLAUDE_PROFILE_ROOT:-$HOME/.claude-profiles}"
BASHRC="$HOME/.bashrc"
BEGIN="# >>> claude-profile >>>"
END="# <<< claude-profile <<<"
PURGE=0

for arg in "$@"; do
    case "$arg" in
      --purge) PURGE=1 ;;
      -h|--help)
        echo "usage: ./uninstall.sh [--purge]"
        echo "  --purge  also delete $PROFILE_ROOT (logins included)"
        exit 0 ;;
      *) echo "unknown option: $arg" >&2; exit 1 ;;
    esac
done

say()  { printf '  %s\n' "$*"; }
step() { printf '\n%s\n' "$*"; }

step "1. Shell integration"
if grep -qF "$BEGIN" "$BASHRC" 2>/dev/null; then
    cp "$BASHRC" "$BASHRC.bak-claude-profile-uninstall-$(date +%Y%m%d%H%M%S)"
    sed -i "\|^$BEGIN\$|,\|^$END\$|d" "$BASHRC"
    bash -n "$BASHRC" && say "removed from ~/.bashrc (parses OK)"
else
    say "nothing in ~/.bashrc"
fi
if grep -q '^# ---- Claude Code per-project profiles' "$BASHRC" 2>/dev/null; then
    sed -i '/^# ---- Claude Code per-project profiles/,/^# -\{20,\}$/d' "$BASHRC"
    bash -n "$BASHRC" && say "removed legacy inline block"
fi

step "2. VSCode extension"
removed=0
for SETTINGS in \
    "$HOME/.local/share/code-server/User/settings.json" \
    "$HOME/.vscode-server/data/Machine/settings.json" \
    "$HOME/.vscode-server/data/User/settings.json" \
    "$HOME/.config/Code/User/settings.json"; do
    [ -f "$SETTINGS" ] || continue
    grep -q 'claudeProcessWrapper' "$SETTINGS" || continue
    if command -v python3 >/dev/null; then
        cp "$SETTINGS" "$SETTINGS.bak-claude-profile-uninstall"
        python3 - "$SETTINGS" <<'PY'
import json, sys
path = sys.argv[1]
with open(path) as fh:
    data = json.load(fh)
data.pop("claudeCode.claudeProcessWrapper", None)
with open(path, "w") as fh:
    json.dump(data, fh, indent=4)
    fh.write("\n")
PY
        say "cleared claudeProcessWrapper in $SETTINGS"
        removed=1
    else
        say "python3 missing — remove claudeCode.claudeProcessWrapper from"
        say "  $SETTINGS  by hand"
    fi
done
[ "$removed" -eq 1 ] && say "RELOAD THE VSCODE WINDOW" || say "nothing to clear"

step "3. Profile data"
if [ "$PURGE" -eq 1 ]; then
    if [ -d "$PROFILE_ROOT" ]; then
        # Drop the symlinks first so nothing can walk into shared history.
        find "$PROFILE_ROOT" -maxdepth 2 -type l -delete 2>/dev/null || true
        rm -rf "${PROFILE_ROOT:?}"
        say "deleted $PROFILE_ROOT (profile logins removed)"
    else
        say "$PROFILE_ROOT does not exist"
    fi
    say "~/.claude and all conversation history are untouched"
else
    if [ -d "$PROFILE_ROOT" ]; then
        say "kept $PROFILE_ROOT"
        say "re-run with --purge to delete it, or remove it by hand"
    else
        say "$PROFILE_ROOT does not exist"
    fi
fi

step "Done."
say "run 'exec bash' — 'claude' now always uses your default account"
