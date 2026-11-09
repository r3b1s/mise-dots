#!/usr/bin/env bash
#MISE description="Install or update Paseo desktop AppImage"
#USAGE flag "--check" help="Check if latest release is installed without changing anything"
#USAGE flag "--remove" help="Remove Paseo desktop AppImage and desktop entry"
#USAGE flag "--tag <tag>" help="Install specific release tag"
#USAGE flag "-n --dry-run" help="Preview actions without downloading"
set -euo pipefail

dry=0
check=0
remove=0
tag=

[[ "${usage_dry_run:-false}" == "true" ]] && dry=1
[[ "${usage_check:-false}" == "true" ]] && check=1
[[ "${usage_remove:-false}" == "true" ]] && remove=1
if [ -n "${usage_tag:-}" ]; then tag="$usage_tag"; fi

while [ $# -gt 0 ]; do
    case "$1" in
        --tag)        tag=${2:?--tag needs a value}; shift ;;
        --check)      check=1 ;;
        --remove)     remove=1 ;;
        -n|--dry-run) dry=1 ;;
        *)            break ;;
    esac
    shift
done

say()  { printf '\033[1;34m::\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
run()  { if [ "$dry" = 1 ]; then echo "+ $*"; else "$@"; fi; }

REPO=getpaseo/paseo
ASSET=Paseo-x86_64.AppImage
SLUG=paseo
APPS_DIR="$HOME/Applications"
DESKTOP_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
ICON_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor"
DESKTOP_FILE="$DESKTOP_DIR/$SLUG.desktop"

install_appimage_helper() {
    local src="$1"
    mkdir -p "$APPS_DIR"
    local dest="$APPS_DIR/$(basename -- "$src")"
    if [ "$(realpath -- "$src")" != "$(realpath -m -- "$dest")" ]; then
        mv -f -- "$src" "$dest"
    fi
    chmod u+x -- "$dest"
}

if command -v install-appimage >/dev/null 2>&1; then
    INSTALL_APPIMAGE="install-appimage"
elif [ -x "$HOME/.local/bin/install-appimage" ]; then
    INSTALL_APPIMAGE="$HOME/.local/bin/install-appimage"
elif [ -x "$HOME/Dotfiles/cachy-dots/bin/install-appimage" ]; then
    INSTALL_APPIMAGE="$HOME/Dotfiles/cachy-dots/bin/install-appimage"
else
    INSTALL_APPIMAGE="install_appimage_helper"
fi

entries_running() {
    [ -d "$DESKTOP_DIR" ] || return 0
    grep -lF -- "$1" "$DESKTOP_DIR"/*.desktop 2>/dev/null | grep -vxF "$DESKTOP_FILE" || true
}

remove_appimages() {
    local keep=${1:-} app name
    [ -d "$APPS_DIR" ] || return 0
    while IFS= read -r app; do
        [ -n "$app" ] || continue
        name=${app##*/}
        case $name in
            Paseo-*.AppImage|Paseo.AppImage) ;;
            *) continue ;;
        esac
        [ -n "$keep" ] && [ "$app" = "$keep" ] && continue
        say "Removing old AppImage $app"
        run rm -f "$app"
        while IFS= read -r entry; do
            [ -n "$entry" ] || continue
            say "Removing obsolete desktop entry $entry (pointed at $name)"
            run rm -f "$entry"
        done < <(entries_running "$name")
    done < <(find "$APPS_DIR" -maxdepth 1 -type f 2>/dev/null)
}

refresh_desktop_database() {
    if command -v update-desktop-database >/dev/null 2>&1 && [ "$dry" = 0 ]; then
        update-desktop-database "$DESKTOP_DIR" 2>/dev/null || true
    fi
}

