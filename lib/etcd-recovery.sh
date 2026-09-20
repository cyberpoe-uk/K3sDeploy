#!/usr/bin/env bash

ETCD_RECOVERY_BACKUP=
ETCD_RECOVERY_CONFIG_BACKUP=
ETCD_RECOVERY_REMOVED_NODES=
ETCD_RECOVERY_CORE_SUCCEEDED=false
ETCD_RECOVERY_RESUME_ONLY=false
ETCD_RECOVERY_SERVICE_STOPPED=false
readonly ETCD_RECOVERY_TRANSITION_RC=77

etcd_quorum_log_evidence(){
  grep -Eiq \
    'failed to publish local member to cluster through raft|failed to check local etcd status.*context deadline exceeded|failed to test etcd connection.*context deadline exceeded|etcdserver.*(no leader|request timed out)|rafthttp.*(failed|unhealthy)|etcd.*quorum'
}

filter_etcd_quorum_log_evidence(){
  grep -Ei \
    'failed to publish local member to cluster through raft|failed to check local etcd status.*context deadline exceeded|failed to test etcd connection.*context deadline exceeded|etcdserver.*(no leader|request timed out)|rafthttp.*(failed|unhealthy)|etcd.*quorum' || true
}

lost_etcd_quorum_detected(){
  local journal service_state
  systemd_unit_exists k3s || return 1
  as_root_capture test -d /var/lib/rancher/k3s/server/db/etcd/member || return 1
  as_root_capture k3s kubectl get --raw=/readyz >/dev/null 2>&1 && return 1
  service_state=$(systemctl is-active k3s 2>/dev/null || true)
  [[ $service_state == active || $service_state == activating || $service_state == failed || $service_state == inactive ]] || return 1
  journal=$(as_root_capture journalctl -u k3s -b -n 500 --no-pager 2>/dev/null || true)
  etcd_quorum_log_evidence <<<"$journal"
}

offer_etcd_quorum_recovery(){
  local already_detected=${1:-false}
  if [[ $already_detected != true ]] && ! lost_etcd_quorum_detected; then
    return 1
  fi
  section 'Recommended next action'
  error 'This manager has strong signs of lost embedded-etcd quorum.'
  warn 'Cluster add-on failures above may be consequences of the unavailable Kubernetes API. They do not prove that those add-ons or their data were deleted.'
  info 'Ordinary safe repair cannot change etcd membership. Guarded option 7 is the appropriate recovery path.'
  if confirm_yes 'Continue directly to option 7 now?'; then
    info 'Starting the separate guarded quorum-recovery workflow. Its checks and exact confirmation still apply.'
    return 0
  fi
  info 'Quorum recovery was not started. Validation made no system or cluster changes.'
  return 1
}

render_single_member_recovery_config(){
  awk '
    BEGIN { print "cluster-init: true" }
    /^(server|token|cluster-init)(\+)?:[[:space:]]*/ { next }
    { print }
  '
}

etcd_recovery_backup_space_sufficient(){
  local estimated_bytes=$1 available_bytes=$2 reserve_bytes=$((100 * 1024 * 1024))
  ((available_bytes >= estimated_bytes + reserve_bytes))
}

