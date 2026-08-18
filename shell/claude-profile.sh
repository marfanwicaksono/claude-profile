# Claude Code per-project profiles — shell integration.
#
# Sourced from ~/.bashrc by install.sh. Looks for a `.claude-profile` file in
# the current directory or any parent; its contents name a profile under
# $CLAUDE_PROFILE_ROOT, which becomes CLAUDE_CONFIG_DIR for that launch.
# No `.claude-profile` found -> the normal default account (~/.claude).

# Where profile data (credentials, settings, per-profile config) lives.
# Never inside the git repo — these directories hold live OAuth tokens.
: "${CLAUDE_PROFILE_ROOT:=$HOME/.claude-profiles}"

# Where this repo lives, so the helper scripts can be found.
_CLAUDE_PROFILE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)"

# Names under $CLAUDE_PROFILE_ROOT that are support files, not profiles.
# `bin` is legacy (helpers used to live there before the repo split).
_claude_reserved_name() {
    case "$1" in
      bin) return 0 ;;
      *)   return 1 ;;
    esac
}

# Conversation history is deliberately SHARED across profiles: these dirs are
# symlinked to the default account's, so every profile shows one session list.
# Credentials, settings and MCP servers stay per-profile.
_claude_shared_dirs="projects file-history session-env"

_claude_link_shared() {
    local d="$1" sub
    [ -d "$d" ] || return 1
    for sub in $_claude_shared_dirs; do
        [ -L "$d/$sub" ] && continue
        if [ -d "$d/$sub" ]; then
            # Real directory with content: fold it into the shared store first
            # so nothing is lost, then replace it with the link.
            cp -rn "$d/$sub/." "$HOME/.claude/$sub/" 2>/dev/null || true
            rm -rf "${d:?}/$sub"
        fi
        mkdir -p "$HOME/.claude/$sub"
        ln -s "$HOME/.claude/$sub" "$d/$sub"
    done
}

