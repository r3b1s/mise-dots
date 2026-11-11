#!/usr/bin/env bash
#MISE description="Install and configure Paseo daemon systemd user service"
#MISE alias="services:paseo"
#USAGE flag "--netbird" help="Bind daemon to NetBird (wt0) IPv4 address"
#USAGE flag "--tailscale" help="Expose daemon over HTTPS via Tailscale Serve on port 6767"
#USAGE flag "--remove" help="Stop service, remove Tailscale Serve proxy, and remove systemd unit"
#USAGE flag "-n --dry-run" help="Preview actions without modifying system"
set -euo pipefail

source "${MISE_TASK_DIR}/../../../lib/common.sh"
require_arch

say()  { printf '\033[1;34m::\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
run()  { if [ "$dry" = 1 ]; then echo "+ $*"; else "$@"; fi; }

dry=0
remove=0
mode=

[[ "${usage_dry_run:-false}" == "true" ]] && dry=1
[[ "${usage_remove:-false}" == "true" ]] && remove=1
if [[ "${usage_netbird:-false}" == "true" ]]; then
    mode=netbird
fi
if [[ "${usage_tailscale:-false}" == "true" ]]; then
    if [ -n "$mode" ]; then
        die "--netbird and --tailscale exclude each other"
    fi
    mode=tailscale
fi

for arg in "$@"; do
    case "$arg" in
        --netbird|--tailscale)
            want=${arg#--}
            if [ -n "$mode" ] && [ "$mode" != "$want" ]; then
                die "--netbird and --tailscale exclude each other"
            fi
            mode=$want
            ;;
        --remove)     remove=1 ;;
        -n|--dry-run) dry=1 ;;
    esac
done

service_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
service_file="$service_dir/paseo.service"
paseo_home="$HOME/.paseo"
port=6767
serve_target="http://127.0.0.1:$port"

