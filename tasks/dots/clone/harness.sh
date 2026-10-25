#!/usr/bin/env bash
#MISE description="Clone harness-dots (AI harness configs)"
#USAGE flag "--ssh" help="Rewrite the cloned remote to SSH"
set -euo pipefail
source "${MISE_TASK_DIR}/../../../lib/common.sh"

use_ssh_when_requested "${usage_ssh:-false}"
clone_repo "$DOTS_HARNESS_HTTPS" "$DOTS_HARNESS_SSH" "$DOTS_HARNESS_DIR"
