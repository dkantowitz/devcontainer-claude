#!/bin/bash
set -euo pipefail  # Exit on error, undefined vars, and pipeline failures
IFS=$'\n\t'       # Stricter word splitting

# Usage: init-firewall.sh [container-name]

# ── Bypass check ─────────────────────────────────────────────────────
# /etc/firewall/ is a directory bind-mounted read-only from the host's
# ~/dotclaude/firewall/. Directory mount prevents the single-file mv
# attack (replacing an inode-based mount via parent directory rename).
#
# Per-container override: $1 is the container name (workspace folder basename),
# passed as a command-line argument from postStartCommand.  If a file named
# <container-name>.conf exists it takes precedence over the global
# firewall.conf.  Deleting the per-container file reverts to the global
# default (one-shot toggle).
FIREWALL_DIR="/etc/firewall"
CONTAINER_NAME="${1:-}"
FIREWALL_CONF=""

if [ -n "$CONTAINER_NAME" ] && [ -f "${FIREWALL_DIR}/${CONTAINER_NAME}.conf" ]; then
    FIREWALL_CONF="${FIREWALL_DIR}/${CONTAINER_NAME}.conf"
    echo "Using per-container firewall config: ${FIREWALL_CONF}"
elif [ -f "${FIREWALL_DIR}/firewall.conf" ]; then
    FIREWALL_CONF="${FIREWALL_DIR}/firewall.conf"
fi

if [ -n "$FIREWALL_CONF" ]; then
    mode=$(tr -d '[:space:]' < "$FIREWALL_CONF")
    if [ "$mode" = "bypass" ]; then
        echo "Firewall BYPASSED (${FIREWALL_CONF} = bypass)"
        echo "Container has unrestricted network access."
        # Ensure default policies are ACCEPT (Docker default, but be explicit)
        iptables -P INPUT ACCEPT
        iptables -P FORWARD ACCEPT
        iptables -P OUTPUT ACCEPT
        iptables -F
        exit 0
    fi
fi

# ── Allowlist paths ──────────────────────────────────────────────────
# Defined early so they are available to both the hash guard and the
# allowlist-loading section below.
HOST_ALLOWLIST="/etc/firewall/allowlist"
PROJECT_ALLOWLIST="/workspace/.devcontainer/allowlist"
HASH_FILE="/var/run/firewall-allowlist.sha256"

# ── Allowlist-hash gated rerun ───────────────────────────────────────
# On first run, hash both allowlists and store the combined digest.
# On subsequent runs, only proceed if neither allowlist has been modified.
# This prevents an agent from injecting entries into either allowlist and
# re-running the script to open arbitrary network access, while still
# allowing legitimate reruns (e.g., after a DNS resolution failure).

compute_allowlist_hash() {
    # Hash the concatenation of both allowlist files (host + project).
    # Either file may be absent; absent files contribute empty content.
    # A fixed sentinel is appended when both files are missing so the
    # result is still deterministic across runs.
    local host_content project_content
    host_content=$(cat "$HOST_ALLOWLIST" 2>/dev/null || true)
    project_content=$(cat "$PROJECT_ALLOWLIST" 2>/dev/null || true)
    if [ -z "$host_content" ] && [ -z "$project_content" ]; then
        echo "no-allowlist-files"
    else
        echo "${host_content}${project_content}" | sha256sum | awk '{print $1}'
    fi
}

current_hash=$(compute_allowlist_hash)

if [ -f "$HASH_FILE" ]; then
    stored_hash=$(cat "$HASH_FILE")
    if [ "$current_hash" != "$stored_hash" ]; then
        echo "ERROR: Allowlist has been modified since the firewall was first initialised."
        echo "  Stored hash : $stored_hash"
        echo "  Current hash: $current_hash"
        echo "  Files       : $HOST_ALLOWLIST, $PROJECT_ALLOWLIST"
        echo ""
        echo "Refusing to rerun.  Restart the container to apply a new allowlist."
        exit 1
    fi
    echo "Hash-validated rerun — allowlists unchanged"
else
    echo "Initial firewall run — recording combined allowlist hash"
fi

# ── Firewall config ──────────────────────────────────────────────────

