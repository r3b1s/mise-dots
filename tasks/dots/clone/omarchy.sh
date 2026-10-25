#!/usr/bin/env bash
#MISE description="Clone quattro-dots (Omarchy dotfiles)"
#USAGE flag "--ssh" help="Rewrite the cloned remote to SSH"
set -euo pipefail
source "${MISE_TASK_DIR}/../../../lib/common.sh"

use_ssh_when_requested "${usage_ssh:-false}"
clone_repo "$DOTS_OMARCHY_HTTPS" "$DOTS_OMARCHY_SSH" "$DOTS_OMARCHY_DIR"
