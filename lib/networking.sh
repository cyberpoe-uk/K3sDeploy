#!/usr/bin/env bash
detect_interface(){ ip -4 route show default 2>/dev/null | awk 'NR==1{print $5}'; }
detect_node_ip(){ local dev=${1:-$(detect_interface)}; ip -4 -o addr show dev "$dev" scope global 2>/dev/null | awk 'NR==1{sub(/\/.*/,"",$4);print $4}'; }
port_reachable(){ timeout 3 bash -c "</dev/tcp/$1/$2" 2>/dev/null; }
local_ipv4_present(){ ip -4 -o addr show scope global | awk '{sub(/\/.*/,"",$4); print $4}' | grep -Fxq "$1"; }
vip_conflict_check(){ local vip=$1 iface=$2; if command -v arping >/dev/null; then if arping -D -c 2 -I "$iface" "$vip" >/dev/null 2>&1; then ok "VIP $vip is currently unclaimed"; else warn "VIP $vip responds on $iface (expected for an existing cluster; investigate for a new cluster)"; fi; else warn "arping unavailable; could not test address ownership"; fi; }
