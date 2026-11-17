#!/usr/bin/env bash
#MISE description="Install OmniRoute AI gateway as rootless Podman Quadlet pod (Arch-based)"
#MISE alias="services:omniroute"
#USAGE flag "--tailscale" help="Also publish dashboard/API ports on the Tailscale (tailscale0) address"
#USAGE flag "--reconfigure" help="Prompt again for the Tailscale IPv4 address"
#USAGE flag "--remove" help="Stop pod, remove Quadlet units and env file (data dir is preserved)"
#USAGE flag "-n --dry-run" help="Preview actions without modifying system"
set -euo pipefail

source "${MISE_TASK_DIR}/../../../lib/common.sh"
require_arch

say()  { printf '\033[1;34m::\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
run()  { if [ "$dry" = 1 ]; then echo "+ $*"; else "$@"; fi; }

tailscale=0
reconfigure=0
remove=0
dry=0

[[ "${usage_tailscale:-false}" == "true" ]] && tailscale=1
[[ "${usage_reconfigure:-false}" == "true" ]] && reconfigure=1
[[ "${usage_remove:-false}" == "true" ]] && remove=1
[[ "${usage_dry_run:-false}" == "true" ]] && dry=1

for arg in "$@"; do
    case "$arg" in
        --tailscale)   tailscale=1 ;;
        --reconfigure) reconfigure=1 ;;
        --remove)      remove=1 ;;
        -n|--dry-run)  dry=1 ;;
    esac
done

if [ "$(id -u)" -eq 0 ]; then
    die "run this as your own user, not root: the pod is rootless"
fi

lib="${MISE_TASK_DIR}/../../../lib/services/omniroute"
config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/omniroute"
envfile="$config_dir/.env"
data_dir="${XDG_DATA_HOME:-$HOME/.local/share}/omniroute/data"
quadlet_dir="${XDG_CONFIG_HOME:-$HOME/.config}/containers/systemd"

pod_unit="$quadlet_dir/omniroute.pod"
app_unit="$quadlet_dir/omniroute-app.container"
redis_unit="$quadlet_dir/omniroute-redis.container"

# ── Removal ───────────────────────────────────────────────────────────────────
if [ "$remove" = 1 ]; then
    say "Stopping and removing the OmniRoute pod..."
    if command -v systemctl >/dev/null 2>&1; then
        if systemctl --user is-active --quiet omniroute-pod.service 2>/dev/null; then
            say "Stopping omniroute-pod.service"
            run systemctl --user stop omniroute-pod.service
        fi
    fi
    for f in "$pod_unit" "$app_unit" "$redis_unit"; do
        if [ -f "$f" ]; then
            say "Removing $f"
            run rm -f "$f"
        fi
    done
    command -v systemctl >/dev/null 2>&1 && run systemctl --user daemon-reload
    if [ -f "$envfile" ]; then
        say "Removing $envfile"
        run rm -f "$envfile"
    fi
    say "OmniRoute units removed. Data (incl. credentials) is preserved in $data_dir"
    say "Delete it manually if you want it gone, or back it up first: mise run services:omniroute:backup"
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

