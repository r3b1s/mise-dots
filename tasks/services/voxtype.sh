#!/usr/bin/env bash
#MISE description="Opt in to Voxtype push-to-talk speech dictation (Arch-based)"
#MISE alias="services:voxtype:setup"
#USAGE flag "--remove" help="Stop daemon, remove session hooks, and remove voxtype package"
#USAGE flag "-n --dry-run" help="Preview actions without modifying system"
set -euo pipefail

source "${MISE_TASK_DIR}/../../lib/common.sh"
require_arch

say()  { printf '\033[1;34m::\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
run()  { if [ "$dry" = 1 ]; then echo "+ $*"; else "$@"; fi; }

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

[ "$(id -u)" -ne 0 ] || die "run this as your own user: the hooks and config are in your home"
command -v pacman >/dev/null || die "pacman not found: this is for Arch-based systems"

cfg="${XDG_CONFIG_HOME:-$HOME/.config}"
config_src="${MISE_TASK_DIR}/../../lib/services/voxtype/config.toml"
config_dst="$cfg/voxtype/config.toml"

AUR_KEYS=(E79F5BAF8CD51A806AA27DBB7DA2709247D75BC6 9CCF7915B750CAE8B095ED1AA3FC9F33FD209279)

i3_hook="$cfg/i3/conf.d/06-services.conf"
i3_header='# Opt-in service autostarts (managed by tasks/services/*)'
i3_line='exec --no-startup-id ~/.local/bin/dictate daemon'
hypr_hook="$cfg/hypr/cachy-services.lua"
hypr_header='-- Opt-in service autostarts (managed by tasks/services/*)
-- Sourced by ~/.config/hypr/cachy.lua during hyprland.start'
hypr_line='hl.exec_cmd("~/.local/bin/dictate daemon")'
ours='dictate daemon|voxtype -q daemon'

set_hook() {
    local file=$1 header=$2 line=${3:-} tmp
    [ -f "$file" ] || [ -n "$line" ] || return 0
    tmp=$(mktemp)
    {
        if [ -f "$file" ]; then grep -vE "$ours" "$file" || true; else printf '%s\n' "$header"; fi
        [ -z "$line" ] || printf '%s\n' "$line"
    } > "$tmp"
    if [ -f "$file" ] && cmp -s "$tmp" "$file"; then
        rm -f "$tmp"
        return 0
    fi
    if ! grep -qvE '^[[:space:]]*((#|--).*)?$' "$tmp"; then
        rm -f "$tmp"
        run rm -f "$file"
        echo "removed $file (nothing left in it)"
        return 0
    fi
    if [ "$dry" = 1 ]; then
        rm -f "$tmp"
        echo "+ write $file"
        return 0
    fi
    mkdir -p "$(dirname "$file")"
    cat "$tmp" > "$file"
    rm -f "$tmp"
    echo "updated $file"
}

check_host_cachy_lua() {
    if grep -qF 'voxtype -q daemon' "$cfg/hypr/cachy.lua" 2>/dev/null; then
        warn "$cfg/hypr/cachy.lua starts voxtype itself: remove its voxtype hl.exec_cmd line to avoid autostart race"
    fi
}

# ── Removal ───────────────────────────────────────────────────────────────────
if [ "$remove" = 1 ]; then
    say "Removing voxtype"
    pgrep -x -u "$(id -u)" voxtype >/dev/null && run pkill -x -u "$(id -u)" voxtype
    set_hook "$i3_hook" "$i3_header"
    set_hook "$hypr_hook" "$hypr_header"
    if [ "$(readlink "$config_dst" 2>/dev/null)" = "$config_src" ]; then
        run rm "$config_dst"
        echo "removed the link $config_dst"
    fi
    if pacman -Qq voxtype-bin >/dev/null 2>&1; then
        run sudo pacman -Rns --noconfirm voxtype-bin
    fi
    check_host_cachy_lua
    say "Done. The speech models in ${XDG_DATA_HOME:-$HOME/.local/share}/voxtype are kept."
    exit 0
fi

# ── Package ───────────────────────────────────────────────────────────────────
if pacman -Qq voxtype-bin >/dev/null 2>&1; then
    say "$(pacman -Q voxtype-bin) is installed."
elif pacman -Si voxtype-bin >/dev/null 2>&1; then
    say "Installing voxtype-bin from pacman repository"
    run sudo pacman -Syu --needed --noconfirm voxtype-bin || die "could not install voxtype-bin"
else
    command -v yay >/dev/null || [ "$dry" = 1 ] || die "no yay installed: voxtype-bin must be built from the AUR"
    say "Building voxtype-bin from the AUR with yay"
    if [ "$dry" = 1 ]; then
        echo "+ gpg --recv-keys ${AUR_KEYS[*]}"
    else
        for key in "${AUR_KEYS[@]}"; do
            gpg --quiet --keyserver hkps://keyserver.ubuntu.com --recv-keys "$key" >/dev/null 2>&1 || true
        done
    fi
    run yay -S --needed --noconfirm --answerclean None --answerdiff None voxtype-bin \
        || die "could not build voxtype-bin from the AUR"
fi

# ── Config Symlink ────────────────────────────────────────────────────────────
if [ "$(readlink "$config_dst" 2>/dev/null)" != "$config_src" ]; then
    run mkdir -p "$(dirname "$config_dst")"
    if [ -e "$config_dst" ] && [ ! -L "$config_dst" ]; then
        backup="$config_dst.bak.$(date +%s)"
        run mv "$config_dst" "$backup"
        echo "backed up $config_dst -> $backup"
    fi
    run ln -sfn "$config_src" "$config_dst"
    echo "linked $config_dst -> $config_src"
fi

# ── ONNX Binary ───────────────────────────────────────────────────────────────
onnx_active() {
    if [ -L /usr/bin/voxtype ]; then
        case "$(readlink -f /usr/bin/voxtype)" in */voxtype-onnx-*) return 0 ;; esac
        return 1
    fi
    grep -qs '^exec [^ ]*/voxtype-onnx' /usr/bin/voxtype
}

