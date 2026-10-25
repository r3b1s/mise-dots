#!/usr/bin/env bash
#MISE description="Set up Omarchy with personal dotfiles"
#USAGE flag "--ssh" help="Rewrite cloned remotes to SSH"
set -euo pipefail
source "${MISE_TASK_DIR}/../../../lib/common.sh"

require_os omarchy
use_ssh_when_requested "${usage_ssh:-false}"

# Omarchy dotfiles
clone_repo "$DOTS_OMARCHY_HTTPS" "$DOTS_OMARCHY_SSH" "$DOTS_OMARCHY_DIR"
bash < "${DOTS_OMARCHY_DIR}/install.sh"

# Omarchy Pinkrot theme
clone_repo "$DOTS_THEME_HTTPS" "$DOTS_THEME_SSH" "${DOTS_DIR}/${DOTS_THEME_NAME}"
link_theme

# AI harness configs
clone_repo "$DOTS_HARNESS_HTTPS" "$DOTS_HARNESS_SSH" "$DOTS_HARNESS_DIR"

# Point this dotfiles checkout at SSH too
if [[ "${DOTS_GIT_PROTOCOL:-https}" == "ssh" ]]; then
  git -C "$DOTS_MISE_DIR" remote set-url origin "$DOTS_MISE_SSH"
fi
