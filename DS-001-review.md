# DS-001 Review: Requirements and Technical Solutions

**Reviewer:** Claude Code (automated review)
**Date:** 2026-03-18 (revised 2026-03-19)
**Document:** DS-001-devcontainer-web-and-github-access-control v0.5

---

## Design Goal

The primary goal is to specify network access rules in `.devcontainer/allowlist`
using three entry types:

| Type | Format | Example | Enforcement |
|------|--------|---------|-------------|
| 1 — Host | `name` | `registry.npmjs.org` | iptables ipset (direct) |
| 2 — Host+Port | `name:port` or `name:port/proto` | `host.docker.internal:9222` | iptables per-IP rule |
| 3 — Path | `name/path` | `github.com/org/repo` | Squid ssl-bump + URL ACL |

The system must create the combination of iptables and Squid proxy rules to
enforce this allowlist with the **least performance impact** — only traffic that
*requires* inspection (path-based rules) goes through Squid. Everything else
goes direct via iptables.

**Exception: CIDR based product families.** All GitHub/githubusercontent traffic must go through Squid because GitHub's anycast CIDR architecture makes IP-level service
separation impossible (see §1 below). Squid uses `splice` (passthrough) for
non-inspected GitHub domains and `ssl-bump` only for repo-serving domains
that need path filtering.  Potentially Google must be handled the same way, so this approach must be generic beyond github.  (see `init-firewall.sh` on branch proj-voicemail).

All components (`init-firewall.sh`, `deploy-security.sh`, Squid config
generation) process the **same single allowlist** file and act only on the portions
relevant to their task. There is no splitting of the file into separate pieces.

---

## Resolved Architecture Decisions

These decisions are final. The review findings that prompted them are preserved
below for context.

### D1. All GitHub Traffic Through Squid (Option A)

Every GitHub-family domain goes through Squid. The iptables firewall blocks
direct access to all GitHub CIDRs. `NO_PROXY` must NOT include any GitHub or
githubusercontent.com domains.

Squid handles GitHub traffic in two modes:
- **ssl-bump + path filter**: `github.com`, `api.github.com`,
  `raw.githubusercontent.com`, `codeload.github.com`, `gist.github.com`
  (repo-serving domains requiring URL inspection)
