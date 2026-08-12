#!/usr/bin/env bash
# Install per-project Claude Code account switching.
#
# Idempotent: safe to re-run after `git pull`. Touches three things —
#   1. ~/.bashrc          a marked block that sources shell/claude-profile.sh
#   2. VSCode settings    claudeCode.claudeProcessWrapper -> bin/claude-vscode-wrapper
#   3. ~/.claude-profiles created if absent; existing profiles get shared history
#
# Profile data (credentials) always stays in ~/.claude-profiles, never in this repo.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILE_ROOT="${CLAUDE_PROFILE_ROOT:-$HOME/.claude-profiles}"
BASHRC="$HOME/.bashrc"
BEGIN="# >>> claude-profile >>>"
END="# <<< claude-profile <<<"
SKIP_VSCODE=0

for arg in "$@"; do
    case "$arg" in
      --no-vscode) SKIP_VSCODE=1 ;;
      -h|--help)
        echo "usage: ./install.sh [--no-vscode]"
        exit 0 ;;
      *) echo "unknown option: $arg" >&2; exit 1 ;;
    esac
done

say()  { printf '  %s\n' "$*"; }
step() { printf '\n%s\n' "$*"; }

step "1. Scripts"
chmod +x "$REPO"/bin/* 2>/dev/null || true
say "executable: $(cd "$REPO/bin" && echo *)"

step "2. Profile data directory"
mkdir -p "$PROFILE_ROOT"
say "$PROFILE_ROOT"

# Helpers used to live in $PROFILE_ROOT/bin before the repo split. Remove that
# copy so there is one source of truth, but never touch profile directories.
if [ -d "$PROFILE_ROOT/bin" ]; then
    rm -rf "${PROFILE_ROOT:?}/bin"
    say "removed legacy $PROFILE_ROOT/bin (helpers now live in the repo)"
fi

step "3. Shell integration (~/.bashrc)"
cp "$BASHRC" "$BASHRC.bak-claude-profile-$(date +%Y%m%d%H%M%S)"
say "backed up ~/.bashrc"

# Remove a previous marked block, if any.
if grep -qF "$BEGIN" "$BASHRC"; then
    sed -i "\|^$BEGIN\$|,\|^$END\$|d" "$BASHRC"
    say "removed previous block"
fi

# Remove the pre-repo inline block, if this machine has one.
if grep -q '^# ---- Claude Code per-project profiles' "$BASHRC"; then
    sed -i '/^# ---- Claude Code per-project profiles/,/^# -\{20,\}$/d' "$BASHRC"
    say "removed legacy inline block (functions now sourced from the repo)"
fi

cat >> "$BASHRC" <<EOF
$BEGIN
export CLAUDE_PROFILE_ROOT="$PROFILE_ROOT"
[ -f "$REPO/shell/claude-profile.sh" ] && . "$REPO/shell/claude-profile.sh"
$END
EOF
say "sources $REPO/shell/claude-profile.sh"

bash -n "$BASHRC" && say "~/.bashrc parses OK"

step "4. Shared conversation history"
# shellcheck disable=SC1090
CLAUDE_PROFILE_ROOT="$PROFILE_ROOT" . "$REPO/shell/claude-profile.sh"
found=0
for d in "$PROFILE_ROOT"/*/; do
    [ -d "$d" ] || continue
    name=${d%/}; name=${name##*/}
    _claude_reserved_name "$name" && continue
    _claude_link_shared "$d"
    say "$name -> shares ~/.claude/{projects,file-history,session-env}"
    found=1
done
[ "$found" -eq 0 ] && say "no profiles yet — create one with: claude-profile new <name>"
true  # keep `set -e` from tripping on the test above when profiles do exist

step "5. VSCode extension"
if [ "$SKIP_VSCODE" -eq 1 ]; then
    say "skipped (--no-vscode)"
else
    WRAPPER="$REPO/bin/claude-vscode-wrapper"
    # A machine can host several VSCode servers at once — code-server for the
    # browser, .vscode-server for Remote-SSH, native VSCode. Each keeps its own
    # settings, and you cannot tell from here which one the user will open.
    # Update every settings file that exists; stopping at the first leaves a
    # stale wrapper path behind, which breaks that editor at launch.
    if ! command -v python3 >/dev/null; then
        say "python3 not found — set this by hand in your VSCode settings.json:"
        say "  \"claudeCode.claudeProcessWrapper\": \"$WRAPPER\""
    else
        updated=0
        for SETTINGS in \
            "$HOME/.local/share/code-server/User/settings.json" \
            "$HOME/.vscode-server/data/Machine/settings.json" \
            "$HOME/.vscode-server/data/User/settings.json" \
            "$HOME/.config/Code/User/settings.json"; do
            [ -f "$SETTINGS" ] || continue
            cp "$SETTINGS" "$SETTINGS.bak-claude-profile"
            python3 - "$SETTINGS" "$WRAPPER" <<'PY'
import json, sys
path, wrapper = sys.argv[1], sys.argv[2]
with open(path) as fh:
    data = json.load(fh)
data["claudeCode.claudeProcessWrapper"] = wrapper
with open(path, "w") as fh:
    json.dump(data, fh, indent=4)
    fh.write("\n")
PY
            say "set in $SETTINGS"
            updated=$((updated + 1))
        done

        if [ "$updated" -eq 0 ]; then
            say "no VSCode settings.json found — skipping."
            say "the shell integration works regardless; the extension panel will"
            say "use your default account until you set, in your settings.json:"
            say "  \"claudeCode.claudeProcessWrapper\": \"$WRAPPER\""
        else
            say "updated $updated settings file(s), each backed up as *.bak-claude-profile"
            say "RELOAD THE VSCODE WINDOW for this to take effect"
        fi
    fi
fi

step "Done."
say "run 'exec bash', then 'claude-profile list'"