has_tailscale_serve() {
    command -v tailscale >/dev/null 2>&1 || return 1
    tailscale serve status --json 2>/dev/null \
        | jq -e --arg port "$port" --arg target "$serve_target" '
            .TCP[$port].HTTPS == true and
            ([.Web // {} | to_entries[] | select(.key | endswith(":" + $port)) | .value.Handlers["/"].Proxy == $target] | any)
        ' >/dev/null 2>&1
}

disable_tailscale_serve_if_active() {
    if has_tailscale_serve; then
        say "Removing Tailscale Serve HTTPS proxy on port $port..."
        run tailscale serve --https="$port" off
    fi
}

# ── Removal ───────────────────────────────────────────────────────────────────
if [ "$remove" = 1 ]; then
    say "Removing Paseo systemd user service..."
    disable_tailscale_serve_if_active

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
run cp "${MISE_TASK_DIR}/../../../lib/services/paseo/paseo.service" "$service_file"

# ── 3. Daemon reload ──────────────────────────────────────────────────────────
say "Reloading systemd user daemon..."
run systemctl --user daemon-reload

# ── 4. Listen address, Tailscale Serve & hostnames ────────────────────────────
ts_hosts_json=
ts_https_origins_json=
ts_stale_http_origins_json=
config_changed=0

if [ "$mode" = netbird ]; then
    command -v ip >/dev/null 2>&1 || die "ip (iproute2) is required for --netbird"
    addr=$(ip -4 -o addr show dev wt0 scope global 2>/dev/null | awk '{ sub(/\/.*/, "", $4); print $4; exit }')
    [ -n "$addr" ] || die "wt0 has no IPv4 address: is NetBird up?"
elif [ "$mode" = tailscale ]; then
    addr=127.0.0.1
    command -v tailscale >/dev/null 2>&1 || die "tailscale CLI is required for --tailscale"
    ts_status=$(tailscale status --json 2>/dev/null) || die "could not query tailscale status: is tailscale up?"
    ts_hosts_json=$(echo "$ts_status" | jq -c '
        [
            .Self.HostName,
            ((.Self.DNSName // "") | rtrimstr(".")),
            (.CertDomains // [])[]
        ]
        | map(select(length > 0))
        | unique
    ')
    [ -n "$ts_hosts_json" ] && [ "$ts_hosts_json" != "[]" ] || die "could not determine Tailscale hostnames from tailscale status"

    ts_https_hosts_json=$(echo "$ts_status" | jq -c '
        [
            (.CertDomains // [])[],
            ((.Self.DNSName // "") | rtrimstr("."))
        ]
        | map(select(length > 0))
        | unique
    ')
    [ -n "$ts_https_hosts_json" ] && [ "$ts_https_hosts_json" != "[]" ] || die "could not determine Tailscale MagicDNS/HTTPS domain from tailscale status"

    ts_https_origins_json=$(echo "$ts_https_hosts_json" | jq -c --argjson port "$port" '
        map("https://" + . + ":" + ($port | tostring))
    ')
    ts_stale_http_origins_json=$(echo "$ts_hosts_json" | jq -c --argjson port "$port" '
        map("http://" + . + ":" + ($port | tostring))
    ')
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
    config_changed=1
fi

if [ "$mode" = tailscale ]; then
    current_hostnames=
    if mise exec -- paseo --version >/dev/null 2>&1; then
        current_hostnames=$(mise exec -- paseo daemon config get --home "$paseo_home" daemon.hostnames 2>/dev/null \
            | jq -c '.value // []' 2>/dev/null) || current_hostnames="[]"
    fi
    new_hostnames=$(jq -nc \
        --argjson current "${current_hostnames:-[]}" \
        --argjson ts "$ts_hosts_json" '
        if ($current | type) == "array" then
            ($current + $ts) | unique
        elif $current == true then
            true
        else
            $ts | unique
        end
    ')

    if [ "$new_hostnames" = "$current_hostnames" ]; then
        say "daemon.hostnames already includes Tailscale hostnames"
    else
        say "Allowing Tailscale hostnames in daemon.hostnames: $(echo "$ts_hosts_json" | jq -r 'join(", ")')"
        if [ "$dry" = 1 ]; then
            echo "+ mise exec -- paseo daemon config set --home $paseo_home daemon.hostnames '$new_hostnames'"
        else
            mise exec -- paseo daemon config set --home "$paseo_home" daemon.hostnames "$new_hostnames" >/dev/null \
                || die "could not set daemon.hostnames in $paseo_home/config.json"
        fi
        config_changed=1
    fi

    current_cors=
    if mise exec -- paseo --version >/dev/null 2>&1; then
        current_cors=$(mise exec -- paseo daemon config get --home "$paseo_home" daemon.cors.allowedOrigins 2>/dev/null \
            | jq -c '.value // []' 2>/dev/null) || current_cors='["https://app.paseo.sh"]'
    fi
    new_cors=$(jq -nc \
        --argjson current "${current_cors:-[]}" \
        --argjson ts "$ts_https_origins_json" \
        --argjson stale "$ts_stale_http_origins_json" '
        (if ($current | type) == "array" then $current else ["https://app.paseo.sh"] end)
        | map(select(. as $o | ($stale | index($o)) | not))
        | (. + $ts)
        | unique
    ')

    if [ "$new_cors" = "$current_cors" ]; then
        say "daemon.cors.allowedOrigins already includes Tailscale HTTPS origins"
    else
        say "Updating Tailscale HTTPS origins in daemon.cors.allowedOrigins: $(echo "$ts_https_origins_json" | jq -r 'join(", ")')"
        if [ "$dry" = 1 ]; then
            echo "+ mise exec -- paseo daemon config set --home $paseo_home daemon.cors.allowedOrigins '$new_cors'"
        else
            mise exec -- paseo daemon config set --home "$paseo_home" daemon.cors.allowedOrigins "$new_cors" >/dev/null \
                || die "could not set daemon.cors.allowedOrigins in $paseo_home/config.json"
        fi
        config_changed=1
    fi

    if has_tailscale_serve; then
        say "Tailscale Serve already proxies HTTPS port $port to $serve_target"
    else
        say "Configuring Tailscale Serve HTTPS proxy on port $port -> $serve_target..."
        run tailscale serve --bg --https="$port" "$serve_target"
    fi
else
    disable_tailscale_serve_if_active
fi

if [ "$config_changed" = 1 ] && systemctl --user is-active --quiet paseo 2>/dev/null; then
    warn "paseo.service is running with its old config: systemctl --user restart paseo"
fi

printf '\n'
say "Paseo setup complete!"
echo "  Self-hosted Web UI: http://$listen"
if [ -n "$ts_https_origins_json" ]; then
    for origin in $(echo "$ts_https_origins_json" | jq -r '.[]'); do
        echo "  Tailscale HTTPS UI: $origin"
    done
fi
echo "  To start daemon:     systemctl --user start paseo"
echo "  To enable autostart: systemctl --user enable --now paseo"
