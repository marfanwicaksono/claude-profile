# Claude Code per-project profiles — shell integration.
#
# Sourced from ~/.bashrc by install.sh. Looks for a `.claude-profile` file in
# the current directory or any parent; its contents name a profile under
# $CLAUDE_PROFILE_ROOT, which becomes CLAUDE_CONFIG_DIR for that launch.
# No `.claude-profile` found -> the normal default account (~/.claude).
#
# A profile authenticates one of two ways:
#   OAuth    `claude auth login` writes .credentials.json into the config dir
#   API key  .api-key holds the key, .api-base-url optionally points it at a
#            gateway or proxy instead of api.anthropic.com
# Both API-key files are read at launch and exported, because auth resolves
# before any config file is read.

# Where profile data (credentials, settings, per-profile config) lives.
# Never inside the git repo — these directories hold live tokens and API keys.
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

# First line of a file with surrounding whitespace stripped, or nothing.
# Keys and URLs pasted through an editor often pick up a stray space or newline,
# and an API key with a trailing space fails authentication in a way that gives
# no useful error, so trim rather than trust the file byte-for-byte.
_claude_first_line() {
    local v=""
    [ -r "$1" ] || return 1
    IFS= read -r v < "$1" 2>/dev/null
    v=${v#"${v%%[![:space:]]*}"}
    v=${v%"${v##*[![:space:]]}"}
    [ -n "$v" ] && printf '%s\n' "$v"
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
    local found name profile_dir key url
    found=$(_claude_resolve_profile)
    name=${found%%$'\t'*}

    if [ -z "$found" ]; then
        command claude "$@"
        return
    fi

    profile_dir="$CLAUDE_PROFILE_ROOT/$name"
    if [ ! -d "$profile_dir" ]; then
        printf 'claude: profile %s not found in %s\n' "$name" "$CLAUDE_PROFILE_ROOT" >&2
        printf "claude: run 'claude-profile new %s' first, or fix %s\n" \
               "$name" "${found#*$'\t'}/.claude-profile" >&2
        return 1
    fi

    key=$(_claude_first_line "$profile_dir/.api-key")
    if [ -z "$key" ]; then
        CLAUDE_CONFIG_DIR="$profile_dir" command claude "$@"
        return
    fi

    # API-key profile. A subshell keeps the key out of the interactive shell's
    # environment — it exists only for the life of this launch.
    url=$(_claude_first_line "$profile_dir/.api-base-url")
    (
        export CLAUDE_CONFIG_DIR="$profile_dir"
        export ANTHROPIC_API_KEY="$key"
        [ -n "$url" ] && export ANTHROPIC_BASE_URL="$url"
        command claude "$@"
    )
}

# Warn when a base URL is not Anthropic's own API. Not a refusal — gateways and
# proxies are a normal setup — but the destination of your prompts is worth
# stating out loud rather than burying in a config file.
_claude_note_base_url() {
    case "$1" in
      ""|https://api.anthropic.com|https://api.anthropic.com/*) return 0 ;;
      *) printf 'note: this profile sends requests to %s, not Anthropic'\''s API.\n' "$1" ;;
    esac
}