check_etcd_recovery_backup_space(){
  local candidate estimated_bytes available_bytes required_bytes
  local -a paths=()
  for candidate in \
    /etc/rancher/k3s \
    /etc/k3s-bootstrap \
    /var/lib/rancher/k3s/server/db \
    /var/lib/rancher/k3s/server/token; do
    as_root_capture test -e "$candidate" && paths+=("$candidate")
  done
  ((${#paths[@]} > 0)) || die 'No protected K3s state was found to estimate the recovery backup.'
  estimated_bytes=$(as_root_capture du -sb -- "${paths[@]}" 2>/dev/null | awk '{total += $1} END {print total + 0}')
  available_bytes=$(df -B1 --output=avail /var/lib/rancher/k3s/server 2>/dev/null | awk 'NR==2 {print $1}')
  [[ $estimated_bytes =~ ^[0-9]+$ && $available_bytes =~ ^[0-9]+$ ]] || die 'Could not verify free space for the protected recovery backup.'
  required_bytes=$((estimated_bytes + 100 * 1024 * 1024))
  etcd_recovery_backup_space_sufficient "$estimated_bytes" "$available_bytes" || die "The recovery backup needs at least $((required_bytes / 1024 / 1024)) MiB free, but only $((available_bytes / 1024 / 1024)) MiB is available."
  info "Recovery backup space check passed: approximately $((estimated_bytes / 1024 / 1024)) MiB of state and $((available_bytes / 1024 / 1024)) MiB free"
}

etcd_recovery_dropin_join_keys(){
  local file files=
  [[ -d /etc/rancher/k3s/config.yaml.d ]] || return 1
  files=$(as_root_capture find /etc/rancher/k3s/config.yaml.d -maxdepth 1 -type f \( -name '*.yaml' -o -name '*.yml' \) -print 2>/dev/null || true)
  while IFS= read -r file; do
    [[ -n $file ]] || continue
    if as_root_capture grep -Eq '^(server|token|cluster-init|datastore-endpoint)(\+)?:[[:space:]]*' "$file"; then
      printf '%s\n' "$file"
      return 0
    fi
  done <<<"$files"
  return 1
}

collect_etcd_recovery_evidence(){
  local journal
  journal=$(as_root_capture journalctl -u k3s -b -n 500 --no-pager 2>/dev/null || true)
  if ! etcd_quorum_log_evidence <<<"$journal"; then
    warn 'The API is unavailable, but recent K3s logs do not prove an embedded-etcd quorum failure.'
    printf '\nRecent etcd-related K3s messages:\n\n'
    grep -Ei 'etcd|raft|quorum|leader|deadline|timeout' <<<"$journal" | tail -n 30 || true
    die 'Automatic quorum recovery was refused. Diagnose the service, networking, disk, and time synchronization before considering a cluster reset.'
  fi
  ok 'Recent K3s logs contain strong evidence of lost embedded-etcd quorum'
  printf '\nMatched evidence (up to 12 recent lines):\n\n'
  filter_etcd_quorum_log_evidence <<<"$journal" | tail -n 12
}

check_etcd_recovery_eligibility(){
  local service_state dropin
  ETCD_RECOVERY_RESUME_ONLY=false
  command -v k3s >/dev/null 2>&1 || die 'The K3s binary is missing. This recovery is only for an installed manager.'
  systemd_unit_exists k3s || die 'The k3s server service is not installed. Worker nodes cannot use embedded-etcd quorum recovery.'
  if systemd_unit_exists k3s-agent && ! systemd_unit_exists k3s; then
    die 'This is a worker-only node. Workers are not embedded-etcd members.'
  fi
  as_root_capture test -d /var/lib/rancher/k3s/server/db/etcd/member || die 'No local embedded-etcd member data was found. K3sDeploy will not create or reset a datastore here.'
  as_root_capture test -f "$CONFIG_FILE" || die "The K3s server configuration is missing at $CONFIG_FILE. Automatic recovery was refused."
  as_root_capture test -f "$STATE_FILE" || die "K3sDeploy state is missing at $STATE_FILE. Automatic recovery cannot confirm the installer-managed cluster design."
  if as_root_capture grep -Eq '^datastore-endpoint(\+)?:[[:space:]]*' "$CONFIG_FILE"; then
    die 'The K3s configuration selects an external datastore. Embedded-etcd recovery is not applicable.'
  fi

  if as_root_capture k3s kubectl get --raw=/readyz >/dev/null 2>&1; then
    die 'The Kubernetes API is ready. Lost-quorum disaster recovery is not required and no reset was attempted.'
  fi

  if as_root_capture test -e /var/lib/rancher/k3s/server/db/reset-flag; then
    ETCD_RECOVERY_RESUME_ONLY=true
    warn 'K3s has a cluster-reset completion flag. The datastore must not be reset a second time.'
    info 'K3sDeploy will only start the normal k3s service and verify the completed reset.'
    return 0
  fi

  service_state=$(systemctl is-active k3s 2>/dev/null || true)
  case $service_state in
    active|activating|failed|inactive) ;;
    *) die "The k3s service state is '$service_state', not a supported lost-quorum pattern. Use validation and ordinary repair first.";;
  esac
  if dropin=$(etcd_recovery_dropin_join_keys); then
    die "A K3s config drop-in contains a server, token, cluster-init, or datastore-endpoint key: $dropin. Automatic recovery cannot safely determine precedence."
  fi
  check_etcd_recovery_backup_space
  collect_etcd_recovery_evidence
}

show_etcd_recovery_warning(){
  local node=$1
  section 'Embedded-etcd quorum disaster recovery'
  printf '%s\n' \
    '  This is not an ordinary repair. It changes embedded-etcd membership.' \
    "  This manager ($node) will become the only etcd member and source of truth." \
    '  All other manager machines must be powered off or permanently isolated.' \
    '  An old manager database must never reconnect after this reset.' \
    '  Other managers must return from a clean pre-join state, or have their local' \
    '  /var/lib/rancher/k3s/server/db directory cleared before they join again.' \
    '  Worker nodes are not etcd members and are not reset by this workflow.' \
    '  K3sDeploy will remove stale Kubernetes Node objects only for other managers.' \
    '  Longhorn node and replica records are preserved for separate data review.'
}

confirm_etcd_recovery(){
  local node=$1 response expected
  expected="RESET ETCD TO $node"
  read -r -p "Type '$expected' to continue: " response
  [[ $response == "$expected" ]]
}

confirm_etcd_recovery_resume(){
  local node=$1 response expected
  expected="RESUME ETCD ON $node"
  read -r -p "Type '$expected' to start K3s without repeating the reset: " response
  [[ $response == "$expected" ]]
}

backup_etcd_recovery_state(){
  local stamp directory candidate
  local -a paths=()
  stamp=$(date +%Y%m%d-%H%M%S)
  directory=/var/lib/rancher/k3s/server/etcd-recovery
  ETCD_RECOVERY_BACKUP="$directory/pre-quorum-reset-$stamp.tar.gz"
  ETCD_RECOVERY_CONFIG_BACKUP="$directory/config.yaml.before-reset-$stamp"
  as_root install -d -o root -g root -m 700 "$directory"
  for candidate in \
    etc/rancher/k3s \
    etc/k3s-bootstrap \
    var/lib/rancher/k3s/server/db \
    var/lib/rancher/k3s/server/token; do
    as_root_capture test -e "/$candidate" && paths+=("$candidate")
  done
  ((${#paths[@]} > 0)) || die 'No protected K3s state was available to back up. The reset was not attempted.'
  as_root tar -C / -czf "$ETCD_RECOVERY_BACKUP" "${paths[@]}"
  as_root chmod 600 "$ETCD_RECOVERY_BACKUP"
  as_root tar -tzf "$ETCD_RECOVERY_BACKUP" >/dev/null
  as_root cp -a -- "$CONFIG_FILE" "$ETCD_RECOVERY_CONFIG_BACKUP"
  as_root chmod 600 "$ETCD_RECOVERY_CONFIG_BACKUP"
  ok "Protected pre-reset state was verified at $ETCD_RECOVERY_BACKUP"
  warn 'This archive contains the cluster token and private keys. Keep it root-only and protect any external copy.'
}

prepare_single_member_recovery_config(){
  local current rendered
  current=$(as_root_capture cat "$CONFIG_FILE")
  rendered=$(render_single_member_recovery_config <<<"$current")
  [[ $(grep -c '^cluster-init: true$' <<<"$rendered") -eq 1 ]] || die 'Could not produce an unambiguous single-manager K3s configuration.'
  grep -Eq '^(server|token)(\+)?:[[:space:]]*' <<<"$rendered" && die 'The recovery configuration still contains a join server or token. The reset was not attempted.'
  write_root_file "$CONFIG_FILE" 600 "$rendered" || true
}

restore_pre_recovery_config(){
  [[ -n ${ETCD_RECOVERY_CONFIG_BACKUP:-} ]] || return 0
  if as_root_capture test -f "$ETCD_RECOVERY_CONFIG_BACKUP"; then
    as_root cp -a -- "$ETCD_RECOVERY_CONFIG_BACKUP" "$CONFIG_FILE"
    warn 'The original K3s configuration was restored after the failed reset command.'
  fi
}

etcd_recovery_exit_cleanup(){
  local rc=$?
  if $ETCD_RECOVERY_SERVICE_STOPPED; then
    warn 'The recovery workflow stopped while the k3s service was down.'
    if as_root_capture test -e /var/lib/rancher/k3s/server/db/reset-flag; then
      warn 'K3s recorded reset completion. The original join configuration will not be restored and the reset will not be repeated.'
    else
      restore_pre_recovery_config
    fi
    as_root systemctl start --no-block k3s || true
    info 'A normal k3s start was requested. Rerun option 7, which will diagnose whether recovery must resume.'
  fi
  cleanup_join_check
  return "$rc"
}

run_single_member_etcd_reset(){
  local rc=0
  if as_root timeout 600 k3s server --cluster-reset; then
    return 0
  else
    rc=$?
  fi
  if as_root_capture test -e /var/lib/rancher/k3s/server/db/reset-flag; then
    warn "The reset command exited with status $rc, but K3s recorded reset completion. K3sDeploy will not run it again."
    return 0
  fi
  restore_pre_recovery_config
  as_root systemctl start --no-block k3s || true
  ETCD_RECOVERY_SERVICE_STOPPED=false
  trap cleanup_join_check EXIT
  die "The embedded-etcd reset failed with exit $rc. The protected backup remains at $ETCD_RECOVERY_BACKUP. The reset was not retried."
}

remove_stale_manager_nodes(){
  local current=$1 node nodes
  ETCD_RECOVERY_REMOVED_NODES=
  nodes=$(kubectl_local get nodes -l node-role.kubernetes.io/etcd \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)
  while IFS= read -r node; do
    [[ -n $node && $node != "$current" ]] || continue
    warn "Removing stale manager Node object: $node"
    kubectl_local delete node "$node" --wait=false
    ETCD_RECOVERY_REMOVED_NODES+="${ETCD_RECOVERY_REMOVED_NODES:+, }$node"
  done <<<"$nodes"
  if [[ -n $ETCD_RECOVERY_REMOVED_NODES ]]; then
    ok "Removed stale manager Node object(s): $ETCD_RECOVERY_REMOVED_NODES"
  else
    info 'No other etcd-labelled Kubernetes Node objects remained.'
  fi
}

wait_recovered_kube_vip(){
  local end=$((SECONDS+180))
  kubectl_local -n kube-system get daemonset kube-vip >/dev/null 2>&1 || {
    warn 'The kube-vip DaemonSet is absent. Verify the API endpoint using the load-balancer design selected for this cluster.'
    return 0
  }
  info 'Waiting up to three minutes for kube-vip to match the surviving manager set.'
  until kube_vip_ready; do
    if ((SECONDS >= end)); then
      warn "Core etcd recovery succeeded, but kube-vip is not ready ($(kube_vip_status || printf 'status unavailable'))."
      warn 'Run safe repair after reviewing the stale node and kube-vip status.'
      return 0
    fi
    sleep 5
  done
  ok "kube-vip is ready ($(kube_vip_status))"
}

show_etcd_recovery_next_steps(){
  section 'Required recovery follow-up'
  printf '%s\n' \
    '  1. Keep every former manager powered off until it has been cleaned.' \
    '  2. Review Longhorn volumes, replicas, and any stale Longhorn node record.' \
    '  3. Rebuild or restore manager two from a clean state, then join it once.' \
    '  4. Join manager three before treating the control plane as highly available.' \
    '  5. Validate the cluster after each manager joins.' \
    '' \
    '  Do not boot an old manager with its pre-reset server database.' \
    '  Do not test manager failure while the recovered cluster has only one member.'
}

recover_embedded_etcd_quorum(){
  local node
  node=$(short_hostname)
  DESIRED_HOSTNAME=$node
  NODE_ROLE=server
  TARGET_ROLE='recovered single-member control-plane + etcd'

  phase 1 5 'Diagnosing embedded-etcd quorum loss'
  check_etcd_recovery_eligibility
  show_etcd_recovery_warning "$node"

  if $ETCD_RECOVERY_RESUME_ONLY; then
    confirm_etcd_recovery_resume "$node" || die 'Exact recovery-resume confirmation failed. No service change was made.'
    phase 2 5 'Resuming a completed cluster reset safely'
    phase 3 5 'Skipping the already-completed etcd reset'
    skip 'The reset completion flag prevents K3sDeploy from repeating the reset'
  else
    confirm_etcd_recovery "$node" || die 'Exact disaster-recovery confirmation failed. No change was made.'
    if $DRY_RUN; then
      change 'Would stop K3s and create a protected local server-state backup'
      change 'Would rewrite join settings for one-member cluster initialization'
      change 'Would run k3s server --cluster-reset exactly once'
      change 'Would start K3s, remove stale manager Node objects, and validate the survivor'
      return 0
    fi
    phase 2 5 'Stopping K3s and backing up protected server state'
    trap etcd_recovery_exit_cleanup EXIT
    as_root systemctl stop k3s
    ETCD_RECOVERY_SERVICE_STOPPED=true
    backup_etcd_recovery_state

    phase 3 5 'Resetting embedded etcd to this sole manager'
    prepare_single_member_recovery_config
    run_single_member_etcd_reset
  fi

  phase 4 5 'Starting and cleaning the recovered control plane'
  as_root systemctl reset-failed k3s || true
  as_root systemctl start k3s
  ETCD_RECOVERY_SERVICE_STOPPED=false
  trap cleanup_join_check EXIT
  wait_k3s
  wait_local_node
  ETCD_RECOVERY_CORE_SUCCEEDED=true
  remove_stale_manager_nodes "$node"
  wait_recovered_kube_vip

  phase 5 5 'Validating recovery and showing required next steps'
  validate_cluster
  show_etcd_recovery_next_steps
  if ((${VALIDATION_FAILURES:-0} > 0)); then
    warn 'Core etcd quorum recovery completed, but the health report still has failures that require review.'
  else
    ok 'The surviving manager has a working single-member embedded-etcd control plane'
  fi
}
