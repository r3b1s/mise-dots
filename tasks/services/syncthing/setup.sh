#!/usr/bin/env bash
#MISE description="Install rootless Syncthing Quadlet container (Arch-based)"
#MISE alias="services:syncthing"
#USAGE flag "--reconfigure" help="Prompt again for Tailscale IPv4 address"
#USAGE flag "--remove" help="Stop service and remove container unit"
#USAGE flag "-n --dry-run" help="Preview actions without modifying system"
set -euo pipefail

source "${MISE_TASK_DIR}/../../../lib/common.sh"
require_arch

say()  { printf '\033[1;34m::\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
run()  { if [ "$dry" = 1 ]; then echo "+ $*"; else "$@"; fi; }

reconfigure=0
remove=0
dry=0

[[ "${usage_reconfigure:-false}" == "true" ]] && reconfigure=1
[[ "${usage_remove:-false}" == "true" ]] && remove=1
[[ "${usage_dry_run:-false}" == "true" ]] && dry=1

for arg in "$@"; do
    case "$arg" in
        --reconfigure) reconfigure=1 ;;
        --remove)      remove=1 ;;
        -n|--dry-run)  dry=1 ;;
    esac
done

if [ "$(id -u)" -eq 0 ]; then
    die "run this as your own user, not root: the container is rootless"
fi

template="${MISE_TASK_DIR}/../../../lib/services/syncthing/syncthing.container"
dest="${XDG_CONFIG_HOME:-$HOME/.config}/containers/systemd/syncthing.container"

# ── Removal ───────────────────────────────────────────────────────────────────
if [ "$remove" = 1 ]; then
    say "Stopping and removing Syncthing Quadlet container..."
    if command -v systemctl >/dev/null 2>&1; then
        if systemctl --user is-active --quiet syncthing.service 2>/dev/null; then
            say "Stopping syncthing.service"
            run systemctl --user stop syncthing.service
        fi
    fi
    if [ -f "$dest" ]; then
        say "Removing $dest"
        run rm -f "$dest"
        command -v systemctl >/dev/null 2>&1 && run systemctl --user daemon-reload
    fi
    say "Syncthing container unit removed. Data in ~/Sync and ~/.local/share/syncthing-container is preserved."
    exit 0
fi

# ── Prerequisites ─────────────────────────────────────────────────────────────
if ! command -v podman >/dev/null 2>&1 || ! command -v pasta >/dev/null 2>&1; then
    say "Installing podman and passt (needed for rootless quadlet networking)..."
    run sudo pacman -S --needed --noconfirm podman passt
fi

# The IPv4 address on tailscale0 right now, or nothing when Tailscale is down.
tailscale0_ip() {
    ip -4 -o addr show dev tailscale0 2>/dev/null | awk '{ split($4, a, "/"); print a[1]; exit }'
}

# The address the installed unit publishes 22000 on, or nothing.
installed_ip() {
    [ -f "$dest" ] || return 0
    sed -n 's|^PublishPort=\([0-9.]*\):22000:22000/tcp$|\1|p' "$dest"
}

# Prints the Tailscale IPv4 address to publish on (stdout); prompts go to stderr.
ask_tailscale_ip() {
    local def answer o ok
    local octet='(0|[1-9][0-9]{0,2})'
    def=$(tailscale0_ip)
    while :; do
        if ! read -rp "Tailscale (tailscale0) address of this host${def:+ [$def]}: " answer && [ -z "$answer" ]; then
            printf '\nno address given\n' >&2
            return 1
        fi
        answer=${answer:-$def}
        ok=0
        if [[ $answer =~ ^$octet(\.$octet){3}$ ]]; then
            ok=1
            for o in ${answer//./ }; do (( o <= 255 )) || ok=0; done
        fi
        case $answer in 0.0.0.0|127.*)
            echo "$answer is not a Tailscale address" >&2; continue ;;
        esac
        if [ "$ok" = 1 ]; then
            printf '%s\n' "$answer"
            return 0
        fi
        echo "not an IPv4 address: ${answer:-(empty)}" >&2
    done
}

ip=
[ "$reconfigure" = 1 ] || ip=$(installed_ip)
if [ -n "$ip" ]; then
    say "Tailscale address: $ip (from the installed unit; --reconfigure to change)"
else
    ip=$(ask_tailscale_ip)
fi
current=$(tailscale0_ip)
[ "$ip" = "$current" ] || warn "tailscale0 has ${current:-no address} now, not $ip; syncthing will retry until $ip is up"

rendered=$(mktemp)
trap 'rm -f "$rendered"' EXIT
sed "s/@TAILSCALE_IP@/$ip/g" "$template" > "$rendered"

changed=1
cmp -s "$rendered" "$dest" 2>/dev/null && changed=0
if [ "$changed" = 1 ]; then
    say "writing $dest"
    [ "$dry" = 1 ] && { diff -u "$dest" "$rendered" 2>/dev/null || true; }
    run mkdir -p "$(dirname "$dest")" "$HOME/Sync"
    run install -m 0644 "$rendered" "$dest"
    run systemctl --user daemon-reload
fi

if systemctl --user -q is-active syncthing.service 2>/dev/null; then
    if [ "$changed" = 1 ]; then
        say "restarting syncthing.service"
        run systemctl --user restart syncthing.service
    fi
else
    say "starting syncthing.service (the first start pulls the image)"
    run systemctl --user start syncthing.service
fi

if [ "$(loginctl show-user "$USER" -p Linger --value 2>/dev/null)" != yes ]; then
    warn "syncthing stops when you log out; to keep it running: loginctl enable-linger"
fi
say "GUI: http://127.0.0.1:8384 (set a GUI password; add $HOME/Sync as the folder)"
say "give each remote device a static address (Edit > Advanced > Addresses):"
say "  tcp://<peer Tailscale IP>:22000, quic://<peer Tailscale IP>:22000"
say "and give this host's to the peers: tcp://$ip:22000, quic://$ip:22000"
