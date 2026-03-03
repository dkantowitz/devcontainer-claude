# Using the devcontainer

Goal is a 'portable' set of .devcontainer files I can copy into any of my projects and use 'claude --dangerously-skip-permissions' in that project from within the devcontainer.

The container must have limited network access and limited access to the host's file system.

As a matter of 'good practice', devcontainers are fundamentally ephemeral: any data you want to save must be on paths mounted to the host environment.

Generally there are two places with files to be preserved across devcontainers:

- **/workspace** the devcontainer project directory.
- **~/.claude/** Claude stuff.

Note: don't use the devcontainer user account home directory for working files. The only thing that goes in the devcontainer user's home directory are configuration files. Use a combination of Dockerfile statements and the post-create.sh script to populate devcontainer's home dir.

Finally, I want a roughly common claude 'user' environment that's persistent on the host and used in all the devcontainers. This makes handling the .claude directory a little tricky.

### claudebox

I started with claudebox. It was a good way to get going quickly, but is kinda fiddly for what I need:

- Shell admin mode didn't always work to capture container changes.
- 'Slots' system means the ~/.claude/ directories slowly diverge.
- Poor VSCode integration.
- Adding to the 'configurations' required editing in the claudebox source.

Overall, my conclusion was claudebox was mainly someone's personal setup (probably at least partially ai coded) that they put on github.

## Container Lifecycle

The devcontainer goes through four phases:

1. **initializeCommand** (`devcontainer-utils.ps1 init`) — Runs on the _host_ before
   build. Creates any missing files/directories under `%USERPROFILE%\dotclaude\` and
   ensures `firewall.conf` defaults to `enforce`.

2. **build** (`Dockerfile`) — Installs toolchain (C/C++, Python, Node, zsh, DuckDB,
   git-delta, Claude Code). Sets up sudoers for firewall and workspace chown. Runs as
   `node` user at the end.

3. **postCreateCommand** (`post-create.sh`) — Runs once after container creation.
   Creates the shell history directory. (Project sessions and memory are
   persisted via the host mount `dotclaude/projects/<project>/` → `~/.claude/projects/-workspace/`.)

4. **postStartCommand** — Runs on every start. Initialises the firewall via
   `init-firewall.sh` (as root via sudo), then `chown -R node:node /workspace`
   (needed because NTFS-mounted files appear as root:root).

## Setup

### Claude Auth

### Long Lived Token

```bash
$ claude setup-token
```

Save the displayed token to $HOME/dotclaude/claude.token

#### Host Login to Claude

The `.credentials.json` is mounted as a read-only file. Login to claude from the host computer and copy $HOME/.claude/.credentials.json to $HOME/dotclaude.

If you login to claude from within the devcontainer, it will work, but your login will be lost when the devcontainer restarts. ^1

Procedure:

- cd to a temp directory
- start claude.
- /login
- do what's needed
- /exit
- copy $HOME/.claude/.credentials.json to $HOME/dotclaude/.credentials.json

`devcontainer-utils.ps1 login` might work too.

[1] claude does posix write/mv trick to atomically update the .credentials.json file. This causes docker to loose track of the single file mapping.

#### Devcontainer Login to Claude

You can also auth 'normally' from claude running in a specific devcontainer. This will get lost when the devcontainer restarts.

### SSH

Claude will need access to ssh credentials to use git. These are stored in $HOME/dotclaude/ssh.

This is read only to prevent claude from adding anything (ex. new known hosts).

Copy the known_hosts from somewhere useful.

Use ssh-keygen to create a new id key in the dotclaude/ssh directory and add that key to the remote git repos you need to access.

### Networking

The firewall (`init-firewall.sh`) runs as root via `postStartCommand`. It resolves
a set of required domains (Anthropic APIs, Sentry, Statsig) plus optional domains
from the two-tier allowlist system, then sets iptables to DROP everything else.

**Two-tier allowlist system:**

Domains are loaded from two sources, merged and deduplicated before processing:

| Tier | File | Scope | How to edit |
| ---- | ---- | ----- | ----------- |
| Host | `%USERPROFILE%\dotclaude\firewall\allowlist` | All projects on this machine | Edit on the host |
| Project | `.devcontainer/allowlist` | This project only | Edit and commit to the repo |

- The host allowlist is mounted read-only into the container at `/etc/firewall/allowlist`
  automatically via the existing `dotclaude/firewall/ → /etc/firewall/` directory mount.
- `devcontainer-utils.ps1 init` creates `dotclaude\firewall\allowlist` with a comment header if it
  doesn't exist yet (empty — no extra domains are allowed by default).
- Either tier may be absent: missing files are silently skipped.
- Duplicates between tiers are deduplicated silently.

**Format:** One entry per line. Supports plain domains, IP addresses, and CIDR ranges.
Any `github.com` or `githubusercontent.com` entry triggers a bulk CIDR fetch from
`api.github.com/meta` (plain DNS is insufficient for GitHub's anycast fleet).
Lines starting with `#` and blank lines are ignored.

**Firewall bypass (global):** For temporary unrestricted network access (e.g.
installing new packages, debugging connectivity), toggle the firewall to bypass mode:

1. Edit `%USERPROFILE%\dotclaude\firewall\firewall.conf` — change `enforce` to `bypass`
2. Rebuild the container (Ctrl+Shift+P → "Dev Containers: Rebuild Container")

Or use the toggle subcommand from a host-side PowerShell terminal:

```powershell
powershell -File .devcontainer/devcontainer-utils.ps1 toggle-firewall
```

**Per-container firewall override:** Each devcontainer can have its own firewall
state that overrides the global `firewall.conf`. The container name is derived from
the workspace folder name (e.g., workspace folder `vparams` produces container name
`vparams`).

To bypass the firewall for a single container without affecting others:

```powershell
# Toggle bypass for one container
powershell -File .devcontainer/devcontainer-utils.ps1 toggle-firewall vparams

# Delete the per-container override (revert to global default)
powershell -File .devcontainer/devcontainer-utils.ps1 toggle-firewall -Delete vparams
```

This creates (or toggles) `%USERPROFILE%\dotclaude\firewall\vparams.conf`. When
present, it overrides `firewall.conf` for that container only. Deleting the
per-container file reverts to the global default. This is a one-shot toggle -- the
per-container file is not created automatically and persists across rebuilds only
if you leave it in place.

**Resolution order** (checked by `init-firewall.sh`):
1. `~/dotclaude/firewall/<container-name>.conf` -- per-container override
2. `~/dotclaude/firewall/firewall.conf` -- global default

**Security model:** The config file lives in `~/dotclaude/firewall/` on the host,
mounted as a **read-only directory** to `/etc/firewall/` inside the container. Key
properties:

- `node` user cannot write to `/etc/firewall/` (read-only directory mount)
- Directory mounts are immune to the single-file `mv` attack (where `mv` replaces
  the parent directory entry, bypassing the inode-level read-only bind)
- `sudo` only permits running `init-firewall.sh`, which always re-reads the
  read-only config — re-running it cannot change the outcome
- `sudo` strips environment variables (no `SETENV` in sudoers), so env spoofing
  doesn't apply. The container name is passed as a command-line argument (not env
  var) to `init-firewall.sh`; even if spoofed, it can only select a different
  `.conf` file from the same read-only host-controlled directory
- `node` has no direct `iptables` access (`NET_ADMIN` is root-only inside the container)

### 'User' level CLAUDE.md and plugins

Edit `$HOME/dotclaude/CLAUDE.md` on the host with user-level instructions. It is
bind-mounted read-only into the container at `~/.claude/CLAUDE.md`. Claude loads this
as the user-level instruction file (separate from the project `/workspace/CLAUDE.md`).

User slash commands go in `$HOME/dotclaude/commands/` and plugins in
`$HOME/dotclaude/plugins/`. Both are bind-mounted read-write so Claude can discover them.

### API key

Two options (both can coexist):

1. **Host environment variable** — `CLAUDE_CODE_OAUTH_TOKEN` is passed through from the host
   environment via `remoteEnv` in `devcontainer.json`. Set it in your host shell profile
   or Windows environment variables.

2. **Token file** — Place your API key in `%USERPROFILE%\dotclaude\claude.token` (a
   plain-text file containing just the key). The `devcontainer-utils.ps1 init` command reads
   it and writes `.devcontainer/.env`, which Docker loads via `--env-file` at container
   start. The `.env` file is gitignored.

If both are set, the token file value takes effect (Docker `--env-file` is processed
after `remoteEnv`).

## Persistent Files

### Host — `%USERPROFILE%\dotclaude\`

Shared across all devcontainers. Created by `devcontainer-utils.ps1 init` if missing.

| Host path                     | Container path                | Mode | Purpose                       |
| ----------------------------- | ----------------------------- | ---- | ----------------------------- |
| `dotclaude/.credentials.json` | `~/.claude/.credentials.json` | ro   | Auth token                    |
| `dotclaude/settings.json`     | `~/.claude/settings.json`     | rw   | User preferences, status line |
| `dotclaude/CLAUDE.md`         | `~/.claude/CLAUDE.md`         | ro   | User-level instructions       |
| `dotclaude/commands/`         | `~/.claude/commands/`         | rw   | User slash commands           |
| `dotclaude/plugins/`          | `~/.claude/plugins/`          | rw   | User plugins                  |
| `dotclaude/history.jsonl`     | `~/.claude/history.jsonl`     | rw   | Cross-session prompt history  |
| `dotclaude/ssh/`              | `~/.ssh/`                     | ro   | SSH keys and known_hosts      |
| `dotclaude/firewall/`         | `/etc/firewall/`              | ro   | Firewall config (dir mount); `firewall.conf` (global) + optional `<name>.conf` (per-container) |
| `dotclaude/firewall/allowlist`| `/etc/firewall/allowlist`     | ro   | Host-level allowlist (via dir mount) |
| `dotclaude/projects/<project>/` | `~/.claude/projects/-workspace/` | rw | Session JSONLs and project memory |
| `dotclaude/claude.token`      | _(read by devcontainer-utils.ps1 init)_ | — | API key for `--env-file` |

### Workspace — `.devcontainer/`

Per-project, checked into the repo (except session data).

| Workspace path                                     | Container path                                    | Purpose                               |
| -------------------------------------------------- | ------------------------------------------------- | ------------------------------------- |
| `.devcontainer/commandhistory/`                    | `/commandhistory/`                                | Shell history across rebuilds         |
| `.devcontainer/.env`                               | _(Docker `--env-file`)_                           | API key from token file (git-ignored) |

### Ephemeral (not mounted)

These directories are created inside the container and lost on rebuild. This is
intentional — they are per-session state that doesn't need to persist.

`todos/`, `ide/`, `debug/`, `shell-snapshots/`, `statsig/`, `stats-cache.json`

## .claude files reference

| `.claude/{$_}`                    | `~/.claude/`                  | `/workspace/.claude/`       | Session Conflict Risk                |
| --------------------------------- | ----------------------------- | --------------------------- | ------------------------------------ |
| `.credentials.json`               | Auth token                    | —                           | Low — read-only after login          |
| `settings.json`                   | User preferences, status line | Project-level settings      | Low — rarely written at runtime      |
| `settings.local.json`             | Local user overrides          | Local project overrides     | Low                                  |
| `CLAUDE.md`                       | User-level instructions       | Project memory/instructions | Low — Claude reads, rarely writes    |
| `commands/`                       | User slash commands           | Project slash commands      | None — read-only at runtime          |
| `plugins/`                        | User plugins                  | —                           | None — read-only at runtime          |
| `projects/`                       | Session JSONLs + memory       | —                           | None — unique filename per session   |
| `projects/<key>/memory/MEMORY.md` | Per-project persistent memory | —                           | Low — one session writes at a time   |
| `history.jsonl`                   | Cross-session prompt history  | —                           | Low — unlikely simultaneous writes   |
| `todos/`                          | Todo list                     | —                           | **High — shared, concurrent writes** |
| `ide/`                            | IDE integration state         | —                           | Medium — per-session, isolate        |
| `debug/`                          | Debug logs                    | —                           | Low — but noisy, isolate             |
| `shell-snapshots/`                | Shell state snapshots         | —                           | Low — but per-session, isolate       |
| `statsig/`                        | Analytics/feature flags       | —                           | None — don't care                    |
| `stats-cache.json`                | Stats cache                   | —                           | None — don't care                    |
