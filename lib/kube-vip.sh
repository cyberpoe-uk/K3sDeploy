#!/usr/bin/env bash
kube_vip_status(){ kubectl_local -n kube-system get ds kube-vip -o jsonpath='{.status.desiredNumberScheduled}/{.status.numberReady}/{.status.numberAvailable}' 2>/dev/null; }
kube_vip_ready(){
  local ds desired ready available
  ds=$(kube_vip_status) || return 1
  IFS=/ read -r desired ready available <<<"$ds"
  [[ $desired =~ ^[1-9][0-9]*$ && $desired == "$ready" && $ready == "$available" ]]
}
wait_kube_vip(){
  $DRY_RUN && return 0
  local end=$((SECONDS+300))
  until kubectl_local -n kube-system get ds kube-vip >/dev/null 2>&1; do
    ((SECONDS < end)) || die 'kube-vip DaemonSet did not appear within 300 seconds'
    sleep 5
  done
  if ! kubectl_local -n kube-system rollout status daemonset/kube-vip --timeout=300s; then
    kubectl_local -n kube-system get pods -l app=kube-vip -o wide || true
    die 'kube-vip did not become ready. Review the pod status and logs shown above.'
  fi
  kube_vip_ready || die "kube-vip rollout completed but its status is $(kube_vip_status || printf 'unavailable')"
  ok "kube-vip is ready ($(kube_vip_status))"
}
install_kube_vip(){
  local manifest="$PROJECT_ROOT/templates/kube-vip/kube-vip.yaml" rendered
  rendered=$(sed -e "s/__VIP__/$API_VIP/g" -e "s/__VERSION__/$KUBE_VIP_VERSION/g" "$manifest")
  write_root_file /var/lib/rancher/k3s/server/manifests/kube-vip.yaml 600 "$rendered" || true
  wait_kube_vip
}
validate_kube_vip(){
  local ds
  if ! ds=$(kube_vip_status); then report kube-vip FAIL 'DaemonSet not found'; return 1; fi
  if kube_vip_ready; then report kube-vip OK "desired/ready/available: $ds"; else report kube-vip FAIL "desired/ready/available: $ds"; return 1; fi
}
check_kube_vip_interface(){ local configured; configured=$(kubectl_local -n kube-system get ds kube-vip -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="vip_interface")].value}' 2>/dev/null || true); if [[ -n $configured && $configured != "$PRIMARY_IFACE" ]]; then warn "Existing kube-vip pins interface '$configured', but this node uses '$PRIMARY_IFACE'. Reconcile the DaemonSet before declaring this node healthy."; return 1; fi; }
