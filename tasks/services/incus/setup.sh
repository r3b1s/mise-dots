#!/usr/bin/env bash
#MISE description="Opt in to Incus system-container and VM manager (Arch-based)"
#MISE alias="services:incus"
#USAGE flag "--ui" help="Install incus-ui web UI package"
#USAGE flag "--remove" help="Disable incus services and remove its firewalld zone and ufw rules"
#USAGE flag "-n --dry-run" help="Preview actions without modifying system"
set -euo pipefail

source "${MISE_TASK_DIR}/../../../lib/common.sh"
source "${MISE_TASK_DIR}/../../../lib/firewalld.sh"
require_arch

BRIDGE=incusbr0
SUBID="root:1000000:1000000000"
ZONE=cachy-incus
UFW_TAG=incus

say()  { printf '\033[1;34m::\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
run()  { if [ "$dry" = 1 ]; then echo "+ $*"; else "$@"; fi; }

# ── ufw rules, tagged with the comment $UFW_TAG ──────────────────────────────
# rule ADD [SHOWN]: a wanted rule, as given to ufw, and as `ufw show added` prints it
# when that differs (ufw prints 0.0.0.0/0 as any, and moves proto to the end).
want_add=()
want_shown=()
rule() { want_add+=("$1"); want_shown+=("${2:-$1}"); }

ufw_do() {
    if [ "$dry" = 1 ]; then echo "+ ${SUDO:+$SUDO }ufw $*"; else $SUDO ufw "$@" >/dev/null; fi
}

# Make the rules tagged $UFW_TAG exactly the wanted ones: stale ones (from an old
# subnet, say) are deleted, missing ones added. Untagged rules are never touched.
ufw_sync() {
    local have r w keep words
    have=$($SUDO ufw show added 2>/dev/null | sed -n "s/^ufw \(.*\) comment '$UFW_TAG'\$/\1/p")
    while IFS= read -r r; do
        [ -n "$r" ] || continue
        keep=0
        for w in "${want_shown[@]}"; do [ "$r" = "$w" ] && keep=1; done
        [ "$keep" = 0 ] || continue
        say "Removing ufw rule: $r"
        read -ra words <<<"$r"
        # IPv4-only rules: ufw also looks for a v6 twin, and says it found none.
        if [ "${words[0]}" = route ]; then
            ufw_do route delete "${words[@]:1}"
        else
            ufw_do delete "${words[@]}"
        fi
    done <<<"$have"
    for i in "${!want_add[@]}"; do
        grep -qxF -- "${want_shown[$i]}" <<<"$have" && continue
        say "Adding ufw rule: ${want_shown[$i]} (comment '$UFW_TAG')"
        read -ra words <<<"${want_add[$i]}"
        ufw_do "${words[@]}" comment "$UFW_TAG"
    done
}

ui=0
remove=0
dry=0

[[ "${usage_ui:-false}" == "true" ]] && ui=1
[[ "${usage_remove:-false}" == "true" ]] && remove=1
[[ "${usage_dry_run:-false}" == "true" ]] && dry=1

for arg in "$@"; do
    case "$arg" in
        --ui)         ui=1 ;;
        --remove)     remove=1 ;;
        -n|--dry-run) dry=1 ;;
    esac
done

command -v pacman >/dev/null || die "pacman not found: this is for Arch-based systems"

SUDO=
if [ "$(id -u)" -ne 0 ]; then SUDO=sudo; fi
user=${SUDO_USER:-$(id -un)}
[ "$user" != root ] || die "run it as your own user (or with sudo from it), so there is a user to give access to"

# ── Removal ───────────────────────────────────────────────────────────────────
if [ "$remove" = 1 ]; then
    if fw_installed; then
        fw_guest_zone_remove "$ZONE"
        fw_commit
    fi
    if command -v ufw >/dev/null; then
        ufw_sync
    fi
    if systemctl is-enabled --quiet incus.service 2>/dev/null || systemctl is-enabled --quiet incus.socket 2>/dev/null; then
        warn "disabling Incus stops its running instances"
        say "Disabling incus.service and incus.socket"
        run $SUDO systemctl disable --now incus.service incus.socket
    fi
    if pacman -Qq incus-ui >/dev/null 2>&1; then
        say "Removing incus-ui"
        run $SUDO pacman -Rns --noconfirm incus-ui
    fi
    say "Done. The incus package, instances, storage, /etc/subuid, /etc/subgid and incus-admin are left as they were."
    exit 0
fi

# ── Packages ─────────────────────────────────────────────────────────────────
pkgs=(incus edk2-ovmf)
if [ "$ui" = 1 ]; then pkgs+=(incus-ui); fi
missing=()
for p in "${pkgs[@]}"; do
    pacman -Qq "$p" >/dev/null 2>&1 || missing+=("$p")
