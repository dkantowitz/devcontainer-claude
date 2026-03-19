---
id: DS-001-devcontainer-web-and-github-access-control
title: Enforce Path-based Web Access Control and GitHub Repo Allowlist for Devcontainer Claude Sessions
status: Draft
created_date: 2026-03-18
authors: TBD
replaces:
template_version: 0.4
---

## Table of Contents

- [Revision History](#revision-history)
- [Lens: Problem Frame](#lens-problem-frame)
  - [1. Problem Statement](#1-problem-statement)
  - [2. Solution Sketch](#2-solution-sketch)
  - [3. Scoping](#3-scoping)
  - [4. Success Signal](#4-success-signal)
- [Lens: Technical Response](#lens-technical-response)
  - [5. Problem Restatement](#5-problem-restatement)
  - [6. Done Objectives](#6-done-objectives)
  - [7. Constraints & Context](#7-constraints--context)
  - [8. Architecture](#8-architecture)
  - [9. Unresolved Concerns](#9-unresolved-concerns)
  - [10. Workstreams & Execution Plan](#10-workstreams--execution-plan)
  - [11. External Interfaces & APIs](#11-external-interfaces--apis)
  - [12. Testing Strategy](#12-testing-strategy)
  - [13. Operational Considerations](#13-operational-considerations)
  - [14. Risk Register](#14-risk-register)
  - [15. Rollout Strategy](#15-rollout-strategy)
  - [16. Feature Prioritization and Descoping Plan](#16-feature-prioritization-and-descoping-plan)
  - [17. Alternatives Considered](#17-alternatives-considered)
  - [18. References](#18-references)



<!-- INSTRUCTIONS FOR WRITING THIS DELIVERY SPECIFICATION (delete before committing)

This document is the durable state that survives the context boundary between a web chat
exploration and a Claude Code implementation session. It is the single source of truth for
a deliverable — not a summary of the conversation, but a specification another engineer+AI
team acts on without access to the original conversation.

───────────────────────────────────────────────
ROLE: WEB CHAT CLAUDE  (drafting from conversation)
───────────────────────────────────────────────
You are formalizing a conversation that has already reached technical conclusions.
Do not re-explore. Transcribe and structure what was decided.

  PROBLEM LENS  (Sections 1–4)
    Strip the solution back out and verify the problem statement holds independently.
    Chats drift — the problem as finally understood may differ from how it was first framed.
    No solution language in §1. §2–4 may reference the solution sketch only to bound scope.

  TECHNICAL LENS  (Sections 5–13)
    Formalize what was decided in the conversation. For each architecture decision, assign
    a state: Decided / Open / Punted. Do not leave decisions implicitly open.
    Open decisions become EXPLORATION tickets. Punted decisions need explicit unpunt conditions.

  CONSISTENCY CHECK  (before handing off to human)
    Verify §5 (Problem Restatement) against §1 (Problem Statement).
    If they materially diverge, flag the discrepancy explicitly — do not paper over it.
    The human must resolve it; do not resolve it yourself.
    This is the authoring check. Perform it before marking the draft ready for human review.

  WHAT TO LEAVE BLANK
    If the conversation did not resolve something, mark it TBD.
    A TBD field is honest. An invented answer is a liability.

───────────────────────────────────────────────
ROLE: HUMAN  (review, edit, gate)
───────────────────────────────────────────────
  1. Review the draft for accuracy against your recollection of the conversation.
  2. Resolve any consistency flags Claude raised between §1 and §5.
  3. Fill any TBD fields or explicitly mark them as Open Questions in §9.
  4. Confirm §18 contains the link to the source chat thread.
  5. When satisfied: set status → In Review, bump Revision History, commit the file.
     Committing with status "In Review" is the gate signal to Claude Code.
     This is a human act. The document cannot enforce it.

───────────────────────────────────────────────
ROLE: CLAUDE CODE  (consuming a committed DS)
───────────────────────────────────────────────
  Entry condition: DS file is committed with status "In Review" or "Accepted".
  Do not process a Draft DS — ask the human to complete the review gate first.

  1. Verify §5 is consistent with §1. This is an independent consumer check, not a substitute for the authoring check Web Chat Claude performs. If they diverge, stop and surface the discrepancy.
  2. For any thin or missing Phase 2 sections, ask the human targeted questions
     before generating tickets. Do not invent answers.
  3. Generate the backlog per the BACKLOG GENERATION block at the bottom of this file.
  4. Set status → Accepted in the front-matter and add a Revision History row.

Discipline in this doc pays forward:
- Ambiguous architecture = exploration tickets, not guessed implementation tickets
- Punted decisions must have explicit unpunt conditions or Claude Code will invent them
- Join-point interfaces defined here become the contract between parallel workstreams
- Done Objectives here become acceptance criteria at the epic level

-->

---
## Revision History

| Version | Date | Author | Status change | Summary of changes |
|---------|------|--------|---------------|--------------------|
| 0.1 | 2026-03-18 | | Draft | Initial draft from chat thread |
| 0.2 | 2026-03-18 | | Draft | Clarified threat model: strong enforced outer shell against prompt-driven and malicious binary injection; elevated objects.githubusercontent.com gap; marked SNI-only descope as goal-defeating |
| 0.3 | 2026-03-18 | | Draft | Added iptables placement rationale, lifecycle/cleanup design, and corruption recovery; made testing strategy podman-explicit; added dotclaude log storage with per-sidecar isolation and logrotate spec |
| 0.4 | 2026-03-18 | | Draft | Replaced WSL2 host iptables approach with compose network topology isolation (no host modification required); added SSH-over-Squid tunnelling for allowed repos; added multi-project concurrency as hard constraint; closed OQ-1/OQ-2; removed WS-2 and iptables scripts from scope |
| 0.5 | 2026-03-18 | | Draft | Adopted dual-network Option B: devcontainer retains existing default-deny firewall with direct internet access; Squid sidecar handles GitHub path-filtering only; allowlist parser routes entries by type; repo-serving domain guard added; existing firewall integration formalised as WS-4; GitHub services requiring direct access (Copilot, ghcr.io) documented |
| 0.6 | 2026-03-18 | | Draft | Incorporated review findings: all GitHub/CIDR-family traffic routed through Squid (splice for non-inspected, bump for repo-serving) due to CIDR overlap; added gist.github.com to repo-serving guard; fixed iptables flush race (DROP-before-flush); restricted ipset to TCP (QUIC bypass prevention); fixed NO_PROXY CIDR parsing; corrected Squid ssl_bump step ordering (peek+bump, no stare); added deny-log observability via shared volume; added Copilot proxy compatibility as early risk gate; restructured workstreams into phased execution; genericised CIDR product family handling |

---
# Lens: Problem Frame

## 1. Problem Statement

Claude Code running inside a devcontainer operates with agentic autonomy: it
executes shell commands, reads files, and makes network requests with minimal
per-action oversight. GitHub is an unrestricted public hosting service — any
actor can publish any content or binary to any public repository at any time.
Two concrete attack vectors exist within this surface:

**Prompt injection**: malicious instructions embedded in content Claude reads
during normal operation (issue comments, README files, commit messages,
third-party documentation) direct Claude to fetch from unauthorized repositories
or download unauthorized binaries.

**Malicious binary injection via project-level GitHub access**: an attacker with
knowledge of the project's GitHub footprint crafts content or tooling that causes
Claude to pull executables or scripts from repositories outside the project's
intended scope.

The devcontainer user account cannot be trusted to enforce its own restrictions:
environment variable–based controls (`HTTPS_PROXY`, `GIT_SSH_COMMAND`) are
trivially unset by the same process they are meant to constrain. The goal is a
strong, enforced outer shell at the network level — a hard boundary between the
GitHub repositories Claude is legitimately working with and the rest of GitHub's
hosting surface. This is not security in depth (scanning downloaded content,
auditing on-disk files); it is a single crunch layer that makes unauthorized
GitHub network access structurally impossible from inside the devcontainer.

## 2. Solution Sketch

The devcontainer has **two enforcement layers** that work independently:

**Layer 1 — Existing devcontainer firewall (non-GitHub traffic).**
The existing system reads `host` and `host:port` entries from
`.devcontainer/allowlist` and enforces them via root-set iptables `OUTPUT` rules
inside the devcontainer at startup. This is default-deny: only explicitly listed
addresses pass through. Non-GitHub services (Anthropic API, pypi, npm, etc.)
are handled here — direct internet access, no Squid involvement.

**Layer 2 — Squid proxy sidecar (all GitHub/CIDR-family traffic).**
A Squid sidecar on an internal compose network handles **all** traffic to
GitHub and related domains. This is necessary because GitHub's anycast CIDR
architecture makes IP-level service separation impossible — `copilot.github.com`,
`ghcr.io`, `github.com`, and `api.github.com` all resolve to the same broad
CIDR blocks (see §8 Appendix). You cannot allow one at the IP level without
allowing all.

The existing firewall **blocks all GitHub CIDRs directly** — these IPs are
redirected to Squid via iptables. `NO_PROXY` must NOT include any GitHub or
`githubusercontent.com` domains. Squid handles GitHub traffic in two modes:

- **ssl-bump + path filter**: `github.com`, `api.github.com`,
  `raw.githubusercontent.com`, `codeload.github.com`, `gist.github.com`
  (repo-serving domains requiring URL inspection)
- **splice (passthrough)**: `copilot.github.com`, `ghcr.io`,
  `copilot-proxy.githubusercontent.com`, `api.githubcopilot.com`,
  `copilot-telemetry.githubusercontent.com`, etc. (no inspection, opaque
  CONNECT tunnels — clients see GitHub's real certificate)

Spliced connections add one internal TCP hop. No CA cert substitution occurs.

**This CIDR-family routing approach must be generic.** Google services may
share the same CIDR overlap pattern. The implementation must support defining
additional CIDR product families beyond GitHub without architectural changes
(see `init-firewall.sh` on branch `proj-voicemail` for the existing pattern).

**The single allowlist file feeds both layers.** Each consumer ignores entry
types it doesn't own: the existing firewall processes `host`/`host:port` entries
for non-CIDR-family domains; Squid processes CIDR-family domains (all types)
and `host/path` entries. The file format is unchanged; the parse logic in
`deploy-security.sh` routes entries to the correct consumer and constructs
`NO_PROXY` automatically.

SSH git operations use a root-owned wrapper that enforces the allowlist and
tunnels allowed repos through Squid CONNECT. Interactive SSH is unaffected.

**Adversarial manipulation can only degrade capability, never expand it.** If
`HTTPS_PROXY` is unset: direct GitHub TCP is blocked by the existing firewall —
both allowed and unauthorized repos become unreachable. If Squid is down: same
outcome. The worst case for Claude is total GitHub unavailability.

## 3. Scoping

**In scope**
- Squid sidecar per devcontainer, on a separate internal compose network,
  handling **all** GitHub/CIDR-family traffic via forward-proxy (ssl-bump for
  repo-serving domains, splice for all others)
- Integration with the existing default-deny devcontainer firewall (iptables
  OUTPUT rules set via sudoer script at container startup)
- CIDR product family routing: all domains sharing GitHub's CIDR blocks are
  redirected to Squid via iptables; direct access blocked. This mechanism
  must be generic (not hardcoded to GitHub alone)
- Allowlist parser in `deploy-security.sh` routing entries by type:
  `host`/`host:port` for non-CIDR-family domains → existing firewall
  (unchanged); `host/path` → Squid ACL + `HTTPS_PROXY` domain scope +
  `NO_PROXY` exclusion; CIDR-family `host`/`host:port` entries → Squid
  splice (not direct firewall allow)
- Guard in existing iptables script: repo-serving domains (`github.com`,
  `raw.githubusercontent.com`, `codeload.github.com`, `api.github.com`,
  `gist.github.com`) refused as direct-allow entries even if present without
  a path in the allowlist
- GitHub-family services requiring non-inspected access (`ghcr.io`,
  `copilot.github.com`, etc.) routed through Squid with splice (passthrough,
  no ssl-bump, no CA cert substitution) — not direct
- Per-project `.devcontainer/allowlist` file: `host`, `host:port`, `host/path`,
  `host:port/path` entries; exact repo and org-wildcard path formats
- SSH wrapper: fast-fail for disallowed repos; ProxyCommand tunnelling through
  Squid for allowed repos; interactive SSH unaffected
- Root-locked deployment pattern: source in `.devcontainer/`, deployed to
  root-owned paths at container build time via Dockerfile
- CA cert installation for Squid's signing cert into the devcontainer trust
  store, git, and per-tool env vars
- `gh` CLI API access as an optional feature toggled via `.devcontainer/features.env`
- `objects.githubusercontent.com` (release asset / LFS CDN): allowed unfiltered
  as an explicit residual risk — paths are content-addressed hashes, no
  org/repo component present, path-level filtering impossible. See §14.
- Multiple concurrent devcontainers with independent allowlists and isolated
  compose stacks running simultaneously; project shift over days/weeks
- Squid deny-log observability from the main devcontainer via shared volume
- Iptables flush race condition fix (DROP-before-flush)
- UDP/QUIC bypass prevention (TCP-only ipset rules for ssl-bump domains)

**Out of scope**
- WSL2 host iptables modification of any kind (see §17)
- Rewriting or replacing the existing devcontainer firewall mechanism
- Devcontainer baseline image configuration (separate DS)
- Filtering of content already on disk post-clone
- GitLab, Bitbucket, or other git hosts
- Inbound traffic controls

## 4. Success Signal

- Git clone of a non-allowlisted repo fails regardless of `HTTPS_PROXY` state:
  if set, Squid returns 403; if unset, the existing firewall blocks direct TCP
  to `github.com`
- Git clone of an allowlisted repo succeeds via Squid
- `ssh git@github.com git-upload-pack '/unlisted-org/repo.git'` exits non-zero
  immediately (SSH wrapper fast-fail); the same for an allowlisted repo succeeds
  via Squid CONNECT tunnel
- Interactive `ssh git@github.com` succeeds (tunnelled through Squid)
- Non-GitHub traffic (`api.anthropic.com`, `pypi.org`, etc.) reaches
  the internet **directly** — no Squid involvement, no CA cert in TLS chain
- GitHub-family services not subject to repo filtering (`ghcr.io`,
  `copilot.github.com`) route through Squid with **splice** — no ssl-bump,
  no CA cert substitution, clients see GitHub's real certificate. One internal
  TCP hop of added latency.
- A host-only `github.com` entry in the allowlist is rejected by the iptables
  guard script with a clear error; the container start fails visibly
- Two devcontainers for different projects running simultaneously do not share
  Squid instances, networks, or allowlists
- When Squid denies a request, the denial is observable from the main
  devcontainer via `tail -f /var/log/squid/denied.log` without requiring
  `docker exec` into the sidecar

---
# Lens: Technical Response

## 5. Problem Restatement

The goal is a strong enforced outer shell: unauthorized GitHub network access
must be structurally impossible from inside the devcontainer. The enforcement
must survive a process running as the devcontainer user that is actively
attempting to reach unauthorized resources — whether driven by prompt injection
or by malicious tooling present in an accessed repository.

**Two enforcement layers, independent, complementary.**

**Layer 1 — Existing devcontainer firewall.**
The existing system applies default-deny iptables `OUTPUT` rules via a root-set
sudoer script at container startup. Only addresses explicitly listed in
`.devcontainer/allowlist` as `host` or `host:port` entries are permitted direct
egress. This covers all non-GitHub traffic: Anthropic API, package registries,
and any other non-CIDR-family services.

Critically, **all GitHub CIDR blocks are blocked for direct access** and
redirected to the Squid proxy. This is necessary because GitHub's anycast
architecture means all services — `github.com`, `copilot.github.com`,
`ghcr.io`, `api.github.com` — resolve to the same broad CIDR ranges. You
cannot allow Copilot at the IP level without also allowing `github.com`.
The existing firewall fetches GitHub CIDRs (from `api.github.com/meta`) and
adds them to a `github-proxy` ipset with iptables rules that redirect matching
traffic to Squid, rather than adding them to the `allowed-domains` ipset.

A guard in the iptables script enforces that repo-serving domains (`github.com`,
`raw.githubusercontent.com`, `codeload.github.com`, `api.github.com`,
`gist.github.com`) cannot appear as host-only entries. If any of these appear
as a host-only entry, the script exits non-zero and container startup fails
visibly. This prevents misconfiguration from silently bypassing Squid.

**Layer 2 — Squid sidecar.**
The devcontainer connects to Squid via `HTTPS_PROXY`. `NO_PROXY` is
automatically constructed by `deploy-security.sh` to include every non-CIDR-
family host that appears as a `host`/`host:port` entry — so non-GitHub traffic
never touches Squid. `NO_PROXY` must NOT include any GitHub or
`githubusercontent.com` domains.

Squid handles GitHub traffic in two modes:
- **ssl-bump + path filter**: repo-serving domains (`github.com`,
  `api.github.com`, `raw.githubusercontent.com`, `codeload.github.com`,
  `gist.github.com`) — URL path inspected against allowlist ACL
- **splice (passthrough)**: all other GitHub-family domains
  (`copilot.github.com`, `ghcr.io`, `copilot-proxy.githubusercontent.com`,
  `api.githubcopilot.com`, etc.) — opaque CONNECT tunnel, no cert
  substitution, clients see GitHub's real certificate

**Why two layers rather than Squid as sole egress?**
The existing firewall is already present, default-deny, and handles all
non-GitHub traffic reliably. Routing non-GitHub traffic through Squid would add
an unnecessary point of failure (Squid down → all external access lost),
introduce a sidecar dependency for performance-sensitive package downloads, and
require the Squid CA cert to be trusted for all TLS connections — not just
GitHub ones. The dual-layer approach keeps the performance and reliability
profile of the existing system while adding repo-level GitHub control.

**Why all GitHub traffic through Squid, not just repo-serving domains?**
GitHub's anycast CIDR architecture makes IP-level service separation impossible.
Live data from `api.github.com/meta` confirms all GitHub services share the
same broad CIDR blocks (`192.30.252.0/22`, `185.199.108.0/22`,
`140.82.112.0/20`, `143.55.64.0/20`). The existing `init-firewall.sh` already
demonstrates this: it dumps `web + api + git + copilot` CIDRs into one ipset.
You cannot allow `copilot.github.com` at the IP level without also allowing
`github.com`. Spliced connections through Squid add only one internal TCP hop
with no TLS overhead — acceptable for all GitHub-family services.

**Adversarial property remains intact.** Unsetting `HTTPS_PROXY` does not open
a path to GitHub — the existing firewall's iptables rules redirect all GitHub
CIDR traffic to Squid regardless of proxy environment variables. The worst
outcome from any devcontainer user manipulation is that Claude loses access to
allowlisted GitHub repos (capability loss). It cannot gain access to
unauthorized repos.

**Filesystem enforcement — SSH.**
SSH git does not use `HTTPS_PROXY`. The SSH wrapper (root-owned, non-writable)
is the only executable path to the real ssh binary. For allowlisted repos it
tunnels via Squid CONNECT; for others it fast-fails immediately.

**Acknowledged residual risk — `objects.githubusercontent.com`**: content-
addressed paths; no repo filtering possible; allowed unfiltered. A prompt could
instruct Claude to `curl` a binary from any GitHub release. The attack surface
is significant: `objects.githubusercontent.com` serves release assets, LFS
objects, and user-uploaded images in issues/PRs. An attacker can upload a binary
as a release asset on any public repo they control, then include a link in an
issue comment on a repo Claude *is* working with. Mitigated by the human gate on
the allowlist; accepted as residual. See §14.

**Out-of-scope gap — on-disk content**: injections in cloned files operate
within the allowed surface. Not a network control problem.

## 6. Done Objectives

| # | Objective | Validation method |
|---|-----------|-------------------|
| 1 | HTTPS git to non-allowlisted repos blocked unconditionally | `unset HTTPS_PROXY; git clone https://github.com/unlisted/repo` → blocked by existing firewall (iptables redirect to Squid, Squid 403); with proxy set → same result |
| 2 | HTTPS git to allowlisted repos succeeds via Squid | `git clone https://github.com/allowed-org/allowed-repo` → succeeds |
| 3 | SSH git to non-allowlisted repos blocked immediately | `ssh git@github.com git-upload-pack '/unlisted/repo.git'` → non-zero exit, no network attempt |
| 4 | SSH git to allowlisted repos succeeds via Squid tunnel | Same for allowlisted repo → succeeds through Squid CONNECT |
| 5 | Interactive SSH to github.com unaffected | `ssh -T git@github.com` → "Hi username" (tunnelled through Squid) |
| 6 | Non-GitHub traffic goes direct, never through Squid | `curl -v https://api.anthropic.com` → 200; TLS cert chain contains no Squid CA cert |
| 7 | GitHub-family spliced services work through Squid without ssl-bump | `docker pull ghcr.io/org/image` → succeeds; TLS cert chain shows GitHub's real cert, no Squid CA; traffic routes through Squid (splice mode) |
| 8 | Devcontainer user cannot modify deployed security scripts | `chmod 777 /usr/local/lib/security/git-ssh-allowlist.sh` → permission denied |
| 9 | gh CLI toggling works | `GITHUB_GH_CLI_ENABLED=true` → api.github.com path entries added to Squid ACL |
| 10 | Misconfiguration guard fires on repo-serving host-only entry | Adding bare `github.com` to allowlist → container start fails with explicit error |
| 11 | Multiple concurrent stacks fully isolated | Two stacks simultaneously: no shared Squid, no shared networks, no cross-stack GitHub access |
| 12 | Squid deny events observable from main devcontainer | `tail -f /var/log/squid/denied.log` shows blocked request details; Claude Code can self-diagnose network errors |
| 13 | Iptables flush has no open window | DROP policy set before flush; no unrestricted access between flush and rule application |
| 14 | UDP/QUIC cannot bypass Squid | `curl --http3 https://github.com` fails; UDP to GitHub CIDRs dropped |

## 7. Constraints & Context

- **Host**: Windows 11 + WSL2. No WSL2 host modification required or permitted.
  All enforcement is within the devcontainer and its compose stack.
- **Container runtime**: rootless Podman inside WSL2. No Docker socket.
  `docker-compose.yml` syntax executed via `podman compose`.
- **Devcontainer user**: non-root, restricted sudo. Sudo grants added surgically
  in the Dockerfile for specific scripts only.
- **Existing devcontainer**: this DS extends an existing image. Dockerfile
  additions are additive; the base image is not modified.
- **Existing firewall mechanism**: root-set iptables `OUTPUT` rules applied via
  a sudoer-allowed script at container startup. Default-deny. Only `host` and
  `host:port` entries from `.devcontainer/allowlist` for non-CIDR-family
  domains are added as direct-allow rules. CIDR-family domains (GitHub) are
  redirected to Squid instead. This mechanism is **not replaced** — this DS
  extends it.
- **CIDR product family routing**: domains that share broad CIDR blocks (making
  IP-level service separation impossible) are routed as a group through Squid.
  GitHub is the first such family. The approach must be generic — additional
  families (potentially Google) can be defined without architectural changes.
  `init-firewall.sh` fetches CIDRs and creates a `github-proxy` ipset that
  redirects matching traffic to Squid.
- **Repo-serving domain guard**: the existing iptables script must refuse to
  add direct-allow rules for `github.com`, `raw.githubusercontent.com`,
  `codeload.github.com`, `api.github.com`, and `gist.github.com` (with or
  without a port). If any of these appear as a host-only entry, the script
  exits non-zero and container startup fails visibly. This prevents
  misconfiguration from silently bypassing Squid. The guard is implemented
  in WS-4.
- **GitHub-family services requiring non-inspected access**: `ghcr.io`,
  `copilot.github.com`, `*.copilot.github.com`,
  `copilot-proxy.githubusercontent.com`, `api.githubcopilot.com`,
  `copilot-telemetry.githubusercontent.com`, and similar GitHub services that
  do not expose per-repo paths. These are routed through Squid with **splice**
  (passthrough, no ssl-bump, no CA cert substitution). They are NOT given
  direct firewall access because they share CIDRs with repo-serving domains.
  The confirmed list of such services is an open question (OQ-3).
- **NO_PROXY construction**: `deploy-security.sh` builds `NO_PROXY`
  automatically from all non-CIDR-family `host`/`host:port` entries in the
  allowlist. `NO_PROXY` must NOT include any GitHub or `githubusercontent.com`
  domain. This ensures non-GitHub traffic never reaches Squid even if
  `HTTPS_PROXY` is set.
- **Dual-network compose topology**: the devcontainer is attached to both the
  existing external network (direct internet, governed by existing firewall) and
  a new internal-only network shared with the Squid sidecar. Squid has both
  internal and external network attachments. The devcontainer routes GitHub
  traffic via iptables redirect and `HTTPS_PROXY` to Squid; all other traffic
  goes direct.
- **Multi-project concurrency**: multiple devcontainers run simultaneously.
  Each compose stack is fully independent: separate Squid sidecar, separate
  internal network, separate allowlist. `COMPOSE_PROJECT_NAME` (set by VS Code
  from devcontainer folder name) is the namespace key.
- **Project churn**: stopped stacks leave named volumes. Cleanup is a human
  operation; the design must not assume volumes are absent.
- **Squid version**: 6.x (current stable). SSL-bump requires a signing CA cert
  generated at first run, persisted to a named volume.
- **Per-project allowlist**: each devcontainer's `.devcontainer/allowlist` is
  independent. No shared allowlist or shared Squid instance.
- **Iptables safety**: the iptables script must set `DROP` policy on OUTPUT,
  INPUT, and FORWARD chains **before** flushing existing rules. This eliminates
  the race condition where the container has unrestricted access between flush
  and rule application. Preferred approach: `iptables -P OUTPUT DROP` then
  `iptables -F` (not the other way around).
- **UDP/QUIC bypass prevention**: for any hostname requiring Squid ssl-bump,
  UDP to that hostname's IPs must be blocked. Squid cannot intercept QUIC
  (HTTP/3 over UDP/443); allowing UDP would create a proxy bypass. The ipset
  rule for allowed domains must be TCP-only: `iptables -A OUTPUT -p tcp -m set
  --match-set allowed-domains dst -j ACCEPT`. GitHub CIDRs in the
  `github-proxy` ipset are also TCP-only (UDP dropped by default OUTPUT DROP).
- **deploy-security.sh security model**: the script must be idempotent (safe
  to run multiple times), must not depend on any file writable by the
  `remoteUser` (node) account (deploy-copy model with root-owned copies and/or
  hash verification), and the hash guard in `init-firewall.sh` must compute
  against the original allowlist file (before processing).
- **Compose migration**: the current `devcontainer.json` uses
  `build.dockerfile` (no compose). The Squid sidecar requires compose. This is
  a significant migration and should be an early task: `devcontainer.json`
  switches from `"build"` to `"dockerComposeFile"` + `"service"` syntax;
  `runArgs` move to compose service config; `mounts` translate to compose
  volumes. Use `vhiribarren/echo-server` as a placeholder for Squid during
  initial compose migration.

---

## 8. Architecture

### Stack & Runtime

| Component | Technology | Location |
|-----------|-----------|----------|
| Existing default-deny firewall | iptables OUTPUT rules, root-set via sudoer script | Devcontainer |
| Repo-serving domain guard | Guard logic in existing iptables script | Devcontainer |
| CIDR product family redirect | iptables ipset `github-proxy`, REDIRECT to squid:3128 | Devcontainer |
| Squid forward proxy + SSL-bump | Squid 6.x (C) | Sidecar container |
| SSL-bump CA | Dynamically generated PEM, volume-persisted | Sidecar |
| Path ACL evaluation | Squid `url_regex` ACL from generated file | Sidecar |
| Splice passthrough | Squid `ssl_bump splice` for non-inspected CIDR-family domains | Sidecar |
| Dual-network topology | Compose: devcontainer on internal + external; Squid on internal + external | Compose |
| SSH filtering + tunnelling | Bash wrapper + allowlist parser + ProxyCommand | Devcontainer (root-locked) |
| Allowlist parser + NO_PROXY builder | `deploy-security.sh` | Devcontainer (root-locked) |
| Allowlist source | `.devcontainer/allowlist` (plaintext, VC'd) | Devcontainer source |
| Feature flags | `.devcontainer/features.env` | Devcontainer source |
| CA cert export | PEM on named volume, mounted read-only into devcontainer | Shared volume |
| Deny log observability | Squid denied-request log on shared volume, read-only in devcontainer | Shared volume |

### Key Components

```
Compose Stack  (one per devcontainer project; fully independent across projects)
│
├── [internal network — Squid reachable; no internet gateway]
│     │
│     ├── Devcontainer  ←──────────────────────────────────────────────┐
│     │     - existing firewall: default-deny iptables OUTPUT rules    │
│     │       (allows direct egress for non-CIDR-family host entries)  │
│     │     - GitHub CIDRs: iptables REDIRECT → squid:3128             │
│     │     - HTTPS_PROXY=http://squid:3128  (GitHub traffic)          │
│     │     - NO_PROXY=<all non-CIDR-family host entries>              │
│     │     - /usr/bin/ssh → root-locked wrapper                       │
│     │     - /var/log/squid/denied.log → read-only shared volume      │
│     │     │                                                           │
│     │     ├─[direct egress, existing firewall]──▶ api.anthropic.com  │
│     │     ├─[direct egress, existing firewall]──▶ pypi.org           │
│     │     ├─[iptables REDIRECT → Squid, splice]──▶ ghcr.io          │
│     │     ├─[iptables REDIRECT → Squid, splice]──▶ copilot.github.com
│     │     ├─[via HTTPS_PROXY → Squid, bump]──▶ github.com/org/repo  │
│     │     └─[via HTTPS_PROXY → Squid, bump]──✗ github.com/other  403│
│     │                                                                 │
│     └── Squid Sidecar                                                 │
│           - listens :3128 (forward proxy, HTTP CONNECT)               │
│           - ssl_bump peek → bump: repo-serving domains only           │
│           - ssl_bump peek → splice: all other GitHub-family domains   │
│           - url_regex ACL from /etc/squid/github-acl.conf             │
│           - CONNECT :22 allowed for github.com (SSH tunnelling)       │
│           - denied.log: deny-specific access log on shared volume     │
│
└── [external network — internet access for Squid outbound only]
      └── Squid Sidecar  (outbound interface)
```

### CIDR Product Family Routing

GitHub's anycast architecture means all services share the same broad CIDR
blocks. Live data from `api.github.com/meta` confirms:

| Shared IPv4 CIDRs | Services |
|---|---|
| `192.30.252.0/22` | web, api, git, copilot, packages |
| `185.199.108.0/22` | web, api, git, copilot |
| `140.82.112.0/20` | web, api, git, copilot, packages |
| `143.55.64.0/20` | web, api, git, copilot |

| Service | Dedicated IPs? | Separable from github.com via IP? |
|---|---|---|
| api.github.com | Has unique /32s, shares broad CIDRs | No |
| copilot.github.com | Has 11 unique /32s, shares broad CIDRs | No |
| ghcr.io | Has unique /32s, all within shared CIDRs | No |
| gist.github.com | No dedicated IPs at all | No |
| git (SSH/HTTPS) | Shares exact same IPs as web | No |

**Consequence**: `init-firewall.sh` must treat all GitHub/githubusercontent
domains as a single routing group. When any GitHub domain appears in the
allowlist, the script fetches CIDRs from `api.github.com/meta` and adds them
to a `github-proxy` ipset. Iptables rules redirect `github-proxy` traffic to
Squid (REDIRECT or DNAT to squid:3128). The `allowed-domains` ipset is NOT
used for GitHub traffic.

The existing `init-firewall.sh` `github_triggered` flag (which currently dumps
all GitHub CIDRs into `allowed-domains`) must be reworked: instead of adding
CIDRs to `allowed-domains` (which allows direct access), add them to
`github-proxy` (which redirects to Squid). The allowlist parser must recognise
GitHub entries and route them to the proxy path, not the direct path.

**Generic design**: this CIDR-family mechanism must not be hardcoded to GitHub.
Additional product families can be defined by:
1. A list of domains belonging to the family
2. A CIDR source endpoint (or static CIDR list)
3. An ipset name for the redirect rule

### Dual-Network Topology and Traffic Routing

The devcontainer has **two network attachments**:

1. **External network** (existing): the network the devcontainer has always
   used, with direct internet access governed by the existing default-deny
   iptables firewall. All non-CIDR-family traffic exits here.

2. **Internal network** (new, compose `internal: true`): shared only with the
   Squid sidecar. No internet gateway. The devcontainer uses this to reach
   `squid:3128`.

Squid also has two network attachments: the internal network (reachable from
devcontainer) and its own external network (for outbound GitHub connections).

**Traffic routing by entry type:**

| Allowlist entry | Consumer | Routing |
|----------------|----------|---------|
| `host` / `host:port` (non-CIDR-family) | Existing iptables script | Direct egress via external network; added to `NO_PROXY` |
| `host` / `host:port` for repo-serving domains | **Rejected by guard** | Container start fails |
| `host` / `host:port` for CIDR-family non-repo domains (e.g. `ghcr.io`, `copilot.github.com`) | Squid splice | Redirected to Squid via iptables; spliced (passthrough); NOT added to `NO_PROXY` |
| `host/path` / `host:port/path` | Squid ACL (ssl-bump) | `HTTPS_PROXY` → Squid → GitHub; host NOT added to `NO_PROXY` |

**`NO_PROXY` construction** (performed by `deploy-security.sh` at postCreate):

```bash
# Extract all host/host:port entries (no slash after host portion)
# EXCLUDING CIDR-family domains (GitHub/githubusercontent)
# and excluding CIDR notation (host/digits-only)
NO_PROXY=$(grep -vE '^\s*#|^\s*$' .devcontainer/allowlist \
  | grep -vE '^[^/]+/[^0-9]|^[^/]+/[0-9]+/' \
  | grep -viE 'github\.com|githubusercontent\.com|ghcr\.io|githubassets\.com' \
  | sed 's/:.*$//' \
  | sort -u \
  | tr '\n' ',' \
  | sed 's/,$//')
export NO_PROXY="localhost,127.0.0.1,::1,${NO_PROXY}"
```

Note: the `grep -vE` pattern for path entries must correctly distinguish
Type 3 path entries (containing at least two path segments) from CIDR notation
(single `/` followed by digits only). The pattern
`'^[^/]+/[^0-9]|^[^/]+/[0-9]+/'` correctly handles both cases:
- `github.com/org/repo` → excluded (Type 3, has non-digit after `/`)
- `host.example.com/24` → kept (CIDR, digits only after `/`)
- `api.github.com/repos/org/path` → excluded (Type 3)

This is written to `/etc/profile.d/github-proxy.sh` (root-owned) and sourced
at shell startup. The devcontainer user can read but not modify it.

**Repo-serving domain guard** (added to existing iptables script):

```bash
BLOCKED_DIRECT=(
  "github.com"
  "raw.githubusercontent.com"
  "codeload.github.com"
  "api.github.com"
  "gist.github.com"
)

for domain in "${BLOCKED_DIRECT[@]}"; do
  if grep -qE "^${domain}(:[0-9]+)?$" "$ALLOWLIST"; then
    echo "ERROR: '${domain}' cannot be a direct-allow entry." >&2
    echo "       Use a path entry (${domain}/org/repo) for repo access." >&2
    exit 1
  fi
done
```

### SSH Wrapper: Allowlist Enforcement and Squid Tunnelling

The real `ssh` binary is moved to `/usr/local/lib/security/ssh-real` (mode
`750`, root:root). The wrapper at `/usr/local/lib/security/git-ssh-allowlist.sh`
(mode `755`) replaces `/usr/bin/ssh`.

The devcontainer user can execute the wrapper; cannot write to it; cannot execute
`ssh-real` directly (mode 750, not in root group); cannot set
`GIT_SSH_COMMAND=/usr/local/lib/security/ssh-real` (permission denied).

**Wrapper logic:**

1. Inspect argv for `git-upload-pack` or `git-receive-pack` — git-over-SSH signal
2. If **not git**: exec `ssh-real "$@"` via Squid ProxyCommand unconditionally
   (interactive SSH, scp, etc. all tunnel through Squid to reach github.com:22)
3. If **git and repo not in allowlist**: exit 1 immediately, no network attempt
4. If **git and repo in allowlist**: exec `ssh-real` with ProxyCommand:

```bash
exec /usr/local/lib/security/ssh-real \
  -o "ProxyCommand=nc --proxy squid:3128 --proxy-type http %h %p" \
  "$@"
```

Squid must permit CONNECT on port 22 for github.com:

```squid
acl github_ssh_host dstdomain github.com
acl ssh_port port 22
http_access allow CONNECT ssh_port github_ssh_host
```

SSH to github.com (git and interactive) transits Squid. Direct TCP to
`github.com:22` is blocked by the existing firewall (GitHub CIDRs redirected
to Squid) — consistent with the default-deny model.

### Allowlist File Format

```
# .devcontainer/allowlist
# One entry per line. Blank lines and # comments ignored.
#
# THREE ENTRY TYPES — each consumed by a different subsystem:
#
# TYPE 1: host
#   Consumer: existing iptables firewall (direct egress allow)
#             UNLESS the host belongs to a CIDR product family (e.g. GitHub),
#             in which case it is routed through Squid with splice instead.
#   Also:     added to NO_PROXY (non-CIDR-family only)
#   Example:  api.anthropic.com
#             registry.npmjs.org
#   CIDR-family example (routed through Squid splice, NOT direct):
#             ghcr.io
#             copilot.github.com
#   GUARD:    github.com, raw.githubusercontent.com, codeload.github.com,
#             api.github.com, gist.github.com are REJECTED here — use a
#             path entry instead. Container start fails with an explicit
#             error if these appear.
#
# TYPE 2: host:port
#   Consumer: existing iptables firewall (direct egress allow on specific port)
#             UNLESS CIDR product family (same as Type 1)
#   Also:     added to NO_PROXY (non-CIDR-family only)
#   Example:  host.docker.internal:9222
#
# TYPE 3: host/path-prefix  (or host:port/path-prefix)
#   Consumer: Squid ACL (path-level filter via ssl-bump)
#   Also:     host added to HTTPS_PROXY scope; NOT added to NO_PROXY
#   Host NOT allowed direct egress — existing firewall blocks it by default-deny
#   Path syntax:
#     github.com/org/repo       exact repo
#     github.com/org/*          all repos under org
#   Example:  github.com/my-org/my-repo
#             github.com/my-org/*
#             raw.githubusercontent.com/my-org/*
#             api.github.com/repos/my-org/*   (requires GITHUB_GH_CLI_ENABLED=true)
#
# PARSING RULE: a '/' after the host portion (before any ':' port) identifies
# a Type 3 entry. Everything else is Type 1 or 2.
# Exception: CIDR notation (host/digits-only like 10.0.0.0/8) is NOT Type 3.
#
# This file is parsed by deploy-security.sh which:
#   1. Passes non-CIDR-family Type 1/2 entries to the existing iptables script
#   2. Routes CIDR-family Type 1/2 entries to Squid splice configuration
#   3. Generates /etc/squid/github-acl.conf from Type 3 entries
#   4. Constructs NO_PROXY from all non-CIDR-family Type 1/2 hosts
#   5. Runs the repo-serving domain guard before the iptables script executes
#   6. Copies the file to /usr/local/lib/security/allowlist.conf (root-owned)
#      for use by the SSH wrapper
```

### Feature Flags File

```bash
# .devcontainer/features.env
# Sourced by deploy-security.sh at container build time.
# Change values and rebuild container to apply.

# Enable gh CLI / GitHub REST API access.
# When true: api.github.com/repos/<allowlist entries> added to Squid ACL.
# When false: api.github.com blocked entirely.
GITHUB_GH_CLI_ENABLED=false

# objects.githubusercontent.com policy.
# "allow" = unfiltered pass-through (LFS, release assets work; no repo filtering possible).
# "block" = blocked entirely.
GITHUB_OBJECTS_POLICY=allow
```

### SSH Wrapper Enforcement Pattern

Covered in Key Components above. Summarised for reference:
- `/usr/bin/ssh` → wrapper (root:root 755)
- `/usr/local/lib/security/ssh-real` (root:root 750 — devcontainer user cannot exec)
- Non-git invocations: tunnelled via Squid ProxyCommand unconditionally
- Git invocations for allowlisted repos: tunnelled via Squid ProxyCommand
- Git invocations for non-allowlisted repos: exit 1 immediately, no network attempt

### Squid Configuration Sketch

```squid
# Forward proxy port — devcontainer connects here
http_port 3128

# SSL-bump: intercept github repo-serving domains; splice all others
acl github_repo_domains ssl::server_name github.com api.github.com \
    raw.githubusercontent.com codeload.github.com gist.github.com
ssl_bump peek all
ssl_bump bump github_repo_domains
ssl_bump splice all

# Path ACL (generated from allowlist by deploy-security.sh)
include /etc/squid/github-acl.conf

# SSH tunnelling: allow CONNECT to github.com:22 only
acl github_ssh_host dstdomain github.com
acl ssh_port port 22
http_access allow CONNECT ssh_port github_ssh_host

# objects domain policy (controlled by GITHUB_OBJECTS_POLICY at build time)
# allow: splice-only (no bump, no filter) — LFS/release assets work, unfiltered
# block: deny entirely

# Deny github traffic not matching allowlist; allow everything else
acl github_traffic dstdomain .github.com .githubusercontent.com .githubassets.com
http_access deny github_traffic !allowed_github_paths
http_access allow all

# Deny-specific access log (shared volume, readable from main devcontainer)
logformat denied %ts.%03tu %6tr %>a %Ss/%03>Hs %<st %rm %ru %un %Sh/%<a %mt
access_log daemon:/var/log/squid/shared/denied.log logformat=denied deny
```

**Note on `ssl_bump` step ordering**: In forward proxy mode with CONNECT, Squid
already knows the hostname from the CONNECT request — `stare` (completing the
TLS handshake to see the server cert) is unnecessary for hostname-based
decisions and adds an extra round-trip. The correct sequence is `peek → bump`
for known domains, skipping `stare`:
```squid
ssl_bump peek all
ssl_bump bump github_repo_domains
ssl_bump splice all
```

### Compose Network Configuration Sketch

```yaml
# docker-compose.yml
networks:
  squid-internal:
    internal: true    # no internet gateway; used only for devcontainer ↔ Squid
  squid-external: {}  # internet access for Squid outbound connections

services:
  squid:
    build: .devcontainer/squid/
    networks:
      - squid-internal
      - squid-external
    labels:
      squid-log-slug: "${COMPOSE_PROJECT_NAME}"
    volumes:
      - squid-certs:/etc/squid/ca
      - /home/davidk/dotclaude/logs/github-proxy-${COMPOSE_PROJECT_NAME}:/var/log/squid
      - squid-denied-logs:/var/log/squid/shared
    healthcheck:
      test: ["CMD", "squid", "-k", "check"]
      interval: 5s
      timeout: 3s
      retries: 5

  devcontainer:
    # ... existing config ...
    # NOTE: the devcontainer's existing external network (for direct internet
    # egress governed by iptables) is inherited from the pre-compose
    # devcontainer.json config. In compose mode this becomes the default
    # compose network. The squid-internal network is added alongside it.
    networks:
      - default             # existing external network: direct egress, existing firewall
      - squid-internal      # new: path to Squid only
    # HTTPS_PROXY and NO_PROXY are NOT set in compose env —
    # they are written to /etc/profile.d/github-proxy.sh by deploy-security.sh
    # at postCreate time, derived from the allowlist. Setting them in compose
    # env would prevent per-project customisation and bypass the parser.
    depends_on:
      squid:
        condition: service_healthy
    volumes:
      - squid-certs:/etc/squid/ca:ro
      - squid-denied-logs:/var/log/squid:ro

volumes:
  squid-certs:
  squid-denied-logs:
```

**`depends_on` with healthcheck** ensures Squid is ready before the firewall
script redirects traffic to it. No race condition between iptables redirect
and Squid availability.

### Container Lifecycle

```
postCreateCommand (runs once after container creation):
  1. deploy-security.sh:
     - Reads allowlist, classifies entries by type and CIDR family
     - Generates Squid ACL config (/etc/squid/github-acl.conf)
     - Generates NO_PROXY value (excluding CIDR-family domains)
     - Writes /etc/profile.d/github-proxy.sh (HTTPS_PROXY + NO_PROXY)
     - Deploys SSH wrapper and root-owned allowlist copy
     - Installs Squid CA cert to system trust store and git config
     - All outputs are root-owned (deploy copy model)
     - Idempotent — safe to re-run

postStartCommand (runs every container start):
  1. Wait for Squid sidecar health check (compose `depends_on` +
     `healthcheck`)
  2. init-firewall.sh:
     - Sets DROP policy FIRST (iptables -P OUTPUT/INPUT/FORWARD DROP)
     - Flushes existing rules (safe — default is already DROP)
     - Applies iptables rules for non-CIDR-family allowlist entries
     - Fetches GitHub CIDRs, creates github-proxy ipset
     - Redirects github-proxy traffic to Squid (TCP only)
     - Applies TCP-only ipset for direct-allowed domains
     - Hash-validates allowlist hasn't changed (against original file)
  3. Verify connectivity (existing example.com check)
```

The hash guard in `init-firewall.sh` must compute against the original
allowlist file, not any generated artifacts. Since `deploy-security.sh` does
not modify the allowlist, this is satisfied by the current design.

### Development Environment

1. **System dependencies**: Squid 6.x with SSL support (`squid-openssl`);
   `openssl` for CA generation; `netcat-openbsd` (`nc`) for SSH ProxyCommand;
   `bats` for shell unit tests; `bash` 4+; `iptables` (already present in
   existing devcontainer)
2. **Network**: devcontainer retains existing external network attachment.
   New `squid-internal` compose network added alongside it. No external host
   configuration required beyond what the existing allowlist already permits.
3. **Container build tooling**: rootless Podman 4.x with `podman compose` built-in.
4. **CA cert**: generated at Squid first-run, written to `squid-certs` named
   volume. `deploy-security.sh` waits up to 30s for cert; exits non-zero if
   absent. CA installed into system trust store, git `http.sslCAInfo`, and
   `/etc/profile.d/github-proxy.sh`.
5. **COMPOSE_PROJECT_NAME**: must be unique per project. VS Code sets this from
   the devcontainer folder name. Verify no collision across active projects.
6. **Verification checklist**:
   - `podman build -t github-proxy:dev .devcontainer/squid/ && podman run --rm github-proxy:dev squid -v | grep ssl` → ssl-bump compiled in
   - `podman compose up -d` → both services start
   - From devcontainer: `curl -v https://github.com/unlisted/repo` → blocked (iptables redirects to Squid, Squid 403)
   - From devcontainer: `curl -v --proxy http://squid:3128 https://github.com/unlisted/repo` → Squid 403
   - From devcontainer: `curl -v https://api.anthropic.com` → 200; TLS cert chain has no Squid CA
   - From devcontainer: `curl -v https://ghcr.io/v2/` → 200; routed through Squid splice; TLS cert chain shows GitHub's real cert, no Squid CA
   - From devcontainer: `git clone git@github.com:unlisted/repo.git` → immediate exit 1 (SSH wrapper fast-fail)
   - From devcontainer: `ssh -T git@github.com` → succeeds (tunnelled via Squid)
   - Misconfiguration guard: add bare `github.com` to allowlist → `podman compose up` fails with error message
   - Two stacks: `podman network ls` → `projecta_squid-internal`, `projectb_squid-internal` separate

---

## 9. Unresolved Concerns

### Open Questions

| # | Question | Acceptable answer looks like | Blocks |
|---|----------|------------------------------|--------|
| 1 | Squid ssl-bump in forward proxy mode (not TPROXY) inside a rootless Podman container: confirmed working? | Verified in test build; Squid bumps github.com HTTPS and returns 403 for unlisted repo | WS-1 |
| 2 | VS Code sets `COMPOSE_PROJECT_NAME` from devcontainer folder name — reliable and unique across all active projects? | Verified: distinct project name per folder; no two active projects share a name | WS-1, DO-11 |
| 3 | Complete list of GitHub-family services requiring non-inspected (splice) access through Squid? Candidates: `ghcr.io`, `copilot.github.com`, `*.copilot.github.com`, `copilot-proxy.githubusercontent.com`, `api.githubcopilot.com`, `copilot-telemetry.githubusercontent.com`, `pkg.github.com`, `uploads.github.com`. Any others in active use? | Confirmed list; each classified as splice-only in Squid config | WS-1, WS-4 |
| 4 | Does VS Code Copilot honor `HTTPS_PROXY` for **all** its endpoints — completions, telemetry, auth, and the completions proxy? Does `api.githubcopilot.com` and `copilot-proxy.githubusercontent.com` traffic go through the configured proxy? Are there any hardcoded direct connections in the Copilot extension? | Verified: all Copilot traffic respects `HTTPS_PROXY`, or identified which endpoints bypass it | WS-1 (Phase 0 gate) |

### Early High-Risk Gate: Copilot Proxy Compatibility

**This must be resolved before investing in further implementation work.**

VS Code's Copilot extension must respect `HTTPS_PROXY` for **all** its
endpoints. If any Copilot endpoint bypasses the proxy, the architecture breaks
(traffic hits the iptables redirect to a potentially unreachable Squid address,
or fails entirely).

**What to verify** (OQ-4):
1. Does VS Code Copilot honor `HTTPS_PROXY` / `http.proxy` for all endpoints?
2. Does `api.githubcopilot.com` traffic go through the configured proxy?
3. Does `copilot-proxy.githubusercontent.com` traffic go through the proxy?
4. Are there any hardcoded direct connections in the Copilot extension?

**How to measure latency impact**: With the proxy in splice mode (no
inspection), measure completion latency with and without proxy. The added
latency should be minimal (one internal TCP hop), but autocomplete is the
most latency-sensitive operation. If measured latency is unacceptable, we
reassess — but measure first, decide from data.

### Punted Decisions

| Decision | Current default | Unpunt condition |
|----------|-----------------|------------------|
| Centralised Squid for multiple devcontainers | Per-devcontainer sidecar | Sidecar resource usage becomes noticeable, or allowlist management across projects becomes burdensome |
| Allowlist change hot-reload (no container rebuild) | Requires rebuild to deploy updated ACL and NO_PROXY | Allowlist changes become frequent enough that rebuilds are materially disruptive |
| Per-rule Squid CA (only ssl-bump connections trust Squid CA) | System-wide trust store install | Low priority; spliced connections never see Squid CA regardless |
| `objects.githubusercontent.com` content filtering | Allowed unfiltered (accepted residual risk) | Content-type/extension filtering via Squid ssl-bump becomes necessary (e.g., after a real binary injection incident) |

---

## 10. Workstreams & Execution Plan

### Phased Execution

#### Phase 0 — Risk Reduction
1. **Verify Copilot proxy compatibility** (OQ-4) — manual testing with
   `HTTPS_PROXY` pointed at a test Squid instance. If this fails, the
   architecture needs revision. **This gates all subsequent phases.**
2. **Compose migration** — convert `devcontainer.json` from Dockerfile-only to
   compose. Use `vhiribarren/echo-server` as Squid placeholder. Validate all
   mounts, capabilities, and lifecycle commands work in compose mode.

#### Phase 1 — Firewall Hardening (no Squid dependency)
3. **Fix iptables flush race** — set DROP policy before flush
4. **Restrict ipset to TCP** — prevent UDP/QUIC bypass
5. **Fix `NO_PROXY` parsing** — distinguish path entries from CIDR notation

#### Phase 2 — Squid Integration
6. **Replace echo-server with Squid** container in compose
7. **Implement allowlist-driven Squid config generation** in `deploy-security.sh`
   — read allowlist, classify entries (CIDR-family vs direct, splice vs bump),
   generate `squid.conf` with splice/bump rules
8. **Rework `init-firewall.sh` GitHub handling** — redirect GitHub CIDRs to
   Squid (`github-proxy` ipset) instead of direct-allowing via `allowed-domains`
9. **Shared deny log volume** — Squid writes denied-request log to shared
   volume, main devcontainer mounts read-only for Claude Code self-diagnosis
10. **Deploy SSH wrapper** with `ProxyCommand` for git-over-SSH through Squid

#### Phase 3 — Path Filtering
11. **Implement ssl-bump for repo-serving domains** — CA generation, cert
    deployment to system trust store and git config
12. **Implement URL path ACLs** in Squid for Type 3 allowlist entries
13. **Add `gist.github.com`** to ssl-bump domain list and repo-serving guard

#### Phase 4 — Hardening
14. **`objects.githubusercontent.com` content filtering** (if unpunted)
15. **Latency measurement** for Copilot through splice proxy
16. **Per-rule Squid CA** (deferred improvement)

### Workstreams

**WS-1 · Squid Sidecar**
Build the Squid container image with ssl-bump support in forward proxy mode.
Generate CA at first run, persist to named volume. Implement compose network
config (`squid-internal` / `squid-external` split; devcontainer gets both
`existing-external` and `squid-internal`). Implement ACL generation
(`deploy-security.sh` → `/etc/squid/github-acl.conf`). Add CONNECT :22 ACL.
Implement splice for non-inspected CIDR-family domains. Configure
denied-request log on shared volume. Validate path-level blocking, splice
passthrough, and SSH CONNECT. Use `peek → bump` for repo-serving domains,
`peek → splice` for all others (no `stare` step).

**WS-2 · SSH Wrapper**
Write `git-ssh-allowlist.sh` wrapper with ProxyCommand tunnelling for allowed
repos and fast-fail for blocked repos. Write Dockerfile steps: move real ssh,
deploy wrapper, set permissions. Validate interactive SSH, git SSH blocking,
and git SSH success via Squid tunnel.

**WS-3 · Devcontainer Integration**
Write `deploy-security.sh`: allowlist parser (Type 1/2 non-CIDR-family →
existing firewall passthrough; Type 1/2 CIDR-family → Squid splice config;
Type 3 → Squid ACL); `NO_PROXY` builder (excluding all CIDR-family domains);
CA cert install; profile script generation; feature flag evaluation. Idempotent,
no writable dependencies (deploy-copy model). Add `postCreateCommand` to
`devcontainer.json`. Validate end-to-end from VS Code attach.

**WS-4 · Existing Firewall Integration**
Add repo-serving domain guard to the existing iptables startup script (including
`gist.github.com`). Implement `github-proxy` ipset: fetch GitHub CIDRs, create
ipset, add iptables REDIRECT rules (TCP-only). Ensure `allowed-domains` ipset
rule is TCP-only. Implement DROP-before-flush. Extend the existing script to
skip Type 3 (path) entries and CIDR-family Type 1/2 entries — these must not
generate direct-allow rules. Confirm guard fires correctly on misconfiguration
(DO-10). Resolve OQ-3 (complete list of GitHub-family splice services).

### Join Points

| Join point | Workstreams | Interface contract |
|------------|-------------|-------------------|
| JP-1 · Squid ACL file | WS-1 ← WS-3 | `/etc/squid/github-acl.conf`: `acl allowed_github_paths url_regex` lines, one per Type 3 allowlist entry. WS-1 reads via `include`; WS-3 generates at postCreate. |
| JP-2 · CA cert export | WS-1 → WS-3 | Squid writes PEM to named volume at `/etc/squid/ca/squid-ca-cert.pem`. WS-3 reads from that path (mounted read-only). |
| JP-3 · SSH ProxyCommand target | WS-2 ↔ WS-1 | Wrapper hardcodes `squid:3128`. WS-1 exposes Squid on that name/port on `squid-internal` network. |
| JP-4 · Allowlist type parsing | WS-3 ↔ WS-4 | `deploy-security.sh` (WS-3) extracts non-CIDR-family Type 1/2 entries and passes them to the existing iptables script (WS-4). Interface: list of `host` or `host:port` strings, one per line, to stdin or temp file. Guard runs before iptables rules are applied. CIDR-family entries are NOT passed to the iptables script's direct-allow logic. |
| JP-5 · NO_PROXY profile script | WS-3 ↔ WS-1 | `/etc/profile.d/github-proxy.sh` (root-owned, written by WS-3 at postCreate) exports `HTTPS_PROXY`, `NO_PROXY`. Squid service name `squid` on `squid-internal` must be stable — WS-1 owns this. NO_PROXY must NOT include any GitHub/CIDR-family domain. |
| JP-6 · Deny log volume | WS-1 ↔ WS-3 | Squid writes denied-request log to `/var/log/squid/denied.log` on shared volume. Devcontainer mounts read-only at same path. WS-1 configures Squid `access_log`; WS-3 configures compose volume mount. |
| JP-7 · github-proxy ipset | WS-4 ↔ WS-1 | `init-firewall.sh` (WS-4) creates `github-proxy` ipset and REDIRECT rules pointing to `squid:3128`. WS-1 must have Squid listening on 3128 on `squid-internal`. Redirect is TCP-only. |

### Critical Path

1. **Phase 0 gate**: Copilot proxy compatibility verified (OQ-4)
2. **Phase 0**: Compose migration validated with echo-server placeholder
3. WS-1: Squid image builds; ssl-bump confirmed in forward proxy mode (OQ-1)
4. WS-4: guard added (with `gist.github.com`); DROP-before-flush; TCP-only
   ipset; `github-proxy` ipset with REDIRECT; misconfiguration test passes (DO-10)
5. WS-3: allowlist parser produces correct Type split with CIDR-family routing;
   `NO_PROXY` excludes all GitHub domains; deny log volume configured
6. WS-1 + WS-3: CA cert flow, Squid ACL generation, and splice config end-to-end
7. WS-2: SSH wrapper validates — fast-fail and ProxyCommand tunnel
8. Full stack: all DO acceptance criteria pass (including DO-12, DO-13, DO-14)
9. Concurrent stack test: two projects simultaneously, DO-11 verified

---

## 11. External Interfaces & APIs

```
# .devcontainer/allowlist  — STABLE
# Three entry types; each consumed independently.
#
# Type 1: host
#   → Non-CIDR-family: existing iptables script (direct allow); added to NO_PROXY
#   → CIDR-family (GitHub/githubusercontent): Squid splice; NOT added to NO_PROXY
#   → GUARD: repo-serving domains rejected (github.com, raw.githubusercontent.com,
#             codeload.github.com, api.github.com, gist.github.com)
#
# Type 2: host:port
#   → Same routing as Type 1
#
# Type 3: host/path-prefix  or  host:port/path-prefix
#   → Squid url_regex ACL; host added to HTTPS_PROXY scope
#   → NOT passed to iptables script; NOT added to NO_PROXY
#   → Path: exact (github.com/org/repo) or wildcard (github.com/org/*)
#
# Parse rule: presence of '/' after host portion (not as port separator,
# not CIDR notation /digits-only) identifies Type 3. All other non-blank,
# non-comment lines are Type 1/2.
#
# CIDR-family classification: domains matching *github.com,
# *githubusercontent.com, ghcr.io, *githubassets.com are CIDR-family.
# Additional families can be defined without format changes.

# .devcontainer/features.env  — STABLE
# Keys: GITHUB_GH_CLI_ENABLED=(true|false), GITHUB_OBJECTS_POLICY=(allow|block)

# deploy-security.sh  — PROVISIONAL
# Inputs: .devcontainer/allowlist, .devcontainer/features.env,
#         /etc/squid/ca/squid-ca-cert.pem (from named volume)
# Outputs:
#   /etc/squid/github-acl.conf         — Squid path ACL (root-owned)
#   /etc/squid/github-splice.conf      — Squid splice domain list (root-owned)
#   /etc/profile.d/github-proxy.sh     — HTTPS_PROXY, NO_PROXY exports (root-owned)
#   /usr/local/lib/security/allowlist.conf — root-owned copy for SSH wrapper
#   CA cert installed to system store and git http.sslCAInfo
# Also invokes existing iptables script with non-CIDR-family Type 1/2 entries
# Exit: 0 on success; non-zero with message on guard violation or missing input
# Idempotent: safe to run multiple times with the same result

# git-ssh-allowlist.sh  — STABLE
# Drop-in for /usr/bin/ssh. Reads /usr/local/lib/security/allowlist.conf.
# git invocations: allowlist check, then ProxyCommand tunnel or fast-fail.
# non-git invocations: ProxyCommand tunnel unconditionally.
```

---

## 12. Testing Strategy

All container operations use **rootless Podman** (`podman` / `podman compose`).
No Docker socket.

**Sidecar build and smoke test (Podman)**
```bash
podman build -t github-proxy:dev .devcontainer/squid/
podman run --rm github-proxy:dev squid -v | grep ssl   # ssl-bump compiled in
podman run --rm -d --name github-proxy-test \
  -p 3128:3128 github-proxy:dev
podman exec github-proxy-test squid -k check
podman exec github-proxy-test ls /etc/squid/ca/        # cert generated
podman stop github-proxy-test
```

**Unit tests (bats)**
- Allowlist parser: Type 1 non-CIDR-family entry → iptables passthrough +
  NO_PROXY; Type 1 CIDR-family entry → Squid splice config, NOT iptables,
  NOT NO_PROXY; Type 2 same distinction; Type 3 → Squid ACL + HTTPS_PROXY
  scope, NOT iptables, NOT NO_PROXY
- Guard: `github.com` → exit 1; `raw.githubusercontent.com` → exit 1;
  `gist.github.com` → exit 1; `ghcr.io` → allowed (Type 1, CIDR-family
  splice); `github.com/org/repo` → allowed (Type 3)
- NO_PROXY builder: correct comma-separated output from mixed allowlist;
  no GitHub/githubusercontent domains present in output
- NO_PROXY CIDR parsing: `host.example.com/24` kept (CIDR); `github.com/org/repo` excluded (Type 3)
- SSH wrapper argv: git-upload-pack, git-receive-pack, interactive, scp
- Iptables: DROP policy set before flush; ipset rules are TCP-only

**Integration tests (full compose stack)**
```bash
podman compose up -d

# DO-1: blocked unconditionally
unset HTTPS_PROXY
git clone https://github.com/unlisted-org/repo         # iptables redirect → Squid 403

# DO-1 via explicit proxy path
HTTPS_PROXY=http://squid:3128 \
  git clone https://github.com/unlisted-org/repo       # Squid 403

# DO-2: allowed repo via Squid
git clone https://github.com/allowed-org/allowed-repo  # succeeds

# DO-6: non-GitHub direct, no Squid CA
curl -v https://api.anthropic.com 2>&1 | grep -v "squid\|github-proxy"

# DO-7: GitHub-family spliced service (through Squid, real cert)
curl -v https://ghcr.io/v2/ 2>&1   # succeeds; cert is GitHub's, not Squid CA

# DO-10: guard fires on misconfiguration
echo "github.com" >> .devcontainer/allowlist
podman compose down && podman compose up 2>&1 | grep ERROR  # must show guard error
git checkout .devcontainer/allowlist

# DO-10 extended: gist.github.com also guarded
echo "gist.github.com" >> .devcontainer/allowlist
podman compose down && podman compose up 2>&1 | grep ERROR
git checkout .devcontainer/allowlist

# DO-11: concurrent stack isolation
# (second terminal, different project)
cd /path/to/project-b && podman compose up -d
podman network ls | grep squid-internal   # two separate networks

# DO-12: deny log observability
curl https://github.com/unlisted-org/repo 2>/dev/null
tail -1 /var/log/squid/denied.log   # shows the denied request

# DO-13: no open window during iptables flush
# (verify DROP policy is set before rules are applied — inspect script logic)

# DO-14: UDP/QUIC bypass blocked
# (verify ipset rules are TCP-only — inspect iptables -L output)
iptables -L OUTPUT -v -n | grep allowed-domains   # should show "tcp" protocol

podman compose down
```

**Regression (bypass resistance)**
```bash
# Existing firewall blocks direct GitHub even with no HTTPS_PROXY
unset HTTPS_PROXY HTTP_PROXY
curl https://github.com/unlisted-org/repo    # iptables redirect → Squid → 403

# SSH wrapper is only path to real binary
GIT_SSH_COMMAND=/usr/local/lib/security/ssh-real \
  git clone git@github.com:unlisted/repo.git # permission denied on ssh-real

# CIDR-family domains cannot bypass via direct connection
unset HTTPS_PROXY HTTP_PROXY
curl https://copilot.github.com    # iptables redirect → Squid → splice → succeeds
# (not direct — traffic went through Squid even without HTTPS_PROXY set)
```

---

## 13. Operational Considerations

### Observability

Squid access logs are written to the host path `/home/davidk/dotclaude/logs/`
rather than staying inside the ephemeral sidecar container. This makes logs
persistent across container restarts and accessible without `podman exec`.

**Deny-log observability from main devcontainer**

When Squid blocks a request, the denial must be observable from the main
devcontainer without requiring `docker exec` into the Squid sidecar. Claude
Code runs in the main container and needs to inspect block events to
diagnose network issues and recommend allowlist changes to the user.

**Mechanism**: Squid writes denied-request logs to a shared named volume.
The volume is mounted at `/var/log/squid/shared` inside the Squid sidecar
(a subdirectory of the main log path, which is a host bind mount for
access/cache logs). The same volume is mounted read-only at `/var/log/squid`
inside the devcontainer:

```yaml
# docker-compose.yml (deny-log volume mounts only; see §8 for full sketch)
services:
  squid:
    volumes:
      - squid-denied-logs:/var/log/squid/shared    # Squid writes denied.log here
  devcontainer:
    volumes:
      - squid-denied-logs:/var/log/squid:ro         # denied.log appears here

volumes:
  squid-denied-logs:
```

Squid config writes the deny log to the shared subdirectory:
```squid
logformat denied %ts.%03tu %6tr %>a %Ss/%03>Hs %<st %rm %ru %un %Sh/%<a %mt
access_log daemon:/var/log/squid/shared/denied.log logformat=denied deny
```

The path mapping: Squid writes to `/var/log/squid/shared/denied.log` →
`squid-denied-logs` volume → devcontainer sees it at `/var/log/squid/denied.log`.

The main devcontainer can then:
- `tail -f /var/log/squid/denied.log` for live monitoring
- Claude Code can read this log to self-diagnose "connection refused" errors
- Claude Code can read these logs to self-diagnose "connection refused" errors
  and suggest specific allowlist additions to the user

**Log rotation and persistence**: access/cache logs are persisted to the host
via the bind mount at `/home/davidk/dotclaude/logs/github-proxy-<slug>/`
(see Per-sidecar log isolation below). The deny-log shared volume
(`squid-denied-logs`) is a named Docker volume — it survives container
restarts but is not persisted to a specific host path. This is appropriate
for debugging logs that Claude Code reads in real time.

**Per-sidecar log isolation (collision avoidance)**

Each sidecar instance writes access/cache logs to a subdirectory named by the
devcontainer project slug, derived from the compose project name at sidecar
startup:

```
/home/davidk/dotclaude/logs/
  github-proxy-<project-slug>/
    access.log        <- Squid native format; one line per request
    cache.log         <- Squid startup/error events
```

The project slug for log directory naming is derived directly from
`COMPOSE_PROJECT_NAME` — the same value VS Code uses to namespace compose
networks and volumes. No separate `SQUID_LOG_SLUG` env var is needed; the
compose volume mount path uses the variable directly:

```yaml
# docker-compose.yml (sidecar service)
labels:
  squid-log-slug: "${COMPOSE_PROJECT_NAME}"
volumes:
  - /home/davidk/dotclaude/logs/github-proxy-${COMPOSE_PROJECT_NAME}:/var/log/squid
```

`COMPOSE_PROJECT_NAME` must be set in the shell or `.env` file before
`podman compose up`. VS Code sets it automatically from the devcontainer folder
name when launching via the devcontainer extension. For manual invocation, add
it to the project's `.env` file alongside other compose variables.

The directory is created by `deploy-security.sh` at postCreate if absent.
Multiple simultaneous sidecars write to separate directories (`github-proxy-projecta/`,
`github-proxy-projectb/`) with no shared file handles.

**Log rotation and cleanup**

Managed by `logrotate` on the WSL2 host, not inside the container:

```
# /etc/logrotate.d/github-proxy (WSL2 host)
/home/davidk/dotclaude/logs/github-proxy-*/access.log
/home/davidk/dotclaude/logs/github-proxy-*/cache.log {
    daily
    rotate 7          # 7 days retention
    compress
    delaycompress
    missingok         # no error if log absent (sidecar not running)
    notifempty
    sharedscripts
    postrotate
        # Signal Squid to reopen log files after rotation
        # Squid PID is inside the container; use podman kill
        podman ps --filter "label=squid-log-slug" --format "{{.Names}}" \
          | xargs -I{} podman kill --signal USR1 {} 2>/dev/null || true
    endscript
}
```

Logrotate is triggered by the WSL2 host cron or systemd timer. Daily rotation with 7-day retention bounds worst-case
disk use to approximately `(daily_request_volume × 7)`. For a single developer's
GitHub operations this is typically < 5 MB total across all projects.

**Stale project log directories** (from deleted devcontainers) accumulate
without cleanup. A companion entry in the logrotate `postrotate` block removes
directories whose matching sidecar container no longer exists:

```bash
# Prune log dirs for containers that no longer exist
for dir in /home/davidk/dotclaude/logs/github-proxy-*/; do
    slug=$(basename "$dir" | sed 's/github-proxy-//')
    podman ps -a --filter "label=squid-log-slug=$slug" \
      --format "{{.Names}}" | grep -q . || rm -rf "$dir"
done
```

### Error Handling & Recovery
- **Squid down**: `HTTPS_PROXY` points at a dead address; GitHub connections
  fail. Iptables REDIRECT also sends traffic to an unresponsive Squid. Non-GitHub
  traffic (direct via existing network) is unaffected — Claude retains all
  non-GitHub capability. Recovery: `podman compose restart squid`.
  This is a graceful degradation, not a total failure.
- **CA cert missing at postCreateCommand**: `deploy-security.sh` exits non-zero
  with a clear message. Do not silently proceed — git over HTTPS will fail with
  TLS errors harder to diagnose than a missing cert.
- **Guard fires at startup**: container exits with explicit error identifying the
  problematic allowlist entry. Resolution: remove or convert to a path entry.
- **`COMPOSE_PROJECT_NAME` collision**: two stacks share `squid-internal` network
  name; one fails to start or routes to the wrong Squid. Verify unique names
  before concurrent operation (OQ-2).

### Security & Trust Boundary
- The allowlist source in `.devcontainer/` is Claude-editable. This is
  intentional: the human reviews and commits changes. The deployed copy at
  `/usr/local/lib/security/allowlist.conf` is root-owned; it is only updated
  by `deploy-security.sh` at container build time (a human action). Claude
  cannot expand the allowed surface without human review and a container rebuild.
- The Squid CA cert is a trust root inside the devcontainer. It must not be
  exported to the WSL2 host trust store or other containers.
- **`objects.githubusercontent.com` is an accepted residual hole in the outer
  shell.** The attack surface is larger than just release assets: it serves
  release assets, LFS objects, and user-uploaded images in issues/PRs. An
  attacker can upload a binary as a release asset on *any* public repo they
  control, then include a link in an issue comment on a repo Claude *is*
  working with. The allowlist "human gate" doesn't help because it controls
  repo cloning, not arbitrary URL fetches. Any `curl`/`wget` invocation
  targeting a GitHub release asset URL will succeed regardless of whether
  the source repo is in the allowlist. The primary mitigation is the allowlist
  human gate — an injected prompt cannot silently expand what repos Claude can
  clone, limiting the attacker's ability to stage binaries in a repo Claude
  can be directed to pull from. Document this gap explicitly in the project
  SECURITY.md.

---

## 14. Risk Register

| Risk | Likelihood / Impact | Mitigation |
|------|---------------------|------------|
| Binary injection via `objects.githubusercontent.com`: injected prompt directs Claude to `curl` a prebuilt binary from any public GitHub release; path is a content hash, allowlist cannot block it. Attack surface includes release assets, LFS objects, and user-uploaded images in issues/PRs — attacker uploads binary to any public repo, links it in an issue comment on a repo Claude is working with. | Medium / High | Accepted residual risk. Partial mitigation: human gate on allowlist prevents attacker staging a binary in a repo Claude can be directed to clone. Document in SECURITY.md. Revisit if `GITHUB_OBJECTS_POLICY=block` becomes tolerable. Future mitigation: route through Squid ssl-bump with content-type/extension filtering (block `application/octet-stream`, `application/x-executable`, `application/zip`; allow images and text). |
| Squid ssl-bump in forward proxy mode not working in rootless Podman (OQ-1) | Medium / High | Exploration ticket; custom Go proxy is the fallback. SNI-only blocking is not acceptable — see §16. |
| `COMPOSE_PROJECT_NAME` collision (OQ-2): two stacks share `squid-internal` network name; one routes to wrong Squid or fails to start | Low / High | Exploration ticket; verify VS Code naming produces unique values. Document naming constraint. |
| Allowlist misconfiguration: repo-serving domain added as host-only entry, granting direct GitHub access that bypasses Squid | Low / High | Guard in existing iptables script rejects these entries and fails container startup with explicit error (DO-10). Guard covers all five repo-serving domains including `gist.github.com`. |
| Copilot extension bypasses `HTTPS_PROXY` for some endpoints: completions traffic goes direct, hitting iptables REDIRECT to Squid (may fail or route incorrectly) | Medium / Medium | OQ-4 — must verify before implementation. If Copilot bypasses proxy, architecture needs revision (possibly Copilot-specific exceptions or alternative routing). |
| UDP/QUIC bypass: if GitHub enables HTTP/3 (`Alt-Svc: h3`), clients could bypass Squid via QUIC on UDP/443 | Low / High | ipset rules are TCP-only; UDP to GitHub CIDRs dropped by default OUTPUT DROP policy (DO-14). GitHub does not currently advertise HTTP/3 as of 2026-03-18; this is a preventive measure. |
| Iptables flush race condition: between flush and rule application, container has unrestricted access | Low / High | DROP-before-flush: set `iptables -P OUTPUT DROP` before `iptables -F` (DO-13). |
| `gist.github.com` as attack vector: serves attacker-controlled content (arbitrary code snippets); prompt injection could direct Claude to fetch a gist containing malicious instructions | Medium / Medium | Added to repo-serving domain guard; ssl-bump with path filtering; cannot be a host-only allowlist entry. |
| GitHub-family direct-access service list incomplete (OQ-3): a service not in the list is spliced unnecessarily or blocked | Low / Low | Incorrect routing, not a security issue. Squid splices unknown GitHub-family traffic. Correct by adding to splice list. |
| Injected prompt modifies `.devcontainer/allowlist` to add unauthorized path entries | Medium / Low | Deployed `allowlist.conf` is root-owned; changes require container rebuild (human action). Edit is visible in version control. |
| Allowlisted repo contains malicious tooling staging further payloads within the allowed surface | Low / Medium | Out of scope. Acknowledged residual risk of any allowlist-based approach. |
| Squid down: GitHub access lost | Low / Low | Non-GitHub traffic unaffected (direct via existing network). Graceful degradation. Recovery: `podman compose restart squid`. |
| Stale named volumes from deleted projects accumulate | Low / Low | Human cleanup. No security impact; disk space only. |

## 15. Rollout Strategy

Apply to one devcontainer first. Run acceptance criteria manually. Confirm
non-GitHub traffic is unaffected (Anthropic API, pypi, npm). Confirm
GitHub-family spliced services (Copilot, ghcr.io) work through Squid without
ssl-bump overhead. Measure Copilot autocomplete latency with splice proxy
vs direct. Then extend to remaining devcontainers by copying the
`.devcontainer` additions and adjusting the per-project allowlist.

## 16. Feature Prioritization and Descoping Plan

1. Cut first: `gh` CLI support (`GITHUB_GH_CLI_ENABLED`). Remove api.github.com
   from scope entirely; adds ACL complexity for a future-use feature.
2. Cut second: org wildcard support in allowlist. Exact repo entries only reduces
   allowlist parser complexity and ACL size.
3. **Not acceptable as a fallback**: SSL-bump + Squid replaced by domain-only
   blocking (SNI-level). Domain-only blocking cannot distinguish repos within
   `github.com`. This defeats the stated goal — any repository becomes
   accessible — and must not be treated as a viable descope. If Squid ssl-bump
   is unresolvable in rootless Podman (OQ-1), the correct response is to pursue
   a custom Go proxy (see §17) rather than accept SNI-only filtering.

---

## 17. Alternatives Considered

| Alternative | Reason rejected |
|-------------|----------------|
| Squid as sole egress (all traffic through Squid) | Routes non-GitHub traffic through Squid unnecessarily: adds a single point of failure for all external access (Squid down → Claude loses Anthropic API, package registries, everything); requires Squid CA cert trusted for all TLS, not just GitHub; adds latency to performance-sensitive package downloads. The existing default-deny firewall already handles non-GitHub access reliably. |
| Direct firewall allow for GitHub-family services (Copilot, ghcr.io) with Squid only for repo-serving domains | Rejected after CIDR analysis. GitHub's anycast architecture means all services share the same broad CIDR blocks. Allowing `copilot.github.com` at the IP level also allows `github.com`. IP-level service separation is impossible. All GitHub traffic must route through Squid (splice for non-inspected, bump for repo-serving). |
| WSL2 host iptables (transparent redirect) | Requires host modification; iptables state resets on WSL2 restart; rules from multiple tools corrupt the nat table (known failure mode); Podman compose has no native postStop hook for cleanup. Compose network topology achieves the same enforcement with none of these failure modes. |
| `HTTPS_PROXY` env var only | Trivially bypassed by `unset`; provides no enforcement. The existing firewall default-deny + iptables REDIRECT is what makes the architecture enforce correctly when `HTTPS_PROXY` is unset. |
| mitmproxy (Python) | Correct capability set; Python runtime overhead; Squid is purpose-built with native ACL engine. |
| tinyproxy | Cannot SSL-bump; only sees CONNECT hostname, not path. Insufficient for repo-level filtering. |
| Custom Go proxy | Would work; rejected to avoid writing TLS interception code. Revisit if Squid ssl-bump proves unworkable in rootless Podman (OQ-1). |
| Single shared Squid for all devcontainers | Per-project allowlists require independent instances; each project's compose stack needs its own `squid-internal` network. |
| Allowlist in container ENV vars | Not version-controlled with project; not Claude-editable in the right place; harder to audit. |

---

## 18. References

### Design Details
Included by reference:
- `allowlist.example` — annotated example with all three entry types
- `deploy-security.sh` — allowlist parser, Squid ACL generator, NO_PROXY builder, CA install
- `git-ssh-allowlist.sh` — SSH wrapper (allowlist check + ProxyCommand tunnelling)
- `iptables-firewall.sh` — existing firewall script (extended with repo-serving domain guard, github-proxy ipset, DROP-before-flush, TCP-only ipset)
- `docker-compose.yml` — dual-network compose topology with healthcheck and deny-log volume
- `squid.conf` — Squid configuration (ssl-bump peek+bump, splice, ACL includes, CONNECT :22, denied-request log)
- `/etc/profile.d/github-proxy.sh` — generated HTTPS_PROXY / NO_PROXY exports

### External References
- Squid ssl-bump: https://wiki.squid-cache.org/Features/SslBump
- Squid forward proxy ACL: https://wiki.squid-cache.org/SquidFaq/SquidAcl
- Podman compose `internal` network: https://docs.podman.io/en/latest/markdown/podman-network-create.1.html
- GitHub API meta endpoint (CIDR source): https://api.github.com/meta
- Source chat thread: TBD — add link before committing

---

<!-- ═══════════════════════════════════════════════════════════════════
BACKLOG GENERATION INSTRUCTIONS FOR CLAUDE CODE
(This block travels with the document. Do not delete.)

When generating the initial ticket backlog from this Delivery Spec:

TICKET SHAPE
- Use the project ticket template (template.md) for every ticket.
- One ticket per discrete, independently-reviewable unit of work.
- Ticket title format: imperative verb phrase ("Add X", "Refactor Y").

DEV ENVIRONMENT TICKETS
- Generate from Section 8 "Development Environment". These are P1 tickets
  that block nearly all implementation work.
- Typical ticket breakdown (combine or split as appropriate for the project):
  1. DEVCONTAINER / ENV SETUP — system packages, language runtime, dev
     dependencies, firewall allowlist, IDE config, gitignore. Verification
     checklist from §8 becomes the acceptance criteria.
  2. CONTAINER BUILD TOOLING (if applicable) — install and configure
     container build capability (Podman/Docker-in-Docker/etc.) inside
     the dev environment. Separate ticket because it has distinct
     verification steps and may require privileged configuration.
- Every implementation ticket should depend on the dev environment ticket(s).
- Walk the full dependency tree (requirements.txt, package.json, etc.) to
  identify system-level packages. Do not assume the base image has them.
- Include the firewall allowlist for ALL known external hosts. Mark TBD
  hosts with a note referencing the exploration ticket that will resolve them.
- Label: infrastructure

EXPLORATION TICKETS
- Generate one EXPLORATION ticket per row in Section 9 Open Questions.
- Mark each as a blocker on all tickets in the dependent workstream.
- Label: exploration

WORKSTREAMS & SWIMLANES
- Map WS-N names directly to swimlane front-matter values.
- Encode join-point dependencies as depends_on: front-matter links.

PUNTED DECISIONS
- Do not generate implementation tickets for punted decisions unless
  the unpunt condition is already satisfied.

DONE OBJECTIVES
- Attach the relevant Done Objective number(s) (with text slug for mnemonic
  clarity) to each ticket that contributes to fulfilling that objective.

═══════════════════════════════════════════════════════════════════ -->
