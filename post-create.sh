#!/bin/bash
# .devcontainer/post-create.sh
set -euo pipefail

echo "Running post-create setup..."

# Shell history directory
mkdir -p /workspace/.devcontainer/commandhistory

echo "Post-create setup complete"