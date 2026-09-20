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
# shellcheck source=lib/nfs.sh
source "$SCRIPT_DIR/lib/nfs.sh"
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
use_metallb(){ [[ $LOAD_BALANCER_MODE == metallb ]]; }
use_servicelb(){ [[ $LOAD_BALANCER_MODE == servicelb ]]; }
use_longhorn(){ [[ $STORAGE_PROVIDER == longhorn ]]; }
use_nfs(){ [[ $STORAGE_PROVIDER == nfs ]]; }
set_recommended_profile(){ INSTALL_PROFILE=recommended; LOAD_BALANCER_MODE=metallb; STORAGE_PROVIDER=longhorn; }
collect_nfs_config(){
  local export_path
  section 'Shared NFS storage'
  printf '%s\n' \
    '  K3sDeploy will install the Kubernetes NFS CSI driver and use one existing' \
    '  NFSv4.1 export for dynamically provisioned persistent volumes.' \
    '  Every cluster node must be able to reach the same server and export.' \
    '  A single NFS server is still a single point of failure; shared storage is' \
    '  highly available only when the NFS service and its data are themselves HA.'
  printf '\n'
  while true; do
    prompt_ipv4 NFS_SERVER 'NFS server IPv4 address'
    read -r -p 'NFS export path (example: /mnt/pool/k3s): ' export_path
    if [[ $export_path =~ ^/[A-Za-z0-9._/-]+$ ]]; then NFS_EXPORT=$export_path; else warn 'Enter an absolute export path using letters, numbers, dots, underscores, hyphens, and slashes.'; continue; fi
    if ! port_reachable "$NFS_SERVER" 2049; then
      warn "NFS port 2049 is not reachable at $NFS_SERVER."
      confirm 'Keep these NFS settings and verify the mount later anyway?' || continue
    fi
    confirm 'I understand NFS availability depends on the external NFS service' || continue
    return 0
  done
}
configure_advanced_profile(){
  local choice
  INSTALL_PROFILE=advanced
  section 'Advanced load-balancer choice'
  printf '%s\n' \
    '1. MetalLB (recommended; installed and configured by K3sDeploy)' \
    '2. K3s ServiceLB (built in; simpler, but not the recommended HA design)' \
    '3. External or none (you will install and manage it separately)'
  while true; do
    printf '\n'
    read -r -p 'Selection [1]: ' choice
    case ${choice:-1} in
      1) LOAD_BALANCER_MODE=metallb; break;;
      2)
        warn 'MetalLB is recommended for the HA, bare-metal-style design used by K3sDeploy.'
        if confirm 'Continue with K3s ServiceLB instead?'; then LOAD_BALANCER_MODE=servicelb; break; else info 'Choose a load-balancer option again.'; fi
        ;;
      3)
        warn 'K3sDeploy cannot validate availability or address ownership for an external load balancer.'
        if confirm 'Continue with externally managed load balancing?'; then LOAD_BALANCER_MODE=external; break; else info 'Choose a load-balancer option again.'; fi
        ;;
      *) warn 'Choose load-balancer option 1, 2, or 3.';;
    esac
  done

  section 'Advanced persistent-storage choice'
  printf '%s\n' \
    '1. Longhorn (recommended HA storage; installed and configured by K3sDeploy)' \
    '2. Shared NFS (guided NFS CSI setup using an existing NFSv4.1 export)' \
    '3. K3s local-path (NON-HA node-local storage; explicit risk acceptance required)' \
    '4. Other external or none (K3s local-storage is disabled; you manage it)'
  while true; do
    printf '\n'
    read -r -p 'Selection [1]: ' choice
    case ${choice:-1} in
      1) STORAGE_PROVIDER=longhorn; break;;
      2) STORAGE_PROVIDER=nfs; collect_nfs_config; break;;
      3)
        warn 'Local-path volumes remain on one node and are not replicated or failed over by K3sDeploy.'
        warn 'A node or disk failure can make those volumes unavailable and may cause data loss.'
        local risk_acceptance
        read -r -p 'Type ACCEPT-NON-HA-STORAGE to choose local-path: ' risk_acceptance
        if [[ $risk_acceptance == ACCEPT-NON-HA-STORAGE ]]; then STORAGE_PROVIDER=local-path; break; fi
        info 'Local-path was not selected. Choose a storage option again.'
        ;;
      4) STORAGE_PROVIDER=external; break;;
      *) warn 'Choose persistent-storage option 1, 2, 3, or 4.';;
    esac
  done
  warn 'Advanced choices must match the architecture used by every other node in this cluster.'
}
choose_install_profile(){
  local choice
  while true; do
    section 'Installation profile'
    printf '%s\n' \
      '1. Recommended installation' \
      '   K3sDeploy configures kube-vip, MetalLB, and Longhorn with guided defaults.' \
      '' \
      '2. Advanced / custom installation' \
      '   Choose supported or externally managed load balancing and shared storage.' \
      '   K3sDeploy only installs components it explicitly lists as supported.' \
      '' \
      '3. Exit'
    printf '\n'
    read -r -p 'Selection [1]: ' choice
    case ${choice:-1} in
      1) set_recommended_profile; return 0;;
      2) configure_advanced_profile; return 0;;
      3) return 1;;
      *) warn 'Choose installation profile 1, 2, or 3.';;
    esac
  done
}
prepare_storage_choice(){
  if use_longhorn; then
    select_storage
  else
    STORAGE_MODE=external
    STORAGE_DEVICE=
    STORAGE_DEVICE_MAJMIN=
    if [[ $STORAGE_PROVIDER == nfs ]]; then
      STORAGE_MODE=nfs-csi
      STORAGE_DEVICE="$NFS_SERVER:$NFS_EXPORT"
      STORAGE_DESCRIPTION='install the pinned NFS CSI driver and create the nfs-csi-retain StorageClass'
    elif [[ $STORAGE_PROVIDER == local-path ]]; then
      STORAGE_DESCRIPTION='use the built-in K3s local-path provisioner; data remains tied to one node'
    else
      STORAGE_DESCRIPTION='externally managed; K3s local-storage is disabled and no storage device is changed'
    fi
    LONGHORN_PATH=
    LONGHORN_DEVICE_UUID=
    skip "Longhorn storage selection omitted ($STORAGE_PROVIDER selected)"
  fi
}
prepare_storage_host(){
  case $STORAGE_PROVIDER in
    longhorn) apply_storage_plan;;
    nfs) verify_nfs_share;;
    *) skip "No host storage preparation requested ($STORAGE_PROVIDER selected)";;
  esac
}
install_cluster_storage(){
  case $STORAGE_PROVIDER in
    longhorn) install_longhorn;;
    nfs) install_nfs_csi;;
    *) skip "No cluster storage add-on selected ($STORAGE_PROVIDER)";;
  esac
}
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
  section 'Node identity'
  current_hostname=$(short_hostname); current_hostname=${current_hostname,,}
  printf '  Detected hostname: %s\n\n' "$current_hostname"
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
  section 'Node network address'
  printf '  Detected address:   %s\n' "$DETECTED_IP"
  printf '  Detected interface: %s\n\n' "${PRIMARY_IFACE:-unknown}"
  info 'Every cluster node needs a stable address, normally provided by a DHCP reservation or static network configuration.'
  if ! confirm_yes "Use $DETECTED_IP as this node's permanent cluster address?"; then
    die 'Configure the desired static address or DHCP reservation, restart networking (or reboot), and rerun K3sDeploy.'
  fi
  NODE_IP=$DETECTED_IP
  valid_ip_or_die 'Node IP' "$NODE_IP"
}

