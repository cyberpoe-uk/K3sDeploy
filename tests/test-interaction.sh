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

configure_advanced_profile <<< $'3\ny\n4'
assert_eq "$INSTALL_PROFILE" advanced
assert_eq "$LOAD_BALANCER_MODE" external
assert_eq "$STORAGE_PROVIDER" external
prepare_storage_choice
assert_eq "$STORAGE_MODE" external

LOAD_BALANCER_MODE=metallb
STORAGE_PROVIDER=longhorn
configure_advanced_profile <<< $'1\n3\nDECLINE\n3\nACCEPT-NON-HA-STORAGE'
assert_eq "$STORAGE_PROVIDER" local-path

port_reachable(){ return 0; }
collect_nfs_config <<< $'10.10.20.40\n/mnt/pool/k3s\ny'
assert_eq "$NFS_SERVER" 10.10.20.40
assert_eq "$NFS_EXPORT" /mnt/pool/k3s
nfs_class=$(render_nfs_storageclass)
assert_ok grep -q 'server: "10.10.20.40"' <<<"$nfs_class"
assert_ok grep -q 'share: "/mnt/pool/k3s"' <<<"$nfs_class"
assert_ok grep -q 'onDelete: retain' <<<"$nfs_class"

set_recommended_profile
assert_eq "$LOAD_BALANCER_MODE" metallb
assert_eq "$STORAGE_PROVIDER" longhorn
banner_output=$(show_banner)
assert_ok grep -q 'K3SDEPLOY.*K3sDeploy' <<<"$banner_output"

DESIRED_HOSTNAME=k3s-test
NODE_IP=10.10.10.101
API_VIP=10.10.10.105
TARGET_ROLE='control-plane + etcd + schedulable worker'
STORAGE_MODE=root
STORAGE_DESCRIPTION='test storage'
STORAGE_DEVICE='root filesystem'
POOL_START=10.10.10.110
POOL_END=10.10.10.115
plan_output=$(summary 'Create test cluster' "$POOL_START-$POOL_END")
assert_ok grep -q '^  MetalLB address pool: 10.10.10.110-10.10.10.115$' <<<"$plan_output"
assert_eq "$(grep -c '10.10.10.110' <<<"$plan_output")" 1

kubectl_local(){
  case "$*" in
    'get --raw=/readyz') return 0;;
    '-n metallb-system get deploy controller -o jsonpath={.status.availableReplicas}') printf '1';;
    '-n metallb-system get daemonset speaker -o jsonpath={.status.numberReady}') printf '1';;
    '-n metallb-system get ipaddresspool homelab-pool') return 1;;
    *) return 0;;
  esac
}
collect_metallb_pool(){ POOL_START=10.10.10.110; POOL_END=10.10.10.115; }
METALLB_REPAIRS=0
STATE_WRITES=0
install_metallb(){ ((++METALLB_REPAIRS)); }
persist_state(){ ((++STATE_WRITES)); }
NODE_ROLE=server
LOAD_BALANCER_MODE=metallb
STORAGE_PROVIDER=external
POOL_START=
POOL_END=
repair_managed_addons <<< ''
assert_eq "$METALLB_REPAIRS" 1
assert_eq "$STATE_WRITES" 1
assert_eq "$POOL_START-$POOL_END" 10.10.10.110-10.10.10.115

dispatch_action(){ return 23; }
assert_ok run_menu_action 1

# Optional clean-node probes must not fail a strict-mode installation workflow.
findmnt(){ return 1; }
as_root_capture(){ return 1; }
CONFIG_FILE=/tmp/k3sdeploy-test-no-config
assert_ok detect_existing

printf '%s passed, %s failed\n' "$pass" "$fail"
((fail == 0))