done
restart_reason=
if [ ${#missing[@]} -gt 0 ]; then
    say "Installing ${missing[*]} (pacman -Syu: never -S against a stale database)"
    run $SUDO pacman -Syu --needed --noconfirm "${missing[@]}" || die "could not install ${missing[*]}"
    case " ${missing[*]} " in *" incus-ui "*) restart_reason="incus-ui was installed" ;; esac
fi

# ── Subordinate IDs ──────────────────────────────────────────────────────────
for f in /etc/subuid /etc/subgid; do
    if ! grep -q '^root:' "$f" 2>/dev/null; then
        say "Adding $SUBID to $f"
        if [ "$dry" = 1 ]; then echo "+ echo $SUBID >> $f"; else printf '%s\n' "$SUBID" | $SUDO tee -a "$f" >/dev/null; fi
        restart_reason="${restart_reason:+$restart_reason and }new subordinate ID ranges"
    fi
done

# ── Services ─────────────────────────────────────────────────────────────────
was_active=0
if systemctl is-active --quiet incus.service 2>/dev/null; then was_active=1; fi

if ! systemctl is-enabled --quiet incus.service 2>/dev/null || ! systemctl is-enabled --quiet incus.socket 2>/dev/null; then
    say "Enabling and starting incus.socket and incus.service"
    run $SUDO systemctl enable --now incus.socket incus.service
fi

if [ -n "$restart_reason" ] && [ "$was_active" = 1 ]; then
    running=$($SUDO incus list --all-projects --format csv --columns ns 2>/dev/null | grep -c ',RUNNING$' || true)
    if [ "$running" = 0 ]; then
        say "Restarting incus.service ($restart_reason)"
        run $SUDO systemctl restart incus.service
    else
        warn "$restart_reason, and incus.service needs a restart for that. $running instance(s) are running, and a restart stops them: run 'sudo systemctl restart incus.service' when they can stop"
    fi
fi

# ── Group ────────────────────────────────────────────────────────────────────
if ! id -nG "$user" | tr ' ' '\n' | grep -qx incus-admin; then
    if [ "$dry" = 0 ] && ! getent group incus-admin >/dev/null; then
        die "no incus-admin group: the incus package's sysusers file should have made it"
    fi
    say "Adding $user to incus-admin (root-equivalent): log out of your desktop session and back in, or run \`newgrp incus-admin\` in a terminal"
    run $SUDO usermod -aG incus-admin "$user"
fi

# ── Default network ──────────────────────────────────────────────────────────
# incus admin init --minimal makes a dir storage pool and $BRIDGE, with a random
# 10.x.y.0/24. The firewall rules below are scoped to whatever subnet it picked.
cidr=
if command -v incus >/dev/null && $SUDO incus info >/dev/null 2>&1; then
    if ! $SUDO incus network show "$BRIDGE" >/dev/null 2>&1; then
        if [ -z "$($SUDO incus storage list --format csv 2>/dev/null)" ]; then
            say "Initialising Incus: a dir storage pool and $BRIDGE (incus admin init --minimal)"
            run $SUDO incus admin init --minimal
        else
            warn "Incus is already initialised, but without a $BRIDGE network: no firewall rules for it"
        fi
    fi
    cidr=$($SUDO incus network get "$BRIDGE" ipv4.address 2>/dev/null || true)
elif [ "$dry" = 1 ]; then
    echo "+ ${SUDO:+$SUDO }incus admin init --minimal    # when there is no $BRIDGE yet"
    warn "dry run: $BRIDGE's subnet is not known yet, so the ufw rules for it are not shown"
fi

gw=
net=
if [[ $cidr =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]]; then
    gw=${cidr%/*}
    net=$(ipv4_net "$cidr")
elif [ -n "$cidr" ]; then
    warn "$BRIDGE has ipv4.address=$cidr: no IPv4 firewall rules for it"
fi

# ── ufw ──────────────────────────────────────────────────────────────────────
# IPv4 only: every rule names an IPv4 address, so ufw makes no v6 twin of it. Egress
# is to wired (en+) and wireless (wl+) interfaces, not to Tailscale or other bridges.
if command -v ufw >/dev/null && [ -n "$net" ]; then
    rule "allow in on $BRIDGE proto udp from 0.0.0.0/0 port 68 to 0.0.0.0/0 port 67" \
         "allow in on $BRIDGE from any port 68 to any port 67 proto udp"
    rule "allow in on $BRIDGE from $net to $gw port 53"
    rule "route allow in on $BRIDGE out on en+ from $net"
    rule "route allow in on $BRIDGE out on wl+ from $net"
    ufw_sync
    if ! $SUDO ufw status 2>/dev/null | grep -qx 'Status: active'; then
        warn "ufw is installed but not enabled: its $BRIDGE rules apply once it is"
    fi
fi

# ── Firewalld ────────────────────────────────────────────────────────────────
if fw_installed; then
    fw_guest_zone "$ZONE" "$BRIDGE" "The default Incus bridge: DHCP and DNS from the host, and forwarding (tasks/services/incus). Bridges with other names are not covered."
    fw_commit
fi

echo
echo "Incus is configured${net:+ ($BRIDGE: $net)}. Next, as $user (after the group applies):"
echo "    incus launch images:archlinux/cloud demo"
if [ "$ui" = 1 ]; then
    echo "    incus webui                   # the web UI, in your browser, over the local socket"
fi
