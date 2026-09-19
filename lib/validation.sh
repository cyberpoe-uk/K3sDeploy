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
report(){ local label=$1 status=$2 detail=${3:-}; printf '%-31s %-10s %s\n' "$label" "$status" "$detail"; }
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
    report 'Persistent storage' MISSING 'K3s local-path requires K3s installation'
  else
    report 'Persistent storage' SKIP 'externally managed; validate it with its own tooling'
  fi
}

validate_cluster(){
  printf '\nHealth report\n'
  if [[ -r /etc/os-release && ${OS_PACKAGE_MANAGER:-unsupported} != unsupported ]]; then report 'Operating system' OK "${OS_NAME:-Linux} ($OS_PACKAGE_MANAGER)"; else report 'Operating system' FAIL 'unsupported or not detected'; fi
  check Network ip route get 1.1.1.1 || true
  if ! k3s_local_installation_present; then
    report_fresh_node
    printf '\nThis is a clean node. Choose option 1 to create the first manager, option 2 to join a manager, or option 3 to join a worker.\n'
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
    if [[ ${LOAD_BALANCER_MODE:-metallb} == metallb ]]; then validate_metallb || true; else report MetalLB SKIP "not selected ($LOAD_BALANCER_MODE mode)"; fi
    if [[ ${STORAGE_PROVIDER:-longhorn} == longhorn ]]; then validate_longhorn || true; else report Longhorn SKIP "$STORAGE_PROVIDER storage selected"; fi
    if kubectl_local -n kube-system get svc traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null | grep -q .; then report Traefik OK; else report Traefik WARN 'no external IP'; fi
  fi
  if [[ ${STORAGE_PROVIDER:-longhorn} == local-path ]]; then
    report open-iscsi SKIP 'Longhorn not selected'
    if kubectl_local -n kube-system get deploy local-path-provisioner >/dev/null 2>&1 && kubectl_local get storageclass local-path >/dev/null 2>&1; then
      report 'Persistent storage' OK 'K3s local-path provisioner is available'
    else
      report 'Persistent storage' FAIL 'K3s local-path provisioner or StorageClass is missing'
    fi
  elif [[ ${STORAGE_PROVIDER:-longhorn} != longhorn ]]; then
    report open-iscsi SKIP 'Longhorn not selected'
    report 'Persistent storage' SKIP 'externally managed; validate it with its own tooling'
  else
    if ! command -v iscsiadm >/dev/null 2>&1; then report open-iscsi MISSING 'package is not installed'; elif systemctl is-active --quiet iscsid; then report open-iscsi OK; else report open-iscsi FAIL 'installed service is inactive'; fi
    validate_storage_selection || true
    report 'Persistent storage' 'NOT TESTED' 'run tests/smoke-longhorn.sh explicitly'
  fi
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
  fi
  [[ ! -f $CONFIG_FILE ]] || warn "Configuration reconciliation requires desired values and explicit confirmation; no automatic cluster-identity changes are made."
  validate_cluster
}