- **splice (passthrough)**: `copilot.github.com`, `ghcr.io`,
  `copilot-proxy.githubusercontent.com`, `api.githubcopilot.com`,
  `copilot-telemetry.githubusercontent.com`, etc. (no inspection, opaque
  CONNECT tunnels — clients see GitHub's real certificate)

Spliced connections add one internal TCP hop. No CA cert substitution occurs.

### D2. UDP Automatically Disabled for ssl-bump Domains

For any hostname that requires Squid path filtering (ssl-bump), `init-firewall.sh`
must ensure UDP to that hostname's IPs is blocked. Since Squid cannot intercept
QUIC (HTTP/3 over UDP/443), allowing UDP would create a proxy bypass.

For GitHub specifically: the broad ipset rule must be TCP-only:
```bash
iptables -A OUTPUT -p tcp -m set --match-set github-proxy dst -j REDIRECT ...
# No UDP rule for GitHub CIDRs — UDP to GitHub is dropped by default OUTPUT DROP
```

For non-GitHub domains requiring ssl-bump: add explicit UDP drop rules per-IP
before the ipset ACCEPT rule.

### D3. Fix Iptables Flush Race Condition

The current `init-firewall.sh` flushes all rules (line 95) before applying new
ones. Between flush and completion, the container has unrestricted access.

**Fix**: Set `DROP` policy *before* flushing, or use `iptables-restore` for
atomic rule replacement. The preferred approach:
```bash
# Set restrictive policy FIRST (before any flush)
iptables -P OUTPUT DROP
iptables -P INPUT DROP
iptables -P FORWARD DROP
# Now safe to flush — default is already DROP
iptables -F
iptables -X
# ... apply new rules ...
```

### D4. Add `gist.github.com` to Repo-Serving Domain Guard

`gist.github.com` serves user-controlled content (arbitrary code snippets).
Claude rarely needs gist access for normal work. Add it to the ssl-bump
domain list with path filtering, alongside `github.com`, `api.github.com`,
`raw.githubusercontent.com`, and `codeload.github.com`.

### D5. Squid CA Trust: System Trust Store First, Per-Rule CA Deferred

Initial implementation installs the Squid CA into the system trust store, git
config (`http.sslCAInfo`), and per-tool env vars. This is the simplest approach
that works.

**Deferred improvement** (low priority): path-filter-specific Squid CA — only
connections that actually undergo ssl-bump MITM would need to trust the Squid
CA. Connections that are spliced never see the Squid CA regardless.

### D6. Compose Migration as Early Task

The current `devcontainer.json` uses `build.dockerfile` (no compose). The Squid
sidecar requires compose. This is a **significant migration** and should be an
early task in the work stream:

- `devcontainer.json` switches from `"build"` to `"dockerComposeFile"` +
  `"service"` syntax
- `runArgs` (`--cap-add=NET_ADMIN`, `--cap-add=NET_RAW`, `--env-file`) move
  to compose `services.devcontainer` config
- All `mounts` translate to compose `volumes`
- Use `vhiribarren/echo-server` as a placeholder for the Squid proxy container
  during initial compose migration (swap for real Squid later)

### D7. Single Allowlist, No Splitting

`deploy-security.sh` must NOT split the allowlist into separate files. Every
component (`init-firewall.sh`, Squid config generator, `NO_PROXY` builder)
reads the same allowlist and acts only on entries relevant to its function:

- `init-firewall.sh`: processes Type 1 (host) and Type 2 (host:port) entries
  for iptables rules; for GitHub entries, redirects traffic to Squid instead
  of allowing direct
- Squid config generator: processes Type 3 (path) entries for ssl-bump ACLs;
  processes GitHub entries for splice/bump classification
- `NO_PROXY` builder: includes Type 1 and Type 2 entries, excludes Type 3
  and all GitHub/githubusercontent domains

### D8. `deploy-security.sh` Security Model

The `deploy-security.sh` script requires a sudoers entry. It must be:
- **Idempotent**: safe to run multiple times with the same result
- **No writable dependencies**: must not depend on any file that the
  `remoteUser` (node) account can write to — use the "deploy copy" model
  (root-owned copies of config) and/or hash verification
- The hash guard in `init-firewall.sh` computes against the *original*
  allowlist (before any processing)

### D9. Squid Deny Logs Visible from Main Devcontainer

When Squid blocks a request, the denial must be observable from the main
devcontainer without requiring `docker exec` into the Squid sidecar. Claude
Code runs in the main container and needs to inspect block events to
diagnose network issues and recommend allowlist changes to the user.

**Mechanism**: Squid writes denied-request logs to a shared volume mounted
read-only into the main devcontainer:

```yaml
# docker-compose.yml
services:
  squid:
    volumes:
      - squid-logs:/var/log/squid
  devcontainer:
    volumes:
      - squid-logs:/var/log/squid:ro

volumes:
  squid-logs:
```

Squid config uses a dedicated `access_log` directive for denials:
```squid
logformat denied %ts.%03tu %6tr %>a %Ss/%03>Hs %<st %rm %ru %un %Sh/%<a %mt
access_log daemon:/var/log/squid/denied.log denied deny !all
```

The main devcontainer can then:
- `tail -f /var/log/squid/denied.log` for live monitoring
- `grep DENIED /var/log/squid/access.log` for historical lookups
- Claude Code can read these logs to self-diagnose "connection refused" errors
  and suggest specific allowlist additions to the user

**Log rotation**: Squid's built-in `logfile_rotate` handles rotation inside
the sidecar. The shared volume survives container restarts but is ephemeral
(not persisted to host) — appropriate for debugging logs.

---

## Findings Requiring Implementation

### F1. GitHub CIDR Overlap Makes IP-Level Service Separation Impossible

Live data from `api.github.com/meta` confirms all GitHub services share the
same broad CIDR blocks:

| Shared IPv4 CIDRs | Services |
|---|---|
| `192.30.252.0/22` | web, api, git, copilot, packages |
| `185.199.108.0/22` | web, api, git, copilot |
| `140.82.112.0/20` | web, api, git, copilot, packages |
| `143.55.64.0/20` | web, api, git, copilot |

The existing `init-firewall.sh` already demonstrates this: lines 267-268 use
a single `github_triggered` flag, and line 306 dumps `web + api + git + copilot`
CIDRs into one ipset. You cannot allow `copilot.github.com` at the IP level
without also allowing `github.com`.

**Resolution**: Decision D1 — all GitHub traffic through Squid.

### F2. `init-firewall.sh` ipset Allows UDP (QUIC Bypass Risk)

Line 335:
```bash
iptables -A OUTPUT -m set --match-set allowed-domains dst -j ACCEPT
```
This matches ALL protocols (TCP + UDP) to allowed IPs. If any service enables
HTTP/3 (QUIC on UDP/443), clients could bypass Squid entirely.

**Current status**: GitHub does not advertise HTTP/3 (`Alt-Svc: h3`) as of
2026-03-18, but this is a latent vulnerability.

**Resolution**: Decision D2. For the immediate fix, restrict the ipset rule
to TCP:
```bash
iptables -A OUTPUT -p tcp -m set --match-set allowed-domains dst -j ACCEPT
```

### F3. Iptables Flush-Then-Apply Race Condition

Lines 94-101 flush all rules before applying new ones. If the script exits
between flush and completion, the container has unrestricted network access.

**Resolution**: Decision D3.

### F4. `gist.github.com` Missing from Domain Guard

Serves attacker-controlled content (arbitrary code snippets). A prompt
injection could direct Claude to fetch a gist containing malicious instructions.

**Resolution**: Decision D4.

### F5. `NO_PROXY` Parsing Bug

The grep pattern `'^[^/]+/[^/]'` intended to exclude Type 3 (path) entries
would also exclude CIDR entries like `host.example.com/24` if allowlist formats
are merged. The existing `init-firewall.sh` supports CIDRs (lines 273-277).

**Fix**: Use a more precise pattern that distinguishes path entries (containing
at least two path segments) from CIDR notation (single `/` followed by digits
only):
```bash
# Exclude Type 3 path entries but keep CIDR notation
grep -vE '^[^/]+/[^0-9]|^[^/]+/[0-9]+/'
```


### F6. Squid `ssl_bump` Step Ordering

The v0.5 Squid config sketch uses `peek → stare → bump`. In forward proxy mode
with CONNECT, Squid already knows the hostname from the CONNECT request —
`stare` (completing the TLS handshake to see the server cert) is unnecessary
for hostname-based decisions and adds an extra round-trip.

**Fix**: Use `peek + bump` for known domains, skip `stare`:
```squid
ssl_bump peek all
ssl_bump bump github_repo_domains
ssl_bump splice all
```

### F7. `objects.githubusercontent.com` Residual Risk

The attack surface is larger than stated in v0.5. `objects.githubusercontent.com`
serves release assets, LFS objects, and user-uploaded images in issues/PRs.
An attacker can upload a binary as a release asset on *any* public repo they
control, then include a link in an issue comment on a repo Claude *is* working
with. The allowlist "human gate" doesn't help because it controls repo cloning,
not arbitrary URL fetches.

**Suggested mitigation for future implimentation**: Route `objects.githubusercontent.com` through Squid
with ssl-bump and apply content-type / file-extension filtering. Block
executable content types (`application/octet-stream`, `application/x-executable`,
`application/zip`, etc.) while allowing images and text. Alternatively, add
`objects.githubusercontent.com` to the ssl-bump domain list with an explicit
allowlist of URL path patterns (e.g., only allow paths matching known-safe
patterns like avatar URLs). This is a defense-in-depth measure — the primary
mitigation remains Claude's instruction-following behavior.



### F8. Container Lifecycle Timing

The design must ensure the environment "just works" with no debugging required.
Clear lifecycle:

```
postCreateCommand (runs once after container creation):
  1. deploy-security.sh:
     - Reads allowlist, generates Squid ACL config
     - Generates NO_PROXY value
     - Deploys SSH wrapper
     - All outputs are root-owned (deploy copy model)
     - Idempotent — safe to re-run

postStartCommand (runs every container start):
  1. Wait for Squid sidecar health check (compose `depends_on` +
     `healthcheck`)
  2. init-firewall.sh:
     - Sets DROP policy first (D3)
     - Flushes and applies iptables rules
     - Redirects GitHub CIDRs to Squid
     - Applies ipset for direct-allowed domains
     - Hash-validates allowlist hasn't changed
  3. Verify connectivity (existing example.com check)
```

The hash guard in `init-firewall.sh` must compute against the original
allowlist file, not any generated artifacts. Since `deploy-security.sh` does
not modify the allowlist (D7), this is satisfied by the current design.

**Compose `depends_on` with healthcheck** ensures Squid is ready before the
firewall script redirects traffic to it. No race condition.

### F9. `init-firewall.sh` `github_triggered` Flag Rework

The current flag (line 267) treats all `*github*` and `*githubusercontent*`
domains identically. With Decision D1, this needs rework:

- When any GitHub/githubusercontent domain appears, fetch CIDRs as before
- But instead of adding them to `allowed-domains` ipset (which allows direct
  access), add them to a separate `github-proxy` ipset
- Add an iptables rule to redirect `github-proxy` traffic to the Squid proxy
  (REDIRECT or DNAT to squid:3128)
- The allowlist parser must recognize GitHub entries and route them to the
  proxy path, not the direct path

### F10. No Squid Observability from Main Devcontainer

The Squid proxy runs as a sidecar container. When it denies a request, the
main devcontainer sees only a generic connection error (e.g., HTTP 403 from
Squid, or TCP RST). There is no way for Claude Code — running in the main
container — to inspect *why* a request was blocked or which allowlist entry
is missing.

This is a significant usability gap. The current `init-firewall.sh` approach
is debuggable because iptables logs and the allowlist are both local to the
container. Moving enforcement to a sidecar breaks that self-diagnosability.

**Impact**: Network errors become opaque. Claude Code cannot recommend
specific allowlist changes. Users must manually `docker exec` into the Squid
container, find logs, correlate timestamps — defeating the "just works" goal.

**Resolution**: Decision D9 — shared log volume, deny-specific access log.

---

## Early High-Risk Question

### Copilot Proxy Compatibility (Must Resolve Before Further Work)

VS Code's Copilot extension must respect `HTTPS_PROXY` for **all** its
endpoints — completions, telemetry, auth, and the completions proxy. If any
Copilot endpoint bypasses the proxy, the architecture breaks.

**What to verify**:
1. Does VS Code Copilot honor `HTTPS_PROXY` / `http.proxy` for all endpoints?
2. Does `api.githubcopilot.com` traffic go through the configured proxy?
3. Does `copilot-proxy.githubusercontent.com` traffic go through the proxy?
4. Are there any hardcoded direct connections in the Copilot extension?

**How to measure latency impact**: With the proxy in splice mode (no
inspection), measure completion latency with and without proxy. The added
latency should be minimal (one internal TCP hop), but autocomplete is the
most latency-sensitive operation. If measured latency is unacceptable, we
reassess — but measure first, decide from data.

**This must be resolved before investing in further implementation work.**

---

## Work Stream Decomposition

Suggested ordering based on dependency and risk:

### Phase 0 — Risk Reduction
1. **Verify Copilot proxy compatibility** — manual testing with `HTTPS_PROXY`
   pointed at a test Squid instance. If this fails, the architecture needs
   revision.
2. **Compose migration** — convert `devcontainer.json` from Dockerfile-only to
   compose. Use `vhiribarren/echo-server` as Squid placeholder. Validate all
   mounts, capabilities, and lifecycle commands work in compose mode.

### Phase 1 — Firewall Hardening (no Squid dependency)
3. **Fix iptables flush race** (D3) — set DROP before flush
4. **Restrict ipset to TCP** (D2/F2) — prevent UDP/QUIC bypass
5. **Fix `NO_PROXY` parsing** (F5)

### Phase 2 — Squid Integration
6. **Replace echo-server with Squid** container in compose
7. **Implement allowlist-driven Squid config generation** in `deploy-security.sh`
   — read allowlist, classify entries, generate `squid.conf` with splice/bump
   rules
8. **Rework `init-firewall.sh` GitHub handling** (F9) — redirect GitHub CIDRs
   to Squid instead of direct-allowing
9. **Shared deny log volume** (D9/F10) — Squid writes denied-request log to
   shared volume, main devcontainer mounts read-only for Claude Code
   self-diagnosis
10. **Deploy SSH wrapper** with `ProxyCommand` for git-over-SSH through Squid

### Phase 3 — Path Filtering
11. **Implement ssl-bump for repo-serving domains** — CA generation, cert
    deployment to system trust store and git config
12. **Implement URL path ACLs** in Squid for Type 3 allowlist entries
13. **Add `gist.github.com`** to ssl-bump domain list (D4)

### Phase 4 — Hardening
14. **`objects.githubusercontent.com` content filtering** (F7)
15. **Latency measurement** for Copilot through splice proxy
16. **Per-rule Squid CA** (D5 deferred improvement)

---

## Appendix: GitHub CIDR Research

Data retrieved 2026-03-18 from `api.github.com/meta`:

| Service | Dedicated IPs? | Separable from github.com via IP? |
|---|---|---|
| api.github.com | Has unique /32s, shares broad CIDRs | No |
| copilot.github.com | Has 11 unique /32s, shares broad CIDRs | No |
| ghcr.io | Has unique /32s, all within shared CIDRs | No |
| gist.github.com | No dedicated IPs at all | No |
| git (SSH/HTTPS) | Shares exact same IPs as web | No |

GitHub does not currently serve HTTP/3 on any service (no `Alt-Svc: h3`
headers as of 2026-03-18). All services respond HTTP/2. UDP/443 blocking is
a preventive measure.
