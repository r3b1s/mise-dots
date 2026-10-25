#!/usr/bin/env bash
#MISE description="Clone all dotfiles repositories"
#USAGE flag "--ssh" help="Rewrite cloned remotes to SSH"
set -euo pipefail
source "${MISE_TASK_DIR}/../../../lib/common.sh"

use_ssh_when_requested "${usage_ssh:-false}"

TASK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for script in "${TASK_DIR}"/*.sh; do
  [[ -f "$script" ]] || continue
  [[ "$(basename "$script")" == "all.sh" ]] && continue
  "$script" "$@"
done