if onnx_active; then
    echo "voxtype runs its ONNX binary already"
else
    say "Switching voxtype to its ONNX binary (Parakeet)"
    run sudo voxtype setup onnx --enable || die "could not enable the ONNX binary"
    if pgrep -x -u "$(id -u)" voxtype >/dev/null; then
        warn "running daemon is still using the Whisper binary: Parakeet starts with next login"
    fi
fi

# ── Speech Model ──────────────────────────────────────────────────────────────
model=$(sed -n '/^\[parakeet\]/,/^\[/s/^model *= *"\(.*\)".*/\1/p' "$config_src")
[ -n "$model" ] || die "no [parakeet] model in $config_src"
if [ ! -d "${XDG_DATA_HOME:-$HOME/.local/share}/voxtype/models/$model" ]; then
    say "Downloading speech model ($model)"
    run voxtype setup --download --model "$model" \
        || warn "model download failed; run: voxtype setup --download --model $model"
fi

# ── Session Hooks ─────────────────────────────────────────────────────────────
set_hook "$i3_hook" "$i3_header" "$i3_line"
set_hook "$hypr_hook" "$hypr_header" "$hypr_line"

# Check if ~/.local/bin/dictate exists; link from cachy-dots if available
if [ ! -x "$HOME/.local/bin/dictate" ]; then
    if [ -x "$HOME/Dotfiles/cachy-dots/bin/dictate" ]; then
        mkdir -p "$HOME/.local/bin"
        run ln -sf "$HOME/Dotfiles/cachy-dots/bin/dictate" "$HOME/.local/bin/dictate"
        say "Linked $HOME/.local/bin/dictate from cachy-dots"
    else
        warn "$HOME/.local/bin/dictate is missing: push-to-talk keybind requires dictate script"
    fi
fi
check_host_cachy_lua

say "Voxtype setup complete. Daemon starts at next login."
