#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
source "$ROOT/lib/common.sh"
pass=0; fail=0
assert_ok(){ if "$@"; then ((++pass)); else echo "FAIL expected success: $*"; ((++fail)); fi; }
assert_bad(){ if "$@"; then echo "FAIL expected failure: $*"; ((++fail)); else ((++pass)); fi; }
assert_eq(){ if [[ $1 == "$2" ]]; then ((++pass)); else echo "FAIL '$1' != '$2'"; ((++fail)); fi; }
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
OS_PACKAGE_MANAGER=apt
assert_ok confirm_yes <<< ''
assert_ok confirm_yes <<< 'yes'
assert_bad confirm_yes <<< 'n'
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
agent_rendered=$(render_k3s_config agent 'agent-secret-token')
assert_ok grep -q '^server: https://10.10.20.10:6443$' <<<"$agent_rendered"
assert_ok grep -q '^token: "agent-secret-token"$' <<<"$agent_rendered"
assert_bad grep -q '^advertise-address:' <<<"$agent_rendered"
assert_bad grep -q '^disable:' <<<"$agent_rendered"
source "$ROOT/config/defaults.env"
source "$ROOT/lib/storage.sh"
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
parted_sample='BYT;
/dev/sda:536870912000B:scsi:512:4096:gpt:Example Disk:;
:17408B:1048575B:1031168B:free;
1:1048576B:107375230975B:107374182400B:ext4::;
:107375230976B:536869863423B:429494632448B:free;'
assert_eq "$(printf '%s\n' "$parted_sample" | parse_largest_free_region)" '107375230976 536869863423 429494632448'
# shellcheck source=../lib/validation.sh
source "$ROOT/lib/validation.sh"
k3s_local_installation_present(){ return 1; }
fresh_report=$(validate_cluster)
assert_ok grep -Eq '^K3s service[[:space:]]+MISSING' <<<"$fresh_report"
assert_ok grep -Eq '^Longhorn[[:space:]]+MISSING' <<<"$fresh_report"
assert_bad grep -Eq '^K3s service[[:space:]]+FAIL' <<<"$fresh_report"
repair_report=$(safe_repair)
assert_ok grep -q 'There is nothing to repair on this clean node' <<<"$repair_report"
assert_bad grep -q 'Start inactive' <<<"$repair_report"
echo "$pass passed, $fail failed"
((fail==0))
