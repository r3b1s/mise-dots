#!/usr/bin/env bash
#MISE description="Install and configure Paseo daemon systemd user service"
#MISE alias="services:paseo:setup"
#USAGE flag "--netbird" help="Bind daemon to NetBird (wt0) IPv4 address"
#USAGE flag "--tailscale" help="Bind daemon to Tailscale (tailscale0) IPv4 address"
#USAGE flag "--remove" help="Stop service and remove systemd unit"
#USAGE flag "-n --dry-run" help="Preview actions without modifying system"
set -euo pipefail

source "${MISE_TASK_DIR}/../../lib/common.sh"
require_arch

say()  { printf '\033[1;34m::\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
run()  { if [ "$dry" = 1 ]; then echo "+ $*"; else "$@"; fi; }

dry=0
remove=0
iface=

[[ "${usage_dry_run:-false}" == "true" ]] && dry=1
[[ "${usage_remove:-false}" == "true" ]] && remove=1
if [[ "${usage_netbird:-false}" == "true" ]]; then
    iface=wt0
fi
if [[ "${usage_tailscale:-false}" == "true" ]]; then
    if [ -n "$iface" ]; then
        die "--netbird and --tailscale exclude each other"
    fi
    iface=tailscale0
fi

for arg in "$@"; do
    case "$arg" in
        --netbird|--tailscale)
            want=wt0
            [ "$arg" = --netbird ] || want=tailscale0
            if [ -n "$iface" ] && [ "$iface" != "$want" ]; then
                die "--netbird and --tailscale exclude each other"
            fi
            iface=$want
            ;;
        --remove)     remove=1 ;;
        -n|--dry-run) dry=1 ;;
    esac
done

service_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
service_file="$service_dir/paseo.service"
paseo_home="$HOME/.paseo"
port=6767

# ── Removal ───────────────────────────────────────────────────────────────────
if [ "$remove" = 1 ]; then
    say "Removing Paseo systemd user service..."
    if command -v systemctl >/dev/null 2>&1; then
        if systemctl --user is-active --quiet paseo 2>/dev/null; then
            say "Stopping running paseo.service..."
            run systemctl --user stop paseo
        fi
        if systemctl --user is-enabled --quiet paseo 2>/dev/null; then
            say "Disabling paseo.service..."
            run systemctl --user disable paseo
        fi
    fi

    if [ -f "$service_file" ]; then
        say "Removing $service_file..."
        run rm -f "$service_file"
    fi

    if command -v systemctl >/dev/null 2>&1; then
        say "Reloading systemd user daemon..."
        run systemctl --user daemon-reload
    fi

    if command -v mise >/dev/null 2>&1; then
        say "Removing @getpaseo/cli from global mise configuration..."
        run mise unuse -g npm:@getpaseo/cli 2>/dev/null || true
    fi

    say "Paseo service and global CLI registration removed."
    exit 0
fi

# ── Prerequisites ─────────────────────────────────────────────────────────────
command -v mise >/dev/null 2>&1 || die "mise is required to install Paseo via the npm backend. Install mise first."
command -v jq >/dev/null 2>&1 || die "jq is required"

# ── 1. Install CLI via mise (npm backend) ────────────────────────────────────
say "Installing @getpaseo/cli globally via mise (npm backend)..."
run mise use -g npm:@getpaseo/cli
run mise reshim 2>/dev/null || true

if [ "$dry" != 1 ]; then
    if ! mise exec -- paseo --version >/dev/null 2>&1; then
        warn "Could not verify paseo execution via mise exec. Ensure Node.js is configured in mise or available in PATH."
    else
        version=$(mise exec -- paseo --version)
        say "Paseo CLI v${version} installed successfully via mise."
    fi
fi

# ── 2. Install systemd user service ──────────────────────────────────────────
say "Installing systemd user service to $service_file..."
run mkdir -p "$service_dir"
run cp "${MISE_TASK_DIR}/../../lib/services/paseo/paseo.service" "$service_file"

# ── 3. Daemon reload ──────────────────────────────────────────────────────────
say "Reloading systemd user daemon..."
run systemctl --user daemon-reload

# ── 4. Listen address ─────────────────────────────────────────────────────────
if [ -n "$iface" ]; then
    command -v ip >/dev/null 2>&1 || die "ip (iproute2) is required for --netbird and --tailscale"
    addr=$(ip -4 -o addr show dev "$iface" scope global 2>/dev/null | awk '{ sub(/\/.*/, "", $4); print $4; exit }')
    [ -n "$addr" ] || die "$iface has no IPv4 address: is $([ "$iface" = wt0 ] && echo NetBird || echo Tailscale) up?"
else
    addr=127.0.0.1
fi
listen="$addr:$port"

current=
if mise exec -- paseo --version >/dev/null 2>&1; then
    current=$(mise exec -- paseo daemon config get --home "$paseo_home" daemon.listen 2>/dev/null \
        | jq -r '.value // empty' 2>/dev/null) || current=
fi
if [ "$current" = "$listen" ]; then
    say "daemon.listen is $listen already"
else
    say "Setting Paseo's listen address to $listen${current:+ (was $current)}"
    if [ "$dry" = 1 ]; then
        echo "+ mise exec -- paseo daemon config set --home $paseo_home --string daemon.listen $listen"
    else
        mise exec -- paseo daemon config set --home "$paseo_home" --string daemon.listen "$listen" >/dev/null \
            || die "could not set daemon.listen in $paseo_home/config.json"
    fi
    if systemctl --user is-active --quiet paseo 2>/dev/null; then
        warn "paseo.service still listens on ${current:-its old address}: systemctl --user restart paseo"
    fi
fi

printf '\n'
say "Paseo setup complete!"
echo "  Self-hosted Web UI: http://$listen"
echo "  To start daemon:     systemctl --user start paseo"
echo "  To enable autostart: systemctl --user enable --now paseo"