# ── Removal ───────────────────────────────────────────────────────────────────
if [ "$remove" = 1 ]; then
    say "Removing Paseo desktop app..."
    remove_appimages ""
    if [ -f "$DESKTOP_FILE" ]; then
        say "Removing $DESKTOP_FILE"
        run rm -f "$DESKTOP_FILE"
    fi
    find "$ICON_DIR" -name "$SLUG.*" -delete 2>/dev/null || true
    refresh_desktop_database
    say "Paseo desktop app removed."
    exit 0
fi

# ── Prerequisites ─────────────────────────────────────────────────────────────
for tool in curl jq sha256sum; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool is required"
done
[ "$(uname -m)" = x86_64 ] || die "Paseo publishes its AppImage for x86_64 only"
if [ "$check" = 0 ] && command -v pacman >/dev/null 2>&1 && ! pacman -Qq fuse2 >/dev/null 2>&1; then
    warn "fuse2 is not installed: the AppImage installs, but needs it to start (sudo pacman -S fuse2)"
fi

# ── 1. The release ────────────────────────────────────────────────────────────
if [ -n "$tag" ]; then
    api="https://api.github.com/repos/$REPO/releases/tags/$tag"
else
    api="https://api.github.com/repos/$REPO/releases/latest"
fi
say "Checking GitHub for ${tag:-the latest release}"
release=$(curl -fsSL -H 'Accept: application/vnd.github+json' "$api") \
    || die "could not read $api"
