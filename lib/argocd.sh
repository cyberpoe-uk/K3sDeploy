#!/usr/bin/env bash

ARGOCD_NAMESPACE=argocd
ARGOCD_GUI_ADDRESS=

argocd_manifest_url(){
  printf 'https://raw.githubusercontent.com/argoproj/argo-cd/%s/manifests/ha/install.yaml\n' "$ARGO_CD_VERSION"
}

workload_records_ready(){
  local kind name desired ready seen=false
  while IFS='|' read -r kind name desired ready; do
    [[ -n $kind && -n $name ]] || continue
    seen=true
    desired=${desired:-1}
    ready=${ready:-0}
    [[ $desired =~ ^[0-9]+$ && $ready =~ ^[0-9]+$ ]] || return 1
    ((desired > 0 && ready == desired)) || return 1
  done
  $seen
}

argocd_workload_records(){
  kubectl_local -n "$ARGOCD_NAMESPACE" get deployment,statefulset \
    -l app.kubernetes.io/part-of=argocd \
    -o jsonpath='{range .items[*]}{.kind}{"|"}{.metadata.name}{"|"}{.spec.replicas}{"|"}{.status.readyReplicas}{"\n"}{end}' 2>/dev/null
}

argocd_installed(){
  kubectl_local get namespace "$ARGOCD_NAMESPACE" >/dev/null 2>&1 &&
    kubectl_local -n "$ARGOCD_NAMESPACE" get deployment argocd-server >/dev/null 2>&1
}

argocd_installation_ready(){
  local records
  argocd_installed || return 1
  kubectl_local -n "$ARGOCD_NAMESPACE" get statefulset argocd-application-controller >/dev/null 2>&1 || return 1
  kubectl_local -n "$ARGOCD_NAMESPACE" get statefulset argocd-redis-ha-server >/dev/null 2>&1 || return 1
  kubectl_local -n "$ARGOCD_NAMESPACE" get deployment argocd-redis-ha-haproxy >/dev/null 2>&1 || return 1
  records=$(argocd_workload_records)
  [[ -n $records ]] || return 1
  workload_records_ready <<<"$records"
}

argocd_installed_version(){
  local image
  image=$(kubectl_local -n "$ARGOCD_NAMESPACE" get deployment argocd-server \
    -o jsonpath='{.spec.template.spec.containers[?(@.name=="argocd-server")].image}' 2>/dev/null || true)
  printf '%s\n' "${image##*:}"
}

manager_counts_from_records(){
  awk -F '|' '
    NF { total++ }
    $2 == "True" { ready++ }
    END { printf "%d|%d\n", ready+0, total+0 }
  '
}

