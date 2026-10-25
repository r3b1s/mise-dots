#!/usr/bin/env bash
#MISE description="Set up Arch/CachyOS with personal dotfiles"
#USAGE flag "--ssh" help="Rewrite cloned remotes to SSH"
set -euo pipefail
source "${MISE_TASK_DIR}/../../../lib/common.sh"

use_ssh_when_requested "${usage_ssh:-false}"

# Arch dotfiles
clone_repo "$DOTS_ARCH_HTTPS" "$DOTS_ARCH_SSH" "$DOTS_ARCH_DIR"
bash < "${DOTS_ARCH_DIR}/install.sh"

# Omarchy Pinkrot theme
clone_repo "$DOTS_THEME_HTTPS" "$DOTS_THEME_SSH" "${DOTS_DIR}/${DOTS_THEME_NAME}"
link_theme

# AI harness configs
clone_repo "$DOTS_HARNESS_HTTPS" "$DOTS_HARNESS_SSH" "$DOTS_HARNESS_DIR"
