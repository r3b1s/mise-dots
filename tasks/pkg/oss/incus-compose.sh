#!/usr/bin/env bash
#MISE description="Install incus-compose from a verified GitHub release, for the local Incus"
#USAGE flag "--tag <tag>" help="Release tag to install (default: latest)"
#USAGE flag "-f --force" help="Reinstall even if the installed version matches"
#USAGE flag "--remove" help="Uninstall /usr/local/bin/incus-compose"
#USAGE flag "-n --dry-run" help="Preview actions without downloading or changing anything"
set -euo pipefail

source "${MISE_TASK_DIR}/../../../lib/common.sh"
require_arch

REPO=lxc/incus-compose
BIN=incus-compose
DEST=/usr/local/bin/incus-compose
BRIDGE=incusbr0
API_PORT=8443

say()  { printf '\033[1;34m::\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
run()  { if [ "$dry" = 1 ]; then echo "+ $*"; else "$@"; fi; }

SUDO=
[ "$(id -u)" -ne 0 ] && SUDO=sudo

tag=""
force=0
remove=0
dry=0

[[ "${usage_force:-false}" == "true" ]] && force=1
[[ "${usage_remove:-false}" == "true" ]] && remove=1
[[ "${usage_dry_run:-false}" == "true" ]] && dry=1
[ -n "${usage_tag:-}" ] && tag="$usage_tag"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --tag)        tag="${2:?--tag needs a value}"; shift ;;
        -f|--force)   force=1 ;;
        --remove)     remove=1 ;;
        -n|--dry-run) dry=1 ;;
    esac
    shift
done

# ── Removal ───────────────────────────────────────────────────────────────────
if [ "$remove" = 1 ]; then
    if [ -e "$DEST" ]; then
        say "Removing $DEST"
        run $SUDO rm -f "$DEST"
    else
        say "$DEST is not installed."
    fi
    if command -v incus >/dev/null && $SUDO incus list --project incus-compose --format csv --columns n 2>/dev/null | grep -q .; then
        warn "the ic-healthd/ic-dns sidecars in the incus-compose project are left running: delete them with 'incus delete --force --project incus-compose ic-healthd ic-dns'"
    fi
    say "Left as they were: core.https_address ($(${SUDO} incus config get core.https_address 2>/dev/null || echo unknown); 'incus config unset core.https_address' clears it), skopeo, and your compose projects."
    exit 0
fi

# ── Prerequisites ─────────────────────────────────────────────────────────────
for tool in curl jq sha256sum tar; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool is required"
done
case "$(uname -m)" in
    x86_64)  arch=amd64 ;;
    aarch64) arch=arm64 ;;
    *)       die "unsupported architecture: $(uname -m)" ;;
esac
command -v incus >/dev/null || die "incus is not installed: run 'mise run services:incus' first"

# ── 1. Release metadata and sha256 ────────────────────────────────────────────
if [ -n "$tag" ]; then
    api="https://api.github.com/repos/$REPO/releases/tags/$tag"
else
    api="https://api.github.com/repos/$REPO/releases/latest"
fi

say "Asking GitHub for ${tag:-the latest release} of $REPO"
release=$(curl -fsSL --proto '=https' --tlsv1.2 -H 'Accept: application/vnd.github+json' "$api") \
    || die "could not read $api"

