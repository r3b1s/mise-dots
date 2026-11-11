#!/usr/bin/env bash
#MISE description="Opt in to Kanata keyboard remapper system service (Arch-based)"
#MISE alias="services:kanata"
#USAGE flag "--remove" help="Disable kanata service and remove system configs"
#USAGE flag "-n --dry-run" help="Preview actions without modifying system"
set -euo pipefail

source "${MISE_TASK_DIR}/../../../lib/common.sh"
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

SUDO=
[ "$(id -u)" -ne 0 ] && SUDO=sudo

KANATA_DIR="${MISE_TASK_DIR}/../../../lib/services/kanata"

# ── Removal ───────────────────────────────────────────────────────────────────
if [ "$remove" = 1 ]; then
    say "Disabling and removing Kanata service and configs..."
    if systemctl is-active --quiet kanata.service 2>/dev/null; then
        say "Stopping kanata.service"
        run $SUDO systemctl stop kanata.service
    fi
    if systemctl is-enabled --quiet kanata.service 2>/dev/null; then
        say "Disabling kanata.service"
        run $SUDO systemctl disable kanata.service
    fi

    files=(
        /etc/kanata/enthium.kbd
        /etc/systemd/system/kanata.service
        /etc/sysusers.d/kanata.conf
        /etc/udev/rules.d/99-kanata-uinput.rules
        /etc/modules-load.d/kanata.conf
    )
    for f in "${files[@]}"; do
        if [ -f "$f" ]; then
            say "Removing $f"
            run $SUDO rm -f "$f"
        fi
    done
    [ -d /etc/kanata ] && run $SUDO rmdir /etc/kanata 2>/dev/null || true

    run $SUDO udevadm control --reload-rules
    run $SUDO udevadm trigger
    run $SUDO systemctl daemon-reload

    say "Kanata system files removed."
    exit 0
fi

# ── Package ───────────────────────────────────────────────────────────────────
before=$(pacman -Q kanata 2>/dev/null || true)

if [ -e /usr/bin/kanata ] && ! pacman -Qo /usr/bin/kanata >/dev/null 2>&1; then
    die "/usr/bin/kanata is not owned by a package. Remove it with: sudo rm /usr/bin/kanata; then re-run this task"
fi

if [ -z "$before" ]; then
    if [ "$dry" != 1 ] && ! pacman -Si chaotic-aur/kanata >/dev/null 2>&1; then
        die "chaotic-aur/kanata is unavailable: chaotic-aur repository is required"
    fi
    say "Installing chaotic-aur/kanata exclusively (pacman -Syu, full sync from chaotic-aur)..."
    run $SUDO pacman -Syu --needed --noconfirm chaotic-aur/kanata || die "could not install chaotic-aur/kanata"
else
    say "kanata $before is installed. A system upgrade (pacman -Syu) updates it."
fi
after=$(pacman -Q kanata 2>/dev/null || true)
pkg_changed=0
[ "$before" != "$after" ] && pkg_changed=1

# ── Config Check ──────────────────────────────────────────────────────────────
stage=$(mktemp -d)
trap 'rm -rf -- "$stage"' EXIT
cp -- "$KANATA_DIR/enthium.kbd" "$stage/enthium.kbd"

say "Checking enthium.kbd with the installed kanata (kanata --check)"
if ! run /usr/bin/kanata --check --cfg "$stage/enthium.kbd"; then
    die "kanata --check rejected enthium.kbd; the live config and service were not touched"
fi

# ── Install files ─────────────────────────────────────────────────────────────
replace() {
    replaced=0
    if [ -f "$2" ] && cmp -s "$1" "$2"; then return 0; fi
    local dir
    dir=$(dirname -- "$2")
    [ -d "$dir" ] || run $SUDO install -d -m 0755 "$dir" || die "could not create $dir"
    run $SUDO install -o root -g root -m "$3" "$1" "$2.new" || die "could not write $2.new"
    run $SUDO mv -f -- "$2.new" "$2" || die "could not replace $2"
    echo "  installed $2"
    replaced=1
}

say "Installing system files as root (sudo)"
replace "$stage/enthium.kbd" /etc/kanata/enthium.kbd 0644;              config_changed=$replaced
replace "$KANATA_DIR/kanata.service" /etc/systemd/system/kanata.service 0644; unit_changed=$replaced
replace "$KANATA_DIR/sysusers.conf" /etc/sysusers.d/kanata.conf 0644
replace "$KANATA_DIR/udev.rules" /etc/udev/rules.d/99-kanata-uinput.rules 0644; udev_changed=$replaced
replace "$KANATA_DIR/modules-load.conf" /etc/modules-load.d/kanata.conf 0644

# ── Activation ────────────────────────────────────────────────────────────────
say "Activating permissions and modules"
run $SUDO systemd-sysusers /etc/sysusers.d/kanata.conf
run $SUDO modprobe uinput
if [ "$udev_changed" = 1 ]; then
    run $SUDO udevadm control --reload-rules
    run $SUDO udevadm trigger
fi
if [ "$unit_changed" = 1 ]; then
    run $SUDO systemctl daemon-reload
    run systemd-analyze verify /etc/systemd/system/kanata.service \
        || warn "systemd-analyze reported problems with kanata.service (above)"
fi
run $SUDO systemctl enable kanata.service
if [ "$pkg_changed" = 1 ] || [ "$config_changed" = 1 ] || [ "$unit_changed" = 1 ]; then
    if systemctl is-active --quiet kanata.service; then
        say "Restarting kanata: package, config or unit changed"
        run $SUDO systemctl restart kanata.service
    fi
fi

echo
echo "kanata is enabled at boot. To view detected keyboards:"
echo "    sudo kanata --list"
echo "To start it now:"
echo "    sudo systemctl start kanata.service"
echo "Emergency quit shortcut: left Ctrl + Space + Escape"
