#!/usr/bin/env bash

wait_metallb_webhook(){
  $DRY_RUN && return 0
  local end=$((SECONDS+300)) address
  until address=$(kubectl_local -n metallb-system get endpoints metallb-webhook-service -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null) && [[ -n $address ]]; do
    ((SECONDS < end)) || die 'MetalLB webhook did not publish a ready endpoint within 300 seconds'
    sleep 5
  done
  ok "MetalLB webhook endpoint is ready at $address"
}

apply_metallb_config(){
  local cfg=$1 attempt output=
  for attempt in {1..12}; do
    if output=$(printf '%s' "$cfg" | kubectl_local apply -f - 2>&1); then
      printf '%s\n' "$output"
      return 0
    fi
    warn "MetalLB webhook rejected the configuration while starting (attempt $attempt/12); retrying in 5 seconds."
    sleep 5
  done
  error "$output"
  die 'MetalLB configuration was not accepted after 12 attempts'
}

install_metallb(){
  local cfg
  kubectl_local apply -f "https://raw.githubusercontent.com/metallb/metallb/$METALLB_VERSION/config/manifests/metallb-native.yaml"
  kubectl_local -n metallb-system rollout status deploy/controller --timeout=300s
  kubectl_local -n metallb-system rollout status daemonset/speaker --timeout=300s
  wait_metallb_webhook
  cfg=$(sed -e "s/__POOL_START__/$POOL_START/g" -e "s/__POOL_END__/$POOL_END/g" "$PROJECT_ROOT/templates/metallb/pool.yaml")
  apply_metallb_config "$cfg"
}

validate_metallb(){
  if kubectl_local -n metallb-system get deploy controller >/dev/null 2>&1; then ok 'MetalLB controller exists'; else warn 'MetalLB controller missing'; fi
  if kubectl_local -n metallb-system get ds speaker >/dev/null 2>&1; then ok 'MetalLB speaker exists'; else warn 'MetalLB speaker missing'; fi
}