cluster_manager_counts(){
  local records
  records=$(kubectl_local get nodes -l node-role.kubernetes.io/control-plane \
    -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{range .status.conditions[?(@.type=="Ready")]}{.status}{end}{"\n"}{end}' \
    2>/dev/null) || return 1
  manager_counts_from_records <<<"$records"
}

require_argocd_cluster_readiness(){
  local counts ready total
  kubectl_local get --raw=/readyz >/dev/null 2>&1 || die 'The Kubernetes API is not ready. Argo CD installation was refused.'
  systemd_unit_exists k3s || die 'Run the Argo CD workflow on a manager with the administrative K3s kubeconfig.'
  counts=$(cluster_manager_counts) || die 'K3sDeploy could not inspect manager readiness.'
  IFS='|' read -r ready total <<<"$counts"
  ((total >= 3)) || die "Argo CD HA requires at least three managers. Detected $total. Join manager three, then retry option 9."
  ((ready == total)) || die "All managers must be Ready before Argo CD installation. Detected $ready Ready out of $total."
  ok "Argo CD HA prerequisite passed: $ready of $total managers are Ready"
}

wait_argocd_ready(){
  local end=$((SECONDS+900))
  $DRY_RUN && return 0
  info 'Waiting up to 15 minutes for all Argo CD HA workloads to become ready.'
  until argocd_installation_ready; do
    if ((SECONDS >= end)); then
      kubectl_local -n "$ARGOCD_NAMESPACE" get deployment,statefulset,pods -o wide 2>/dev/null || true
      die 'Argo CD did not become ready within 15 minutes. Review the workload status shown above.'
    fi
    sleep 5
  done
  ok "Argo CD $ARGO_CD_VERSION HA workloads are ready"
}

wait_argocd_gui_address(){
  local end=$((SECONDS+180))
  ARGOCD_GUI_ADDRESS=
  $DRY_RUN && {
    ARGOCD_GUI_ADDRESS='<MetalLB-address>'
    return 0
  }
  until ARGOCD_GUI_ADDRESS=$(kubectl_local -n "$ARGOCD_NAMESPACE" get service argocd-server \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null) && [[ -n $ARGOCD_GUI_ADDRESS ]]; do
    ((SECONDS < end)) || die 'MetalLB did not assign an address to the Argo CD GUI within three minutes.'
    sleep 3
  done
  ok "Argo CD GUI received MetalLB address $ARGOCD_GUI_ADDRESS"
}

show_argocd_access(){
  local address=${ARGOCD_GUI_ADDRESS:-}
  if [[ -z $address ]]; then
    address=$(kubectl_local -n "$ARGOCD_NAMESPACE" get service argocd-server \
      -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
  fi
  section 'Argo CD GUI access'
  if [[ -n $address ]]; then
    printf '  Address:  https://%s\n' "$address"
    printf '  Username: admin\n'
    printf '%s\n' \
      '  The first browser visit can show a certificate warning because Argo CD' \
      '  initially uses its own certificate. Do not expose this address to the internet.'
  else
    printf '%s\n' \
      '  No external GUI address is available yet.' \
      '  Inspect it with: sudo k3s kubectl get service argocd-server -n argocd'
  fi
  printf '%s\n' \
    '' \
    '  Retrieve the one-time administrator password with:' \
    "  sudo k3s kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}' | base64 --decode" \
    '' \
    '  Change that password after the first login. Connect the GitLab repository' \
    '  from Settings > Repositories using a read-only deploy token or deploy key.'
}

install_argocd(){
  local manifest
  manifest=$(argocd_manifest_url)
  if $DRY_RUN; then
    change "Would install the pinned Argo CD HA manifest from $manifest"
    change 'Would expose the argocd-server service through MetalLB'
    return 0
  fi
  if ! kubectl_local get namespace "$ARGOCD_NAMESPACE" >/dev/null 2>&1; then
    kubectl_local create namespace "$ARGOCD_NAMESPACE"
  fi
  kubectl_local apply --namespace "$ARGOCD_NAMESPACE" --server-side --force-conflicts --filename "$manifest"
  kubectl_local -n "$ARGOCD_NAMESPACE" patch service argocd-server \
    --type merge --patch '{"spec":{"type":"LoadBalancer"}}'
}

install_argocd_workflow(){
  local installed_version existing_address
  phase 1 5 'Checking cluster readiness for Argo CD HA'
  require_argocd_cluster_readiness
  [[ ${LOAD_BALANCER_MODE:-metallb} == metallb ]] || die 'The guided Argo CD GUI workflow currently requires the managed MetalLB profile.'

  installed_version=$(argocd_installed_version)
  existing_address=$(kubectl_local -n "$ARGOCD_NAMESPACE" get service argocd-server \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
  if argocd_installation_ready && [[ $installed_version == "$ARGO_CD_VERSION" && -n $existing_address ]]; then
    ARGOCD_GUI_ADDRESS=$existing_address
    ok "Argo CD $installed_version is already installed and ready"
    validate_cluster
    require_healthy_installation
    show_argocd_access
    return 0
  fi

  phase 2 5 'Reviewing the Argo CD platform plan'
  section 'Argo CD installation plan'
  printf '%s\n' \
    "  Version:       $ARGO_CD_VERSION" \
    '  Topology:      official high-availability manifest' \
    '  Namespace:     argocd' \
    '  GUI exposure:  private MetalLB LoadBalancer address' \
    '  GitLab access: configured by you after the first login' \
    '' \
    '  K3sDeploy will not create a GitLab repository or store GitLab credentials.' \
    '  Applying the pinned manifest is repeatable and does not remove Applications.'
  if argocd_installed; then
    warn "An incomplete, unexposed, or different Argo CD installation was detected: ${installed_version:-version unknown}."
    confirm 'Reconcile it to the pinned K3sDeploy HA release?' || {
      skip 'Argo CD reconciliation was cancelled'
      return 0
    }
  else
    confirm 'Install Argo CD HA and its GUI now?' || {
      skip 'Argo CD installation was cancelled'
      return 0
    }
  fi

  phase 3 5 'Installing the pinned Argo CD HA release'
  install_argocd

  phase 4 5 'Waiting for Argo CD and its GUI address'
  wait_argocd_ready
  wait_argocd_gui_address

  phase 5 5 'Validating Argo CD and showing access details'
  if ! $DRY_RUN; then
    argocd_installation_ready || die 'Argo CD installation finished applying but is not healthy.'
    validate_cluster
    require_healthy_installation
    create_milestone_etcd_snapshot argocd-ready
  fi
  show_argocd_access
}

offer_argocd_after_manager_join(){
  local counts ready total
  [[ ${INSTALL_PROFILE:-recommended} == recommended ]] || return 0
  argocd_installed && return 0
  counts=$(cluster_manager_counts 2>/dev/null || true)
  IFS='|' read -r ready total <<<"${counts:-0|0}"
  if ((total >= 3 && ready == total)); then
    section 'Optional GitOps deployment GUI'
    printf '%s\n' \
      "  All $ready managers are Ready. The cluster can now run the Argo CD HA profile." \
      '  Argo CD provides the web interface for deploying services from GitLab.'
    if confirm_yes 'Install Argo CD HA now?'; then
      install_argocd_workflow
    else
      skip 'Argo CD was not installed. Choose option 9 whenever you are ready.'
    fi
  fi
}

validate_argocd(){
  local version address
  if ! argocd_installed; then
    report 'Argo CD' MISSING 'optional GitOps GUI, install with option 9 after three managers are Ready'
    return 0
  fi
  version=$(argocd_installed_version)
  if ! argocd_installation_ready; then
    report 'Argo CD' FAIL "${version:-version unknown}, one or more HA workloads are not ready"
    return 1
  fi
  address=$(kubectl_local -n "$ARGOCD_NAMESPACE" get service argocd-server \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
  if [[ -n $address ]]; then
    if [[ $version == "$ARGO_CD_VERSION" ]]; then
      report 'Argo CD' OK "$version, GUI https://$address"
    else
      report 'Argo CD' WARN "${version:-version unknown}, pinned release is $ARGO_CD_VERSION, GUI https://$address"
    fi
  else
    report 'Argo CD' WARN "${version:-version unknown}, workloads ready but the GUI has no external address"
  fi
}
