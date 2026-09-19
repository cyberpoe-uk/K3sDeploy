#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../k3s-bootstrap.sh
source "$ROOT/k3s-bootstrap.sh"

pass=0
fail=0
assert_ok(){ if "$@"; then ((++pass)); else printf 'FAIL expected success: %s\n' "$*"; ((++fail)); fi; }
assert_eq(){ if [[ $1 == "$2" ]]; then ((++pass)); else printf "FAIL '%s' != '%s'\n" "$1" "$2"; ((++fail)); fi; }

TEST_IP=
prompt_ipv4 TEST_IP 'Test address' <<< $'not-an-ip\n10.20.30.40'
assert_eq "$TEST_IP" 10.20.30.40

TEST_HOSTNAME=
prompt_hostname TEST_HOSTNAME 'Test hostname' <<< $'bad_name\nNode-Three'
assert_eq "$TEST_HOSTNAME" node-three

ensure_arping(){ return 0; }
VIP_CHECKS=0
vip_conflict_check(){
  ((++VIP_CHECKS))
  if ((VIP_CHECKS == 1)); then VIP_CHECK_RESULT=occupied; return 1; fi
  VIP_CHECK_RESULT=free
  return 0
}
NODE_IP=10.10.10.101
PRIMARY_IFACE=ens18
API_VIP=
collect_new_cluster_vip <<< $'10.10.10.100\n10.10.10.105\n'
assert_eq "$API_VIP" 10.10.10.105
assert_eq "$VIP_CHECKS" 2

dispatch_action(){ return 23; }
assert_ok run_menu_action 1

printf '%s passed, %s failed\n' "$pass" "$fail"
((fail == 0))
