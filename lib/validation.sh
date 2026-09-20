#!/usr/bin/env bash
kubectl_local(){
  if [[ -f /etc/rancher/k3s/k3s.yaml ]]; then
    if [[ $EUID -eq 0 ]]; then k3s kubectl "$@"; else sudo k3s kubectl "$@"; fi
    return
  fi
  local agent_dir=/var/lib/rancher/k3s/agent
  local -a auth=(--server "https://${API_VIP:-127.0.0.1}:6443" --certificate-authority "$agent_dir/server-ca.crt" --client-certificate "$agent_dir/client-kubelet.crt" --client-key "$agent_dir/client-kubelet.key")
  if [[ $EUID -eq 0 ]]; then k3s kubectl "${auth[@]}" "$@"; else sudo k3s kubectl "${auth[@]}" "$@"; fi
}
VALIDATION_FAILURES=0
VALIDATION_WARNINGS=0
VALIDATION_NOT_TESTED=0
report(){
  local label=$1 status=$2 detail=${3:-}
  case $status in
    FAIL) VALIDATION_FAILURES=$((VALIDATION_FAILURES+1));;
    WARN) VALIDATION_WARNINGS=$((VALIDATION_WARNINGS+1));;
    'NOT TESTED') VALIDATION_NOT_TESTED=$((VALIDATION_NOT_TESTED+1));;
  esac
  printf '%-31s %-10s %s\n' "$label" "$status" "$detail"
}
validation_summary(){
  printf '\n'
  if ((VALIDATION_FAILURES > 0)); then
    error "Health result: $VALIDATION_FAILURES failed check(s), $VALIDATION_WARNINGS warning(s), $VALIDATION_NOT_TESTED untested check(s)."
    return 1
  fi
  if ((VALIDATION_WARNINGS > 0 || VALIDATION_NOT_TESTED > 0)); then
    warn "Health result: no failed checks; $VALIDATION_WARNINGS warning(s) and $VALIDATION_NOT_TESTED untested check(s) need review."
    return 0
  fi
  ok 'Health result: all applicable checks passed'
}
check(){ local label=$1; shift; if "$@" >/dev/null 2>&1; then report "$label" OK; else report "$label" FAIL; return 1; fi; }
systemd_unit_exists(){ systemctl list-unit-files --no-legend "$1.service" 2>/dev/null | grep -q "^$1.service"; }
k3s_local_installation_present(){
  command -v k3s >/dev/null 2>&1 || [[ -e $CONFIG_FILE ]] || systemd_unit_exists k3s || systemd_unit_exists k3s-agent
}

report_fresh_node(){
  report 'K3s service' MISSING 'K3s has not been installed on this node'
  report 'Kubernetes API' SKIP 'requires K3s'
  report 'Node Ready' SKIP 'requires K3s'
  report 'Control-plane role' SKIP 'requires K3s'
  report 'etcd role' SKIP 'requires K3s'
  report 'K3s ServiceLB' SKIP 'requires K3s'
  report 'kube-vip' MISSING 'not installed'
  if [[ ${LOAD_BALANCER_MODE:-metallb} == metallb ]]; then report 'MetalLB' MISSING 'not installed'; else report 'MetalLB' SKIP "not selected ($LOAD_BALANCER_MODE mode)"; fi
  report 'Traefik' MISSING 'not installed'
  if [[ ${STORAGE_PROVIDER:-longhorn} == longhorn ]]; then report 'Longhorn' MISSING 'not installed'; else report 'Longhorn' SKIP "$STORAGE_PROVIDER storage selected"; fi
  if [[ ${STORAGE_PROVIDER:-longhorn} != longhorn ]]; then
    report open-iscsi SKIP 'Longhorn not selected'
  elif command -v iscsiadm >/dev/null 2>&1; then
    if systemctl is-active --quiet iscsid; then report open-iscsi OK; else report open-iscsi WARN 'installed but inactive; K3sDeploy will configure it during installation'; fi
  else
    report open-iscsi MISSING 'installed automatically when Longhorn is deployed'
  fi
  if [[ ${STORAGE_PROVIDER:-longhorn} == longhorn ]]; then
    report 'Longhorn storage' MISSING 'not configured'
    report 'Persistent storage' 'NOT TESTED' 'install the cluster before running the smoke test'
  elif [[ ${STORAGE_PROVIDER:-longhorn} == local-path ]]; then
    report 'Persistent storage' MISSING 'K3s local-path requires K3s; it is non-HA node-local storage'
  elif [[ ${STORAGE_PROVIDER:-longhorn} == nfs ]]; then
    report 'Persistent storage' MISSING 'NFS CSI requires K3s installation'
  else
    report 'Persistent storage' SKIP 'externally managed; validate it with its own tooling'
  fi
}

