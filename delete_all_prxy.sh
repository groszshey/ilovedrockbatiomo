#!/bin/bash
# delete_all_proxies.sh — wipe all SOCKS5 proxies managed by proxy-ctl
# Removes state, prefixes, IPv6 aliases on interface, and reloads 3proxy.

set -euo pipefail

STATE_DIR="/etc/3proxy"
STATE_FILE="$STATE_DIR/state.tsv"
PREFIX_FILE="$STATE_DIR/prefixes.txt"
IPV6_LIST="$STATE_DIR/ipv6-list.txt"
OUT_FILE="/root/socks5-ipv6/ipport.txt"

die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "$*"; }

[ "$(id -u)" -eq 0 ] || die "must run as root"

# 1. Confirm
if [ -s "$STATE_FILE" ]; then
  n=$(wc -l < "$STATE_FILE")
  info "About to delete $n proxy entries."
else
  info "No proxies in state. Will still clean prefixes and interface aliases."
fi

if [ "${1:-}" != "--yes" ] && [ "${1:-}" != "-y" ]; then
  read -rp "Type YES to confirm: " ans
  [ "$ans" = "YES" ] || die "aborted"
fi

# 2. Backup state
if [ -s "$STATE_FILE" ]; then
  bak="$STATE_FILE.bak.$(date +%s)"
  cp "$STATE_FILE" "$bak"
  info "Backed up state to $bak"
fi

# 3. Wipe state + prefix + output
: > "$STATE_FILE" 2>/dev/null || true
rm -f "$PREFIX_FILE" "$IPV6_LIST" "$OUT_FILE"
info "Cleared state, prefixes, ipv6-list, output."

# 4. Rebuild empty config + reload 3proxy
if command -v proxy-ctl >/dev/null 2>&1; then
  proxy-ctl rebuild >/dev/null
  info "3proxy reloaded with empty config."
else
  systemctl stop 3proxy 2>/dev/null || true
  info "proxy-ctl not found; stopped 3proxy."
fi

# 5. Remove all /128 IPv6 aliases from default interface
IFACE=$(ip -o -4 route show default | awk '{print $5; exit}')
[ -n "$IFACE" ] || die "no default interface detected"
removed=0
while read -r addr; do
  [ -z "$addr" ] && continue
  ip -6 addr del "$addr" dev "$IFACE" 2>/dev/null && removed=$((removed+1)) || true
done < <(ip -6 addr show dev "$IFACE" scope global | awk '/inet6/ {print $2}' | grep '/128')
info "Removed $removed /128 IPv6 aliases from $IFACE."

# 6. Show final status
info ""
info "=== Done ==="
if command -v proxy-ctl >/dev/null 2>&1; then
  proxy-ctl status
fi
