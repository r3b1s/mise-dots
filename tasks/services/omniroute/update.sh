#!/usr/bin/env bash
#MISE description="Back up OmniRoute, pull the latest images, and restart the pod"
#USAGE flag "--no-backup" help="Skip the automatic pre-update backup (not recommended)"
#USAGE flag "-n --dry-run" help="Preview actions without pulling or restarting"
set -euo pipefail

HERE=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

dry=0
no_backup=0

[[ "${usage_dry_run:-false}" == "true" ]] && dry=1
[[ "${usage_no_backup:-false}" == "true" ]] && no_backup=1

for arg in "$@"; do
    case "$arg" in
        --no-backup) no_backup=1 ;;
        -n|--dry-run) dry=1 ;;
    esac
done

say()  { printf '\033[1;34m::\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
run()  { if [ "$dry" = 1 ]; then echo "+ $*"; else "$@"; fi; }

if [ "$(id -u)" -eq 0 ]; then
    die "run this as your own user, not root: the pod is rootless"
fi
command -v podman >/dev/null 2>&1 || die "podman is required"
command -v systemctl >/dev/null 2>&1 || die "systemctl is required"

if ! systemctl --user -q is-enabled omniroute-pod.service 2>/dev/null; then
    die "omniroute-pod.service is not installed: run 'mise run services:omniroute' first"
fi

# ── 1. Back up first (credentials live in the data dir) ──────────────────────
if [ "$no_backup" = 1 ]; then
    warn "skipping the pre-update backup (--no-backup)"
else
    say "Backing up before the update..."
    args=()
    [ "$dry" = 1 ] && args+=(--dry-run)
    "$HERE/backup.sh" "${args[@]}" || die "backup failed: aborting the update"
fi

# ── 2. Pull ───────────────────────────────────────────────────────────────────
say "Pulling docker.io/diegosouzapw/omniroute:latest and docker.io/library/redis:8-alpine..."
run podman pull docker.io/diegosouzapw/omniroute:latest
run podman pull docker.io/library/redis:8-alpine

# ── 3. Restart ────────────────────────────────────────────────────────────────
if systemctl --user -q is-active omniroute-pod.service 2>/dev/null; then
    say "Restarting omniroute-pod.service on the new images..."
    run systemctl --user restart omniroute-pod.service
else
    say "omniroute-pod.service is installed but not running; starting it..."
    run systemctl --user start omniroute-pod.service
fi

say "Update done. Dashboard: check the version in the UI footer."
