#!/usr/bin/env bash
#MISE description="Back up OmniRoute data dir and env file to a timestamped tarball"
#USAGE flag "--dest <dir>" help="Directory to write the tarball into (default: ~/.local/share/omniroute/backups)"
#USAGE flag "-n --dry-run" help="Preview actions without writing anything"
set -euo pipefail

dry=0
dest=

[[ "${usage_dry_run:-false}" == "true" ]] && dry=1
if [ -n "${usage_dest:-}" ]; then dest="$usage_dest"; fi

for arg in "$@"; do
    case "$arg" in
        --dest) dest=${2:?--dest needs a value}; shift ;;
        --dest=*) dest=${arg#--dest=} ;;
        -n|--dry-run) dry=1 ;;
    esac
done

say()  { printf '\033[1;34m::\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
run()  { if [ "$dry" = 1 ]; then echo "+ $*"; else "$@"; fi; }

config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/omniroute"
state_dir="${XDG_DATA_HOME:-$HOME/.local/share}/omniroute"
data_dir="$state_dir/data"
envfile="$config_dir/.env"
dest=${dest:-"$state_dir/backups"}

[ -d "$data_dir" ] || die "nothing to back up: $data_dir does not exist (is OmniRoute installed?)"

stamp=$(date +%Y%m%d-%H%M%S)
out="$dest/omniroute-backup-$stamp.tar.gz"

say "Backing up $data_dir${envfile:+ and $envfile} to $out"
warn "this backup contains API keys and OAuth credentials: store it somewhere safe"
run mkdir -p "$dest"

if [ "$dry" = 1 ]; then
    echo "+ tar -czf $out -C ... (data/ + .env)"
    exit 0
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/omniroute-backup.XXXXXX")
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/omniroute-backup-$stamp"
cp -a "$data_dir" "$work/omniroute-backup-$stamp/data"
if [ -f "$envfile" ]; then
    cp -a "$envfile" "$work/omniroute-backup-$stamp/.env"
fi
tar -czf "$out" -C "$work" "omniroute-backup-$stamp"
chmod 0600 "$out"
say "wrote $out"