tag=$(jq -r '.tag_name // empty' <<<"$release")
[[ $tag =~ ^v?[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.]+)?$ ]] || die "unexpected release tag: ${tag:-<empty>}"
version=${tag#v}
asset="${BIN}_${version}_linux_${arch}.tar.gz"

asset_field() { jq -r --arg a "$1" --arg f "$2" '.assets[] | select(.name == $a) | .[$f] // empty' <<<"$release"; }
url=$(asset_field "$asset" browser_download_url)
sha=$(asset_field "$asset" digest)
sums_url=$(asset_field checksums.txt browser_download_url)
[ -n "$url" ] || die "release $tag has no $asset asset"
[ -n "$sums_url" ] || die "release $tag has no checksums.txt"
for u in "$url" "$sums_url"; do
    case "$u" in https://*) ;; *) die "refusing a non-https download URL: $u" ;; esac
done
sha=${sha#sha256:}
[[ $sha =~ ^[0-9a-f]{64}$ ]] || die "GitHub publishes no sha256 digest for $asset in $tag"

say "incus-compose $tag ($asset, sha256: $sha)"

installed=
if [ -x "$DEST" ]; then
    installed=$("$DEST" version 2>/dev/null | awk '{ print $NF }' || true)
fi
if [ "$force" = 0 ] && [ "$installed" = "$version" ]; then
    say "$DEST is already at $version."
    skip_install=1
else
    skip_install=0
fi

# ── 2. Download, verify, and install ──────────────────────────────────────────
if [ "$skip_install" = 0 ]; then
    work=$(mktemp -d "${TMPDIR:-/tmp}/incus-compose-install.XXXXXX")
    trap 'rm -rf "$work"' EXIT

    if [ "$dry" = 1 ]; then
        echo "+ curl -fL --proto '=https' --tlsv1.2 -o $work/$asset $url"
        echo "+ curl -fL --proto '=https' --tlsv1.2 -o $work/checksums.txt $sums_url"
        echo "+ verify sha256($work/$asset) == $sha == its checksums.txt entry"
        echo "+ gh attestation verify $work/$asset --repo $REPO    # when gh is logged in"
        echo "+ tar -xzf $work/$asset -C $work/x $BIN"
        echo "+ ${SUDO:+$SUDO }install -o root -g root -Dm0755 $work/x/$BIN $DEST"
    else
        say "Downloading $asset"
        if [ -t 1 ]; then progress=--progress-bar; else progress=-sS; fi
        curl -fL --proto '=https' --tlsv1.2 "$progress" -o "$work/$asset" "$url"
        curl -fsSL --proto '=https' --tlsv1.2 -o "$work/checksums.txt" "$sums_url"

        listed=$(awk -v a="$asset" '$2 == a { print $1 }' "$work/checksums.txt")
        [ "$listed" = "$sha" ] || die "checksums.txt lists ${listed:-nothing} for $asset, but GitHub's digest is $sha"
        actual=$(sha256sum "$work/$asset" | awk '{ print $1 }')
        [ "$actual" = "$sha" ] || die "sha256 mismatch for $asset: expected $sha, got $actual"
        say "Verified sha256 against GitHub's digest and checksums.txt."

        if command -v gh >/dev/null && gh auth status >/dev/null 2>&1; then
            gh attestation verify "$work/$asset" --repo "$REPO" >/dev/null \
                || die "gh attestation verify failed for $asset"
            say "Verified the build provenance attestation (gh attestation verify)."
        else
            say "Skipping the attestation check: gh is not logged in."
        fi

        mkdir "$work/x"
        tar -xzf "$work/$asset" -C "$work/x" --no-same-owner "$BIN" \
            || die "$asset has no $BIN"
        [ -f "$work/x/$BIN" ] && [ ! -L "$work/x/$BIN" ] || die "$BIN in $asset is not a regular file"

        say "Installing $DEST"
        $SUDO install -o root -g root -Dm0755 "$work/x/$BIN" "$DEST"
        say "$("$DEST" version)"
    fi
fi

# ── 3. OCI support ────────────────────────────────────────────────────────────
# Compose images, and the sidecars, are OCI images: Incus pulls them with skopeo, an
# optional dependency of the incus package.
if ! pacman -Qq skopeo >/dev/null 2>&1; then
    say "Installing skopeo for Incus OCI support (pacman -Syu: never -S against a stale database)"
    run $SUDO pacman -Syu --needed --noconfirm skopeo || die "could not install skopeo"
fi

# ── 4. Incus server ───────────────────────────────────────────────────────────
target_user=${SUDO_USER:-$(id -un)}
if ! id -nG "$target_user" | tr ' ' '\n' | grep -qx incus-admin; then
    warn "$target_user is not in the incus-admin group (run 'mise run services:incus')"
fi

$SUDO incus info >/dev/null 2>&1 || die "the Incus server is not reachable: run 'mise run services:incus' first"

# incus-compose needs Incus 7.5+, or the 7.0 LTS from 7.0.2.
server=$($SUDO incus version 2>/dev/null | awk -F': *' '/^Server version/ { print $2 }')
if [[ $server =~ ^([0-9]+)\.([0-9]+)(\.([0-9]+))? ]]; then
    maj=${BASH_REMATCH[1]} min=${BASH_REMATCH[2]} pat=${BASH_REMATCH[4]:-0}
    if ! { [ "$maj" -gt 7 ] || { [ "$maj" = 7 ] && { [ "$min" -ge 5 ] || { [ "$min" = 0 ] && [ "$pat" -ge 2 ]; }; }; }; }; then
        warn "Incus server $server is too old: incus-compose needs 7.5 or later, or 7.0.2 LTS"
    fi
else
    warn "could not read the Incus server version"
fi

# The sidecars (ic-healthd, ic-dns) reach the Incus API over HTTPS, at the address
# core.https_address names. Binding it to $BRIDGE's address keeps the API off the LAN.
# At boot the bridge is not up yet when Incus first binds: Incus retries once, 30s
# later, and the sidecars reconnect on their own.
api=$($SUDO incus config get core.https_address 2>/dev/null || true)
gw=$($SUDO incus network get "$BRIDGE" ipv4.address 2>/dev/null || true)
gw=${gw%/*}
if [ -n "$api" ]; then
    case "$api" in
        :*|0.0.0.0:*|\[::\]:*|127.*|localhost*|\[::1\]*)
            warn "core.https_address is $api: the sidecars need a non-loopback host in it, or INCUS_COMPOSE_HEALTHD_INCUS / INCUS_COMPOSE_DNS_INCUS set" ;;
        *)  say "core.https_address is already $api; leaving it." ;;
    esac
elif [[ $gw =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    api="$gw:$API_PORT"
    say "Setting core.https_address to $api ($BRIDGE's address), for the sidecars"
    run $SUDO incus config set "core.https_address=$api"
else
    die "core.https_address is unset and $BRIDGE has no IPv4 address to bind it to: run 'mise run services:incus' first"
fi
api_ip=${api%:*}

# ── 5. What is left to you ────────────────────────────────────────────────────
ic_cidr=$($SUDO incus network get icompose0 ipv4.address 2>/dev/null || true)
if [[ $ic_cidr =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]]; then
    ic_gw=${ic_cidr%/*}
    ic_net=$(ipv4_net "$ic_cidr")
else
    ic_gw="<icompose0 gateway>"
    ic_net="<icompose0 subnet>"
fi

echo
say "incus-compose $tag is installed at $DEST."
cat <<EOF

The task does not start the sidecars or open any firewall ports. The first
'incus-compose up' starts ic-healthd and ic-dns on a new bridge, icompose0, with a
random subnet. Each compose project gets its own bridge and subnet, too.

ic-dns resolves only compose names until it has an upstream: once icompose0 exists,
    incus-compose dns up --forward $ic_gw

With a default-deny firewall, the sidecars and each project's bridge need rules.
EOF
if command -v ufw >/dev/null; then
    cat <<EOF
With ufw, for example (comment them, so they can be found and removed together):
    sudo ufw allow in on icompose0 proto udp from 0.0.0.0/0 port 68 to 0.0.0.0/0 port 67 comment incus-compose
    sudo ufw allow in on icompose0 from $ic_net to $ic_gw port 53 comment incus-compose
    sudo ufw allow in on icompose0 proto tcp from $ic_net to $api_ip port $API_PORT comment incus-compose
  and for each project's bridge, <bridge> and <subnet>:
    sudo ufw allow in on <bridge> proto udp from 0.0.0.0/0 port 68 to 0.0.0.0/0 port 67 comment incus-compose
    sudo ufw route allow in on <bridge> out on icompose0 from <subnet> to <ic-dns address> port 53 comment incus-compose
    sudo ufw route allow in on <bridge> out on en+ from <subnet> comment incus-compose
    sudo ufw route allow in on <bridge> out on wl+ from <subnet> comment incus-compose
  Published ports are blocked from other machines until you allow them, too.
EOF
fi
if command -v firewall-cmd >/dev/null; then
    cat <<EOF
With firewalld: put icompose0 and each project's bridge in a zone with the dhcp
service and DNS to its gateway, with policies from that zone to your WAN zone and to
ic-dns's port 53, and $api_ip:$API_PORT open from icompose0.
EOF
fi
cat <<EOF
'incus-compose list' and 'incus network list --all-projects' show the bridges and subnets.
EOF
