#!/usr/bin/env bash
#MISE description="Install or upgrade CommandCode desktop app from official GitHub release"
#MISE alias="pkg:proprietary:commandcode"
#USAGE flag "--tag <tag>" help="Release tag or version to install (default: latest)"
#USAGE flag "-f --force" help="Reinstall even if current version is up to date"
#USAGE flag "--check" help="Check if an upgrade is available without downloading"
#USAGE flag "--remove" help="Uninstall CommandCode desktop app and remove launcher/icons"
#USAGE flag "-n --dry-run" help="Preview actions without downloading"
set -euo pipefail

source "${MISE_TASK_DIR}/../../../lib/common.sh"
require_arch

say()  { printf '\033[1;34m::\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
run()  { if [ "$dry" = 1 ]; then echo "+ $*"; else "$@"; fi; }

REPO="CommandCodeAI/desktop"
SLUG="commandcode"
APPS_DIR="$HOME/Applications"
DESKTOP_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
ICON_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor"
BIN_DIR="$HOME/.local/bin"
BIN_LINK="$BIN_DIR/$SLUG"
DESKTOP_FILE="$DESKTOP_DIR/$SLUG.desktop"

tag=""
force=0
check=0
remove=0
dry=0

[[ "${usage_force:-false}" == "true" ]] && force=1
[[ "${usage_check:-false}" == "true" ]] && check=1
[[ "${usage_remove:-false}" == "true" ]] && remove=1
[[ "${usage_dry_run:-false}" == "true" ]] && dry=1
[ -n "${usage_tag:-}" ] && tag="$usage_tag"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --tag)        tag="${2:?--tag needs a value}"; shift ;;
        -f|--force)   force=1 ;;
        --check)      check=1 ;;
        --remove)     remove=1 ;;
        -n|--dry-run) dry=1 ;;
    esac
    shift
done

# ── Removal ───────────────────────────────────────────────────────────────────
if [ "$remove" = 1 ]; then
    say "Removing CommandCode desktop application..."
    if [ -d "$APPS_DIR" ]; then
        find "$APPS_DIR" -maxdepth 1 -name 'CommandCode-*.AppImage' -delete 2>/dev/null || true
    fi
    [ -L "$BIN_LINK" ] && run rm -f "$BIN_LINK"
    [ -f "$DESKTOP_FILE" ] && run rm -f "$DESKTOP_FILE"
    find "$ICON_DIR" -name "$SLUG.*" -delete 2>/dev/null || true

    if command -v update-desktop-database >/dev/null 2>&1 && [ "$dry" = 0 ]; then
        update-desktop-database "$DESKTOP_DIR" 2>/dev/null || true
    fi
    say "CommandCode removed."
    exit 0
fi

# ── Prerequisites ─────────────────────────────────────────────────────────────
for tool in curl jq sha256sum; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool is required"
done
[ "$(uname -m)" = x86_64 ] || die "CommandCode publishes Linux AppImages for x86_64 only"

if [ "$check" = 0 ] && command -v pacman >/dev/null 2>&1 && ! pacman -Qq fuse2 >/dev/null 2>&1; then
    warn "fuse2 is not installed: AppImages require libfuse.so.2 (sudo pacman -S fuse2)"
fi

# ── 1. Fetch Release Metadata ─────────────────────────────────────────────────
url=""
sha256=""
sha512_hex=""
version=""

say "Checking for CommandCode release..."

# Try gh release view first if available
if command -v gh >/dev/null 2>&1; then
    gh_args=(release view --repo "$REPO" --json tagName,assets)
    [ -n "$tag" ] && gh_args=(release view "$tag" --repo "$REPO" --json tagName,assets)
    if json=$(gh "${gh_args[@]}" 2>/dev/null); then
        tag=$(jq -r '.tagName // empty' <<<"$json")
        version="${tag#v}"
        url=$(jq -r '.assets[] | select(.name | test("^CommandCode-.*-x86_64\\.AppImage$")) | .url // empty' <<<"$json")
        digest=$(jq -r '.assets[] | select(.name | test("^CommandCode-.*-x86_64\\.AppImage$")) | .digest // empty' <<<"$json")
        sha256="${digest#sha256:}"
    fi
fi

# Direct fallback to latest-linux.yml release manifest if gh not configured
if [ -z "$url" ]; then
    yml_url="https://github.com/$REPO/releases/latest/download/latest-linux.yml"
    [ -n "$tag" ] && yml_url="https://github.com/$REPO/releases/download/$tag/latest-linux.yml"
    if yml=$(curl -fsSL --proto '=https' --tlsv1.2 "$yml_url" 2>/dev/null); then
        version=$(grep -m1 '^version:' <<<"$yml" | awk '{print $2}' | tr -d '\r"')
        tag="v$version"
        asset_file=$(grep -m1 '^path:' <<<"$yml" | awk '{print $2}' | tr -d '\r"')
        [ -n "$asset_file" ] || asset_file="CommandCode-${version}-x86_64.AppImage"
        url="https://github.com/$REPO/releases/download/${tag}/${asset_file}"
        sha512_b64=$(grep -m1 'sha512:' <<<"$yml" | awk '{print $2}' | tr -d '\r"')
        if command -v xxd >/dev/null 2>&1; then
            sha512_hex=$(printf '%s' "$sha512_b64" | base64 -d 2>/dev/null | xxd -p -c 64 || true)
        fi
    fi
fi

[ -n "$url" ] || die "Could not resolve download URL for CommandCode release (${tag:-latest})"
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.]+)?$ ]] || die "Unexpected release version format: $version"

dest="$APPS_DIR/CommandCode-$version-x86_64.AppImage"

