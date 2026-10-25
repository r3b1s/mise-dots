#!/usr/bin/env bash
#MISE description="Clone the Omarchy Pinkrot theme"
#USAGE flag "--ssh" help="Rewrite the cloned remote to SSH"
set -euo pipefail
source "${MISE_TASK_DIR}/../../../lib/common.sh"

use_ssh_when_requested "${usage_ssh:-false}"
clone_repo "$DOTS_THEME_HTTPS" "$DOTS_THEME_SSH" "${DOTS_DIR}/${DOTS_THEME_NAME}"
