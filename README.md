# claude-profile

Per-project Claude Code accounts on one machine. Bind a directory to an account
with a `.claude-profile` file; every `claude` launch from inside it — terminal or
VSCode panel — uses that account automatically.

```
$ cd ~/some-work-project
$ claude-profile list
    research  you@university.example    max
  * work      you@work.example          max
    default   you@personal.example      max  <- ~/.claude
```

`*` marks the profile active in the current directory.

---

## Install

```bash
git clone <this-repo> ~/git/claude-profile
cd ~/git/claude-profile
./install.sh          # --no-vscode to skip the extension wiring
exec bash
```

Idempotent — re-run it after a `git pull`. It touches exactly three things:

| | |
| --- | --- |
| `~/.bashrc` | a marked block sourcing `shell/claude-profile.sh` |
| VSCode `settings.json` | `claudeCode.claudeProcessWrapper` -> `bin/claude-vscode-wrapper` |
| `~/.claude-profiles/` | created if absent; existing profiles get shared history |

Both files are backed up before editing.

## Uninstall

```bash
./uninstall.sh            # remove the integration, keep profiles and logins
./uninstall.sh --purge    # also delete ~/.claude-profiles
exec bash
```

Conversation history is never deleted by either form — profiles hold *symlinks*
into `~/.claude/`, and removing a symlink doesn't touch its target.

---

## Layout

Code and credentials are deliberately separate. `~/.claude-profiles/` holds live
OAuth tokens, so it is never part of the repo:

```
~/git/claude-profile/          <- this repo, safe to commit
  install.sh  uninstall.sh
  shell/claude-profile.sh      sourced by ~/.bashrc
  bin/claude-profile-list      reads account identity for `list`
  bin/claude-vscode-wrapper    launched by the VSCode extension

~/.claude-profiles/            <- data, never committed
  work/     .credentials.json  .claude.json  projects -> ~/.claude/projects
  research/ .credentials.json  .claude.json  projects -> ~/.claude/projects
  vscode-wrapper.log

~/.claude/                     <- default account + the shared history store
```

---

## How it works

Claude Code keeps its entire state — credentials, settings, MCP servers, history —
under one directory. `CLAUDE_CONFIG_DIR` relocates it:

| `CLAUDE_CONFIG_DIR` | Account |
| --- | --- |
| unset | `~/.claude` |
| `~/.claude-profiles/work` | whatever that profile logged into |

**The constraint:** it must be set *before* `claude` starts. Auth resolves at
startup, before project config is read — so a project's `.claude/settings.json`
`env` block will **not** work. It has to happen at launch, which is what the two
wrappers below do.

### Terminal

A `claude()` shell function shadows the binary. It walks up from `$PWD` for the
nearest `.claude-profile`, reads the name, exports `CLAUDE_CONFIG_DIR`, then runs
the real `claude`. Nothing found → default account.

### VSCode extension

The shell function does **not** apply here. The extension host spawns Claude
directly:

```
code-server -> node (extension host)
  -> ~/.vscode-server/extensions/anthropic.claude-code-<ver>/resources/native-binary/claude
```

No shell is involved, so `~/.bashrc` is never sourced — and it runs its own bundled
binary by absolute path, which a shell function could not intercept anyway.

The extension contributes `claudeCode.claudeProcessWrapper`. When set it launches
`<wrapper> <real-binary> [args...]` with cwd at the workspace folder, which is
enough to redo the resolution. `bin/claude-vscode-wrapper` does that.

Two deliberate differences from the terminal path:

- **A missing profile falls back to the default account** rather than refusing to
  launch. In a terminal an error is visible; in the panel a non-zero exit is just a
  silent failure to start.
- **Every launch is logged** to `~/.claude-profiles/vscode-wrapper.log` so that
  fallback stays diagnosable:

  ```bash
  tail ~/.claude-profiles/vscode-wrapper.log
  ```

The **integrated terminal** is unaffected — that's a real interactive bash, so the
shell function handles it.

#### Why not per-workspace settings?

Both `claudeCode.claudeProcessWrapper` and `claudeCode.environmentVariables` are
declared `"scope": "machine"`. VSCode **ignores machine-scoped settings in a
workspace's `.vscode/settings.json`**, so `CLAUDE_CONFIG_DIR` cannot be set
per-project that way — it would be one value for every workspace. Hence a
cwd-resolving wrapper script rather than a per-workspace env var.

---

## Usage

| Command | Effect |
| --- | --- |
| `claude-profile` | Which profile does the current directory resolve to? |
| `claude-profile list` | All profiles, the account each uses, and its plan |
| `claude-profile new <name>` | Create a profile, wire up shared history, print login command |
| `claude-profile use <name>` | Bind the current directory to a profile |
| `claude` | Launch, auto-selecting the profile for this directory |

### Add an account

```bash
claude-profile new client-x
CLAUDE_CONFIG_DIR=~/.claude-profiles/client-x claude auth login

cd ~/some-project
claude-profile use client-x
```

> The subcommand is `claude auth login`. There is no bare `claude login` — that
> parses as a prompt, not a command.

### Bind a project

```bash
cd ~/my-project
claude-profile use work     # writes ./.claude-profile containing "work"
claude                      # now on the work account
```

Subdirectories inherit it. Anywhere without a `.claude-profile` above it falls
through to the default account.

### Check before launching

```bash
$ cd ~/my-project/src
$ claude-profile
profile: work (from /home/you/my-project/.claude-profile)
config:  /home/you/.claude-profiles/work
account: you@work.example (max)
```

```bash
$ cd ~
$ claude-profile
profile: default (no .claude-profile here or above)
config:  /home/you/.claude
account: you@personal.example (max)
```

### One-off override

```bash
CLAUDE_CONFIG_DIR=~/.claude-profiles/work command claude
```