# Identify existing installed version
installed_app=""
installed_ver=""
if [ -d "$APPS_DIR" ]; then
    installed_app=$(find "$APPS_DIR" -maxdepth 1 -name 'CommandCode-*.AppImage' 2>/dev/null | sort -V | tail -n 1 || true)
    if [ -n "$installed_app" ]; then
        installed_ver=$(basename "$installed_app" | sed -E 's/^CommandCode-([0-9.]+.*)-x86_64\.AppImage$/\1/')
    fi
fi

# ── 2. Check / Up-to-date Comparison ──────────────────────────────────────────
if [ "$check" = 1 ]; then
    if [ -f "$dest" ] && [ -n "$installed_ver" ] && [ "$installed_ver" = "$version" ]; then
        say "CommandCode v$version is installed and up to date."
        exit 0
    elif [ -n "$installed_ver" ]; then
        say "CommandCode update available: v$installed_ver -> v$version"
        exit 10
    else
        say "CommandCode v$version is available (none currently installed)."
        exit 11
    fi
fi

if [ "$force" = 0 ] && [ -f "$dest" ] && [ -n "$installed_ver" ] && [ "$installed_ver" = "$version" ]; then
    say "CommandCode v$version is already up to date ($dest)."
    exit 0
fi

if [ -n "$installed_ver" ] && [ "$installed_ver" != "$version" ]; then
    say "Upgrading CommandCode: v$installed_ver -> v$version"
else
    say "Installing CommandCode v$version..."
fi

# ── 3. Download & Verify ──────────────────────────────────────────────────────
work=$(mktemp -d "${TMPDIR:-/tmp}/commandcode-install.XXXXXX")
trap 'rm -rf "$work"' EXIT

download_target="$work/CommandCode-$version-x86_64.AppImage"

if [ "$dry" = 1 ]; then
    echo "+ curl -fL --proto '=https' --tlsv1.2 -o $download_target $url"
    echo "+ verify checksum"
    echo "+ move to $dest"
    echo "+ ln -sfn $dest $BIN_LINK"
    echo "+ extract and register desktop entry and icons"
    if [ -n "$installed_app" ] && [ "$installed_app" != "$dest" ]; then
        echo "+ remove previous version: $installed_app"
    fi
    exit 0
fi

say "Downloading $url..."
if [ -t 1 ]; then progress=--progress-bar; else progress=-sS; fi
curl -fL --proto '=https' --tlsv1.2 $progress -o "$download_target" "$url"

# Verify checksum
if [ -n "$sha256" ]; then
    actual=$(sha256sum "$download_target" | awk '{print $1}')
    [ "$actual" = "$sha256" ] || die "sha256 mismatch: expected $sha256, got $actual"
    say "Verified sha256 checksum ($sha256)."
elif [ -n "$sha512_hex" ]; then
    actual=$(sha512sum "$download_target" | awk '{print $1}')
    [ "$actual" = "$sha512_hex" ] || die "sha512 mismatch: expected $sha512_hex, got $actual"
    say "Verified sha512 checksum."
fi

# ── 4. Internal Install Function ──────────────────────────────────────────────
mkdir -p "$APPS_DIR" "$BIN_DIR" "$DESKTOP_DIR" "$ICON_DIR"
mv -f "$download_target" "$dest"
chmod u+x "$dest"

# Symlink launcher
ln -sfn "$dest" "$BIN_LINK"
say "Linked launcher: $BIN_LINK -> $dest"

# ── 5. Icons and Desktop Entry Extraction ─────────────────────────────────────
say "Extracting desktop metadata and icons..."
(cd "$work" && "$dest" --appimage-extract '*.desktop' >/dev/null 2>&1 \
    && "$dest" --appimage-extract 'usr/share/icons/*' >/dev/null 2>&1) || true

# Install extracted icons
icon_installed=0
if [ -d "$work/squashfs-root/usr/share/icons/hicolor" ]; then
    while read -r icon; do
        [ -n "$icon" ] || continue
        rel=${icon#"$work/squashfs-root/usr/share/icons/hicolor/"}
        target="$ICON_DIR/${rel%/*}/$SLUG.${icon##*.}"
        mkdir -p "$(dirname "$target")"
        cp -f "$icon" "$target"
        icon_installed=1
    done < <(find "$work/squashfs-root/usr/share/icons/hicolor" -type f \( -name '*.png' -o -name '*.svg' \) 2>/dev/null)
fi

icon_name="$SLUG"
[ "$icon_installed" = 1 ] || icon_name="application-x-executable"

# Write desktop entry
cat > "$DESKTOP_FILE" <<EOF
[Desktop Entry]
Name=CommandCode
Comment=AI Software Development Assistant
Exec="$dest" %U
TryExec=$dest
Icon=$icon_name
Terminal=false
Type=Application
Categories=Development;IDE;
StartupWMClass=commandcode
X-AppImage-Version=$version
EOF
chmod 644 "$DESKTOP_FILE"

if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "$DESKTOP_DIR" 2>/dev/null || true
fi
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
    gtk-update-icon-cache -q -t -f "$ICON_DIR" 2>/dev/null || true
fi

# ── 6. Clean Up Previous Releases ─────────────────────────────────────────────
if [ -n "$installed_app" ] && [ "$installed_app" != "$dest" ] && [ -f "$installed_app" ]; then
    say "Cleaning up superseded version: $(basename "$installed_app")"
    rm -f "$installed_app"
fi

printf '\n\033[1;32m✓ CommandCode v%s successfully installed!\033[0m\n' "$version"
echo "  Binary:        $BIN_LINK"
echo "  Desktop Entry: $DESKTOP_FILE"
