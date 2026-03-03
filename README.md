# devcontainer-claude

A devcontainer for running Claude Code with network isolation and persistent sessions.

Specifically for running `claude --dangerously-skip-permissions` inside a firewall-secured Docker container. The container gets default-deny networking (only Anthropic APIs and your `allowlist`ed
domains), while your Claude config, sessions, and project memory persist on the host
across devcontainer rebuilds.

## Features

- **Network firewall** -- iptables allowlist with default-deny; only Anthropic endpoints and your explicitly listed domains are reachable
- **Host-side persistent config** -- a single `dotclaude/` directory on the host holds credentials, settings, SSH keys, and command history shared across all projects
- **Per-project session and memory persistence** -- session JSONLs and `MEMORY.md` survive container rebuilds via host mounts keyed by workspace name
- **Per-container firewall toggle** -- bypass the firewall for a single project without affecting others
- **Two-tier allowlist** -- host-level allowlist (all projects) merges with per-project allowlist (committed to the repo)
- **Claude wrapper** -- pins the working directory to `/workspace` and applies `--dangerously-skip-permissions` automatically
- **PowerShell host utilities** -- `devcontainer-utils.ps1` handles host-side init, firewall toggling, and OAuth login

### Note: login issues

Login stuff doesn't work smoothly. You'll probably need to cut & paste the oauth URLs as claude code prompts you from the cli.

## Prerequisites

- **Docker Desktop** or Docker Engine
- **VS Code** with the [Dev Containers](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-containers) extension
- **PowerShell** (Windows) -- the `initializeCommand` runs `devcontainer-utils.ps1` on the host before each build
- **A Claude account** -- Max subscription (OAuth) or an API key

## Quick Start

```
1.  Copy the .devcontainer/ directory into your project root.
2.  Open the project in VS Code.
3.  Authenticate Claude (see Authentication below).
4.  Ctrl+Shift+P -> "Dev Containers: Reopen in Container"
```

