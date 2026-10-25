#!/usr/bin/env bash
#MISE description="Clone cachy-dots (Arch dotfiles)"
#USAGE flag "--ssh" help="Rewrite the cloned remote to SSH"
set -euo pipefail
source "${MISE_TASK_DIR}/../../../lib/common.sh"

use_ssh_when_requested "${usage_ssh:-false}"
clone_repo "$DOTS_ARCH_HTTPS" "$DOTS_ARCH_SSH" "$DOTS_ARCH_DIR"
