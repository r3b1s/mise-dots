#!/usr/bin/env bash
#MISE description="Clone qubes-dots (Qubes OS dotfiles)"
#USAGE flag "--ssh" help="Rewrite the cloned remote to SSH"
set -euo pipefail
source "${MISE_TASK_DIR}/../../../lib/common.sh"

use_ssh_when_requested "${usage_ssh:-false}"
clone_repo "$DOTS_QUBES_HTTPS" "$DOTS_QUBES_SSH" "$DOTS_QUBES_DIR"