# 1. Extract Docker DNS info BEFORE any flushing
DOCKER_DNS_RULES=$(iptables-save -t nat | grep "127\.0\.0\.11" || true)

# Flush existing rules and delete existing ipsets
iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X
iptables -t mangle -F
iptables -t mangle -X
ipset destroy allowed-domains 2>/dev/null || true

# 2. Selectively restore ONLY internal Docker DNS resolution
if [ -n "$DOCKER_DNS_RULES" ]; then
    echo "Restoring Docker DNS rules..."
    iptables -t nat -N DOCKER_OUTPUT 2>/dev/null || true
    iptables -t nat -N DOCKER_POSTROUTING 2>/dev/null || true
    echo "$DOCKER_DNS_RULES" | grep -v '^#' | xargs -L 1 iptables -t nat
else
    echo "No Docker DNS rules to restore"
fi

# First allow DNS and localhost before any restrictions
# Allow outbound DNS (UDP for standard queries, TCP for large responses)
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT
# Allow inbound DNS responses (stateful — only replies to our own queries)
iptables -A INPUT -p udp --sport 53 -m state --state ESTABLISHED -j ACCEPT
# Allow localhost
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# Create ipset with CIDR support
ipset create allowed-domains hash:net

# Resolves DOMAIN via DNS, validates IPs, and adds each to allowed-domains ipset.
# Prints "Adding $ip for $domain" for each valid IP.
# Prints a WARNING for any individual IP that fails validation (and skips it).
# Returns 0 if at least one IP was successfully added, 1 otherwise.
resolve_and_add() {
    local domain="$1"
    local ips ip added=0
    ips=$(dig +noall +answer A "$domain" | awk '$4 == "A" {print $5}')
    if [ -z "$ips" ]; then
        return 1
    fi
    while read -r ip; do
        if [[ ! "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            echo "WARNING: Invalid IP for $domain: $ip (skipping)"
            continue
        fi
        echo "Adding $ip for $domain"
        ipset add --exist allowed-domains "$ip"
        added=$((added + 1))
    done < <(echo "$ips")
    [ "$added" -gt 0 ]
}

# Resolve and add Claude Code required domains.
# Attempt all of them before failing so every problem is visible at once.
required_failed=false
for domain in \
    "api.anthropic.com" \
    "console.anthropic.com" \
    "statsig.anthropic.com" \
    "statsig.com" \
    "sentry.io"; do
    echo "Resolving $domain..."
    if ! resolve_and_add "$domain"; then
        echo "ERROR: Failed to resolve required domain: $domain"
        required_failed=true
    fi
done
if [ "$required_failed" = true ]; then
    # echo "ERROR: One or more required domains failed; aborting."
    # exit 1
    echo "WARNING: One or more required domains for claude failed to resolve"
fi

# Read additional domains/CIDRs from allowlist files.
# Two allowlists are merged:
#   1. Host allowlist: /etc/firewall/allowlist (from ~/dotclaude/firewall/allowlist on host)
#      — user-level, shared across all projects (read-only directory mount)
#   2. Project allowlist: /workspace/.devcontainer/allowlist
#      — per-project, checked into the repo
# Entries are deduplicated. Either or both may be absent (non-fatal).
# (HOST_ALLOWLIST and PROJECT_ALLOWLIST are set at the top of this script.)
github_triggered=false

# Build a deduplicated combined entry list from both allowlists.
# Uses an associative array as a set to discard duplicates.
declare -A seen_entries
combined_entries=()

process_allowlist_file() {
    local file="$1"
    local label="$2"
    if [ ! -f "$file" ]; then
        return
    fi
    echo "Loading extra entries from $file ($label)..."
    while IFS= read -r line || [[ -n "$line" ]]; do
        local no_comment entry
        no_comment="${line%%#*}"                              # strip trailing (or single line) comments
        entry="${no_comment#"${no_comment%%[![:space:]]*}"}"  # strip leading spaces
        entry="${entry%"${entry##*[![:space:]]}"}"            # strip trailing spaces

        [[ -z "$entry" || "$entry" == "#"* ]] && continue    # ignore blank and comment-only lines

        if [[ -z "${seen_entries["$entry"]+_}" ]]; then
            seen_entries["$entry"]=1
            combined_entries+=("$entry")
        fi
    done < "$file"
}

process_allowlist_file "$HOST_ALLOWLIST" "host"
process_allowlist_file "$PROJECT_ALLOWLIST" "project"

for entry in "${combined_entries[@]}"; do
    # github domains encountered flags us to do the full github
    # anycast CIDR block lookup.
    if [[ "$entry" =~ (github|githubusercontent)\.com$ ]]; then
        github_triggered=true
        continue
    fi

    # directly handle explicit ipv4 addresses
    if [[ "$entry" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}(/[0-9]{1,2})?$ ]]; then
        echo "Adding $entry from allowlist"
        ipset add --exist allowed-domains "$entry"
        continue
    fi

    # DNS lookup & add
    echo "Resolving $entry from allowlist..."
    resolve_and_add "$entry" || echo "WARNING: Failed to resolve $entry (skipping)"
done

# GitHub domains use CIDR block fetching rather than DNS — a single DNS
# lookup only returns a rotating subset of GitHub's anycast IPs, which
# breaks git operations that land on a different server.
if [ "$github_triggered" = true ]; then
    echo "GitHub domain detected — fetching CIDR ranges from api.github.com/meta..."
    gh_ranges=$(curl -s https://api.github.com/meta || true)
    if [ -z "$gh_ranges" ]; then
        echo "WARNING: Failed to fetch GitHub IP ranges (skipping GitHub)"
    elif ! echo "$gh_ranges" | jq -e '.web and .api and .git' >/dev/null 2>&1; then
        echo "WARNING: GitHub API response missing required fields (skipping GitHub)"
    else
        # Note: only the web, api, and git CIDR sets are fetched. GitHub also
        # publishes ranges for actions, packages (ghcr.io), copilot, and pages —
        # add those keys to the jq expression if you need those services.
        # Note: aggregate discards IPv6 CIDRs silently; this ipset is IPv4-only.
        while read -r cidr; do
            if [[ ! "$cidr" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]; then
                echo "WARNING: Invalid CIDR from GitHub meta: $cidr (skipping)"
                continue
            fi
            echo "Adding GitHub range $cidr"
            ipset add --exist allowed-domains "$cidr"
        done < <(echo "$gh_ranges" | jq -r '(.web + .api + .git + .copilot)[]' | aggregate -q)
    fi
fi

# Get host IP from default route
HOST_IP=$(ip route | grep default | head -1 | cut -d" " -f3)
if [ -z "$HOST_IP" ]; then
    echo "ERROR: Failed to detect host IP"
    exit 1
fi

HOST_NETWORK=$(echo "$HOST_IP" | sed "s/\.[0-9]*$/.0\/24/")
echo "Host network detected as: $HOST_NETWORK"

# Set up remaining iptables rules
iptables -A INPUT -s "$HOST_NETWORK" -j ACCEPT
iptables -A OUTPUT -d "$HOST_NETWORK" -j ACCEPT

# Allow established/related connections — must be added before the DROP policies
# so in-flight connections are not severed the instant the policies flip.
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# Set default policies to DROP — anything not matched by an ACCEPT rule is blocked.
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT DROP

# Then allow only specific outbound traffic to allowed domains
iptables -A OUTPUT -m set --match-set allowed-domains dst -j ACCEPT

# Explicitly REJECT all other outbound traffic for immediate feedback
iptables -A OUTPUT -j REJECT --reject-with icmp-admin-prohibited

echo "Firewall configuration complete"
echo "Verifying firewall rules..."
if curl --connect-timeout 5 https://example.com >/dev/null 2>&1; then
    echo "ERROR: Firewall verification failed - was able to reach https://example.com"
    exit 1
else
    echo "Firewall verification passed - unable to reach https://example.com as expected"
fi

# ── Store allowlist hash ────────────────────────────────────────────
# Written after successful verification so a failed first run doesn't
# leave a stale hash file that blocks retries.
echo "$current_hash" > "$HASH_FILE"
chmod 0444 "$HASH_FILE"
echo "Allowlist hash stored in $HASH_FILE"

