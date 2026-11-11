#!/usr/bin/env bash
#MISE description="Opt in to Sunshine GameStream server user service (Arch-based)"
#MISE alias="services:sunshine"
#USAGE flag "--remove" help="Stop service, remove autostart hooks, and uninstall sunshine"
#USAGE flag "-n --dry-run" help="Preview actions without modifying system"
set -euo pipefail

source "${MISE_TASK_DIR}/../../../lib/common.sh"
require_arch

PACMAN_CONF="/etc/pacman.conf"
BEGIN='# >>> cachy-dots lizardbyte >>>'
END='# <<< cachy-dots lizardbyte <<<'

say()  { printf '\033[1;34m::\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
run()  { if [ "$dry" = 1 ]; then echo "+ $*"; else "$@"; fi; }

SUDO=
[ "$(id -u)" -ne 0 ] && SUDO=sudo

remove=0
dry=0

[[ "${usage_remove:-false}" == "true" ]] && remove=1
[[ "${usage_dry_run:-false}" == "true" ]] && dry=1

for arg in "$@"; do
    case "$arg" in
        --remove)     remove=1 ;;
        -n|--dry-run) dry=1 ;;
    esac
done

command -v pacman >/dev/null || die "pacman not found: this is for Arch-based systems"

is_omarchy=0
if grep -qx 'ID=omarchy' /etc/os-release 2>/dev/null || pacman-conf --repo-list 2>/dev/null | grep -qx 'omarchy'; then
    is_omarchy=1
fi

is_cachyos=0
if grep -qx 'ID=cachyos' /etc/os-release 2>/dev/null || pacman-conf --repo-list 2>/dev/null | grep -qx 'cachyos'; then
    is_cachyos=1
fi

user_service_dst="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/sunshine.service"

# ── Removal ───────────────────────────────────────────────────────────────────
if [ "$remove" = 1 ]; then
    say "Stopping and removing Sunshine systemd user service..."
    if command -v systemctl >/dev/null 2>&1; then
        run systemctl --user stop sunshine.service 2>/dev/null || true
    fi
    if [ -f "$user_service_dst" ]; then
        run rm -f "$user_service_dst"
        command -v systemctl >/dev/null 2>&1 && run systemctl --user daemon-reload 2>/dev/null || true
    fi

    # Remove from i3 06-services.conf
    i3_services="${XDG_CONFIG_HOME:-$HOME/.config}/i3/conf.d/06-services.conf"
    if [ -f "$i3_services" ] && grep -qF "sunshine.service" "$i3_services"; then
        say "Removing sunshine autostart from $i3_services..."
        if [ "$dry" = 1 ]; then
            echo "+ remove sunshine from $i3_services"
        else
            sed -i '/sunshine\.service/d' "$i3_services"
            if ! grep -qvE '^[[:space:]]*(#.*)?$' "$i3_services"; then
                rm -f "$i3_services"
                echo "removed empty $i3_services"
            fi
        fi
    fi

    # Remove from Hyprland cachy-services.lua
    hypr_services="${XDG_CONFIG_HOME:-$HOME/.config}/hypr/cachy-services.lua"
    if [ -f "$hypr_services" ] && grep -qF "sunshine.service" "$hypr_services"; then
        say "Removing sunshine autostart from $hypr_services..."
        if [ "$dry" = 1 ]; then
            echo "+ remove sunshine from $hypr_services"
        else
            sed -i '/sunshine\.service/d' "$hypr_services"
            if ! grep -qvE '^[[:space:]]*(--.*)?$' "$hypr_services"; then
                rm -f "$hypr_services"
                echo "removed empty $hypr_services"
            fi
        fi
    fi

    if pacman -Qq sunshine >/dev/null 2>&1; then
        say "Removing sunshine package..."
        run $SUDO pacman -Rns --noconfirm sunshine
    fi

    if grep -qxF "$BEGIN" "$PACMAN_CONF" 2>/dev/null; then
        say "Removing [lizardbyte] repository from $PACMAN_CONF..."
        if [ "$dry" = 1 ]; then
            echo "+ delete $BEGIN block from $PACMAN_CONF"
        else
            $SUDO cp -a "$PACMAN_CONF" "$PACMAN_CONF.bak.$(date +%s)"
            $SUDO sed -i "\|^$BEGIN\$|,\|^$END\$|d" "$PACMAN_CONF"
            $SUDO sed -i -e :a -e '/^\n*$/{$d;N;ba' -e '}' "$PACMAN_CONF"
        fi
        dbpath=$(pacman-conf DBPath 2>/dev/null || echo /var/lib/pacman/)
        run $SUDO rm -f "${dbpath%/}/sync/lizardbyte.db"
    fi

    say "Sunshine uninstalled successfully."
    exit 0
fi

# ── Installation ─────────────────────────────────────────────────────────────
if [ "$is_omarchy" = 1 ]; then
    say "Detected Omarchy: installing exclusively from 'omarchy/sunshine'..."
    if ! pacman-conf --repo-list 2>/dev/null | grep -qx 'omarchy'; then
        die "omarchy repository not found in $PACMAN_CONF; refusing to fall back"
    fi
    run $SUDO pacman -S --needed --noconfirm omarchy/sunshine
