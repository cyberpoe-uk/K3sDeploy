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
validate_cluster(){
  printf '\nHealth report\n'; check OS grep -qi ubuntu /etc/os-release || true; check Network ip route get 1.1.1.1 || true
  if systemctl is-active --quiet k3s || systemctl is-active --quiet k3s-agent; then report 'K3s service' OK; else report 'K3s service' FAIL; fi
  if command -v k3s >/dev/null; then
    local node=${DESIRED_HOSTNAME:-$(short_hostname)} labels
    check 'Kubernetes API' kubectl_local get --raw=/readyz || true
    if [[ $(kubectl_local get node "$node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null) == True ]]; then report 'Node Ready' OK; else report 'Node Ready' FAIL; fi
    labels=$(kubectl_local get node "$node" --show-labels --no-headers 2>/dev/null || true)
    if grep -q control-plane <<<"$labels"; then report 'Control-plane role' OK; elif [[ ${NODE_ROLE:-server} == agent ]]; then report 'Control-plane role' SKIP 'worker node'; else report 'Control-plane role' FAIL; fi
    if grep -q 'node-role.kubernetes.io/etcd' <<<"$labels"; then report 'etcd role' OK; elif [[ ${NODE_ROLE:-server} == agent ]]; then report 'etcd role' SKIP 'worker node'; else report 'etcd role' FAIL; fi
    if ! kubectl_local -n kube-system get ds svclb-traefik >/dev/null 2>&1; then report 'ServiceLB disabled' OK; else report 'ServiceLB disabled' FAIL; fi
    validate_kube_vip || true; validate_metallb || true; validate_longhorn || true
    if kubectl_local -n kube-system get svc traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null | grep -q .; then report Traefik OK; else report Traefik WARN 'no external IP'; fi
  fi
  if command -v iscsiadm >/dev/null && systemctl is-active --quiet iscsid; then report open-iscsi OK; else report open-iscsi FAIL; fi
  validate_storage_selection || true
  report 'Persistent storage' 'NOT TESTED' 'run tests/smoke-longhorn.sh explicitly'
}
safe_repair(){
  info "Repair mode only offers non-destructive actions"
  local service=k3s; [[ ${NODE_ROLE:-server} == agent ]] && service=k3s-agent
  systemctl is-active --quiet "$service" 2>/dev/null || { confirm "Start inactive $service service?" && as_root systemctl start "$service"; }
  command -v iscsiadm >/dev/null || { confirm 'Install missing open-iscsi?' && ensure_iscsi; }
  systemctl is-active --quiet iscsid 2>/dev/null || { confirm 'Enable/start iscsid?' && as_root systemctl enable --now iscsid; }
  [[ ! -f $CONFIG_FILE ]] || warn "Configuration reconciliation requires desired values and explicit confirmation; no automatic cluster-identity changes are made."
  validate_cluster
}
