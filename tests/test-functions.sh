#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
source "$ROOT/lib/common.sh"
# shellcheck source=../lib/preflight.sh
source "$ROOT/lib/preflight.sh"
pass=0; fail=0
assert_ok(){ if "$@"; then ((++pass)); else echo "FAIL expected success: $*"; ((++fail)); fi; }
assert_bad(){ if "$@"; then echo "FAIL expected failure: $*"; ((++fail)); else ((++pass)); fi; }
assert_eq(){ if [[ $1 == "$2" ]]; then ((++pass)); else echo "FAIL '$1' != '$2'"; ((++fail)); fi; }
installer_version=$VERSION
OS_RELEASE_FILE="$ROOT/tests/fixtures/os-release" detect_operating_system
assert_eq "$OS_NAME" 'Example Linux 24.04 LTS'
assert_eq "$OS_ID" example
assert_eq "$OS_ID_LIKE" 'debian test'
assert_eq "$OS_VERSION_ID" 24.04
assert_eq "$VERSION" "$installer_version"
assert_ok validate_ipv4 10.10.20.13
assert_ok validate_ipv4 0.0.0.0
assert_bad validate_ipv4 256.1.1.1
assert_bad validate_ipv4 10.1.2
assert_bad validate_ipv4 01.2.3.4
OS_PACKAGE_MANAGER=apt
assert_eq "$(package_for arping)" iputils-arping
assert_eq "$(package_for iscsi)" open-iscsi
OS_PACKAGE_MANAGER=dnf
assert_eq "$(package_for arping)" iputils
assert_eq "$(package_for iscsi)" iscsi-initiator-utils
assert_eq "$(package_for nfs)" nfs-utils
OS_PACKAGE_MANAGER=apt
assert_eq "$(package_for nfs)" nfs-common
OS_PACKAGE_MANAGER=zypper
assert_eq "$(package_for nfs)" nfs-client
OS_PACKAGE_MANAGER=apt
assert_ok confirm_yes <<< ''
assert_ok confirm_yes <<< 'yes'
assert_bad confirm_yes <<< 'n'
assert_eq "$(K3SDEPLOY_STDOUT_IS_TTY=true TERM=xterm-256color NO_COLOR= K3SDEPLOY_FORCE_COLOR=false colour '1;33')" $'\033[1;33m'
assert_eq "$(K3SDEPLOY_STDOUT_IS_TTY=true TERM=xterm-256color NO_COLOR=1 K3SDEPLOY_FORCE_COLOR=false colour '1;33')" ''
assert_eq "$(K3SDEPLOY_STDOUT_IS_TTY=true TERM=xterm-256color NO_COLOR=1 K3SDEPLOY_FORCE_COLOR=true colour '1;33')" $'\033[1;33m'
MENU_TEST=
menu_select MENU_TEST 'Test menu' 2 'First choice' 'Second choice' 'Third choice' <<< ''
assert_eq "$MENU_TEST" 2
menu_select MENU_TEST 'Test menu' 1 'First choice' 'Second choice' 'Third choice' <<< '3'
assert_eq "$MENU_TEST" 3
menu_select MENU_TEST 'Disabled menu test' 1 "${MENU_DISABLED_PREFIX}Unavailable choice [Unavailable - test reason]" 'Enabled choice' <<< ''
assert_eq "$MENU_TEST" 2
menu_select MENU_TEST 'Disabled selection test' 2 "${MENU_DISABLED_PREFIX}Unavailable choice [Unavailable - test reason]" 'Enabled choice' <<< $'1\n2'
assert_eq "$MENU_TEST" 2
disabled_render=$(render_menu_options 2 "${MENU_DISABLED_PREFIX}Unavailable choice [Unavailable - test reason]" 'Enabled choice')
assert_ok grep -q '\[Unavailable - test reason\]' <<<"$disabled_render"
assert_bad grep -q "$MENU_DISABLED_PREFIX" <<<"$disabled_render"
selected=
menu_select selected 'Shadow-safe menu' 1 'First choice' 'Second choice' <<< '2'
assert_eq "$selected" 2
assert_ok ip_in_range 10.0.0.10 10.0.0.1 10.0.0.20
assert_bad ip_in_range 10.0.0.21 10.0.0.1 10.0.0.20
assert_ok same_subnet 10.10.20.10 10.10.20.13 24
assert_bad same_subnet 10.10.20.10 10.10.21.13 24
assert_eq "$(ip_to_int 0.0.0.1)" 1
NODE_IP=10.10.20.13 API_VIP=10.10.20.10
source "$ROOT/lib/k3s.sh"
rendered=$(render_k3s_config join 'secret-test-token')
assert_ok grep -q '^server: https://10.10.20.10:6443$' <<<"$rendered"
assert_ok grep -q '^token: "secret-test-token"$' <<<"$rendered"
assert_ok grep -q '^  - servicelb$' <<<"$rendered"
assert_ok grep -q '^  - local-storage$' <<<"$rendered"
assert_ok grep -q '^etcd-snapshot-compress: true$' <<<"$rendered"
assert_ok grep -q '^etcd-snapshot-retention: 5$' <<<"$rendered"
assert_ok grep -q '^etcd-snapshot-schedule-cron: "0 \*/12 \* \* \*"$' <<<"$rendered"
ETCD_SNAPSHOT_POLICY=external
external_snapshot_rendered=$(render_k3s_config join 'secret-test-token')
assert_ok grep -q '^etcd-disable-snapshots: true$' <<<"$external_snapshot_rendered"
assert_bad grep -q '^etcd-snapshot-' <<<"$external_snapshot_rendered"
ETCD_SNAPSHOT_POLICY=managed
LOAD_BALANCER_MODE=servicelb STORAGE_PROVIDER=local-path
servicelb_rendered=$(render_k3s_config first)
assert_bad grep -q '^disable:$' <<<"$servicelb_rendered"
assert_bad grep -q '^  - servicelb$' <<<"$servicelb_rendered"
assert_bad grep -q '^  - local-storage$' <<<"$servicelb_rendered"
LOAD_BALANCER_MODE=external STORAGE_PROVIDER=external
external_rendered=$(render_k3s_config first)
assert_ok grep -q '^  - servicelb$' <<<"$external_rendered"
assert_ok grep -q '^  - local-storage$' <<<"$external_rendered"
LOAD_BALANCER_MODE=metallb STORAGE_PROVIDER=nfs
nfs_rendered=$(render_k3s_config first)
assert_ok grep -q '^  - local-storage$' <<<"$nfs_rendered"
LOAD_BALANCER_MODE=metallb STORAGE_PROVIDER=longhorn
agent_rendered=$(render_k3s_config agent 'agent-secret-token')
assert_ok grep -q '^server: https://10.10.20.10:6443$' <<<"$agent_rendered"
assert_ok grep -q '^token: "agent-secret-token"$' <<<"$agent_rendered"
assert_bad grep -q '^advertise-address:' <<<"$agent_rendered"
assert_bad grep -q '^disable:' <<<"$agent_rendered"
assert_bad grep -q '^etcd-snapshot-' <<<"$agent_rendered"
assert_bad grep -q '^etcd-disable-snapshots:' <<<"$agent_rendered"
# shellcheck source=../lib/etcd-snapshot.sh
source "$ROOT/lib/etcd-snapshot.sh"
snapshot_config_sample='data-dir: "/srv/k3s-data"
etcd-snapshot-dir: '\''/srv/k3s-snapshots'\'' # protected snapshots'
assert_eq "$(parse_k3s_yaml_scalar data-dir <<<"$snapshot_config_sample")" /srv/k3s-data
assert_eq "$(parse_k3s_yaml_scalar etcd-snapshot-dir <<<"$snapshot_config_sample")" /srv/k3s-snapshots
assert_eq "$(milestone_snapshot_name manager-joined 2026-09-21-012345)" 'k3sdeploy-manager-joined-2026-09-21-012345'
snapshot_save_command=$(
  as_root(){ printf '%s\n' "$*"; }
  ETCD_SNAPSHOT_COMPRESS=true run_etcd_snapshot_save /srv/k3s-data /srv/k3s-snapshots k3sdeploy-manager-joined-2026-09-21-012345
)
assert_ok grep -Fq -- 'k3s etcd-snapshot save --config /dev/null --data-dir /srv/k3s-data --dir /srv/k3s-snapshots --name k3sdeploy-manager-joined-2026-09-21-012345 --snapshot-compress' <<<"$snapshot_save_command"
snapshot_prune_command=$(
  as_root(){ printf '%s\n' "$*"; }
  run_etcd_snapshot_prune /srv/k3s-data /srv/k3s-snapshots k3sdeploy-manager-joined 1
)
assert_ok grep -Fq -- 'k3s etcd-snapshot prune --config /dev/null --data-dir /srv/k3s-data --dir /srv/k3s-snapshots --name k3sdeploy-manager-joined --snapshot-retention 1' <<<"$snapshot_prune_command"
assert_bad grep -Fq -- '/etc/rancher/k3s/config.yaml' <<<"$snapshot_prune_command"
VIRTUALIZATION_TYPE=none
assert_bad virtual_machine_detected
VIRTUALIZATION_TYPE=kvm
assert_ok virtual_machine_detected
VIRTUALIZATION_TYPE=none
# shellcheck source=../lib/etcd-recovery.sh
source "$ROOT/lib/etcd-recovery.sh"
quorum_sample='Sep 20 k3s-demo1 k3s[43591]: {"level":"warn","msg":"failed to publish local member to cluster through raft","error":"context deadline exceeded"}'
assert_ok etcd_quorum_log_evidence <<<"$quorum_sample"
assert_ok etcd_quorum_log_evidence <<< 'Failed to check local etcd status for learner management: context deadline exceeded'
assert_bad etcd_quorum_log_evidence <<< 'K3s API server started successfully'
recovery_config=$(render_single_member_recovery_config <<'EOF'
server: https://10.10.10.105:6443
token: "secret-test-token"
cluster-init: false
node-ip: 10.10.10.101
advertise-address: 10.10.10.101
tls-san:
  - 10.10.10.105
disable:
  - servicelb
  - local-storage
EOF
)
assert_eq "$(grep -c '^cluster-init: true$' <<<"$recovery_config")" 1
assert_bad grep -Eq '^(server|token):' <<<"$recovery_config"
assert_ok grep -q '^node-ip: 10.10.10.101$' <<<"$recovery_config"
assert_ok grep -q '^  - 10.10.10.105$' <<<"$recovery_config"
assert_ok grep -q '^  - local-storage$' <<<"$recovery_config"
assert_ok etcd_recovery_backup_space_sufficient 104857600 209715200
assert_bad etcd_recovery_backup_space_sufficient 104857601 209715200
source "$ROOT/config/defaults.env"
source "$ROOT/lib/storage.sh"
source "$ROOT/lib/longhorn.sh"
VIRTUALIZATION_TYPE=kvm
assert_ok grep -q 'kvm virtual disk' <<<"$(show_virtual_disk_capacity_note 161)"
virtual_guidance=$(show_additional_storage_guidance)
assert_ok grep -q 'kvm virtual machine' <<<"$virtual_guidance"
assert_bad grep -q 'Physical machine' <<<"$virtual_guidance"
VIRTUALIZATION_TYPE=none
assert_eq "$(show_virtual_disk_capacity_note 161)" ''
physical_guidance=$(show_additional_storage_guidance)
assert_ok grep -q 'Physical machine' <<<"$physical_guidance"
assert_bad grep -q 'hypervisor or cloud' <<<"$physical_guidance"
assert_ok replica_counts_ready 1 1
assert_ok replica_counts_ready 2 2
assert_ok replica_counts_ready 1 2
assert_bad replica_counts_ready 2 1
assert_bad replica_counts_ready 0 0
assert_bad replica_counts_ready missing 2
assert_eq "$(gib_from_bytes 107374182400)" 100
assert_ok capacity_meets_minimum 120 120
assert_ok capacity_meets_minimum 121 120
assert_bad capacity_meets_minimum 119 120
assert_eq "$(partition_path /dev/sda 3)" /dev/sda3
assert_eq "$(partition_path /dev/nvme0n1 3)" /dev/nvme0n1p3
assert_eq "$(printf '%s\n' '/dev/dm-0 lvm' '└─/dev/sda3 part' '  └─/dev/sda disk' | parse_physical_disks)" /dev/sda
assert_eq "$(printf '  ubuntu-vg | /dev/dm-0  \n' | parse_root_lvm_vg /dev/dm-0)" ubuntu-vg
assert_bad parse_root_lvm_vg /dev/dm-0 <<< 'other-vg|/dev/dm-1'
assert_eq "$(printf '  <64424509440.00\n' | parse_lvm_bytes)" 64424509440
root_capacity_gib(){ printf '57\n'; }
root_available_gib(){ printf '47\n'; }
block_capacity_gib(){ printf '220\n'; }
headroom_output=$(check_os_headroom /dev/test <<< 'y' 2>&1)
assert_ok grep -q 'Root currently has 47 GiB available' <<<"$headroom_output"
assert_ok grep -q 'recommends at least 66 GiB for root' <<<"$headroom_output"
assert_ok grep -q 'K3s images, logs, package updates, and temporary files still use it' <<<"$headroom_output"
assert_ok grep -Fq 'confirm "Continue and leave root at ${root_gib} GiB?"' "$ROOT/lib/storage.sh"
assert_bad check_os_headroom /dev/test <<< 'n' >/dev/null 2>&1
LONGHORN_NODE_TEST_STATUS='True|True|true'
kubectl_local(){
  case "$*" in
    '-n longhorn-system get nodes.longhorn.io k3s-test -o jsonpath='*) printf '%s' "$LONGHORN_NODE_TEST_STATUS";;
    *) return 1;;
  esac
}
assert_ok longhorn_node_ready k3s-test
LONGHORN_NODE_TEST_STATUS='True|False|true'
assert_bad longhorn_node_ready k3s-test
parted_sample='BYT;
/dev/sda:536870912000B:scsi:512:4096:gpt:Example Disk:;
:17408B:1048575B:1031168B:free;
1:1048576B:107375230975B:107374182400B:ext4::;
:107375230976B:536869863423B:429494632448B:free;'
assert_eq "$(printf '%s\n' "$parted_sample" | parse_largest_free_region)" '107375230976 536869863423 429494632448'
# shellcheck source=../lib/validation.sh
source "$ROOT/lib/validation.sh"
report 'Counter test' FAIL >/dev/null
report 'Counter warning' WARN >/dev/null
report 'Counter untested' 'NOT TESTED' >/dev/null
report 'Counter missing' MISSING >/dev/null
assert_eq "$VALIDATION_FAILURES" 1
assert_eq "$VALIDATION_WARNINGS" 1
assert_eq "$VALIDATION_NOT_TESTED" 1
assert_ok grep -q 'name: address' "$ROOT/templates/kube-vip/kube-vip.yaml"
assert_ok grep -q 'name: vip_subnet' "$ROOT/templates/kube-vip/kube-vip.yaml"
assert_bad grep -q 'name: vip_cidr' "$ROOT/templates/kube-vip/kube-vip.yaml"
assert_bad grep -q 'name: vip_address' "$ROOT/templates/kube-vip/kube-vip.yaml"
assert_bad grep -q '/proc/sys/net' "$ROOT/templates/kube-vip/kube-vip.yaml"
assert_bad grep -q 'proc-net' "$ROOT/templates/kube-vip/kube-vip.yaml"
source "$ROOT/lib/kube-vip.sh"
assert_ok kube_vip_failure_is_terminal CrashLoopBackOff StartError 1
assert_ok kube_vip_failure_is_terminal CreateContainerConfigError '' 0
assert_bad kube_vip_failure_is_terminal CrashLoopBackOff Error 4
assert_ok kube_vip_failure_is_terminal CrashLoopBackOff Error 5
k3s_local_installation_present(){ return 1; }
fresh_report=$(validate_cluster)
assert_ok grep -Eq '^K3s service[[:space:]]+MISSING' <<<"$fresh_report"
assert_ok grep -Eq '^Longhorn[[:space:]]+MISSING' <<<"$fresh_report"
assert_bad grep -Eq '^K3s service[[:space:]]+FAIL' <<<"$fresh_report"
STORAGE_PROVIDER=external LOAD_BALANCER_MODE=external
external_report=$(validate_cluster)
assert_ok grep -Eq '^Longhorn[[:space:]]+SKIP' <<<"$external_report"
assert_ok grep -Eq '^Persistent storage[[:space:]]+SKIP' <<<"$external_report"
STORAGE_PROVIDER=longhorn LOAD_BALANCER_MODE=metallb
repair_report=$(safe_repair)
assert_ok grep -q 'There is nothing to repair on this clean node' <<<"$repair_report"
assert_bad grep -q 'Start inactive' <<<"$repair_report"
echo "$pass passed, $fail failed"
((fail==0))