tag=$(jq -r '.tag_name' <<<"$release")
version=${tag#v}
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.]+)?$ ]] || die "unexpected release tag: $tag"
url=$(jq -r --arg a "$ASSET" '.assets[] | select(.name == $a) | .browser_download_url' <<<"$release")
sha=$(jq -r --arg a "$ASSET" '.assets[] | select(.name == $a) | .digest // empty' <<<"$release")
[ -n "$url" ] || die "release $tag has no $ASSET"
sha=${sha#sha256:}
[[ $sha =~ ^[0-9a-f]{64}$ ]] || die "GitHub publishes no sha256 for $ASSET in $tag"

dest="$APPS_DIR/Paseo-$version-x86_64.AppImage"
say "Paseo $version"

if [ "$check" = 1 ]; then
    if [ -f "$dest" ] && [ "$(sha256sum "$dest" | awk '{ print $1 }')" = "$sha" ]; then
        say "$dest is installed and current"
        exit 0
    fi
    installed=$(find "$APPS_DIR" -maxdepth 1 \( -name 'Paseo-*.AppImage' -o -name Paseo.AppImage \) \
        -printf '%f\n' 2>/dev/null | sort -V | tail -n 1) || true
    if [ -z "$installed" ]; then
        say "No Paseo AppImage in $APPS_DIR"
        exit 11
    fi
    say "Paseo $version is out (installed: $installed)"
    exit 10
fi

# ── 2–3. Download, verify, install ────────────────────────────────────────────
work=$(mktemp -d "${TMPDIR:-/tmp}/paseo-appimage.XXXXXX")
trap 'rm -rf "$work"' EXIT

if [ -f "$dest" ] && [ "$(sha256sum "$dest" | awk '{ print $1 }')" = "$sha" ]; then
    say "$dest is already installed"
else
    if [ -e "$dest" ]; then
        warn "$dest does not match the release's sha256; replacing it"
        run rm -f "$dest"
    fi
    if [ "$dry" = 1 ]; then
        echo "+ download $url, check sha256 $sha"
        echo "+ install to $dest"
    else
        say "Downloading $ASSET"
        if [ -t 1 ]; then progress=--progress-bar; else progress=-sS; fi
        curl -fL $progress -o "$work/${dest##*/}" "$url"
        [ "$(sha256sum "$work/${dest##*/}" | awk '{ print $1 }')" = "$sha" ] \
            || die "the download does not match the sha256 GitHub publishes ($sha)"
        $INSTALL_APPIMAGE "$work/${dest##*/}"
    fi
fi

if [ "$dry" = 1 ] && [ ! -f "$dest" ]; then
    echo "+ rewrite $DESKTOP_FILE from the AppImage's own entry, install its icons"
    remove_appimages "$dest"
    exit 0
fi

# ── 4. Icon and desktop entry ─────────────────────────────────────────────────
(cd "$work" && "$dest" --appimage-extract '*.desktop' >/dev/null \
    && "$dest" --appimage-extract 'usr/share/icons/*' >/dev/null) \
    || die "could not unpack the AppImage's desktop entry and icons"
bundled=$(find "$work/squashfs-root" -maxdepth 1 -name '*.desktop' | head -n 1)
[ -n "$bundled" ] || die "the AppImage has no desktop entry"

key() {
    awk -F= -v k="$1" '/^\[/ { group = $0 } group == "[Desktop Entry]" && $1 == k { sub(/^[^=]*=/, ""); print; exit }' "$bundled"
}
icon_name=$(key Icon)
exec_args=$(key Exec)
case $exec_args in
    AppRun\ *) exec_args=${exec_args#AppRun } ;;
    *)         exec_args=%U ;;
esac

say "Icons into $ICON_DIR"
icons=0
while read -r icon; do
    [ -n "$icon" ] || continue
    rel=${icon#"$work/squashfs-root/usr/share/icons/hicolor/"}
    target="$ICON_DIR/${rel%/*}/$SLUG.${icon##*.}"
    icons=$((icons + 1))
    cmp -s "$icon" "$target" || run install -D -m 644 "$icon" "$target"
done < <(find "$work/squashfs-root/usr/share/icons/hicolor" \
    \( -name "$icon_name.png" -o -name "$icon_name.svg" \) 2>/dev/null)
if [ "$icons" = 0 ]; then
    warn "the AppImage has no hicolor icon named $icon_name; the entry keeps a generic one"
    entry_icon=application-x-executable
else
    entry_icon=$SLUG
fi

exec_path=$(printf '%s' "$dest" | sed -e 's/[\\"`$]/\\&/g' -e 's/%/%%/g')
{
    echo '[Desktop Entry]'
    echo 'Type=Application'
    echo "Name=$(key Name | grep . || echo Paseo)"
    [ -z "$(key Comment)" ] || echo "Comment=$(key Comment)"
    echo "Exec=\"$exec_path\" $exec_args"
    echo "TryExec=$dest"
    echo "Icon=$entry_icon"
    echo 'Terminal=false'
    [ -z "$(key Categories)" ] || echo "Categories=$(key Categories)"
    [ -z "$(key MimeType)" ] || echo "MimeType=$(key MimeType)"
    [ -z "$(key StartupWMClass)" ] || echo "StartupWMClass=$(key StartupWMClass)"
    echo "X-AppImage-Version=$version"
} > "$work/$SLUG.desktop"
if cmp -s "$work/$SLUG.desktop" "$DESKTOP_FILE"; then
    say "$DESKTOP_FILE is up to date"
else
    say "Writing $DESKTOP_FILE"
    run install -D -m 644 "$work/$SLUG.desktop" "$DESKTOP_FILE"
fi
if command -v desktop-file-validate >/dev/null 2>&1 && [ "$dry" = 0 ]; then
    desktop-file-validate "$DESKTOP_FILE" || warn "desktop-file-validate has complaints about $DESKTOP_FILE"
fi

refresh_desktop_database
if [[ $(key MimeType) == *x-scheme-handler/paseo* ]] && command -v xdg-mime >/dev/null 2>&1 \
    && [ "$(xdg-mime query default x-scheme-handler/paseo 2>/dev/null)" != "$SLUG.desktop" ]; then
    say "paseo:// links open in the desktop app"
    run xdg-mime default "$SLUG.desktop" x-scheme-handler/paseo
fi

# ── 5. What it replaces ───────────────────────────────────────────────────────
remove_appimages "$dest"

printf '\n\033[1;32m✓ Paseo %s: %s\033[0m\n' "$version" "$dest"
printf '  Desktop entry: %s (icon %s)\n' "$DESKTOP_FILE" "$entry_icon"