validate_cluster(){
  VALIDATION_FAILURES=0
  VALIDATION_WARNINGS=0
  VALIDATION_NOT_TESTED=0
  printf '\nHealth report\n'
  if [[ -r /etc/os-release && ${OS_PACKAGE_MANAGER:-unsupported} != unsupported ]]; then report 'Operating system' OK "${OS_NAME:-Linux} ($OS_PACKAGE_MANAGER)"; else report 'Operating system' FAIL 'unsupported or not detected'; fi
  check Network ip route get 1.1.1.1 || true
  if ! k3s_local_installation_present; then
    report_fresh_node
    printf '\nThis is a clean node. Choose option 1 to create the first manager, option 2 to join a manager, or option 3 to join a worker.\n'
    validation_summary || true
    return 0
  fi
  if systemctl is-active --quiet k3s || systemctl is-active --quiet k3s-agent; then
    report 'K3s service' OK
  elif systemd_unit_exists k3s || systemd_unit_exists k3s-agent; then
    report 'K3s service' FAIL 'installed service is inactive'
  else
    report 'K3s service' FAIL 'partial installation: service unit is missing'
  fi
  if command -v k3s >/dev/null; then
    local node=${DESIRED_HOSTNAME:-$(short_hostname)} labels
    check 'Kubernetes API' kubectl_local get --raw=/readyz || true
    if [[ $(kubectl_local get node "$node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null) == True ]]; then report 'Node Ready' OK; else report 'Node Ready' FAIL; fi
    labels=$(kubectl_local get node "$node" --show-labels --no-headers 2>/dev/null || true)
    if grep -q control-plane <<<"$labels"; then report 'Control-plane role' OK; elif [[ ${NODE_ROLE:-server} == agent ]]; then report 'Control-plane role' SKIP 'worker node'; else report 'Control-plane role' FAIL; fi
    if grep -q 'node-role.kubernetes.io/etcd' <<<"$labels"; then report 'etcd role' OK; elif [[ ${NODE_ROLE:-server} == agent ]]; then report 'etcd role' SKIP 'worker node'; else report 'etcd role' FAIL; fi
    if [[ ${LOAD_BALANCER_MODE:-metallb} == servicelb ]]; then
      if kubectl_local -n kube-system get ds svclb-traefik >/dev/null 2>&1; then report 'K3s ServiceLB' OK 'selected'; else report 'K3s ServiceLB' WARN 'selected but no Traefik service pod was found'; fi
    elif ! kubectl_local -n kube-system get ds svclb-traefik >/dev/null 2>&1; then
      report 'K3s ServiceLB' OK 'disabled as planned'
    else
      report 'K3s ServiceLB' FAIL 'running although another load-balancer mode was selected'
    fi
    validate_kube_vip || true
    if [[ -n ${API_VIP:-} ]]; then
      if port_reachable "$API_VIP" 6443; then report 'API VIP endpoint' OK "$API_VIP:6443 reachable"; else report 'API VIP endpoint' FAIL "$API_VIP:6443 is unreachable"; fi
    else
      report 'API VIP endpoint' FAIL 'saved API VIP is missing'
    fi
    if [[ ${LOAD_BALANCER_MODE:-metallb} == metallb ]]; then validate_metallb || true; else report MetalLB SKIP "not selected ($LOAD_BALANCER_MODE mode)"; fi
    if [[ ${STORAGE_PROVIDER:-longhorn} == longhorn ]]; then validate_longhorn || true; else report Longhorn SKIP "$STORAGE_PROVIDER storage selected"; fi
    if [[ ${STORAGE_PROVIDER:-longhorn} != local-path ]]; then
      if kubectl_local -n kube-system get deploy local-path-provisioner >/dev/null 2>&1; then
        report 'K3s local-path' WARN 'present although it is not selected; do not use it for HA workloads'
      else
        report 'K3s local-path' OK 'disabled as planned'
      fi
    fi
    if kubectl_local -n kube-system get svc traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null | grep -q .; then report Traefik OK; else report Traefik WARN 'no external IP'; fi
  fi
  if [[ ${STORAGE_PROVIDER:-longhorn} == local-path ]]; then
    report open-iscsi SKIP 'Longhorn not selected'
    if kubectl_local -n kube-system get deploy local-path-provisioner >/dev/null 2>&1 && kubectl_local get storageclass local-path >/dev/null 2>&1; then
      report 'Persistent storage' WARN 'K3s local-path is available but is not HA'
    else
      report 'Persistent storage' FAIL 'K3s local-path provisioner or StorageClass is missing'
    fi
  elif [[ ${STORAGE_PROVIDER:-longhorn} == nfs ]]; then
    report open-iscsi SKIP 'Longhorn not selected'
    validate_nfs || true
  elif [[ ${STORAGE_PROVIDER:-longhorn} != longhorn ]]; then
    report open-iscsi SKIP 'Longhorn not selected'
    report 'Persistent storage' SKIP 'externally managed; validate it with its own tooling'
  else
    if ! command -v iscsiadm >/dev/null 2>&1; then report open-iscsi MISSING 'package is not installed'; elif systemctl is-active --quiet iscsid; then report open-iscsi OK; else report open-iscsi FAIL 'installed service is inactive'; fi
    validate_storage_selection || true
    local smoke_status tested_at tested_from tested_version
    smoke_status=$(longhorn_smoke_status || true)
    IFS='|' read -r tested_at tested_from tested_version <<<"$smoke_status"
    if [[ -n $tested_at ]]; then
      report 'Persistent storage' OK "functional test passed $tested_at from ${tested_from:-unknown node} (${tested_version:-version unknown})"
    else
      report 'Persistent storage' 'NOT TESTED' 'no successful functional test has been recorded'
    fi
  fi
  validation_summary || true
}

repair_managed_addons(){
  [[ ${NODE_ROLE:-server} != agent ]] || return 0
  if ! kubectl_local get --raw=/readyz >/dev/null 2>&1; then
    warn 'The Kubernetes API is not ready; cluster add-ons cannot be reconciled yet.'
    return 0
  fi

  if ! kube_vip_ready; then
    warn "The kube-vip API virtual-address DaemonSet is not ready (${API_VIP:-VIP unknown})."
    kubectl_local -n kube-system get pods -l app=kube-vip -o wide 2>/dev/null || true
    if [[ -n ${API_VIP:-} ]] && confirm_yes 'Reapply the pinned kube-vip manifest and wait for it to become ready now?'; then
      install_kube_vip
    fi
  fi

  if [[ ${LOAD_BALANCER_MODE:-metallb} == metallb ]] && {
    [[ $(kubectl_local -n metallb-system get deploy controller -o jsonpath='{.status.availableReplicas}' 2>/dev/null || true) != 1 ]] ||
    ! [[ $(kubectl_local -n metallb-system get daemonset speaker -o jsonpath='{.status.numberReady}' 2>/dev/null || true) =~ ^[1-9][0-9]*$ ]] ||
    ! kubectl_local -n metallb-system get ipaddresspool homelab-pool >/dev/null 2>&1 ||
    ! kubectl_local -n metallb-system get l2advertisement homelab-l2 >/dev/null 2>&1
  }; then
    warn 'The saved plan selects MetalLB, but its address-pool configuration is incomplete.'
    if [[ -z ${POOL_START:-} || -z ${POOL_END:-} ]]; then collect_metallb_pool; fi
    if confirm_yes 'Retry the pinned MetalLB installation and address-pool configuration now?'; then
      install_metallb
      persist_state
    fi
  fi

  if [[ ${STORAGE_PROVIDER:-longhorn} == longhorn ]] && {
    [[ $(kubectl_local -n longhorn-system get deploy longhorn-driver-deployer -o jsonpath='{.status.availableReplicas}' 2>/dev/null || true) != 1 ]] ||
    [[ $(kubectl_local -n longhorn-system get deploy longhorn-ui -o jsonpath='{.status.availableReplicas}' 2>/dev/null || true) != 1 ]]
  }; then
    warn 'The saved plan selects Longhorn, but its installation is missing or incomplete.'
    if confirm_yes 'Continue the pinned Longhorn installation now?'; then
      LONGHORN_REPLICAS=${LONGHORN_REPLICAS:-$LONGHORN_DEFAULT_REPLICAS}
      install_longhorn
    fi
  elif [[ ${STORAGE_PROVIDER:-longhorn} == nfs ]] && {
    ! kubectl_local get csidriver nfs.csi.k8s.io >/dev/null 2>&1 ||
    ! kubectl_local get storageclass nfs-csi-retain >/dev/null 2>&1 ||
    [[ $(kubectl_local -n kube-system get deploy csi-nfs-controller -o jsonpath='{.status.availableReplicas}' 2>/dev/null || true) != 1 ]]
  }; then
    warn 'The saved plan selects NFS, but its CSI installation is missing or incomplete.'
    if [[ -z ${NFS_SERVER:-} || -z ${NFS_EXPORT:-} ]]; then collect_nfs_config; fi
    if confirm_yes 'Verify the NFS share and install the pinned NFS CSI driver now?'; then
      verify_nfs_share
      install_nfs_csi
      persist_state
    fi
  fi
}
offer_longhorn_smoke(){
  [[ ${STORAGE_PROVIDER:-longhorn} == longhorn ]] || return 0
  if [[ ${NODE_ROLE:-server} == agent ]]; then
    info 'This worker does not hold an administrative kubeconfig, so it cannot create the temporary cluster-wide storage test resources.'
    info 'After this worker is Ready, run option 6 on a healthy manager to offer the Longhorn functional test there.'
    return 0
  fi
  if ((${VALIDATION_FAILURES:-0} > 0)); then
    warn 'The Longhorn functional test is not offered while failed health checks remain.'
    return 0
  fi

  local storage_nodes
  storage_nodes=$(longhorn_storage_node_count)
  printf '\nOptional Longhorn functional test\n---------------------------------\n\n'
  if ((storage_nodes < 2)); then
    printf '%s\n' \
      "  Longhorn currently reports $storage_nodes ready, schedulable storage node(s)." \
      '  A one-node test can verify provisioning, attachment, and persistence,' \
      '  but it cannot verify replication or recovery from a node failure.' \
      '  K3sDeploy therefore does not offer it automatically on the first node.' \
      '  After another storage node joins, run option 6 on a manager.'
    skip 'Automatic Longhorn functional test deferred until at least two storage nodes are ready'
    return 0
  fi

  printf '%s\n' \
    "  Longhorn reports $storage_nodes ready, schedulable storage nodes." \
    '  This temporary one-replica test provisions a volume, writes data,' \
    '  reattaches it, verifies the data, and removes the test resources.' \
    '  It is a functional test, not a replica-loss or full HA failover test.'
  if confirm 'Run the temporary Longhorn functional test now?'; then
    if run_longhorn_smoke; then
      info 'Refreshing the health report so the recorded functional-test result is included in the final summary.'
      validate_cluster
      if ((VALIDATION_WARNINGS > 0)); then
        warn 'The Longhorn functional test passed, but the health-report warning(s) above still need review.'
      else
        ok 'Health checks and Longhorn functional verification completed successfully'
      fi
    else
      error 'Longhorn functional verification failed'
      return 1
    fi
  else
    skip 'Longhorn functional smoke test was not requested; configuration checks only were completed'
  fi
}
verify_after_repair(){
  validate_cluster
  info 'The health report above is the same read-only inspection provided by menu option 5; you do not need to run it again now.'
  if ((VALIDATION_FAILURES > 0)); then
    warn 'Repair completed, but failed health checks remain. Resolve the reported failure before deploying workloads.'
    return 0
  fi
  offer_longhorn_smoke
}
safe_repair(){
  info "Repair mode only offers non-destructive actions"
  if ! k3s_local_installation_present; then
    info 'No K3s installation or service was detected. There is nothing to repair on this clean node.'
    info 'Use option 1 for the first manager, option 2 for another manager, or option 3 for a worker.'
    validate_cluster
    return 0
  fi
  local service=
  if systemd_unit_exists k3s; then service=k3s; elif systemd_unit_exists k3s-agent; then service=k3s-agent; fi
  if [[ -n $service ]]; then
    systemctl is-active --quiet "$service" 2>/dev/null || { confirm_yes "Start inactive $service service?" && as_root systemctl start "$service"; }
  else
    warn 'K3s files were detected, but no k3s or k3s-agent service unit exists. Automatic repair is not safe; review the installation log or reinstall deliberately.'
    validate_cluster
    return 0
  fi
  if [[ ${STORAGE_PROVIDER:-longhorn} == longhorn ]]; then
    command -v iscsiadm >/dev/null || { confirm_yes 'Install missing open-iscsi?' && ensure_iscsi; }
    systemctl is-active --quiet iscsid 2>/dev/null || { confirm_yes 'Enable/start iscsid?' && as_root systemctl enable --now iscsid; }
  elif [[ ${STORAGE_PROVIDER:-longhorn} == nfs ]]; then
    ensure_nfs_client
  fi
  repair_managed_addons
  [[ ! -f $CONFIG_FILE ]] || warn "Configuration reconciliation requires desired values and explicit confirmation; no automatic cluster-identity changes are made."
  verify_after_repair
}
