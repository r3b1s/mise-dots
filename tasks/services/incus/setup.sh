#!/usr/bin/env bash
#MISE description="Opt in to Incus system-container and VM manager (Arch-based)"
#MISE alias="services:incus"
#USAGE flag "--ui" help="Install incus-ui web UI package"
#USAGE flag "--remove" help="Disable incus services and remove firewall zone"
#USAGE flag "-n --dry-run" help="Preview actions without modifying system"
set -euo pipefail

source "${MISE_TASK_DIR}/../../../lib/common.sh"
source "${MISE_TASK_DIR}/../../../lib/firewalld.sh"
require_arch

BRIDGE=incusbr0
SUBID="root:1000000:1000000000"
ZONE=cachy-incus

say()  { printf '\033[1;34m::\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
run()  { if [ "$dry" = 1 ]; then echo "+ $*"; else "$@"; fi; }

ui=0
remove=0
dry=0

[[ "${usage_ui:-false}" == "true" ]] && ui=1
[[ "${usage_remove:-false}" == "true" ]] && remove=1
[[ "${usage_dry_run:-false}" == "true" ]] && dry=1

for arg in "$@"; do
    case "$arg" in
        --ui)         ui=1 ;;
        --remove)     remove=1 ;;
        -n|--dry-run) dry=1 ;;
    esac
done

command -v pacman >/dev/null || die "pacman not found: this is for Arch-based systems"

SUDO=
if [ "$(id -u)" -ne 0 ]; then SUDO=sudo; fi
user=${SUDO_USER:-$(id -un)}
[ "$user" != root ] || die "run it as your own user (or with sudo from it), so there is a user to give access to"

# ── Removal ───────────────────────────────────────────────────────────────────
if [ "$remove" = 1 ]; then
    if fw_installed; then
        fw_guest_zone_remove "$ZONE"
        fw_commit
    fi
    if systemctl is-enabled --quiet incus.service 2>/dev/null || systemctl is-enabled --quiet incus.socket 2>/dev/null; then
        warn "disabling Incus stops its running instances"
        say "Disabling incus.service and incus.socket"
        run $SUDO systemctl disable --now incus.service incus.socket
    fi
    if pacman -Qq incus-ui >/dev/null 2>&1; then
        say "Removing incus-ui"
        run $SUDO pacman -Rns --noconfirm incus-ui
    fi
    say "Done. The incus package, instances, storage, /etc/subuid, /etc/subgid and incus-admin are left as they were."
    exit 0
fi

# ── Packages ─────────────────────────────────────────────────────────────────
pkgs=(incus edk2-ovmf)
if [ "$ui" = 1 ]; then pkgs+=(incus-ui); fi
missing=()
for p in "${pkgs[@]}"; do
    pacman -Qq "$p" >/dev/null 2>&1 || missing+=("$p")
done
restart_reason=
if [ ${#missing[@]} -gt 0 ]; then
    say "Installing ${missing[*]} (pacman -Syu: never -S against a stale database)"
    run $SUDO pacman -Syu --needed --noconfirm "${missing[@]}" || die "could not install ${missing[*]}"
    case " ${missing[*]} " in *" incus-ui "*) restart_reason="incus-ui was installed" ;; esac
fi

# ── Subordinate IDs ──────────────────────────────────────────────────────────
for f in /etc/subuid /etc/subgid; do
    if ! grep -q '^root:' "$f" 2>/dev/null; then
        say "Adding $SUBID to $f"
        if [ "$dry" = 1 ]; then echo "+ echo $SUBID >> $f"; else printf '%s\n' "$SUBID" | $SUDO tee -a "$f" >/dev/null; fi
        restart_reason="${restart_reason:+$restart_reason and }new subordinate ID ranges"
    fi
done

# ── Services ─────────────────────────────────────────────────────────────────
was_active=0
if systemctl is-active --quiet incus.service 2>/dev/null; then was_active=1; fi

if ! systemctl is-enabled --quiet incus.service 2>/dev/null || ! systemctl is-enabled --quiet incus.socket 2>/dev/null; then
    say "Enabling and starting incus.socket and incus.service"
    run $SUDO systemctl enable --now incus.socket incus.service
fi

if [ -n "$restart_reason" ] && [ "$was_active" = 1 ]; then
    running=$($SUDO incus list --all-projects --format csv --columns ns 2>/dev/null | grep -c ',RUNNING$' || true)
    if [ "$running" = 0 ]; then
        say "Restarting incus.service ($restart_reason)"
        run $SUDO systemctl restart incus.service
    else
        warn "$restart_reason, and incus.service needs a restart for that. $running instance(s) are running, and a restart stops them: run 'sudo systemctl restart incus.service' when they can stop"
    fi
fi

# ── Group ────────────────────────────────────────────────────────────────────
if ! id -nG "$user" | tr ' ' '\n' | grep -qx incus-admin; then
    if [ "$dry" = 0 ] && ! getent group incus-admin >/dev/null; then
        die "no incus-admin group: the incus package's sysusers file should have made it"
    fi
    say "Adding $user to incus-admin (root-equivalent): log out of your desktop session and back in, or run \`newgrp incus-admin\` in a terminal"
    run $SUDO usermod -aG incus-admin "$user"
fi

# ── Firewalld ────────────────────────────────────────────────────────────────
if fw_installed; then
    fw_guest_zone "$ZONE" "$BRIDGE" "The default Incus bridge: DHCP and DNS from the host, and forwarding (tasks/services/incus). Bridges with other names are not covered."
    fw_commit
fi

echo
echo "Incus is configured. Next, as $user (after the group applies):"
echo "    incus admin init --minimal    # a dir storage pool and $BRIDGE; plain 'incus admin init' asks instead"
echo "    incus launch images:archlinux/cloud demo"
if [ "$ui" = 1 ]; then
    echo "    incus webui                   # the web UI, in your browser, over the local socket"
fi
