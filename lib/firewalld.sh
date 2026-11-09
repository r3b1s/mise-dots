#!/usr/bin/env bash
# firewalld helpers for mise-dots tasks. Source this file; do not execute it.
# The caller sets SUDO and, in a dry run, dry=1; say and run are defined here when it has none.
#
# These helpers manage dedicated zones and policies under /etc/firewalld, written only
# when they differ, and reloaded cleanly. Hand edits to those files are overwritten.

declare -F say >/dev/null || say() { printf '\033[1;34m::\033[0m %s\n' "$*"; }
declare -F run >/dev/null || run() { if [ "${dry:-0}" = 1 ]; then echo "+ $*"; else "$@"; fi; }

fw_changed=0

fw_installed() { command -v firewall-cmd >/dev/null; }

# Through sudo: --state answers "not authorized" to a plain user. And never by the
# unit's state: firewalld exits 0 when nftables cannot load (a kernel upgraded in this
# boot), so `systemctl start` succeeds with no firewall running.
fw_active() { fw_installed && ${SUDO:-} firewall-cmd -q --state >/dev/null 2>&1; }

# fw_put zones|policies NAME: make /etc/firewalld/<kind>/NAME.xml match stdin.
fw_put() {
    local file="/etc/firewalld/$1/$2.xml" tmp
    tmp=$(mktemp)
    cat > "$tmp"
    if ${SUDO:-} cat -- "$file" 2>/dev/null | cmp -s "$tmp" -; then rm -f "$tmp"; return 0; fi
    say "Updating $file"
    if [ "${dry:-0}" = 1 ]; then
        ${SUDO:-} cat -- "$file" 2>/dev/null | diff -u - "$tmp" || true
        rm -f "$tmp"; return 0
    fi
    # 0640 is what firewalld itself writes; the file is only ever read by root.
    ${SUDO:-} install -D -o root -g root -m 0640 "$tmp" "$file"
    rm -f "$tmp"
    fw_changed=1
}

# fw_del zones|policies NAME
fw_del() {
    local file="/etc/firewalld/$1/$2.xml"
    ${SUDO:-} test -e "$file" || return 0
    say "Removing $file"
    run ${SUDO:-} rm -f -- "$file"
    fw_changed=1
}

# Load what fw_put and fw_del wrote. A firewalld that is not running reads it at its
# next start.
fw_commit() {
    if [ "$fw_changed" = 1 ] && fw_active; then
        run ${SUDO:-} firewall-cmd --reload >/dev/null
    fi
    fw_changed=0
}

# fw_guest_zone ZONE IFACE DESCRIPTION: a zone for guest bridges matching IFACE (a
# trailing + is a wildcard). Guests get DHCP and DNS from the host and nothing else of
# it, and forwarding in and out, which the bridge's own ACLs may narrow.
fw_guest_zone() {
    fw_put zones "$1" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<zone>
  <short>$1</short>
  <description>$3</description>
  <interface name="$2"/>
  <service name="dhcp"/>
  <service name="dhcpv6"/>
  <service name="dns"/>
</zone>
EOF
    fw_put policies "$1-out" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<policy target="ACCEPT">
  <short>$1-out</short>
  <description>Forwarding out of $1.</description>
  <ingress-zone name="$1"/>
  <egress-zone name="ANY"/>
</policy>
EOF
    fw_put policies "$1-in" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<policy target="ACCEPT">
  <short>$1-in</short>
  <description>Forwarding into $1.</description>
  <ingress-zone name="ANY"/>
  <egress-zone name="$1"/>
</policy>
EOF
}

# fw_guest_zone_remove ZONE
fw_guest_zone_remove() {
    fw_del policies "$1-in"
    fw_del policies "$1-out"
    fw_del zones "$1"
}
