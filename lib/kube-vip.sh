#!/usr/bin/env bash
kube_vip_status(){ kubectl_local -n kube-system get ds kube-vip -o jsonpath='{.status.desiredNumberScheduled}/{.status.numberReady}/{.status.numberAvailable}' 2>/dev/null; }
kube_vip_ready(){
  local ds desired ready available
  ds=$(kube_vip_status) || return 1
  IFS=/ read -r desired ready available <<<"$ds"
  [[ $desired =~ ^[1-9][0-9]*$ && $desired == "$ready" && $ready == "$available" ]]
}
kube_vip_template_is_current(){
  local image address obsolete_mount
  image=$(kubectl_local -n kube-system get ds kube-vip -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null) || return 1
  address=$(kubectl_local -n kube-system get ds kube-vip -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="address")].value}' 2>/dev/null) || return 1
  obsolete_mount=$(kubectl_local -n kube-system get ds kube-vip -o jsonpath='{.spec.template.spec.containers[0].volumeMounts[?(@.name=="proc-net")].mountPath}' 2>/dev/null || true)
  [[ $image == "ghcr.io/kube-vip/kube-vip:$KUBE_VIP_VERSION" && $address == "$API_VIP" && -z $obsolete_mount ]]
}
kube_vip_failure_is_terminal(){
  local waiting=${1:-} last_reason=${2:-} restarts=${3:-0}
  case $waiting in
    CreateContainerConfigError|CreateContainerError) return 0;;
  esac
  [[ $last_reason == StartError ]] && return 0
  [[ $waiting == CrashLoopBackOff && $restarts =~ ^[0-9]+$ && $restarts -ge 5 ]]
}
kube_vip_terminal_failures(){
  local generation records pod waiting last_reason exit_code restarts message found=false
  generation=$(kubectl_local -n kube-system get ds kube-vip -o jsonpath='{.metadata.generation}' 2>/dev/null) || return 1
  records=$(kubectl_local -n kube-system get pods -l "app=kube-vip,pod-template-generation=$generation" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.status.containerStatuses[0].state.waiting.reason}{"|"}{.status.containerStatuses[0].lastState.terminated.reason}{"|"}{.status.containerStatuses[0].lastState.terminated.exitCode}{"|"}{.status.containerStatuses[0].restartCount}{"|"}{.status.containerStatuses[0].lastState.terminated.message}{"\n"}{end}' 2>/dev/null) || return 1
  while IFS='|' read -r pod waiting last_reason exit_code restarts message; do
    [[ -n $pod ]] || continue
    if kube_vip_failure_is_terminal "$waiting" "$last_reason" "$restarts"; then
      printf 'pod=%s waiting=%s lastReason=%s exitCode=%s restarts=%s\n' "$pod" "${waiting:-none}" "${last_reason:-none}" "${exit_code:-unknown}" "${restarts:-0}"
      [[ -z $message ]] || printf 'message=%s\n' "$message"
      found=true
    fi
  done <<<"$records"
  $found
}
kube_vip_diagnostics(){
  local generation pods pod
  warn 'kube-vip startup diagnostics follow.'
  kubectl_local -n kube-system get daemonset kube-vip \
    -o custom-columns='NAME:.metadata.name,GENERATION:.metadata.generation,OBSERVED:.status.observedGeneration,DESIRED:.status.desiredNumberScheduled,UPDATED:.status.updatedNumberScheduled,READY:.status.numberReady,AVAILABLE:.status.numberAvailable' || true
  kubectl_local -n kube-system get pods -l app=kube-vip -o wide || true
  generation=$(kubectl_local -n kube-system get ds kube-vip -o jsonpath='{.metadata.generation}' 2>/dev/null || true)
  [[ -n $generation ]] || return 0
  pods=$(kubectl_local -n kube-system get pods -l "app=kube-vip,pod-template-generation=$generation" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)
  while read -r pod; do
    [[ -n $pod ]] || continue
    printf '\nTermination details for %s:\n' "$pod"
    kubectl_local -n kube-system get pod "$pod" \
      -o jsonpath='waiting={.status.containerStatuses[0].state.waiting.reason}{"\n"}lastReason={.status.containerStatuses[0].lastState.terminated.reason}{"\n"}exitCode={.status.containerStatuses[0].lastState.terminated.exitCode}{"\n"}restarts={.status.containerStatuses[0].restartCount}{"\n"}message={.status.containerStatuses[0].lastState.terminated.message}{"\n"}' || true
    printf '\nCurrent container log (up to 100 lines):\n'
    kubectl_local -n kube-system logs "$pod" --tail=100 || true
    printf '\nPrevious container log (up to 100 lines):\n'
    kubectl_local -n kube-system logs "$pod" --previous --tail=100 || true
    printf '\nRecent pod events:\n'
    kubectl_local -n kube-system get events --field-selector "involvedObject.name=$pod" --sort-by=.lastTimestamp || true
  done <<<"$pods"
}
wait_kube_vip(){
  $DRY_RUN && return 0
  local end=$((SECONDS+300)) template_end=$((SECONDS+90)) next_update=$((SECONDS+30)) failures status
  until kubectl_local -n kube-system get ds kube-vip >/dev/null 2>&1; do
    ((SECONDS < end)) || die 'kube-vip DaemonSet did not appear within 300 seconds'
    sleep 5
  done
  info 'Waiting up to 90 seconds for K3s to apply the current kube-vip template.'
  until kube_vip_template_is_current; do
    if ((SECONDS >= template_end)); then
      kube_vip_diagnostics
      die 'K3s did not apply the current kube-vip template within 90 seconds.'
    fi
    sleep 3
  done
  info 'The current kube-vip template is applied. Waiting up to five minutes for all manager pods to become ready.'
  while ((SECONDS < end)); do
    if kube_vip_ready; then
      ok "kube-vip is ready ($(kube_vip_status))"
      return 0
    fi
    failures=$(kube_vip_terminal_failures || true)
    if [[ -n $failures ]]; then
      error 'kube-vip has a terminal container startup failure:'
      printf '%s\n' "$failures"
      kube_vip_diagnostics
      die 'kube-vip cannot become ready until the startup error shown above is corrected.'
    fi
    if ((SECONDS >= next_update)); then
      status=$(kube_vip_status || printf 'unavailable')
      info "Still waiting for kube-vip (desired/ready/available: $status)"
      next_update=$((SECONDS+30))
    fi
    sleep 5
  done
  kube_vip_diagnostics
  die 'kube-vip did not become ready within five minutes. Review the diagnostics shown above.'
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
