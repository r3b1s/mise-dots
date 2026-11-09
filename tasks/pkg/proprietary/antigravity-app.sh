#!/usr/bin/env bash
#MISE description="Install or upgrade Google Antigravity desktop app from official package"
#MISE alias="pkg:proprietary:antigravity"
#USAGE flag "--url <url>" help="Direct tar.gz download URL (overrides download page scraping)"
#USAGE flag "-f --force" help="Reinstall even if current version is up to date"
#USAGE flag "--check" help="Check if an upgrade is available without downloading"
#USAGE flag "--remove" help="Uninstall Antigravity and remove launcher/icons"
#USAGE flag "-n --dry-run" help="Preview actions without executing"
set -euo pipefail

source "${MISE_TASK_DIR}/../../../lib/common.sh"
require_arch

say()  { printf '\033[1;34m::\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
run()  { if [ "$dry" = 1 ]; then echo "+ $*"; else "$@"; fi; }

SUDO=
[ "$(id -u)" -ne 0 ] && SUDO=sudo

url=""
force=0
check=0
remove=0
dry=0

[[ "${usage_force:-false}" == "true" ]] && force=1
[[ "${usage_check:-false}" == "true" ]] && check=1
[[ "${usage_remove:-false}" == "true" ]] && remove=1
[[ "${usage_dry_run:-false}" == "true" ]] && dry=1
[ -n "${usage_url:-}" ] && url="$usage_url"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --url)          url="${2:?--url needs a value}"; shift ;;
        -f|--force)     force=1 ;;
        --check)        check=1 ;;
        --remove)       remove=1 ;;
        -n|--dry-run)   dry=1 ;;
    esac
    shift
done

PAGE=https://antigravity.google/download
INSTALL_DIR=/usr/local/lib/antigravity
BIN_LINK=/usr/local/bin/antigravity-app
DESKTOP_FILE=/usr/local/share/applications/antigravity.desktop
ICON_FILE=/usr/local/share/icons/hicolor/512x512/apps/antigravity.png

refresh_desktop_db() {
    if command -v update-desktop-database >/dev/null 2>&1; then
        run $SUDO update-desktop-database -q /usr/local/share/applications || true
    fi
    if command -v gtk-update-icon-cache >/dev/null 2>&1; then
        run $SUDO gtk-update-icon-cache -q -t -f /usr/local/share/icons/hicolor || true
    fi
}

