#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=config/versions.env
source "$SCRIPT_DIR/config/versions.env"
# shellcheck source=config/defaults.env
source "$SCRIPT_DIR/config/defaults.env"
# shellcheck source=lib/networking.sh
source "$SCRIPT_DIR/lib/networking.sh"
# shellcheck source=lib/preflight.sh
source "$SCRIPT_DIR/lib/preflight.sh"
# shellcheck source=lib/k3s.sh
source "$SCRIPT_DIR/lib/k3s.sh"
# shellcheck source=lib/kube-vip.sh
source "$SCRIPT_DIR/lib/kube-vip.sh"
# shellcheck source=lib/metallb.sh
source "$SCRIPT_DIR/lib/metallb.sh"
# shellcheck source=lib/storage.sh
source "$SCRIPT_DIR/lib/storage.sh"
# shellcheck source=lib/longhorn.sh
source "$SCRIPT_DIR/lib/longhorn.sh"
# shellcheck source=lib/updates.sh
source "$SCRIPT_DIR/lib/updates.sh"
# shellcheck source=lib/validation.sh
source "$SCRIPT_DIR/lib/validation.sh"
trap 'on_error $LINENO' ERR
trap cleanup_join_check EXIT

usage(){ cat <<EOF
K3sDeploy Installer $VERSION
Usage: ./k3s-bootstrap.sh [--dry-run] [--verbose] [--yes] [--help] [--version]

Interactive modes: create first manager, join manager, join worker, promote worker, validate, safe repair.
--dry-run  Show intended host changes (cluster queries may still be read-only)
--verbose  Show commands as they run (secret-bearing commands remain redacted)
--yes      Accept ordinary confirmations; never bypasses exact disk confirmation
EOF
}
parse_args(){ while (($#)); do case $1 in --dry-run) DRY_RUN=true;; --verbose) VERBOSE=true;; --yes) ASSUME_YES=true;; --help|-h) usage; exit;; --version) echo "$VERSION"; exit;; *) die "Unknown option: $1";; esac; shift; done; }
valid_ip_or_die(){ validate_ipv4 "$2" || die "$1 is not a valid IPv4 address: $2"; }
valid_hostname_or_die(){ [[ ${#1} -le 253 && $1 =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ && $1 != *..* ]] || die "Invalid hostname '$1'. Use lowercase letters, numbers, dots or hyphens."; }
prompt_ipv4(){
  local var=$1 prompt=$2 value
  while true; do
    read -r -p "$prompt: " value
    if [[ -z $value ]]; then warn "$prompt cannot be empty; please try again."; continue; fi
    if validate_ipv4 "$value"; then printf -v "$var" '%s' "$value"; return; fi
    warn "'$value' is not a valid IPv4 address; please try again."
  done
}
prompt_hostname(){
  local var=$1 prompt=$2 value
  while true; do
    read -r -p "$prompt: " value
    if [[ -z $value ]]; then warn "$prompt cannot be empty; please try again."; continue; fi
    value=${value,,}
    if [[ ${#value} -le 253 && $value =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ && $value != *..* ]]; then printf -v "$var" '%s' "$value"; return; fi
    warn "'$value' is not valid. Use lowercase letters, numbers, dots or hyphens; please try again."
  done
}
collect_local_identity(){
  local current_hostname
  current_hostname=$(short_hostname); current_hostname=${current_hostname,,}
  printf '\nDetected hostname: %s\n' "$current_hostname"
  if confirm_yes "Keep hostname '$current_hostname'?"; then
    DESIRED_HOSTNAME=$current_hostname
  else
    prompt_hostname DESIRED_HOSTNAME 'Enter a unique lowercase hostname for this node'
  fi
  if ! [[ ${#DESIRED_HOSTNAME} -le 253 && $DESIRED_HOSTNAME =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ && $DESIRED_HOSTNAME != *..* ]]; then
    warn "The detected hostname '$DESIRED_HOSTNAME' is not valid for K3s. Choose a replacement."
    prompt_hostname DESIRED_HOSTNAME 'Enter a unique lowercase hostname for this node'
  fi

  [[ -n $DETECTED_IP ]] || die 'No primary IPv4 address was detected. Configure networking, then rerun K3sDeploy.'
  printf '\nDetected node address: %s on interface %s\n' "$DETECTED_IP" "${PRIMARY_IFACE:-unknown}"
  info 'Every cluster node needs a stable address, normally provided by a DHCP reservation or static network configuration.'
  if ! confirm_yes "Use $DETECTED_IP as this node's permanent cluster address?"; then
    die 'Configure the desired static address or DHCP reservation, restart networking (or reboot), and rerun K3sDeploy.'
  fi
  NODE_IP=$DETECTED_IP
  valid_ip_or_die 'Node IP' "$NODE_IP"
}

collect_new_cluster_vip(){
  printf '\nKubernetes API virtual IP (VIP)\n'
  printf '%s\n' \
    'This is one unused address that will always lead to the active managers.' \
    'Choose it from the same Layer-2 network/VLAN as the manager addresses.' \
    'Reserve it outside DHCP. Do not assign it to a VM, router, or other device.' \
    'Example only: if this node is 192.168.10.21/24, an unused reserved address such as 192.168.10.20 could be suitable.'
  ensure_arping || true
  while true; do
    prompt_ipv4 API_VIP 'Enter the unused API VIP for this new cluster'
    if [[ $NODE_IP == "$API_VIP" ]]; then
      warn 'Node IP and API VIP must differ; enter another address.'
      continue
    fi
    if ! same_subnet "$NODE_IP" "$API_VIP" 24; then
      warn 'VIP and node IP do not share a /24. Most kube-vip ARP networks require the same Layer-2 network.'
      confirm 'Use this different-subnet VIP anyway?' || { info 'Enter another VIP on the manager network.'; continue; }
    fi
    if ! vip_conflict_check "$API_VIP" "$PRIMARY_IFACE"; then
      if [[ $VIP_CHECK_RESULT == occupied ]]; then
        warn "$API_VIP answered a network ownership probe and will not be used. Enter another VIP."
        continue
      fi
      confirm "Continue even though the automated checks could not confirm that $API_VIP is unused?" || { info 'Enter another reserved VIP.'; continue; }
    fi
    confirm_yes "I confirm $API_VIP is reserved and not assigned to another device" && return
    info 'Reserve the address or enter another VIP.'
  done
}

collect_join_access(){
  local role=$1 token_label
  printf '\nExisting cluster connection\n'
  printf '%s\n' \
    'Enter the exact Kubernetes API VIP created on the first manager.' \
    'Do not enter this new node address or the address of only one manager.' \
    'The installer will verify the existing cluster and token before asking about storage.'
  token_label='K3s join token from a healthy manager (input hidden)'
  if [[ $role == server ]]; then
    token_label='K3s SERVER token from /var/lib/rancher/k3s/server/token (input hidden)'
    info 'On a healthy manager, retrieve it with: sudo cat /var/lib/rancher/k3s/server/token'
  else
    info 'On a healthy manager, retrieve it with: sudo cat /var/lib/rancher/k3s/server/agent-token'
  fi
  while true; do
    prompt_ipv4 API_VIP 'Existing cluster API VIP'
    if ! port_reachable "$API_VIP" 6443; then
      warn "No K3s API answered at $API_VIP:6443. Check the existing VIP and network, then try again."
      continue
    fi
    printf '%s: ' "$token_label"
    read -rs JOIN_TOKEN
    echo
    if [[ -z $JOIN_TOKEN ]]; then warn 'Join token cannot be empty; please try again.'; continue; fi
    verify_existing_cluster_token "$role" "$JOIN_TOKEN" && return
    JOIN_TOKEN=
    warn 'Cluster verification failed. Re-enter the VIP and token.'
  done
}

check_identity_network(){
  [[ $NODE_IP != "$API_VIP" ]] || die 'Node IP and API VIP must differ'
  same_subnet "$NODE_IP" "$API_VIP" 24 || warn 'VIP and node IP do not share a /24. Verify that this node can reach the VIP and that kube-vip supports the network layout.'
}

collect_metallb_pool(){
  printf '\nMetalLB application address pool\n'
  printf '%s\n' \
    'Choose a range of unused addresses for applications exposed as LoadBalancer services.' \
    'The entire range must be reserved outside DHCP and must not contain any node address or the API VIP.'
  while true; do
    prompt_ipv4 POOL_START 'First MetalLB address'
    prompt_ipv4 POOL_END 'Last MetalLB address'
    if (( $(ip_to_int "$POOL_START") > $(ip_to_int "$POOL_END") )); then warn 'MetalLB range is reversed; enter the range again.'; continue; fi
    if ip_in_range "$API_VIP" "$POOL_START" "$POOL_END"; then warn 'API VIP overlaps the MetalLB pool; enter a different range.'; continue; fi
    if ip_in_range "$NODE_IP" "$POOL_START" "$POOL_END"; then warn 'Node IP overlaps the MetalLB pool; enter a different range.'; continue; fi
    confirm_yes 'I confirm this entire MetalLB range is unused and excluded from DHCP' && return
    info 'Reserve the complete range or enter a different range.'
  done
}
persist_state(){ local body; body=$(printf 'NODE_ROLE=%s\nNODE_IP=%s\nAPI_VIP=%s\nSTORAGE_MODE=%s\nSTORAGE_DEVICE=%s\nLONGHORN_PATH=%s\nLONGHORN_DEVICE_UUID=%s\nMETALLB_MODE=l2\n' "${NODE_ROLE:-server}" "$NODE_IP" "$API_VIP" "$STORAGE_MODE" "${STORAGE_DEVICE:-}" "$LONGHORN_PATH" "${LONGHORN_DEVICE_UUID:-}"); write_root_file "$STATE_FILE" 600 "$body" || true; }
set_hostname_if_needed(){ [[ $(short_hostname) == "$DESIRED_HOSTNAME" ]] && return; need_cmd hostnamectl; info "Changing this node hostname to $DESIRED_HOSTNAME as shown in the accepted plan"; as_root hostnamectl set-hostname "$DESIRED_HOSTNAME"; }
summary(){ cat <<EOF

K3sDeploy Installer $VERSION
  Action:           $1
  Hostname:         $DESIRED_HOSTNAME
  Node IP:          $NODE_IP
  API VIP:          $API_VIP
  Role:             ${TARGET_ROLE:-control-plane + etcd + worker}
  Longhorn:         $STORAGE_MODE ($LONGHORN_PATH)
  Storage source:   ${STORAGE_DEVICE:-root filesystem}
  Storage plan:     ${STORAGE_DESCRIPTION:-use existing configured storage}
  K3s ServiceLB:    disabled
  LoadBalancer:     $2
EOF
}
new_cluster(){ NODE_ROLE=server; TARGET_ROLE='control-plane + etcd + schedulable worker'; phase 1 8 'Collecting node, network and storage choices'; collect_local_identity; collect_new_cluster_vip; select_storage; collect_metallb_pool; LONGHORN_REPLICAS=1
  phase 2 8 'Reviewing preflight checks and planned changes'; summary 'Create new K3s cluster / first server' "$POOL_START-$POOL_END"; preflight_show; detect_existing; [[ $K3S_INSTALLED == no && ! -f $CONFIG_FILE ]] || die 'Existing K3s detected. Use validate/repair; refusing to initialize over it.'; [[ $LONGHORN_DATA_PRESENT == no ]] || die 'Existing Longhorn data was found. Refusing to initialize a new cluster over it.'; confirm Proceed? || { skip Cancelled; return; }; phase 3 8 'Preparing storage, hostname and protected installer state'; apply_storage_plan; set_hostname_if_needed; persist_state; phase 4 8 'Installing the pinned K3s first server'; install_k3s "$(render_k3s_config first)" server; wait_k3s; wait_local_node; phase 5 8 'Installing the kube-vip API virtual address'; install_kube_vip; phase 6 8 'Installing MetalLB for application addresses'; install_metallb; phase 7 8 'Installing Longhorn and host storage prerequisites'; install_longhorn; configure_updates_prompt; phase 8 8 'Running final health validation'; validate_cluster; }
join_cluster(){ NODE_ROLE=server; TARGET_ROLE='control-plane + etcd + schedulable worker'; phase 1 8 'Verifying cluster, then collecting manager choices'; collect_join_access server; collect_local_identity; check_identity_network; select_storage
  phase 2 8 'Checking the existing cluster and local node'; summary 'Join existing HA cluster' 'existing MetalLB cluster'; preflight_show; detect_existing; if [[ $K3S_INSTALLED == yes || -f $CONFIG_FILE ]]; then die 'Existing K3s/config detected. Use validate/repair; refusing to overwrite or rejoin.'; fi; [[ $LONGHORN_DATA_PRESENT == no ]] || die 'Existing Longhorn data was found. Refusing to join over it without manual recovery review.'; confirm Proceed? || { JOIN_TOKEN=; skip Cancelled; return; }; phase 3 8 'Preparing storage, hostname and protected installer state'; apply_storage_plan; set_hostname_if_needed; persist_state; phase 4 8 'Installing K3s and joining embedded etcd'; local cfg; cfg=$(render_k3s_config join "$JOIN_TOKEN"); install_k3s "$cfg" server; JOIN_TOKEN=; cfg=; phase 5 8 'Waiting for Ready, control-plane and etcd roles'; wait_k3s; wait_local_node; phase 6 8 'Checking kube-vip compatibility on this server'; check_kube_vip_interface || warn 'kube-vip requires operator attention'; phase 7 8 'Preparing storage and checking cluster-wide services'; ensure_iscsi; info 'Cluster-wide kube-vip, MetalLB, Traefik and Longhorn are inspected, not reinstalled.'; phase 8 8 'Running final health validation'; validate_cluster; }
join_agent(){ NODE_ROLE=agent; TARGET_ROLE='worker/agent (no control-plane or etcd)'; phase 1 7 'Verifying cluster, then collecting worker choices'; collect_join_access agent; collect_local_identity; check_identity_network; select_storage
  phase 2 7 'Checking the existing cluster and local node'; summary 'Join existing cluster as worker/agent' 'existing MetalLB cluster'; preflight_show; detect_existing; if [[ $K3S_INSTALLED == yes || -f $CONFIG_FILE ]]; then die 'Existing K3s/config detected. Use validate/repair; refusing to overwrite or rejoin.'; fi; [[ $LONGHORN_DATA_PRESENT == no ]] || die 'Existing Longhorn data was found. Refusing to join over it without manual recovery review.'; confirm Proceed? || { JOIN_TOKEN=; skip Cancelled; return; }; phase 3 7 'Preparing storage, hostname and protected installer state'; apply_storage_plan; set_hostname_if_needed; persist_state; phase 4 7 'Installing the pinned K3s agent'; local cfg; cfg=$(render_k3s_config agent "$JOIN_TOKEN"); install_k3s "$cfg" agent; JOIN_TOKEN=; cfg=; phase 5 7 'Waiting for the worker node to become Ready'; wait_agent_node; phase 6 7 'Preparing Longhorn host prerequisites'; ensure_iscsi; info 'Cluster-wide add-ons are not reinstalled on worker nodes.'; phase 7 7 'Running final health validation'; validate_cluster; }
promotion_backup(){ local stamp dir; stamp=$(date +%Y%m%d-%H%M%S); dir="/etc/k3s-bootstrap/promotion-backup-$stamp"; as_root install -d -m 700 "$dir"; for item in /etc/rancher/k3s/config.yaml /etc/rancher/node/password /etc/systemd/system/k3s-agent.service /etc/systemd/system/k3s-agent.service.env; do [[ -e $item ]] && as_root cp -a -- "$item" "$dir/"; done; info "Saved protected pre-promotion files in $dir"; }
promote_agent(){
  NODE_ROLE=${NODE_ROLE:-agent}; TARGET_ROLE='control-plane + etcd + schedulable worker'; phase 1 7 'Verifying that this machine is an existing worker'
  systemctl list-unit-files --no-legend k3s-agent.service 2>/dev/null | grep -q '^k3s-agent.service' || die 'This machine does not have a k3s-agent service; use the normal manager join option instead.'
  systemctl is-active --quiet k3s-agent || die 'k3s-agent is not active; repair the worker before attempting promotion.'
  systemctl is-active --quiet k3s && die 'k3s server is already active; this node is not a worker-only node.'
  DESIRED_HOSTNAME=$(short_hostname); NODE_IP=${NODE_IP:-$(awk '$1=="node-ip:"{print $2; exit}' "$CONFIG_FILE" 2>/dev/null || true)}
  [[ -n ${NODE_IP:-} ]] || prompt_default NODE_IP 'Node IPv4 address' "$DETECTED_IP"; valid_ip_or_die 'Node IP' "$NODE_IP"
  if [[ -z ${API_VIP:-} ]]; then
    info 'Enter the exact API VIP already used by this worker. Do not choose a new address.'
    prompt_required API_VIP 'Existing cluster API VIP'
  fi
  valid_ip_or_die 'API VIP' "$API_VIP"; port_reachable "$API_VIP" 6443 || die "API VIP $API_VIP:6443 is unreachable"
  phase 2 7 'Confirming cluster-side drain and node removal'
  warn 'Promotion briefly removes this machine from Kubernetes and reinstalls its local K3s role.'
  warn 'The official agent uninstaller removes local K3s state, kubelet state, emptyDir data, and local-path PV data.'
  warn 'Longhorn data under /var/lib/longhorn or the selected external path is not removed, but replication is not a backup.'
  printf '\nRun these from a healthy manager before continuing:\n\n  kubectl drain %q --ignore-daemonsets --delete-emptydir-data\n  kubectl delete node %q\n\n' "$DESIRED_HOSTNAME" "$DESIRED_HOSTNAME"
  printf 'If this replaces a failed manager, remove/decommission that failed member safely first. Confirm the remaining etcd cluster has quorum.\n'
  local cluster_confirmation; read -r -p 'Type DRAINED-AND-DELETED after completing those steps: ' cluster_confirmation
  [[ $cluster_confirmation == DRAINED-AND-DELETED ]] || die 'Promotion cancelled: cluster-side preparation was not confirmed.'
  printf 'K3s SERVER token (input hidden; an agent-only token cannot promote a node): '; read -rs JOIN_TOKEN; echo; [[ -n $JOIN_TOKEN ]] || die 'Server token cannot be empty'
  phase 3 7 'Reviewing the irreversible local conversion'; summary 'Promote existing worker to manager' 'existing cluster services'; local exact; read -r -p "Type 'PROMOTE $DESIRED_HOSTNAME' to remove the local agent installation: " exact; [[ $exact == "PROMOTE $DESIRED_HOSTNAME" ]] || die 'Exact promotion confirmation failed.'
  phase 4 7 'Backing up local configuration and removing the agent role'; promotion_backup
  [[ -x /usr/local/bin/k3s-agent-uninstall.sh ]] || die 'Official k3s-agent-uninstall.sh was not found; no removal was attempted.'
  as_root /usr/local/bin/k3s-agent-uninstall.sh
  phase 5 7 'Installing this machine as a manager/server'; local cfg; cfg=$(render_k3s_config join "$JOIN_TOKEN"); install_k3s "$cfg" server; JOIN_TOKEN=; cfg=; NODE_ROLE=server; persist_state
  phase 6 7 'Waiting for Ready, control-plane and etcd membership'; wait_k3s; wait_local_node; check_kube_vip_interface || warn 'kube-vip requires operator attention'; ensure_iscsi
  phase 7 7 'Running final health and quorum-oriented validation'; validate_cluster
}
configure_updates_prompt(){ if ! security_updates_supported; then skip "Automatic security-update configuration is not changed on $OS_NAME; use its native update policy."; elif confirm 'Enable security-only unattended upgrades (automatic reboot disabled)?'; then configure_updates; else skip 'Unattended upgrades unchanged'; fi; }
load_state(){ local state_content; if [[ -r $STATE_FILE ]]; then state_content=$(<"$STATE_FILE"); elif sudo -n test -r "$STATE_FILE" 2>/dev/null; then state_content=$(sudo cat "$STATE_FILE"); else return 0; fi; while IFS='=' read -r key value; do case $key in NODE_ROLE|NODE_IP|API_VIP|STORAGE_MODE|STORAGE_DEVICE|LONGHORN_PATH|LONGHORN_DEVICE_UUID) printf -v "$key" '%s' "$value";; esac; done <<<"$state_content"; }
show_main_menu(){
  printf '\nK3sDeploy Installer %s\n\n1. Create new K3s cluster (Node 1 manager setup)\n2. Join existing K3s cluster as a manager node (control-plane + etcd)\n3. Join K3s cluster as a worker node\n4. Upgrade K3s cluster worker node to manager (control-plane + etcd)\n5. Validate this node and cluster\n6. Repair safe local differences\n7. Exit\n\nFor most clusters use 3 or 5 manager nodes; join remaining machines as workers.\n' "$VERSION"
}
dispatch_action(){
  local action=$1
  if [[ $action == 5 ]] && ! k3s_local_installation_present; then
    phase 1 1 'Running read-only first-use validation'
    validate_cluster
    return
  fi
  if [[ $action == 6 ]] && ! k3s_local_installation_present; then
    phase 1 1 'Checking whether this clean node needs repair'
    safe_repair
    return
  fi
  require_privileges
  load_state
  if [[ $action =~ ^[1-3]$ ]] && { [[ $K3S_INSTALLED == yes ]] || as_root_capture test -e "$CONFIG_FILE" || systemctl is-active --quiet k3s || systemctl is-active --quiet k3s-agent; }; then
    die 'Existing K3s state detected. Refusing a fresh installation; choose validation or safe repair instead.'
  fi
  case $action in
    1) new_cluster;;
    2) join_cluster;;
    3) join_agent;;
    4) promote_agent;;
    5) phase 1 1 'Running read-only node and cluster validation'; validate_cluster;;
    6) phase 1 1 'Checking and offering only safe repairs'; safe_repair;;
  esac
}
run_menu_action(){
  local action=$1 rc
  trap - ERR
  set +e
  (
    set -Eeuo pipefail
    trap 'on_error $LINENO' ERR
    dispatch_action "$action"
  )
  rc=$?
  set -e
  trap 'on_error $LINENO' ERR
  if ((rc != 0)); then
    warn "This workflow stopped safely (exit $rc). No later phases were run."
    info 'Review the message above, correct the input or system condition, then choose an installer option again.'
  else
    ok 'Workflow finished. Returning to the installer menu.'
  fi
}
main(){
  local action
  parse_args "$@"
  while true; do
    preflight_collect
    basic_host_sanity
    announce_existing_k3s
    show_main_menu
    read -r -p 'Selection: ' action
    [[ $action == 7 ]] && return 0
    if [[ ! $action =~ ^[1-6]$ ]]; then warn 'Invalid selection; choose a number from 1 to 7.'; continue; fi
    run_menu_action "$action"
  done
}
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