`command` skips the shell function, so nothing re-resolves.

---

## What is isolated, and what is shared

| | Scope |
| --- | --- |
| Credentials / account | **per profile** |
| Settings, MCP servers, plugins, agents | **per profile** |
| Conversation history / session list | **shared** |

Claude Code isolates *everything* per config dir by default, including history —
which means binding a project to a profile makes its past sessions vanish from the
picker. That's deliberately undone here: `projects/`, `file-history/` and
`session-env/` are symlinked to the default account's, so **every profile shows the
same session list**.

```
~/.claude/projects/                     <- the one real directory
~/.claude-profiles/work/projects/       -> symlink
~/.claude-profiles/research/projects/   -> symlink
```

`file-history/` and `session-env/` are included because they're keyed by session ID;
sharing only `projects/` would list old sessions but break checkpoint/rewind on them.

Consequences:

- Every profile's picker lists **all** conversations, including ones created under a
  different account. Transcripts are not separated by account.
- Deleting a profile removes only symlinks, never the shared history.
- `history.jsonl` (up-arrow prompt recall) is **not** shared — it's a single
  append-only file and concurrent writes from two profiles could interleave.

To restore isolated history for one profile:

```bash
cd ~/.claude-profiles/<name>
rm projects file-history session-env
mkdir projects file-history session-env
```

### Sharing settings

```bash
ln -s ~/.claude/settings.json ~/.claude-profiles/work/settings.json
```

Never symlink `.credentials.json` — that re-merges the accounts and defeats the point.

---

## Other things worth knowing

**You cannot switch mid-session.** Exit and relaunch. `/login` inside a session
swaps the account *and overwrites that profile's stored credentials*.

**The binding is shell-scoped, not filesystem-scoped.** Anything launching `claude`
without the shell hook or the VSCode wrapper — cron, systemd, a bare `sh -c` — gets
the default account regardless of directory. Convenience, not a security boundary.

**Disk.** Shared history means one store rather than one per profile, so profiles
themselves stay small. The shared store grows with use (`du -sh ~/.claude/projects`).

**Usage limits follow the account.** Separate profiles on separate accounts get
separate quotas — normal for accounts you hold, e.g. a work seat plus a personal
subscription. Two profiles on the *same* login share one quota; `claude-profile
list` flags that case, since it's usually an unfinished setup.

**`.claude-profile` in git.** It contains only a profile name, so it's safe to
commit if the whole team shares the convention. Otherwise add it to
`~/.config/git/ignore`.

---

## Troubleshooting

**`claude: profile <name> not found`** — the `.claude-profile` names a profile that
doesn't exist, usually a typo. The error names the file to fix. It refuses to launch
deliberately: otherwise Claude would silently start a blank unauthenticated config.

```bash
claude-profile list          # valid names
claude-profile new <name>    # or create it
```

**`No conversation found with session ID: ...` in the VSCode panel** — the extension
remembered a session ID from before the project was bound and tried to resume it
under a different config dir. Start a new conversation; the stale ID clears itself.
With shared history this shouldn't recur.

**Wrong account launched**

```bash
claude-profile               # what resolves here?
type claude                  # should say "claude is a function"
```

If `type claude` reports a file, `~/.bashrc` wasn't sourced — run `exec bash`.

**A stray `.claude-profile` above your project** — resolution walks up to `/`, so a
leftover file in `~` captures everything beneath it. `claude-profile` prints the
exact file in use.

**Verify which account a profile holds**

```bash
CLAUDE_CONFIG_DIR=~/.claude-profiles/work claude auth status
```

`claude-profile list` reads the same identity straight from `.claude.json` and
`.credentials.json` instead of spawning Claude — ~27ms for all profiles versus
~518ms per profile.

**`Claude Code native binary not found at <path>`** — the extension's
`claudeProcessWrapper` points somewhere that no longer exists. Usually this means a
*second* VSCode server on the same machine still holds an old path: code-server
(browser) and `.vscode-server` (Remote-SSH) keep separate settings, and only the one
you actually open matters. Re-run `./install.sh` — it updates every settings file
that exists — then reload the window.

```bash
grep -l claudeProcessWrapper \
  ~/.local/share/code-server/User/settings.json \
  ~/.vscode-server/data/Machine/settings.json \
  ~/.config/Code/User/settings.json 2>/dev/null
```

**The VSCode panel won't start at all** — every launch routes through the wrapper,
so a moved or deleted repo breaks it. Clear the setting:

```bash
./uninstall.sh    # or edit settings.json and drop claudeCode.claudeProcessWrapper
```

---

## Alternative: direnv

Same mechanism, automated with [direnv](https://direnv.net/) instead of a shell
function. Good if you already use direnv; costs a dependency and a `direnv allow`
re-run whenever `.envrc` changes. Note it covers the terminal only — the VSCode
panel still needs `bin/claude-vscode-wrapper`.

```bash
sudo apt install direnv
echo 'eval "$(direnv hook bash)"' >> ~/.bashrc
exec bash

cd ~/my-project
echo 'export CLAUDE_CONFIG_DIR="$HOME/.claude-profiles/work"' > .envrc
direnv allow
```

Point `.envrc` at `~/.claude-profiles/`, **not** inside the project — a config dir
in the repo puts `.credentials.json` one `git add -A` away from being committed, and
fills the working tree with transcript history.

### On macOS

macOS builds can read credentials from the system Keychain rather than a file in the
config directory. Don't assume `CLAUDE_CONFIG_DIR` isolates the login there — verify:

```bash
CLAUDE_CONFIG_DIR=~/.claude-profiles/work claude auth status
```

On Linux, credentials are a plain file inside the config directory, which is why the
isolation is clean.

---

## License

MIT — see [LICENSE](LICENSE).
