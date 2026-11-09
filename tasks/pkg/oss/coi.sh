#!/usr/bin/env bash
#MISE description="Install coi (Code on Incus) from verified GitHub release"
#USAGE flag "--tag <tag>" help="Release tag to install (default: latest)"
#USAGE flag "-f --force" help="Reinstall even if current sha256 matches"
#USAGE flag "--remove" help="Uninstall /usr/local/bin/coi"
#USAGE flag "-n --dry-run" help="Preview actions without downloading"
set -euo pipefail

source "${MISE_TASK_DIR}/../../../lib/common.sh"
require_arch

REPO=coipond/coi
ASSET=coi-linux-amd64
DEST=/usr/local/bin/coi

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
        --force)      force=1 ;;
        --remove)     remove=1 ;;
        -n|--dry-run) dry=1 ;;
    esac
    shift
done

# ── Removal ───────────────────────────────────────────────────────────────────
if [ "$remove" = 1 ]; then
    if [ -e "$DEST" ]; then
        say "Removing $DEST..."
        run $SUDO rm -f "$DEST"
    else
        say "$DEST is not installed."
    fi
    exit 0
fi

# ── Prerequisites ─────────────────────────────────────────────────────────────
for tool in curl jq sha256sum; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool is required"
done
[ "$(uname -m)" = x86_64 ] || die "only x86_64 ($ASSET) is supported"

# ── 1. Release metadata & sha256 digest ───────────────────────────────────────
if [ -n "$tag" ]; then
    api="https://api.github.com/repos/$REPO/releases/tags/$tag"
else
    api="https://api.github.com/repos/$REPO/releases/latest"
fi

say "Asking GitHub for ${tag:-the latest release} of $REPO..."
release=$(curl -fsSL --proto '=https' --tlsv1.2 -H 'Accept: application/vnd.github+json' "$api") \
    || die "could not read $api"

tag=$(jq -r '.tag_name // empty' <<<"$release")
[[ $tag =~ ^v?[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.]+)?$ ]] || die "unexpected release tag: ${tag:-<empty>}"

url=$(jq -r --arg a "$ASSET" '.assets[] | select(.name == $a) | .browser_download_url // empty' <<<"$release")
sha=$(jq -r --arg a "$ASSET" '.assets[] | select(.name == $a) | .digest // empty' <<<"$release")
[ -n "$url" ] || die "release $tag has no $ASSET asset"
case "$url" in https://*) ;; *) die "refusing a non-https download URL: $url" ;; esac

sha=${sha#sha256:}
[[ $sha =~ ^[0-9a-f]{64}$ ]] || die "GitHub publishes no sha256 digest for $ASSET in $tag"

say "coi $tag ($ASSET, sha256: $sha)"

if [ "$force" = 0 ] && [ -f "$DEST" ] && [ "$(sha256sum "$DEST" | awk '{ print $1 }')" = "$sha" ]; then
    say "$DEST is already up to date ($tag)."
    exit 0
fi

# ── 2. Download, verify sha256, and install ───────────────────────────────────
work=$(mktemp -d "${TMPDIR:-/tmp}/coi-install.XXXXXX")
trap 'rm -rf "$work"' EXIT

if [ "$dry" = 1 ]; then
    echo "+ curl -fL --proto '=https' --tlsv1.2 -o $work/$ASSET $url"
    echo "+ verify sha256($work/$ASSET) == $sha"
    echo "+ ${SUDO:+$SUDO }install -o root -g root -Dm0755 $work/$ASSET $DEST"
else
    say "Downloading $ASSET..."
    if [ -t 1 ]; then progress=--progress-bar; else progress=-sS; fi
    curl -fL --proto '=https' --tlsv1.2 "$progress" -o "$work/$ASSET" "$url"

    actual=$(sha256sum "$work/$ASSET" | awk '{ print $1 }')
    [ "$actual" = "$sha" ] \
        || die "sha256 mismatch for $ASSET: expected $sha, got $actual"
    say "Verified sha256 checksum ($sha)."

    say "Installing $DEST..."
    $SUDO install -o root -g root -Dm0755 "$work/$ASSET" "$DEST"
fi

# ── 3. Incus check ────────────────────────────────────────────────────────────
target_user=${SUDO_USER:-$(id -un)}
if ! command -v incus >/dev/null 2>&1; then
    warn "incus is not installed: coi needs Incus and the incus-admin group (run 'mise run services:incus')"
elif ! id -nG "$target_user" | tr ' ' '\n' | grep -qx incus-admin; then
    warn "$target_user is not in the incus-admin group (run 'mise run services:incus')"
fi

say "coi $tag installed at $DEST."