# The non-loopback address the installed pod publishes on, or nothing.
installed_ip() {
    [ -f "$pod_unit" ] || return 0
    sed -n 's|^PublishPort=\([0-9.]*\):[0-9]*:[0-9]*\(/tcp\)\?$|\1|p' "$pod_unit" \
        | grep -v -x -e '127.0.0.1' -e '0.0.0.0' | head -n 1 || true
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

# ── Env file & data dir ───────────────────────────────────────────────────────
run mkdir -p "$config_dir" "$data_dir"
if [ ! -f "$envfile" ]; then
    say "writing $envfile (defaults; edit it to set REQUIRE_API_KEY=true or ports)"
    if [ "$dry" = 1 ]; then
        echo "+ install -m 0600 $lib/env.example $envfile"
    else
        install -m 0600 "$lib/env.example" "$envfile"
    fi
else
    say "$envfile exists; leaving it untouched"
fi

port_val() {
    local v
    v=$(sed -n "s/^ *$1 *= *//p" "$envfile" 2>/dev/null | tail -n 1)
    v=${v:-$2}
    [[ $v =~ ^[0-9]+$ ]] && (( v >= 1 && v <= 65535 )) || die "$1=$v in $envfile is not a valid port"
    printf '%s' "$v"
}

req_val() {
    sed -n "s/^ *REQUIRE_API_KEY *= *//p" "$envfile" 2>/dev/null | tr '[:upper:]' '[:lower:]' | tail -n 1
}

dashboard_port=$(port_val DASHBOARD_PORT 20128)
api_port=$(port_val API_PORT 20129)
live_ws_port=$(port_val LIVE_WS_PORT 20132)

# ── Bind address ──────────────────────────────────────────────────────────────
binds=(127.0.0.1)
if [ "$tailscale" = 1 ]; then
    ts_ip=
    [ "$reconfigure" = 1 ] || ts_ip=$(installed_ip)
    if [ -n "$ts_ip" ]; then
        say "Tailscale address: $ts_ip (from the installed unit; --reconfigure to change)"
    else
        ts_ip=$(ask_tailscale_ip)
    fi
    current=$(tailscale0_ip)
    [ "$ts_ip" = "$current" ] || warn "tailscale0 has ${current:-no address} now, not $ts_ip; the pod binds $ts_ip regardless"
    binds+=("$ts_ip")

    req=$(req_val)
    if [ "$req" != true ]; then
        warn "REQUIRE_API_KEY is not true in $envfile: --tailscale exposes an"
        warn "unauthenticated /v1 proxy to your whole Tailnet, letting anyone on it"
        warn "burn your provider quotas. Set REQUIRE_API_KEY=true first (recommended),"
        warn "or put an auth-enforcing reverse proxy in front."
        if [ "$dry" = 0 ]; then
            if [ -t 0 ]; then
                read -rp "Expose unauthenticated OmniRoute on the Tailnet anyway? [y/N] " yn
                [[ $yn =~ ^[Yy]$ ]] || die "aborted: set REQUIRE_API_KEY=true in $envfile first"
            else
                die "refusing to expose unauthenticated OmniRoute non-interactively"
            fi
        fi
    fi
fi

pubfile=$(mktemp)
trap 'rm -f "$pubfile"' EXIT
{
    for b in "${binds[@]}"; do
        printf 'PublishPort=%s:%s:20128\n' "$b" "$dashboard_port"
        printf 'PublishPort=%s:%s:20129\n' "$b" "$api_port"
        printf 'PublishPort=%s:%s:20132\n' "$b" "$live_ws_port"
    done
} > "$pubfile"

rendered=$(mktemp)
trap 'rm -f "$pubfile" "$rendered"' EXIT
awk -v f="$pubfile" '{ if ($0 == "@PUBLISH_PORTS@") { while ((getline l < f) > 0) print l; close(f) } else print }' \
    "$lib/omniroute.pod" > "$rendered"

changed=1
cmp -s "$rendered" "$pod_unit" 2>/dev/null && changed=0
if [ "$changed" = 1 ]; then
    say "writing $pod_unit"
    [ "$dry" = 1 ] && { diff -u "$pod_unit" "$rendered" 2>/dev/null || true; }
    run mkdir -p "$quadlet_dir"
    if [ "$dry" = 1 ]; then
        echo "+ install -m 0644 <rendered> $pod_unit"
    else
        install -m 0644 "$rendered" "$pod_unit"
    fi
fi
for src in omniroute-app.container omniroute-redis.container; do
    dest="$quadlet_dir/$src"
    if ! cmp -s "$lib/$src" "$dest" 2>/dev/null; then
        say "writing $dest"
        [ "$dry" = 1 ] && { diff -u "$dest" "$lib/$src" 2>/dev/null || true; }
        run mkdir -p "$quadlet_dir"
        if [ "$dry" = 1 ]; then
            echo "+ install -m 0644 $lib/$src $dest"
        else
            install -m 0644 "$lib/$src" "$dest"
        fi
        changed=1
    fi
done

if [ "$changed" = 1 ]; then
    run systemctl --user daemon-reload
fi

if systemctl --user -q is-active omniroute-pod.service 2>/dev/null; then
    if [ "$changed" = 1 ]; then
        say "restarting omniroute-pod.service (the first start pulls the images)"
        run systemctl --user restart omniroute-pod.service
    fi
else
    say "enabling and starting omniroute-pod.service (the first start pulls the images)"
    run systemctl --user enable --now omniroute-pod.service
fi

if [ "$(loginctl show-user "$USER" -p Linger --value 2>/dev/null)" != yes ]; then
    warn "omniroute stops when you log out; to keep it running: loginctl enable-linger"
fi

if [ "$dry" = 0 ]; then
    warn "REQUIRE_API_KEY=false ships as the default (upstream selfhost behaviour): the"
    warn "dashboard and /v1 proxy are open to APP_BIND_HOST's network. Safe on loopback"
    warn "only — set REQUIRE_API_KEY=true in $envfile once you expose it further."
fi
say "Dashboard: http://127.0.0.1:$dashboard_port (onboarding wizard on first visit)"
if [ "$tailscale" = 1 ]; then
    say "Tailnet:   http://${binds[1]}:$dashboard_port"
fi
say "Data (incl. credentials): $data_dir — back it up: mise run services:omniroute:backup"