# ── Removal ───────────────────────────────────────────────────────────────────
if [ "$remove" = 1 ]; then
    say "Removing Antigravity from /usr/local..."
    if [ -L "$BIN_LINK" ] && [[ "$(readlink "$BIN_LINK")" == "$INSTALL_DIR"/* ]]; then
        run $SUDO rm -f "$BIN_LINK"
    fi
    run $SUDO rm -f "$DESKTOP_FILE" "$ICON_FILE"
    run $SUDO rm -rf "$INSTALL_DIR"
    refresh_desktop_db
    say "Antigravity removed. User data (~/.config/Antigravity) is preserved."
    exit 0
fi

# ── Prerequisites ─────────────────────────────────────────────────────────────
for tool in curl grep sed; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool is required"
done

# ── 1. Fetch Release / Download URL ───────────────────────────────────────────
case "$(uname -m)" in
    x86_64)  platform=linux-x64 ;;
    aarch64) platform=linux-arm ;;
    *) die "unsupported architecture: $(uname -m)" ;;
esac

say "Checking for Antigravity release..."
if [ -z "$url" ]; then
    url=$(curl -fsSL --proto '=https' --tlsv1.2 "$PAGE" \
        | grep -oE "https://storage\.googleapis\.com/antigravity-public/antigravity-hub/[^\"' ]+/$platform/Antigravity\.tar\.gz" \
        | sort -u | head -n1 || true)
    if [ -z "$url" ]; then
        die "no $platform archive found on $PAGE; pass one with --url"
    fi
fi
case "$url" in https://*) ;; *) die "refusing a non-https URL: $url" ;; esac

version=$(sed -E 's|.*/antigravity-hub/([^/]+)/.*|\1|' <<<"$url")
[ "$version" != "$url" ] || version=""

# Identify existing installed version
installed_ver=""
installed_url=""
if [ -f "$INSTALL_DIR/.version" ]; then
    installed_ver=$(cat "$INSTALL_DIR/.version" 2>/dev/null || true)
fi
if [ -f "$INSTALL_DIR/.source-url" ]; then
    installed_url=$(cat "$INSTALL_DIR/.source-url" 2>/dev/null || true)
    if [ -z "$installed_ver" ]; then
        installed_ver=$(sed -E 's|.*/antigravity-hub/([^/]+)/.*|\1|' <<<"$installed_url")
        [ "$installed_ver" != "$installed_url" ] || installed_ver=""
    fi
fi

is_installed=0
[ -d "$INSTALL_DIR" ] && [ -x "$BIN_LINK" ] && is_installed=1

# ── 2. Check / Up-to-date Comparison ──────────────────────────────────────────
if [ "$check" = 1 ]; then
    if [ "$is_installed" = 1 ]; then
        if { [ -n "$version" ] && [ "$installed_ver" = "$version" ]; } || \
           { [ -n "$installed_url" ] && [ "$installed_url" = "$url" ]; }; then
            say "Antigravity ${installed_ver:+v$installed_ver }is installed and up to date."
            exit 0
        else
            say "Antigravity update available: ${installed_ver:-current} -> ${version:-new version}"
            exit 10
        fi
    else
        say "Antigravity ${version:+v$version }is available (none currently installed)."
        exit 11
    fi
fi

if [ "$force" = 0 ] && [ "$is_installed" = 1 ]; then
    if { [ -n "$version" ] && [ "$installed_ver" = "$version" ]; } || \
       { [ -n "$installed_url" ] && [ "$installed_url" = "$url" ]; }; then
        say "Antigravity ${installed_ver:+v$installed_ver }is already up to date ($INSTALL_DIR)."
        exit 0
    fi
fi

if [ "$is_installed" = 1 ]; then
    say "Upgrading Antigravity: ${installed_ver:-current} -> ${version:-new version}"
else
    say "Installing Antigravity ${version:+v$version}..."
fi

# ── 3. Dry Run Preview ────────────────────────────────────────────────────────
if [ "$dry" = 1 ]; then
    echo "+ check system dependencies: gtk3 nss alsa-lib libsecret xdg-utils python"
    echo "+ curl -fL --proto '=https' --tlsv1.2 -o <tmp>/antigravity.tar.gz $url"
    echo "+ unpack archive"
    echo "+ extract icon.png from resources/app.asar"
    echo "+ sudo rm -rf $INSTALL_DIR"
    echo "+ sudo cp -a <tree> $INSTALL_DIR"
    echo "+ sudo chown -R root:root $INSTALL_DIR"
    echo "+ write $INSTALL_DIR/.source-url"
    [ -n "$version" ] && echo "+ write $INSTALL_DIR/.version ($version)"
    echo "+ sudo ln -sfn $INSTALL_DIR/antigravity $BIN_LINK"
    echo "+ sudo install -Dm0644 <icon.png> $ICON_FILE"
    echo "+ write $DESKTOP_FILE"
    echo "+ refresh desktop database"
    exit 0
fi

# ── 4. System Dependencies (pacman) ───────────────────────────────────────────
PKGS=(gtk3 nss alsa-lib libsecret xdg-utils python)

missing_pkgs=()
for pkg in "${PKGS[@]}"; do
    pacman -Qq "$pkg" >/dev/null 2>&1 || missing_pkgs+=("$pkg")
done
if [ "${#missing_pkgs[@]}" -gt 0 ]; then
    say "Installing missing system dependencies: ${missing_pkgs[*]}"
    run $SUDO pacman -S --needed --noconfirm "${missing_pkgs[@]}"
fi

# ── 5. Download and Unpack (as invoking user) ──────────────────────────────────
work=$(mktemp -d "${XDG_CACHE_HOME:-$HOME/.cache}/antigravity-install.XXXXXX")
trap 'rm -rf "$work"' EXIT

say "Downloading Antigravity package ($url)..."
if [ -t 1 ]; then progress=--progress-bar; else progress=-sS; fi
curl -fL --proto '=https' --tlsv1.2 $progress -o "$work/antigravity.tar.gz" "$url"

say "Unpacking..."
mkdir "$work/tree"
tar -xzf "$work/antigravity.tar.gz" -C "$work/tree" --no-same-owner --no-same-permissions

src="$work/tree"
mapfile -t top < <(find "$src" -mindepth 1 -maxdepth 1)
if [ "${#top[@]}" -eq 1 ] && [ -d "${top[0]}" ]; then
    src="${top[0]}"
fi

launcher=$(find "$src" -maxdepth 2 -type f -perm -u+x -iname antigravity | sort | head -n1)
if [ -z "$launcher" ]; then
    die "no 'antigravity' executable found in archive; layout may have changed"
fi
launcher_rel=${launcher#"$src"/}

# Extract icon from resources/app.asar
extract_icon() {
    python3 -I - "$1" "$2" <<'PY'
import hashlib, json, struct, sys
asar, out = sys.argv[1:3]
with open(asar, "rb") as f:
    n = struct.unpack("<I", f.read(16)[12:16])[0]
    header = json.loads(f.read(n))
    entry = header["files"]["icon.png"]
    f.seek((16 + n + 3) & ~3)
    f.seek(int(entry["offset"]), 1)
    data = f.read(entry["size"])
if hashlib.sha256(data).hexdigest() != entry["integrity"]["hash"] or data[:8] != b"\x89PNG\r\n\x1a\n":
    sys.exit("icon.png in app.asar failed its integrity check")
with open(out, "wb") as f:
    f.write(data)
PY
}

icon=""
if extract_icon "$src/resources/app.asar" "$work/icon.png" 2>/dev/null; then
    icon=antigravity
else
    warn "could not extract icon from app.asar; desktop entry will use generic icon"
fi

# ── 6. Installation ───────────────────────────────────────────────────────────
say "Installing to $INSTALL_DIR..."
run $SUDO rm -rf "$INSTALL_DIR"
run $SUDO mkdir -p "$INSTALL_DIR"
run $SUDO cp -a --no-preserve=ownership "$src"/. "$INSTALL_DIR"/
run $SUDO chown -R root:root "$INSTALL_DIR"

printf '%s\n' "$url" | $SUDO tee "$INSTALL_DIR/.source-url" >/dev/null
if [ -n "$version" ]; then
    printf '%s\n' "$version" | $SUDO tee "$INSTALL_DIR/.version" >/dev/null
fi

run $SUDO ln -sfn "$INSTALL_DIR/$launcher_rel" "$BIN_LINK"

if [ -n "$icon" ]; then
    say "Installing icon..."
    $SUDO install -Dm0644 "$work/icon.png" "$ICON_FILE"
fi

say "Writing desktop entry..."
entry=$(mktemp "$work/desktop.XXXXXX")
{
    echo "[Desktop Entry]"
    echo "Name=Antigravity"
    echo "GenericName=AI Development Environment"
    echo "Comment=Google Antigravity"
    echo "Exec=$BIN_LINK %U"
    [ -n "$icon" ] && echo "Icon=$icon"
    echo "Terminal=false"
    echo "Type=Application"
    echo "Categories=Development;IDE;"
    echo "StartupWMClass=antigravity"
    [ -n "$version" ] && echo "X-Antigravity-Version=$version"
} >"$entry"
if ! cmp -s "$entry" "$DESKTOP_FILE" 2>/dev/null; then
    $SUDO install -Dm0644 "$entry" "$DESKTOP_FILE"
fi
refresh_desktop_db

printf '\n\033[1;32m✓ Antigravity %ssuccessfully installed!\033[0m\n' "${version:+v$version }"
echo "  Binary:        $BIN_LINK"
echo "  Desktop Entry: $DESKTOP_FILE"
