#!/usr/bin/env bash
#MISE description="Set the origin remote of every repo cloned under ~/Dotfiles to SSH"
set -euo pipefail
source "${MISE_TASK_DIR}/../../../lib/common.sh"

shopt -s nullglob
for gitdir in "${DOTS_DIR}"/*/.git "${DOTS_DIR}"/*/*/.git; do
  [[ -d "$gitdir" ]] || continue
  repo="${gitdir%/.git}"

  if ! origin="$(git -C "$repo" remote get-url origin 2>/dev/null)"; then
    printf 'No origin remote, skipping: %s\n' "$repo"
    continue
  fi

  if [[ "$origin" == git@*:* ]]; then
    printf 'Already SSH, skipping:     %s (%s)\n' "$repo" "$origin"
    continue
  fi

  ssh_url="$(https_to_ssh "$origin")"
  git -C "$repo" remote set-url origin "$ssh_url"
  printf 'Rewrote origin to SSH:     %s (%s -> %s)\n' "$repo" "$origin" "$ssh_url"
done
