#!/usr/bin/env bash
preflight_collect(){
  OS_NAME=$(awk -F= '/^PRETTY_NAME=/{gsub(/"/,"",$2);print $2}' /etc/os-release 2>/dev/null || echo unknown)
  HOST_NOW=$(short_hostname)
  PRIMARY_IFACE=$(detect_interface || true)
  DETECTED_IP=$(detect_node_ip "$PRIMARY_IFACE" || true)
  DEFAULT_ROUTE=$(ip route show default 2>/dev/null | head -1 || true)
  DISK_FREE=$(df -h / | awk 'NR==2{print $4}'); K3S_INSTALLED=no; command -v k3s >/dev/null && K3S_INSTALLED=yes
  CPU_COUNT=$(nproc 2>/dev/null || echo 0)
  RAM_GIB=$(awk '/^MemTotal:/{printf "%d", $2/1048576}' /proc/meminfo)
  KERNEL_VERSION=$(uname -r)
  ROOT_FILESYSTEM=$(findmnt -no FSTYPE / 2>/dev/null || echo unknown)
  SWAP_STATUS=disabled; swapon --noheadings --show 2>/dev/null | grep -q . && SWAP_STATUS=enabled
  ISCSI_INSTALLED=no; command -v iscsiadm >/dev/null && ISCSI_INSTALLED=yes
  TIME_SYNC=unknown; command -v timedatectl >/dev/null && TIME_SYNC=$(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo unknown)
}
basic_host_sanity(){
  [[ $OS_NAME == *Ubuntu* ]] || die "This release supports Ubuntu Server only; detected: $OS_NAME"
  [[ $(uname -m) == x86_64 || $(uname -m) == aarch64 || $(uname -m) == arm64 ]] || die "Unsupported CPU architecture: $(uname -m)"
  need_cmd ip; need_cmd systemctl; need_cmd curl
}
preflight_show(){ cat <<EOF

Preflight summary
  Hostname:          $HOST_NOW
  Node IP:           ${NODE_IP:-$DETECTED_IP}
  Interface:         $PRIMARY_IFACE
  Default route:     $DEFAULT_ROUTE
  OS:                $OS_NAME
  Architecture:      $(uname -m)
  CPU / RAM:         $CPU_COUNT CPUs / $RAM_GIB GiB
  Kernel:            $KERNEL_VERSION
  Root filesystem:   $ROOT_FILESYSTEM
  Swap:              $SWAP_STATUS
  Root free space:   $DISK_FREE
  Time synchronized: $TIME_SYNC
  K3s installed:     $K3S_INSTALLED
  open-iscsi:        $ISCSI_INSTALLED
  Target role:       ${TARGET_ROLE:-control-plane + etcd + schedulable worker}
  API VIP:           ${API_VIP:-not selected}
EOF
  need_cmd curl; need_cmd ip; need_cmd systemctl
  basic_host_sanity
  [[ -n $PRIMARY_IFACE && -n ${NODE_IP:-$DETECTED_IP} ]] || die "Could not detect the primary IPv4 interface/address"
  local_ipv4_present "${NODE_IP:-$DETECTED_IP}" || die "The selected node IP ${NODE_IP:-$DETECTED_IP} is not configured on a local interface"
  if ((CPU_COUNT<MIN_RECOMMENDED_CPU || RAM_GIB<MIN_RECOMMENDED_RAM_GIB)); then
    warn "Longhorn V1 recommends at least $MIN_RECOMMENDED_CPU CPUs and $MIN_RECOMMENDED_RAM_GIB GiB RAM per storage node."
    confirm "Continue with this smaller machine anyway?" || die "Hardware prerequisite confirmation declined"
  fi
  getent hosts github.com >/dev/null 2>&1 || warn "DNS/internet check failed; installation downloads will fail"
  curl -fsI --max-time 5 https://get.k3s.io >/dev/null 2>&1 || warn "HTTPS connectivity to get.k3s.io could not be confirmed"
  [[ $TIME_SYNC == yes ]] || warn "System clock is not confirmed synchronized"
  [[ $SWAP_STATUS == disabled ]] || warn "Swap is enabled. Monitor memory pressure and confirm your Kubernetes swap policy before production use."
}
announce_existing_k3s(){
  local server_state=not-installed agent_state=not-installed config_state=not-detected
  systemctl list-unit-files --no-legend k3s.service 2>/dev/null | grep -q '^k3s.service' && server_state=$(systemctl is-active k3s 2>/dev/null || true)
  systemctl list-unit-files --no-legend k3s-agent.service 2>/dev/null | grep -q '^k3s-agent.service' && agent_state=$(systemctl is-active k3s-agent 2>/dev/null || true)
  [[ -e $CONFIG_FILE ]] && config_state=present
  if [[ $K3S_INSTALLED == yes || $server_state != not-installed || $agent_state != not-installed || $config_state == present ]]; then
    warn "K3s was detected on this machine. New-cluster and fresh-join operations will be blocked to protect it."
    info "Detected state: binary=$K3S_INSTALLED, config=$config_state, k3s=$server_state, k3s-agent=$agent_state"
    info "Choose validation, safe repair, or worker promotion as appropriate."
  else
    ok "No existing K3s installation was detected"
  fi
}
detect_existing(){
  export LONGHORN_DATA_PRESENT=no
  [[ -f $CONFIG_FILE ]] && warn "Existing K3s configuration detected: $CONFIG_FILE"
  if [[ -d /var/lib/longhorn ]] && [[ -n $(as_root_capture find /var/lib/longhorn -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null) ]]; then LONGHORN_DATA_PRESENT=yes; warn "Existing Longhorn data detected; it will not be removed"; fi
  findmnt -rn /var/lib/longhorn >/dev/null 2>&1 && info "Existing Longhorn mount: $(findmnt -rn -o SOURCE,FSTYPE,TARGET /var/lib/longhorn)"
}
