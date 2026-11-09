#!/usr/bin/env bash
#MISE description="Build and install ArtCraft from source (Arch-based)"
#USAGE flag "--tag <tag>" help="Git release tag or branch to build (default: latest)"
#USAGE flag "--build-dir <dir>" help="Directory to clone and build repository in"
#USAGE flag "--clean" help="Clean build directory before and after build"
#USAGE flag "--remove" help="Uninstall ArtCraft and remove launcher/icons"
#USAGE flag "-n --dry-run" help="Preview actions without executing"
set -euo pipefail

source "${MISE_TASK_DIR}/../../../lib/common.sh"
require_arch

TOOLCHAIN_DIR="${MISE_TASK_DIR}/../../../lib/pkg/oss/artcraft"

say()  { printf '\033[1;34m::\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
run()  { if [ "$dry" = 1 ]; then echo "+ $*"; else "$@"; fi; }

go_dir() {
    if [ "$dry" = 1 ]; then
        echo "+ cd $1"
    else
        pushd "$1" >/dev/null
    fi
}

back_dir() {
    if [ "$dry" = 1 ]; then
        echo "+ cd -"
    else
        popd >/dev/null
    fi
}

SUDO=
[ "$(id -u)" -ne 0 ] && SUDO=sudo

tag=""
build_dir=""
clean=0
remove=0
dry=0

[[ "${usage_clean:-false}" == "true" ]] && clean=1
[[ "${usage_remove:-false}" == "true" ]] && remove=1
[[ "${usage_dry_run:-false}" == "true" ]] && dry=1
[ -n "${usage_tag:-}" ] && tag="$usage_tag"
[ -n "${usage_build_dir:-}" ] && build_dir="$usage_build_dir"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --tag)          tag="${2:-}"; shift ;;
        --build-dir)    build_dir="${2:-}"; shift ;;
        --clean)        clean=1 ;;
        --remove)       remove=1 ;;
        -n|--dry-run)   dry=1 ;;
    esac
    shift
done

BUILD_DIR="${build_dir:-${XDG_CACHE_HOME:-$HOME/.cache}/artcraft-build}"

# ── Removal ───────────────────────────────────────────────────────────────────
if [ "$remove" = 1 ]; then
    say "Removing ArtCraft from /usr/local..."
    run $SUDO rm -f /usr/local/bin/artcraft
    run $SUDO rm -f /usr/local/share/applications/artcraft.desktop
    run $SUDO rm -f /usr/local/share/icons/hicolor/32x32/apps/artcraft.png
    run $SUDO rm -f /usr/local/share/icons/hicolor/64x64/apps/artcraft.png
    run $SUDO rm -f /usr/local/share/icons/hicolor/128x128/apps/artcraft.png
    run $SUDO rm -f /usr/local/share/icons/hicolor/256x256/apps/artcraft.png
    run $SUDO rm -f /usr/local/share/icons/hicolor/512x512/apps/artcraft.png

    if command -v update-desktop-database >/dev/null 2>&1; then
        run $SUDO update-desktop-database -q /usr/local/share/applications || true
    fi
    if command -v gtk-update-icon-cache >/dev/null 2>&1; then
        run $SUDO gtk-update-icon-cache -q -t -f /usr/local/share/icons/hicolor || true
    fi

    if [ "$clean" = 1 ] && [ -d "$BUILD_DIR" ]; then
        say "Cleaning build directory: $BUILD_DIR"
        run rm -rf "$BUILD_DIR"
    fi

    say "ArtCraft uninstalled successfully."
    exit 0
fi

# ── System Dependencies (pacman) ─────────────────────────────────────────────
PKGS=(
    mise
    base-devel
    git
    webkit2gtk-4.1
    gtk3
    libayatana-appindicator
    librsvg
    openssl
    clang
    nasm
    perl
    xdotool
)

missing_pkgs=()
for pkg in "${PKGS[@]}"; do
    if ! pacman -Qq "$pkg" >/dev/null 2>&1; then
        missing_pkgs+=("$pkg")
    fi
done

if [ "${#missing_pkgs[@]}" -gt 0 ]; then
    say "Installing missing system dependencies: ${missing_pkgs[*]}"
    run $SUDO pacman -S --needed --noconfirm "${missing_pkgs[@]}"
fi

# ── Mise Toolchain Provisioning ──────────────────────────────────────────────
say "Provisioning mise build toolchain (node 24, rust, tauri-cli, cmake)..."
run mise trust "$TOOLCHAIN_DIR/mise.toml"
run mise -C "$TOOLCHAIN_DIR" install