claude-profile() {
    local found name dir lister pname burl key remove
    lister="$_CLAUDE_PROFILE_HOME/bin/claude-profile-list"
    case "$1" in
      new)
        [ -z "$2" ] && { echo "usage: claude-profile new <name>" >&2; return 1; }
        _claude_reserved_name "$2" && {
            echo "claude-profile: '$2' is reserved (not a profile)" >&2; return 1; }
        mkdir -p "$CLAUDE_PROFILE_ROOT/$2" || return 1
        _claude_link_shared "$CLAUDE_PROFILE_ROOT/$2"
        echo "created $CLAUDE_PROFILE_ROOT/$2 (history shared with default account)"
        echo "authenticate it, either:"
        echo "  OAuth    CLAUDE_CONFIG_DIR=$CLAUDE_PROFILE_ROOT/$2 claude auth login"
        echo "  API key  claude-profile api-key $2 [--base-url URL]"
        ;;
      api-key)
        pname=""; burl=""; remove=0; key=""
        shift
        while [ $# -gt 0 ]; do
            case "$1" in
              --base-url)
                [ -z "$2" ] && { echo "claude-profile: --base-url needs a URL" >&2; return 1; }
                burl="$2"; shift 2 ;;
              --remove|--clear) remove=1; shift ;;
              -*) echo "claude-profile: unknown option $1" >&2; return 1 ;;
              *)
                if [ -z "$pname" ]; then pname="$1"; shift
                else echo "claude-profile: unexpected argument $1" >&2; return 1; fi ;;
            esac
        done
        [ -z "$pname" ] && {
            echo "usage: claude-profile api-key <name> [--base-url URL] [--remove]" >&2
            return 1; }
        dir="$CLAUDE_PROFILE_ROOT/$pname"
        [ -d "$dir" ] || {
            echo "claude-profile: profile '$pname' does not exist" >&2
            echo "claude-profile: run 'claude-profile new $pname' first" >&2
            return 1; }

        if [ "$remove" -eq 1 ]; then
            rm -f "$dir/.api-key" "$dir/.api-base-url"
            echo "removed the API key from '$pname'; it falls back to OAuth"
            echo "log in with:  CLAUDE_CONFIG_DIR=$dir claude auth login"
            return 0
        fi

        # A tty prompts with the key hidden; a pipe reads it from stdin so the
        # profile can be provisioned from a script or secret store:
        #   printf %s "$KEY" | claude-profile api-key work --base-url https://...
        if [ -t 0 ]; then
            printf 'API key for profile %s (input hidden): ' "$pname"
            IFS= read -rs key
            printf '\n'
        else
            IFS= read -r key
        fi
        [ -n "$key" ] || { echo "claude-profile: no API key given" >&2; return 1; }

        # umask inside the subshell so the file is never briefly world-readable.
        ( umask 077; printf '%s\n' "$key" > "$dir/.api-key" ) || return 1
        chmod 600 "$dir/.api-key"
        key=""

        if [ -n "$burl" ]; then
            ( umask 077; printf '%s\n' "$burl" > "$dir/.api-base-url" )
        fi
        burl=$(_claude_first_line "$dir/.api-base-url")

        if [ -n "$burl" ]; then
            echo "API key set for '$pname' (via $burl)"
        else
            echo "API key set for '$pname'"
        fi
        _claude_note_base_url "$burl"
        ;;
      base-url)
        [ -z "$2" ] && { echo "usage: claude-profile base-url <name> [URL|--remove]" >&2; return 1; }
        dir="$CLAUDE_PROFILE_ROOT/$2"
        [ -d "$dir" ] || { echo "claude-profile: profile '$2' does not exist" >&2; return 1; }
        case "$3" in
          "")
            burl=$(_claude_first_line "$dir/.api-base-url")
            if [ -n "$burl" ]; then echo "$burl"; else echo "(default: Anthropic API)"; fi ;;
          --remove|--clear)
            rm -f "$dir/.api-base-url"
            echo "'$2' now uses the default Anthropic API endpoint" ;;
          *)
            ( umask 077; printf '%s\n' "$3" > "$dir/.api-base-url" )
            echo "'$2' -> $3"
            [ -r "$dir/.api-key" ] || echo "note: '$2' has no API key yet — claude-profile api-key $2"
            _claude_note_base_url "$3" ;;
        esac
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
                    if [ -f "$dir/.api-key" ]; then
                        echo "  $name (API key)"
                    elif [ -f "$dir/.credentials.json" ]; then
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
        echo "usage: claude-profile [status|list|new <name>|use <name>]" >&2
        echo "       claude-profile api-key <name> [--base-url URL] [--remove]" >&2
        echo "       claude-profile base-url <name> [URL|--remove]" >&2
        return 1
        ;;
    esac
}