collect_new_cluster_vip(){
  section 'Kubernetes API virtual IP (VIP)'
  printf '%s\n' \
    '  Purpose: one unused address that always leads to the active managers.' \
    '  Network: use the same Layer-2 network/VLAN as the manager addresses.' \
    '  Reserve: keep it outside DHCP and do not assign it to another device.' \
    '  Example: for node 192.168.10.21/24, an unused address such as 192.168.10.20 may be suitable.'
  printf '\n'
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
  section 'Existing cluster connection'
  printf '%s\n' \
    '  Enter the exact Kubernetes API VIP created on the first manager.' \
    '  Do not enter this node address or the address of only one manager.' \
    '  The installer verifies the cluster and token before asking about storage.'
  printf '\n'
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
  section 'MetalLB application address pool'
  printf '%s\n' \
    '  Choose unused addresses for applications exposed as LoadBalancer services.' \
    '  Reserve the complete range outside DHCP.' \
    '  The range must not contain a node address or the Kubernetes API VIP.'
  printf '\n'
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
persist_state(){ local body; body=$(printf 'INSTALL_PROFILE=%s\nLOAD_BALANCER_MODE=%s\nSTORAGE_PROVIDER=%s\nNODE_ROLE=%s\nNODE_IP=%s\nAPI_VIP=%s\nPOOL_START=%s\nPOOL_END=%s\nSTORAGE_MODE=%s\nSTORAGE_DEVICE=%s\nLONGHORN_PATH=%s\nLONGHORN_DEVICE_UUID=%s\nLONGHORN_REPLICAS=%s\nNFS_SERVER=%s\nNFS_EXPORT=%s\n' "$INSTALL_PROFILE" "$LOAD_BALANCER_MODE" "$STORAGE_PROVIDER" "${NODE_ROLE:-server}" "$NODE_IP" "$API_VIP" "${POOL_START:-}" "${POOL_END:-}" "$STORAGE_MODE" "${STORAGE_DEVICE:-}" "${LONGHORN_PATH:-}" "${LONGHORN_DEVICE_UUID:-}" "${LONGHORN_REPLICAS:-$LONGHORN_DEFAULT_REPLICAS}" "${NFS_SERVER:-}" "${NFS_EXPORT:-}"); write_root_file "$STATE_FILE" 600 "$body" || true; }
set_hostname_if_needed(){ [[ $(short_hostname) == "$DESIRED_HOSTNAME" ]] && return; need_cmd hostnamectl; info "Changing this node hostname to $DESIRED_HOSTNAME as shown in the accepted plan"; as_root hostnamectl set-hostname "$DESIRED_HOSTNAME"; }
summary(){
  local address_detail=$2
  section 'Installation plan'
  cat <<EOF
  Installer:        K3sDeploy $VERSION
  Action:           $1
  Hostname:         $DESIRED_HOSTNAME
  Node IP:          $NODE_IP
  API VIP:          $API_VIP
  Role:             ${TARGET_ROLE:-control-plane + etcd + worker}
  Profile:          $INSTALL_PROFILE
  Load balancer:    $LOAD_BALANCER_MODE
  Storage provider: $STORAGE_PROVIDER
  Storage mode:     $STORAGE_MODE${LONGHORN_PATH:+ ($LONGHORN_PATH)}
  Storage source:   ${STORAGE_DEVICE:-externally managed / none}
  Storage plan:     ${STORAGE_DESCRIPTION:-use existing configured storage}
  K3s ServiceLB:    $(use_servicelb && printf 'enabled' || printf 'disabled')
EOF
  if use_metallb; then printf '  MetalLB address pool: %s\n' "$address_detail"; else printf '  LoadBalancer addresses: %s\n' "$address_detail"; fi
}
new_cluster(){
  NODE_ROLE=server
  TARGET_ROLE='control-plane + etcd + schedulable worker'

  phase 1 8 'Collecting node, network and storage choices'
  collect_local_identity
  collect_new_cluster_vip
  prepare_storage_choice
  if use_metallb; then collect_metallb_pool; else skip "MetalLB address pool omitted ($LOAD_BALANCER_MODE selected)"; fi
  LONGHORN_REPLICAS=$LONGHORN_DEFAULT_REPLICAS

  phase 2 8 'Reviewing preflight checks and planned changes'
  if use_metallb; then summary 'Create new K3s cluster / first server' "$POOL_START-$POOL_END"; else summary 'Create new K3s cluster / first server' "managed by $LOAD_BALANCER_MODE"; fi
  preflight_show
  detect_existing
  [[ $K3S_INSTALLED == no && ! -f $CONFIG_FILE ]] || die 'Existing K3s detected. Use validate/repair; refusing to initialize over it.'
  if use_longhorn; then [[ $LONGHORN_DATA_PRESENT == no ]] || die 'Existing Longhorn data was found. Refusing to initialize a new cluster over it.'; fi
  section 'Final confirmation'
  confirm 'Apply this installation plan?' || { skip 'Cancelled'; return; }

  phase 3 8 'Preparing storage, hostname and protected installer state'
  prepare_storage_host
  set_hostname_if_needed
  persist_state

  phase 4 8 'Installing the pinned K3s first server'
  install_k3s "$(render_k3s_config first)" server
  wait_k3s
  wait_local_node

  phase 5 8 'Installing the kube-vip API virtual address'
  install_kube_vip

  phase 6 8 'Installing MetalLB for application addresses'
  if use_metallb; then install_metallb; else skip "MetalLB not selected; load-balancer mode is $LOAD_BALANCER_MODE"; fi

  phase 7 8 'Installing persistent storage and host prerequisites'
  install_cluster_storage
  configure_updates_prompt

  phase 8 8 'Running final health validation'
  validate_cluster
}

join_cluster(){
  local cfg
  NODE_ROLE=server
  TARGET_ROLE='control-plane + etcd + schedulable worker'

  phase 1 8 'Verifying cluster, then collecting manager choices'
  collect_join_access server
  collect_local_identity
  check_identity_network
  prepare_storage_choice

  phase 2 8 'Checking the existing cluster and local node'
  summary 'Join existing HA cluster' "existing $LOAD_BALANCER_MODE configuration"
  preflight_show
  detect_existing
  if [[ $K3S_INSTALLED == yes || -f $CONFIG_FILE ]]; then
    die 'Existing K3s/config detected. Use validate/repair; refusing to overwrite or rejoin.'
  fi
  if use_longhorn; then [[ $LONGHORN_DATA_PRESENT == no ]] || die 'Existing Longhorn data was found. Refusing to join over it without manual recovery review.'; fi
  section 'Final confirmation'
  confirm 'Apply this installation plan?' || { JOIN_TOKEN=; skip 'Cancelled'; return; }

  phase 3 8 'Preparing storage, hostname and protected installer state'
  prepare_storage_host
  set_hostname_if_needed
  persist_state

  phase 4 8 'Installing K3s and joining embedded etcd'
  cfg=$(render_k3s_config join "$JOIN_TOKEN")
  install_k3s "$cfg" server
  JOIN_TOKEN=
  cfg=

  phase 5 8 'Waiting for Ready, control-plane and etcd roles'
  wait_k3s
  wait_local_node

  phase 6 8 'Checking kube-vip compatibility on this server'
  check_kube_vip_interface || warn 'kube-vip requires operator attention'

  phase 7 8 'Preparing storage and checking cluster-wide services'
  if use_longhorn; then ensure_iscsi; elif use_nfs; then ensure_nfs_client; else skip 'No managed storage host prerequisites selected'; fi
  info 'Cluster-wide kube-vip, load balancing, Traefik and persistent storage are inspected, not reinstalled.'

  phase 8 8 'Running final health validation'
  validate_cluster
  offer_longhorn_smoke
}

join_agent(){
  local cfg
  NODE_ROLE=agent
  TARGET_ROLE='worker/agent (no control-plane or etcd)'

  phase 1 7 'Verifying cluster, then collecting worker choices'
  collect_join_access agent
  collect_local_identity
  check_identity_network
  prepare_storage_choice

  phase 2 7 'Checking the existing cluster and local node'
  summary 'Join existing cluster as worker/agent' "existing $LOAD_BALANCER_MODE configuration"
  preflight_show
  detect_existing
  if [[ $K3S_INSTALLED == yes || -f $CONFIG_FILE ]]; then
    die 'Existing K3s/config detected. Use validate/repair; refusing to overwrite or rejoin.'
  fi
  if use_longhorn; then [[ $LONGHORN_DATA_PRESENT == no ]] || die 'Existing Longhorn data was found. Refusing to join over it without manual recovery review.'; fi
  section 'Final confirmation'
  confirm 'Apply this installation plan?' || { JOIN_TOKEN=; skip 'Cancelled'; return; }

  phase 3 7 'Preparing storage, hostname and protected installer state'
  prepare_storage_host
  set_hostname_if_needed
  persist_state

  phase 4 7 'Installing the pinned K3s agent'
  cfg=$(render_k3s_config agent "$JOIN_TOKEN")
  install_k3s "$cfg" agent
  JOIN_TOKEN=
  cfg=

  phase 5 7 'Waiting for the worker node to become Ready'
  wait_agent_node

  phase 6 7 'Preparing persistent-storage host prerequisites'
  if use_longhorn; then ensure_iscsi; elif use_nfs; then ensure_nfs_client; else skip 'No managed storage host prerequisites selected'; fi
  info 'Cluster-wide add-ons are not reinstalled on worker nodes.'

  phase 7 7 'Running final health validation'
  validate_cluster
  offer_longhorn_smoke
}
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
  phase 6 7 'Waiting for Ready, control-plane and etcd membership'; wait_k3s; wait_local_node; check_kube_vip_interface || warn 'kube-vip requires operator attention'; if use_longhorn; then ensure_iscsi; elif use_nfs; then ensure_nfs_client; else skip 'No managed storage host prerequisites selected'; fi
  phase 7 7 'Running final health and quorum-oriented validation'; validate_cluster; offer_longhorn_smoke
}
configure_updates_prompt(){ if ! security_updates_supported; then skip "Automatic security-update configuration is not changed on $OS_NAME; use its native update policy."; elif confirm 'Enable security-only unattended upgrades (automatic reboot disabled)?'; then configure_updates; else skip 'Unattended upgrades unchanged'; fi; }
load_state(){ local state_content; if [[ -r $STATE_FILE ]]; then state_content=$(<"$STATE_FILE"); elif sudo -n test -r "$STATE_FILE" 2>/dev/null; then state_content=$(sudo cat "$STATE_FILE"); else return 0; fi; while IFS='=' read -r key value; do case $key in INSTALL_PROFILE|LOAD_BALANCER_MODE|STORAGE_PROVIDER|NODE_ROLE|NODE_IP|API_VIP|POOL_START|POOL_END|STORAGE_MODE|STORAGE_DEVICE|LONGHORN_PATH|LONGHORN_DEVICE_UUID|LONGHORN_REPLICAS|NFS_SERVER|NFS_EXPORT) printf -v "$key" '%s' "$value";; esac; done <<<"$state_content"; }
show_main_menu(){
  printf '\nK3sDeploy Installer %s\nProfile: %s | Load balancer: %s | Storage: %s\n\n1. Create new K3s cluster (Node 1 manager setup)\n2. Join existing K3s cluster as a manager node (control-plane + etcd)\n3. Join K3s cluster as a worker node\n4. Upgrade K3s cluster worker node to manager (control-plane + etcd)\n5. Validate this node and cluster\n6. Repair safe local differences\n7. Exit\n\nFor most clusters use 3 or 5 manager nodes; join remaining machines as workers.\n' "$VERSION" "$INSTALL_PROFILE" "$LOAD_BALANCER_MODE" "$STORAGE_PROVIDER"
}
workflow_completion_summary(){
  local action=$1
  section 'K3sDeploy session complete'
  case $action in
    1)
      printf '%s\n' \
        '  Result: the first manager installation workflow completed.' \
        '  Next: use this same K3sDeploy release on manager two, then manager three.'
      ;;
    2)
      printf '%s\n' \
        '  Result: this manager joined the existing control plane and etcd cluster.' \
        '  Next: complete an odd manager count—normally three—before relying on HA.'
      ;;
    3)
      printf '%s\n' \
        '  Result: this worker joined the existing K3s cluster.' \
        '  Next: validate cluster-wide storage from a healthy manager after storage registration completes.'
      ;;
    4)
      printf '%s\n' \
        '  Result: the worker-to-manager promotion workflow completed.' \
        '  Next: confirm the final manager count and etcd quorum from another healthy manager.'
      ;;
    5)
      printf '%s\n' \
        '  Result: read-only validation completed.' \
        '  Changes: no system or cluster changes were requested by this workflow.'
      ;;
    6)
      printf '%s\n' \
        '  Result: safe-repair checks and any repairs you explicitly confirmed completed.' \
        '  Validation: the final health report above is the post-repair result; option 5 does not need to be run again.'
      ;;
  esac
  printf '  Health: %s failed check(s), %s warning(s), %s untested check(s).\n' \
    "${VALIDATION_FAILURES:-0}" "${VALIDATION_WARNINGS:-0}" "${VALIDATION_NOT_TESTED:-0}"
  printf '  Details: %s\n' "$LOG_FILE"
  printf '\nK3sDeploy will now exit. Run it again whenever you need validation, repair, or another node action.\n'
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
  [[ $action =~ ^[4-6]$ ]] && load_state
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
  LAST_WORKFLOW_SUCCEEDED=false
  trap - ERR
  set +e
  (
    set -Eeuo pipefail
    trap 'on_error $LINENO' ERR
    if dispatch_action "$action"; then
      workflow_completion_summary "$action"
    else
      exit $?
    fi
  )
  rc=$?
  set -e
  trap 'on_error $LINENO' ERR
  if ((rc != 0)); then
    warn "This workflow stopped safely (exit $rc). No later phases were run."
    info 'Review the message above, correct the input or system condition, then choose an installer option again.'
  else
    LAST_WORKFLOW_SUCCEEDED=true
    ok 'The requested workflow completed and K3sDeploy is closing normally.'
  fi
}
main(){
  local action
  parse_args "$@"
  show_banner
  choose_install_profile || return 0
  while true; do
    preflight_collect
    basic_host_sanity
    announce_existing_k3s
    show_main_menu
    read -r -p 'Selection: ' action
    [[ $action == 7 ]] && return 0
    if [[ ! $action =~ ^[1-6]$ ]]; then warn 'Invalid selection; choose a number from 1 to 7.'; continue; fi
    run_menu_action "$action"
    $LAST_WORKFLOW_SUCCEEDED && return 0
  done
}
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