_claude_resolve_profile() {
    # echoes "<name>\t<dir>" for the nearest .claude-profile, or nothing
    local d="$PWD" name
    while [ -n "$d" ] && [ "$d" != "/" ]; do
        if [ -r "$d/.claude-profile" ]; then
            name=$(tr -d '[:space:]' < "$d/.claude-profile")
            [ -n "$name" ] && printf '%s\t%s\n' "$name" "$d"
            return
        fi
        d=${d%/*}
    done
    [ -r "/.claude-profile" ] && {
        name=$(tr -d '[:space:]' < "/.claude-profile")
        [ -n "$name" ] && printf '%s\t%s\n' "$name" "/"
    }
}

claude() {
    local found name profile_dir api_key_file
    found=$(_claude_resolve_profile)
    name=${found%%$'\t'*}
    if [ -z "$found" ]; then
        command claude "$@"
    elif [ -d "$CLAUDE_PROFILE_ROOT/$name" ]; then
        profile_dir="$CLAUDE_PROFILE_ROOT/$name"
        api_key_file="$profile_dir/.api-key"

        # Check if this profile uses API key authentication
        if [ -f "$api_key_file" ]; then
            ANTHROPIC_API_KEY=$(cat "$api_key_file") \
            CLAUDE_CONFIG_DIR="$profile_dir" command claude "$@"
        else
            # OAuth authentication
            CLAUDE_CONFIG_DIR="$profile_dir" command claude "$@"
        fi
    else
        printf 'claude: profile %s not found in %s\n' "$name" "$CLAUDE_PROFILE_ROOT" >&2
        printf "claude: run 'claude-profile new %s' first, or fix %s\n" \
               "$name" "${found#*$'\t'}/.claude-profile" >&2
        return 1
    fi
}

claude-profile() {
    local found name dir lister
    lister="$_CLAUDE_PROFILE_HOME/bin/claude-profile-list"
    case "$1" in
      new)
        [ -z "$2" ] && { echo "usage: claude-profile new <name>" >&2; return 1; }
        _claude_reserved_name "$2" && {
            echo "claude-profile: '$2' is reserved (not a profile)" >&2; return 1; }
        mkdir -p "$CLAUDE_PROFILE_ROOT/$2" || return 1
        _claude_link_shared "$CLAUDE_PROFILE_ROOT/$2"
        echo "created $CLAUDE_PROFILE_ROOT/$2 (history shared with default account)"
        echo ""
        echo "authenticate with OAuth:  CLAUDE_CONFIG_DIR=$CLAUDE_PROFILE_ROOT/$2 claude auth login"
        echo "      or with API key:  claude-profile api-key $2"
        ;;
      api-key)
        [ -z "$2" ] && { echo "usage: claude-profile api-key <name>" >&2; return 1; }
        if [ ! -d "$CLAUDE_PROFILE_ROOT/$2" ]; then
            echo "claude-profile: profile '$2' does not exist" >&2
            echo "claude-profile: run 'claude-profile new $2' first" >&2
            return 1
        fi
        local profile_dir="$CLAUDE_PROFILE_ROOT/$2"
        echo "Enter API key for profile '$2':"
        read -rs api_key
        if [ -z "$api_key" ]; then
            echo "claude-profile: no API key provided" >&2
            return 1
        fi
        # Create .api-key file to mark this as API key auth
        echo "$api_key" > "$profile_dir/.api-key"
        chmod 600 "$profile_dir/.api-key"
        # Create a minimal .claude.json to mark it as configured
        if [ ! -f "$profile_dir/.claude.json" ]; then
            echo '{"authMethod":"apiKey"}' > "$profile_dir/.claude.json"
        fi
        echo "API key set for profile '$2'"
        echo "Launch with: ANTHROPIC_API_KEY=\$(cat $profile_dir/.api-key) claude"
        ;;
      use)
        [ -z "$2" ] && { echo "usage: claude-profile use <name>" >&2; return 1; }
        echo "$2" > .claude-profile && echo "$PWD -> profile '$2'"
        ;;
      list|ls)
        if [ -x "$lister" ]; then
            # Resolve here rather than in the helper so there is one definition
            # of "which profile applies", shared with `claude` and `status`.
            found=$(_claude_resolve_profile)
            name=${found%%$'\t'*}
            CLAUDE_PROFILE_ROOT="$CLAUDE_PROFILE_ROOT" \
            CLAUDE_ACTIVE_PROFILE="${name:-default}" "$lister"
        else
            # Fallback if the helper is missing: names and login state only.
            if [ -d "$CLAUDE_PROFILE_ROOT" ]; then
                for dir in "$CLAUDE_PROFILE_ROOT"/*/; do
                    [ -d "$dir" ] || continue
                    name=${dir%/}; name=${name##*/}
                    _claude_reserved_name "$name" && continue
                    if [ -f "$dir/.credentials.json" ]; then
                        echo "  $name (logged in)"
                    else
                        echo "  $name (NOT logged in)"
                    fi
                done
            fi
            echo "  default: ~/.claude"
        fi
        ;;
      ""|status)
        found=$(_claude_resolve_profile)
        if [ -z "$found" ]; then
            echo "profile: default (no .claude-profile here or above)"
            echo "config:  $HOME/.claude"
            [ -x "$lister" ] && echo "account: $(CLAUDE_PROFILE_ROOT="$CLAUDE_PROFILE_ROOT" "$lister" --account default)"
        else
            name=${found%%$'\t'*}
            echo "profile: $name (from ${found#*$'\t'}/.claude-profile)"
            echo "config:  $CLAUDE_PROFILE_ROOT/$name"
            if [ -d "$CLAUDE_PROFILE_ROOT/$name" ]; then
                [ -x "$lister" ] && echo "account: $(CLAUDE_PROFILE_ROOT="$CLAUDE_PROFILE_ROOT" "$lister" --account "$name")"
            else
                echo "account: WARNING - $CLAUDE_PROFILE_ROOT/$name does not exist"
            fi
        fi
        ;;
      *)
        echo "usage: claude-profile [status|list|new <name>|use <name>|api-key <name>]" >&2
        return 1
        ;;
    esac
}
