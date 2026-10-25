#!/usr/bin/env bash
#MISE description="Install hitkit from source (git clone, uv sync, doctor)"
#MISE alias="tools:hitkit:install"
#USAGE arg "[dir]" help="Target directory for checkout"
#USAGE flag "--ssh" help="Rewrite the cloned remote to SSH"
set -euo pipefail
source "${MISE_TASK_DIR}/../../lib/common.sh"

HITKIT_HTTPS="https://github.com/r3b1s/hitkit.git"
HITKIT_SSH="git@github.com:r3b1s/hitkit.git"

use_ssh_when_requested "${usage_ssh:-false}"

dest="${usage_dir:-${HOME}/Projects/hitkit}"
dest="${dest/#\~/$HOME}"

clone_repo "$HITKIT_HTTPS" "$HITKIT_SSH" "$dest"
cd "$dest"
uv sync
uv run hitkit doctor