# ── Source Checkout ──────────────────────────────────────────────────────────
if [ -z "$tag" ]; then
    say "Fetching latest ArtCraft release tag from GitHub..."
    latest_tag=$(curl -sSL "https://api.github.com/repos/storytold/artcraft/releases/latest" 2>/dev/null \
        | grep -m1 '"tag_name":' \
        | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/' || true)
    tag="${latest_tag:-main}"
fi

if [ "$clean" = 1 ] && [ -d "$BUILD_DIR" ]; then
    say "Cleaning existing build directory: $BUILD_DIR"
    run rm -rf "$BUILD_DIR"
fi

if [ ! -d "$BUILD_DIR/.git" ]; then
    say "Cloning ArtCraft ($tag) into $BUILD_DIR..."
    run mkdir -p "$(dirname "$BUILD_DIR")"
    run git clone --depth 1 --branch "$tag" https://github.com/storytold/artcraft.git "$BUILD_DIR"
else
    say "Fetching latest tags and checking out $tag in $BUILD_DIR..."
    run git -C "$BUILD_DIR" fetch --tags --depth 1 origin "$tag" 2>/dev/null || run git -C "$BUILD_DIR" fetch --tags origin
    run git -C "$BUILD_DIR" checkout "$tag"
fi

# ── Frontend Build (via mise) ────────────────────────────────────────────────
say "Installing frontend dependencies (npm ci via mise)..."
go_dir "$BUILD_DIR/frontend"
if [ "$dry" = 1 ]; then
    echo "+ mise -C $TOOLCHAIN_DIR exec -- npm ci --no-audit --no-fund"
else
    run mise -C "$TOOLCHAIN_DIR" exec -- npm ci --no-audit --no-fund
fi

say "Building frontend assets (Nx production build via mise)..."
if [ "$dry" = 1 ]; then
    echo "+ mise -C $TOOLCHAIN_DIR exec -- npx nx run artcraft:build"
else
    run mise -C "$TOOLCHAIN_DIR" exec -- npx nx run artcraft:build
fi
back_dir

# ── Rust / Tauri App Build (via mise) ────────────────────────────────────────
say "Building ArtCraft Rust desktop crate (release via mise)..."
go_dir "$BUILD_DIR/crates/desktop/artcraft"

if [ "$dry" = 1 ]; then
    echo "+ mise -C $TOOLCHAIN_DIR exec -- cargo tauri build --no-bundle --config '{\"build\":{\"beforeBuildCommand\":\"\"}}'"
else
    run mise -C "$TOOLCHAIN_DIR" exec -- cargo tauri build --no-bundle --config '{"build":{"beforeBuildCommand":""}}'
fi
back_dir

# ── Installation ─────────────────────────────────────────────────────────────
say "Installing ArtCraft binary to /usr/local/bin..."
run $SUDO install -Dm0755 "$BUILD_DIR/target/release/artcraft" /usr/local/bin/artcraft

say "Installing desktop entry and icons..."
desktop_file="/usr/local/share/applications/artcraft.desktop"
if [ "$dry" = 1 ]; then
    echo "+ write $desktop_file"
else
    $SUDO mkdir -p /usr/local/share/applications
    $SUDO tee "$desktop_file" >/dev/null <<'EOF'
[Desktop Entry]
Name=ArtCraft
GenericName=AI Creative Studio
Comment=IDE for interactive AI image and video creation
Exec=/usr/local/bin/artcraft %U
Icon=artcraft
Terminal=false
Type=Application
Categories=Graphics;2DGraphics;3DGraphics;AudioVideo;Development;
Keywords=AI;Image;Video;3D;Generation;Art;
StartupWMClass=artcraft
EOF
fi

icons_dir="$BUILD_DIR/crates/desktop/artcraft/icons"
install_icon() {
    local src="$1"
    local dest="$2"
    if [ "$dry" = 1 ]; then
        echo "+ install -Dm0644 $src $dest"
    elif [ -f "$src" ]; then
        run $SUDO install -Dm0644 "$src" "$dest"
    fi
}

install_icon "$icons_dir/32x32.png"      /usr/local/share/icons/hicolor/32x32/apps/artcraft.png
install_icon "$icons_dir/64x64.png"      /usr/local/share/icons/hicolor/64x64/apps/artcraft.png
install_icon "$icons_dir/128x128.png"    /usr/local/share/icons/hicolor/128x128/apps/artcraft.png
install_icon "$icons_dir/128x128@2x.png" /usr/local/share/icons/hicolor/256x256/apps/artcraft.png
install_icon "$icons_dir/icon.png"        /usr/local/share/icons/hicolor/512x512/apps/artcraft.png

if command -v update-desktop-database >/dev/null 2>&1; then
    run $SUDO update-desktop-database -q /usr/local/share/applications || true
fi
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
    run $SUDO gtk-update-icon-cache -q -t -f /usr/local/share/icons/hicolor || true
fi

if [ "$clean" = 1 ]; then
    say "Cleaning build directory: $BUILD_DIR"
    run rm -rf "$BUILD_DIR"
fi

say "ArtCraft installation complete! Launch it with 'artcraft' or via your desktop launcher."
