#!/usr/bin/env bash
#MISE description="Clone kanata-enthium (Kanata keyboard layout)"
#USAGE flag "--ssh" help="Rewrite the cloned remote to SSH"
set -euo pipefail
source "${MISE_TASK_DIR}/../../../lib/common.sh"

use_ssh_when_requested "${usage_ssh:-false}"
clone_repo "$DOTS_KANATA_HTTPS" "$DOTS_KANATA_SSH" "$DOTS_KANATA_DIR"