elif [ "$is_cachyos" = 1 ]; then
    say "Detected CachyOS: installing exclusively from 'cachyos/sunshine'..."
    if ! pacman-conf --repo-list 2>/dev/null | grep -qx 'cachyos'; then
        die "cachyos repository not found in $PACMAN_CONF; refusing to fall back"
    fi
    run $SUDO pacman -S --needed --noconfirm cachyos/sunshine
else
    say "Configuring LizardByte pacman repository for Sunshine..."
    repo_listed=0
    pacman-conf --repo-list 2>/dev/null | grep -qx 'lizardbyte' && repo_listed=1

    if [ "$repo_listed" = 0 ]; then
        say "Adding [lizardbyte] repository to $PACMAN_CONF"
        if [ "$dry" = 1 ]; then
            echo "+ append [lizardbyte] to $PACMAN_CONF"
        else
            $SUDO cp -a "$PACMAN_CONF" "$PACMAN_CONF.bak.$(date +%s)"
            printf '\n%s\n[lizardbyte]\nSigLevel = Optional\nServer = https://github.com/LizardByte/pacman-repo/releases/latest/download\n%s\n' \
                "$BEGIN" "$END" | $SUDO tee -a "$PACMAN_CONF" >/dev/null
        fi
    fi

    dbpath=$(pacman-conf DBPath 2>/dev/null || echo /var/lib/pacman/)
    if [ ! -f "${dbpath%/}/sync/lizardbyte.db" ]; then
        say "Fetching lizardbyte repository sync database..."
        if [ "$dry" = 1 ]; then
            echo "+ sudo pacman --config <[lizardbyte] alone> -Sy"
        else
            conf=$(mktemp)
            trap 'rm -f "$conf"' EXIT
            printf '[options]\nDBPath = %s\nArchitecture = auto\nSigLevel = Optional\n\n[lizardbyte]\nServer = https://github.com/LizardByte/pacman-repo/releases/latest/download\n' \
                "$dbpath" > "$conf"
            $SUDO pacman --config "$conf" -Sy
        fi
    fi

    say "Installing sunshine package..."
    run $SUDO pacman -S --needed --noconfirm lizardbyte/sunshine
fi

# Ensure uinput kernel module is loaded for gamepad/input emulation
if command -v modprobe >/dev/null 2>&1; then
    run $SUDO modprobe uinput 2>/dev/null || true
fi

# ── Systemd User Service Setup ───────────────────────────────────────────────
say "Setting up systemd user service..."
run mkdir -p "$(dirname "$user_service_dst")"
run cp "${MISE_TASK_DIR}/../../../lib/services/sunshine/sunshine.service" "$user_service_dst"

if command -v systemctl >/dev/null 2>&1; then
    run systemctl --user daemon-reload
fi

# ── Session Autostart Setup (i3 and Hyprland) ─────────────────────────────────
say "Configuring graphical session autostarts..."
i3_services="${XDG_CONFIG_HOME:-$HOME/.config}/i3/conf.d/06-services.conf"
if [ "$dry" = 1 ]; then
    echo "+ add sunshine to $i3_services"
else
    mkdir -p "$(dirname "$i3_services")"
    if [ ! -f "$i3_services" ]; then
        cat > "$i3_services" << 'EOF'
# Opt-in service autostarts (managed by tasks/services/*)
EOF
    fi
    if ! grep -qF "sunshine.service" "$i3_services"; then
        echo "exec --no-startup-id systemctl --user start sunshine.service" >> "$i3_services"
        echo "added sunshine to $i3_services"
    fi
fi

hypr_services="${XDG_CONFIG_HOME:-$HOME/.config}/hypr/cachy-services.lua"
if [ "$dry" = 1 ]; then
    echo "+ add sunshine to $hypr_services"
else
    mkdir -p "$(dirname "$hypr_services")"
    if [ ! -f "$hypr_services" ]; then
        cat > "$hypr_services" << 'EOF'
-- Opt-in service autostarts (managed by tasks/services/*)
-- Sourced by ~/.config/hypr/cachy.lua during hyprland.start
EOF
    fi
    if ! grep -qF "sunshine.service" "$hypr_services"; then
        echo 'hl.exec_cmd("systemctl --user start sunshine.service")' >> "$hypr_services"
        echo "added sunshine to $hypr_services"
    fi
fi

# ── Capture Method Config ─────────────────────────────────────────────────────
conf="${XDG_CONFIG_HOME:-$HOME/.config}/sunshine/sunshine.conf"
if [ ! -f "$conf" ]; then
    session="i3"
    session_file="${XDG_CONFIG_HOME:-$HOME/.config}/cachy-dots/session"
    [ -f "$session_file" ] && session=$(cat "$session_file" 2>/dev/null || echo "i3")
    want="x11"
    [ "$session" = "hyprland" ] && want="wlr"
    say "Initializing $conf with capture = $want"
    if [ "$dry" = 1 ]; then
        echo "+ write capture = $want to $conf"
    else
        mkdir -p "$(dirname "$conf")"
        echo "capture = $want" > "$conf"
    fi
fi

say "Sunshine setup complete!"
echo "  - Sunshine will start automatically upon graphical login."
echo "  - Web UI: https://localhost:47990"
