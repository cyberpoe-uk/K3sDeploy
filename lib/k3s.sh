#!/usr/bin/env bash
render_k3s_config(){
  local mode=$1 token=${2:-} component disable_components= snapshot_settings=
  local -a disabled=()
  [[ ${LOAD_BALANCER_MODE:-metallb} == servicelb ]] || disabled+=(servicelb)
  [[ ${STORAGE_PROVIDER:-longhorn} == local-path ]] || disabled+=(local-storage)
  if ((${#disabled[@]})); then
    disable_components=disable:
    for component in "${disabled[@]}"; do disable_components+=$'\n  - '"$component"; done
  fi
  if [[ $mode != agent ]]; then
    snapshot_settings=$(cat <<EOF
etcd-snapshot-compress: ${ETCD_SNAPSHOT_COMPRESS:-true}
etcd-snapshot-retention: ${ETCD_SNAPSHOT_RETENTION:-5}
etcd-snapshot-schedule-cron: "${ETCD_SNAPSHOT_SCHEDULE_CRON:-0 */12 * * *}"
EOF
)
  fi
  if [[ $mode == first ]]; then cat <<EOF
cluster-init: true
node-ip: $NODE_IP
advertise-address: $NODE_IP
tls-san:
  - $API_VIP
$snapshot_settings
$disable_components
EOF
elif [[ $mode == join ]]; then cat <<EOF
server: https://$API_VIP:6443
token: "$token"
node-ip: $NODE_IP
advertise-address: $NODE_IP
tls-san:
  - $API_VIP
$snapshot_settings
$disable_components
EOF
else cat <<EOF
server: https://$API_VIP:6443
token: "$token"
node-ip: $NODE_IP
EOF
fi
}
install_k3s(){ local cfg=$1 role=${2:-server} service=k3s changed=false; [[ $role == agent ]] && service=k3s-agent; write_root_file "$CONFIG_FILE" 600 "$cfg" && changed=true || true
  if ! command -v k3s >/dev/null; then
    $DRY_RUN && { change "Would install K3s $K3S_VERSION"; return; }
    info "Installing pinned K3s $K3S_VERSION"
    local installer; installer=$(mktemp)
    curl -sfL https://get.k3s.io -o "$installer"
    chmod 700 "$installer"
    as_root env INSTALL_K3S_VERSION="$K3S_VERSION" INSTALL_K3S_EXEC="$role" sh "$installer"
    rm -f "$installer"
  elif $changed; then as_root systemctl restart "$service"; else skip "K3s already installed. No reinstall/restart"; fi
}
wait_k3s(){ $DRY_RUN && return; local end=$((SECONDS+300)); until as_root k3s kubectl get --raw=/readyz >/dev/null 2>&1; do ((SECONDS<end)) || die "K3s API did not become ready within 300s"; sleep 5; done; ok "K3s API is ready"; }
wait_local_node(){ $DRY_RUN && return; local node=${DESIRED_HOSTNAME:-$(short_hostname)} end=$((SECONDS+600)); until as_root k3s kubectl get node "$node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -qx True; do ((SECONDS<end)) || die "Node $node did not become Ready within 600s"; sleep 5; done; local labels; labels=$(as_root k3s kubectl get node "$node" --show-labels --no-headers); grep -q 'node-role.kubernetes.io/control-plane' <<<"$labels" || die "Node lacks control-plane role"; grep -q 'node-role.kubernetes.io/etcd' <<<"$labels" || die "Node lacks etcd role"; ok "Node is Ready with control-plane and etcd roles"; }
wait_agent_node(){ $DRY_RUN && return; local node=${DESIRED_HOSTNAME:-$(short_hostname)} end=$((SECONDS+600)); until systemctl is-active --quiet k3s-agent; do ((SECONDS<end)) || die "k3s-agent did not become active within 600s"; sleep 5; done; until kubectl_local get node "$node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -qx True; do ((SECONDS<end)) || die "The agent is running, but Kubernetes did not report node $node Ready within 600s"; sleep 5; done; ok "Agent node is registered and Ready"; }
