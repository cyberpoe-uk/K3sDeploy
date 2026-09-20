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

TOKEN_SHAPED_INPUT='K10examplehash::server:examplecredential'
token_output_file=$(mktemp -t k3sdeploy-token-address-XXXXXX)
prompt_ipv4 TEST_IP 'Token safety test' <<< "$TOKEN_SHAPED_INPUT
10.20.30.41" >"$token_output_file"
token_address_output=$(<"$token_output_file")
rm -f "$token_output_file"
assert_eq "$TEST_IP" 10.20.30.41
if grep -Fq "$TOKEN_SHAPED_INPUT" <<<"$token_address_output"; then
  printf 'FAIL token-shaped input was repeated in output\n'
  ((++fail))
else
  ((++pass))
fi
assert_ok grep -q 'rotate it' <<<"$token_address_output"

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

port_reachable(){ return 0; }
verify_existing_cluster_token(){ [[ $1 == server && $2 == test-server-token ]]; }
join_output_file=$(mktemp -t k3sdeploy-join-access-XXXXXX)
collect_join_access server <<< $'10.10.10.105\ntest-server-token' >"$join_output_file"
join_access_output=$(<"$join_output_file")
rm -f "$join_output_file"
assert_eq "$API_VIP" 10.10.10.105
assert_eq "$JOIN_TOKEN" test-server-token
endpoint_line=$(grep -n 'API endpoint' <<<"$join_access_output" | cut -d: -f1)
token_help_line=$(grep -n 'retrieve the server token' <<<"$join_access_output" | cut -d: -f1)
if [[ $endpoint_line =~ ^[0-9]+$ && $token_help_line =~ ^[0-9]+$ ]] && ((endpoint_line < token_help_line)); then
  ((++pass))
else
  printf 'FAIL token instructions appeared before API VIP verification\n'
  ((++fail))
fi

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
K3SDEPLOY_PLAIN_MENU=1
K3S_INSTALLED=yes
menu_output_file=$(mktemp -t k3sdeploy-main-menu-XXXXXX)
show_main_menu MENU_TEST_ACTION <<< '8' >"$menu_output_file"
menu_output=$(<"$menu_output_file")
rm -f "$menu_output_file"
assert_eq "$MENU_TEST_ACTION" 8
assert_ok grep -q 'Recover lost embedded-etcd quorum - disaster recovery' <<<"$menu_output"
assert_ok grep -q '^  8\. Exit$' <<<"$menu_output"
unset K3SDEPLOY_PLAIN_MENU

assert_ok confirm_etcd_recovery k3s-test <<< 'RESET ETCD TO k3s-test'
if confirm_etcd_recovery k3s-test <<< 'yes'; then
  printf 'FAIL ordinary yes bypassed exact etcd recovery confirmation\n'
  ((++fail))
else
  ((++pass))
fi

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
    'get namespace longhorn-system') return 0;;
    '-n longhorn-system get deployment longhorn-driver-deployer -o jsonpath={.spec.replicas}{"|"}{.status.availableReplicas}') printf '1|1';;
    '-n longhorn-system get deployment longhorn-ui -o jsonpath={.spec.replicas}{"|"}{.status.availableReplicas}') printf '2|2';;
    '-n longhorn-system get daemonset longhorn-manager -o jsonpath={.status.desiredNumberScheduled}{"|"}{.status.numberReady}') printf '1|1';;
    *) return 1;;
  esac
}
assert_ok longhorn_installation_ready

kubectl_local(){
  case "$*" in
    'get --raw=/readyz') return 0;;
    '-n metallb-system get deploy controller -o jsonpath={.status.availableReplicas}') printf '1';;
    '-n metallb-system get daemonset speaker -o jsonpath={.status.numberReady}') printf '1';;
    '-n metallb-system get ipaddresspool homelab-pool') return 1;;
    *) return 0;;
  esac
}
kube_vip_ready(){ return 0; }
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

SMOKE_LOG=$(mktemp -t k3sdeploy-smoke-test-XXXXXX)
kubectl_local(){
  printf 'ARGS %s\n' "$*" >>"$SMOKE_LOG"
  if [[ $* == *'apply -f -' ]]; then cat >>"$SMOKE_LOG"; fi
  return 0
}
assert_ok run_longhorn_smoke
assert_ok grep -q '^reclaimPolicy: Delete$' "$SMOKE_LOG"
assert_ok grep -q '^  numberOfReplicas: "1"$' "$SMOKE_LOG"
assert_ok grep -q 'delete namespace k3sdeploy-smoke-' "$SMOKE_LOG"
assert_ok grep -q 'name: k3sdeploy-longhorn-smoke-status' "$SMOKE_LOG"
rm -f "$SMOKE_LOG"

kubectl_local(){
  printf '%s\n' \
    'manager-1|True|True|true' \
    'manager-2|True|True|true' \
    'worker-1|True|False|true' \
    'worker-2|False|True|true' \
    'worker-3|True|True|false'
}
assert_eq "$(longhorn_storage_node_count)" 2

WAITED_ADDONS=
wait_kube_vip(){ WAITED_ADDONS+=vip,; }
wait_metallb_ready(){ WAITED_ADDONS+=metallb,; }
wait_longhorn_ready_on_node(){ WAITED_ADDONS+=longhorn; }
LOAD_BALANCER_MODE=metallb
STORAGE_PROVIDER=longhorn
DRY_RUN=false
wait_for_joined_node_addons true
assert_eq "$WAITED_ADDONS" vip,metallb,longhorn

VALIDATION_FAILURES=0
assert_ok require_healthy_installation
if (VALIDATION_FAILURES=1; require_healthy_installation); then
  printf 'FAIL unhealthy installation was reported as successful\n'
  ((++fail))
else
  ((++pass))
fi

lost_etcd_quorum_detected(){ return 0; }
recovery_offer_output_file=$(mktemp -t k3sdeploy-recovery-offer-XXXXXX)
if offer_etcd_quorum_recovery <<< 'n' >"$recovery_offer_output_file"; then
  printf 'FAIL declined quorum recovery offer returned success\n'
  ((++fail))
else
  ((++pass))
fi
recovery_offer_output=$(<"$recovery_offer_output_file")
rm -f "$recovery_offer_output_file"
assert_ok grep -q 'option 7' <<<"$recovery_offer_output"
assert_ok grep -q 'Validation made no system or cluster changes' <<<"$recovery_offer_output"
assert_ok offer_etcd_quorum_recovery <<< ''

ACTION_LOG_FILE=$(mktemp -t k3sdeploy-action-transition-XXXXXX)
dispatch_action(){
  printf '%s,' "$1" >>"$ACTION_LOG_FILE"
  [[ $1 == 5 ]] && return "$ETCD_RECOVERY_TRANSITION_RC"
  return 0
}
assert_ok run_menu_action 5
assert_eq "$(<"$ACTION_LOG_FILE")" '5,7,'
rm -f "$ACTION_LOG_FILE"
assert_ok test "$LAST_WORKFLOW_SUCCEEDED" = true

dispatch_action(){ return 23; }
assert_ok run_menu_action 1
assert_ok test "$LAST_WORKFLOW_SUCCEEDED" = false
dispatch_action(){ return 0; }
assert_ok run_menu_action 5
assert_ok test "$LAST_WORKFLOW_SUCCEEDED" = true

# Optional clean-node probes must not fail a strict-mode installation workflow.
findmnt(){ return 1; }
as_root_capture(){ return 1; }
CONFIG_FILE=/tmp/k3sdeploy-test-no-config
assert_ok detect_existing

printf '%s passed, %s failed\n' "$pass" "$fail"
((fail == 0))
