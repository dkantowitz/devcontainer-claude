#!/usr/bin/env bash
# claude-wrapper.sh — shadows the npm claude binary inside the devcontainer.
# Pins project to -workspace and skips permission prompts (firewall is the
# security boundary, not the permission system).
#
# Installed by the Dockerfile to /usr/local/bin/claude, overriding the npm shim.

REAL_CLAUDE=/usr/local/share/npm-global/lib/node_modules/@anthropic-ai/claude-code/cli.js

cd /workspace || exit 1
exec node "$REAL_CLAUDE" --dangerously-skip-permissions "$@"