On first launch, `devcontainer-utils.ps1 init` creates the `dotclaude/` tree on your
host (under `%USERPROFILE%\dotclaude\`) if it does not already exist. No manual
directory creation is required.

## Host Directory Structure

All persistent Claude state lives in a single host directory. The init command creates
any missing entries automatically.

```
%USERPROFILE%\dotclaude\
  .credentials.json          # OAuth credentials (ro mount)
  settings.json              # User preferences (rw mount)
  CLAUDE.md                  # User-level instructions (ro mount)
  history.jsonl              # Cross-session prompt history (rw mount)
  claude.token               # API key plaintext (read by init, not mounted directly)
  commands\                  # User slash commands (rw mount)
  plugins\                   # User plugins (rw mount)
  ssh\                       # SSH keys and known_hosts (ro mount)
  firewall\
    firewall.conf            # Global firewall mode: "enforce" or "bypass"
    allowlist                # Host-level domain allowlist
    <container>.conf         # Per-container firewall override (optional)
  projects\
    <workspace-name>\        # Session JSONLs and project memory, one per project
      memory\
```

## Authentication

Three methods, checked in this order (later overrides earlier):

### 1. Host environment variable

Set `CLAUDE_CODE_OAUTH_TOKEN` in your host shell profile or Windows environment
variables. It is passed through to the container via `remoteEnv` in
`devcontainer.json`.

### 2. Token file

Place your API key in `%USERPROFILE%\dotclaude\claude.token` (plain text, just the
key). The init command reads it and writes `.devcontainer/.env`, which Docker loads at
container start via `--env-file`. The `.env` file is gitignored.

If both the host env var and the token file are set, the token file wins (Docker
`--env-file` is processed after `remoteEnv`).

### 3. OAuth login (Max subscriptions)

For Claude Max subscriptions that use OAuth rather than API keys:

```powershell
powershell -File .devcontainer/devcontainer-utils.ps1 login
```

This runs `claude /login` on the host, which prints an OAuth URL. Open the URL in a
browser, complete the login flow, and paste the response code back into the terminal.
The resulting credentials are copied to `dotclaude/.credentials.json` and mounted into
the container on next rebuild.

You can also run `claude /login` inside a running container. It will work for that
session, but **credentials are lost on container restart** -- Docker's atomic-write
behavior (`mv` to replace a file) breaks the single-file bind mount. Use the host-side
login for persistence.

## Network Security

### Default-deny firewall

`init-firewall.sh` runs as root on every container start. It configures iptables with a
default DROP policy, then allows only:

- **Localhost** and the Docker host network
- **DNS** (UDP and TCP port 53)
- **Anthropic endpoints** -- `api.anthropic.com`, `console.anthropic.com`, `statsig.anthropic.com`, `statsig.com`, `sentry.io`
- **Allowlisted domains** -- resolved via DNS and added to an ipset

After applying rules, the script verifies the firewall by confirming that
`https://example.com` is unreachable.

### Two-tier allowlist

| Tier    | File                           | Scope        | How to edit            |
| ------- | ------------------------------ | ------------ | ---------------------- |
| Host    | `dotclaude\firewall\allowlist` | All projects | Edit on the host       |
| Project | `.devcontainer/allowlist`      | This project | Edit and commit to VCS |

Both files are merged and deduplicated at container start. Either may be absent.

**Format:** One entry per line. Supports plain domains, IP addresses, and CIDR ranges.
Lines starting with `#` and blank lines are ignored.

**GitHub special handling:** Any `github.com` or `githubusercontent.com` entry triggers
a bulk CIDR fetch from `api.github.com/meta` instead of plain DNS, because GitHub's
anycast fleet rotates IPs faster than DNS can track.

### Allowlist hash guard

On the first run, `init-firewall.sh` hashes both allowlists and stores the digest. On
subsequent runs (e.g., if the agent calls `sudo init-firewall.sh` again), the script
refuses to proceed if either allowlist has changed. This prevents an agent from injecting
a domain and re-running the firewall to open it. Restart the container to apply allowlist
changes.

This is necessary because init-firewall.sh runs as root.

### Security model

The firewall config directory is mounted **read-only** from the host. Key properties:

- The `node` user cannot write to `/etc/firewall/` (read-only directory mount)
- Directory mounts are immune to the single-file `mv` attack
- `sudo` only permits running `init-firewall.sh`; the script always re-reads the read-only config
- `sudo` strips environment variables (`NOPASSWD`, no `SETENV`)
- The `node` user has no direct `iptables` access (`NET_ADMIN` is root-only inside the container)

### Firewall bypass

For temporary unrestricted access (installing packages, debugging connectivity):

```powershell
# Toggle the global firewall (affects all containers)
powershell -File .devcontainer/devcontainer-utils.ps1 toggle-firewall

# Toggle for a single container only
powershell -File .devcontainer/devcontainer-utils.ps1 toggle-firewall myproject

# Remove the per-container override (revert to global)
powershell -File .devcontainer/devcontainer-utils.ps1 toggle-firewall -Delete myproject
```

Rebuild the container after toggling (`Ctrl+Shift+P` -> "Dev Containers: Rebuild
Container").

## Customization

### Adding allowed domains

Edit `.devcontainer/allowlist` (per-project, committed) or
`%USERPROFILE%\dotclaude\firewall\allowlist` (host-wide). One domain per line. Rebuild
the container to apply.

### VS Code extensions

Add entries to `customizations.vscode.extensions` in `devcontainer.json`. The default
set includes C/C++ tools, GitLens, Prettier, and the Claude Code extension.

### Dockerfile packages

The Dockerfile installs a C/C++ toolchain, Python, Node 20, zsh with Powerlevel10k,
and common shell utilities. Add `apt-get install` or `npm install -g` lines for
additional packages.

### SSH keys

Place SSH keys and `known_hosts` in `%USERPROFILE%\dotclaude\ssh\`. They are mounted
read-only at `~/.ssh/` inside the container. Use a dedicated key pair for easy revocation.

### User-level CLAUDE.md

Edit `%USERPROFILE%\dotclaude\CLAUDE.md` with instructions that apply to all projects.
It is mounted read-only at `~/.claude/CLAUDE.md` (separate from the project-level
`/workspace/CLAUDE.md`).

## How It Works

### Lifecycle

| Phase               | Runs on   | Script                        | Purpose                                                |
| ------------------- | --------- | ----------------------------- | ------------------------------------------------------ |
| `initializeCommand` | Host      | `devcontainer-utils.ps1 init` | Create `dotclaude/` structure, write `.env` from token |
| `build`             | Docker    | `Dockerfile`                  | Install toolchain, Claude Code, firewall script        |
| `postCreateCommand` | Container | `post-create.sh`              | Create shell history directory                         |
| `postStartCommand`  | Container | `init-firewall.sh` + `chown`  | Apply firewall rules, fix NTFS ownership               |

### Mount strategy

Persistent files are bind-mounted from `%USERPROFILE%\dotclaude\` into the container.
Security-sensitive paths (credentials, SSH keys, firewall config) are mounted read-only.
Ephemeral Claude state (`todos/`, `ide/`, `debug/`, `statsig/`) is not mounted and is
lost on rebuild by design.

Project sessions are keyed by workspace folder name:
`dotclaude/projects/<workspace-name>/` mounts to `~/.claude/projects/-workspace/`.

### Claude wrapper

The Dockerfile installs Claude Code via npm, then overwrites the `claude` binary with
`claude-wrapper.sh`. The wrapper `cd`s to `/workspace` and passes
`--dangerously-skip-permissions` automatically. The firewall is the security boundary,
not the Claude permission system.

## Detailed Documentation

See (poorly maintained) [notes.md](notes.md) for the full design rationale, file-by-file mount table,
session conflict analysis, and troubleshooting notes.
