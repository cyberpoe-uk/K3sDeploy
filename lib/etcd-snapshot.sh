#!/usr/bin/env bash

ETCD_LAST_SNAPSHOT=
ETCD_RESTORE_SELECTED=
ETCD_RESTORE_SERVICE_STOPPED=false
readonly ETCD_RESTORE_CANCEL_RC=78

managed_etcd_snapshots(){ [[ ${ETCD_SNAPSHOT_POLICY:-managed} != external ]]; }

snapshot_policy_description(){
  if managed_etcd_snapshots; then
    printf 'managed locally, %s scheduled and %s per milestone type\n' \
      "${ETCD_SNAPSHOT_RETENTION:-5}" "${ETCD_MILESTONE_RETENTION:-1}"
  else
    printf 'external backup ownership, K3s snapshots disabled\n'
  fi
}

collect_etcd_snapshot_policy(){
  local choice exact
  section 'Embedded-etcd backup policy'
  printf '%s\n' \
    '  Every manager stores its own embedded-etcd database.' \
    '  With managed snapshots, each manager keeps a bounded local snapshot set.' \
    '  One surviving manager can restore the control plane when its snapshot and' \
    '  matching server token survive. A worker alone cannot restore embedded etcd.' \
    '  Local snapshots do not survive loss of every manager or manager disk.' \
    '  Copy important snapshots and the matching token to protected off-node storage.'
  if virtual_machine_detected; then
    printf '%s\n' \
      '' \
      "  Virtual machine detected: ${VIRTUALIZATION_TYPE}." \
      '  Hypervisor backups can complement this protection, but VM snapshots taken' \
      '  at different times are not a coordinated etcd and application-data backup.'
  fi
  printf '\n'
  menu_select choice 'Choose who manages embedded-etcd backups' 1 \
    "Managed local snapshots [Recommended - keep ${ETCD_SNAPSHOT_RETENTION:-5} scheduled and ${ETCD_MILESTONE_RETENTION:-1} per milestone type]" \
    'External backup ownership [Advanced - disable K3s snapshots]'
  if ((choice == 1)); then
    ETCD_SNAPSHOT_POLICY=managed
    return 0
  fi
  printf '%s\n' \
    '' \
    '  K3sDeploy will disable scheduled and milestone snapshots on this manager.' \
    '  Existing snapshot files are preserved. Your external backup process must' \
    '  protect both embedded-etcd state and the matching K3s server token.'
  read -r -p "Type 'MANAGE BACKUPS EXTERNALLY' to accept responsibility: " exact
  if [[ $exact == 'MANAGE BACKUPS EXTERNALLY' ]]; then
    ETCD_SNAPSHOT_POLICY=external
  else
    warn 'External backup ownership was not confirmed. Managed snapshots remain selected.'
    ETCD_SNAPSHOT_POLICY=managed
  fi
}

parse_k3s_yaml_scalar(){
  local key=$1
  awk -v key="$key" '
    $0 ~ "^[[:space:]]*" key ":[[:space:]]*" {
      value=$0
      sub("^[[:space:]]*" key ":[[:space:]]*", "", value)
      sub(/[[:space:]]+#.*$/, "", value)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      if (value ~ /^".*"$/ || value ~ /^\047.*\047$/) {
        value=substr(value, 2, length(value)-2)
      }
      print value
      exit
    }
  '
}

k3s_data_directory(){
  local configured=
  if as_root_capture test -f "$CONFIG_FILE"; then
    configured=$(as_root_capture cat "$CONFIG_FILE" | parse_k3s_yaml_scalar data-dir)
  fi
  printf '%s\n' "${configured:-/var/lib/rancher/k3s}"
}

etcd_snapshot_directory(){
  local configured= data_dir
  if as_root_capture test -f "$CONFIG_FILE"; then
    configured=$(as_root_capture cat "$CONFIG_FILE" | parse_k3s_yaml_scalar etcd-snapshot-dir)
  fi
  if [[ -n $configured ]]; then
    printf '%s\n' "$configured"
    return
  fi
  data_dir=$(k3s_data_directory)
  printf '%s/server/db/snapshots\n' "${data_dir%/}"
}

snapshot_path_is_local_and_safe(){
  local path=$1 directory=$2 resolved_path resolved_directory
  resolved_path=$(readlink -f -- "$path" 2>/dev/null || true)
  resolved_directory=$(readlink -f -- "$directory" 2>/dev/null || true)
  [[ -n $resolved_path && -n $resolved_directory ]] || return 1
  [[ $resolved_path == "$resolved_directory"/* && $resolved_path != "$resolved_directory" ]] || return 1
  as_root_capture test -f "$resolved_path" || return 1
  as_root_capture test ! -L "$path" || return 1
  as_root_capture test -s "$resolved_path"
}

newest_snapshot_matching(){
  local directory=$1 prefix=$2
  as_root_capture find "$directory" -maxdepth 1 -type f -name "$prefix*" -printf '%T@|%p\n' 2>/dev/null |
    sort -t '|' -k1,1nr | awk -F'|' 'NR==1 {print $2}'
}

create_etcd_snapshot(){
  local label=$1 directory before newest
  ETCD_LAST_SNAPSHOT=
  managed_etcd_snapshots || { skip "Etcd snapshot omitted because external backup ownership is selected: k3sdeploy-$label"; return 0; }
  if $DRY_RUN; then
    change "Would create an official K3s etcd snapshot named k3sdeploy-$label"
    return 0
  fi
  systemd_unit_exists k3s || { skip 'Etcd snapshot omitted because this is not a manager'; return 0; }
  as_root_capture test -d "$(k3s_data_directory)/server/db/etcd/member" || { skip 'Etcd snapshot omitted because no local embedded-etcd member was found'; return 0; }
  as_root_capture k3s kubectl get --raw=/readyz >/dev/null 2>&1 || {
    warn 'The Kubernetes API is not ready, so K3sDeploy could not create a consistent on-demand etcd snapshot.'
    return 1
  }
  directory=$(etcd_snapshot_directory)
  before=$(newest_snapshot_matching "$directory" "k3sdeploy-$label" || true)
  info "Creating an official K3s etcd snapshot on this manager: k3sdeploy-$label"
  as_root k3s etcd-snapshot save --name "k3sdeploy-$label"
  newest=$(newest_snapshot_matching "$directory" "k3sdeploy-$label" || true)
  [[ -n $newest && $newest != "$before" ]] || die "K3s reported snapshot completion, but a new snapshot was not found in $directory."
  ETCD_LAST_SNAPSHOT=$newest
  as_root chmod 700 "$directory"
  as_root chmod 600 "$ETCD_LAST_SNAPSHOT"
  ok "Etcd snapshot saved locally at $ETCD_LAST_SNAPSHOT"
  if as_root k3s etcd-snapshot prune --name "k3sdeploy-$label" --snapshot-retention "${ETCD_MILESTONE_RETENTION:-1}"; then
    info "Retained the newest ${ETCD_MILESTONE_RETENTION:-1} k3sdeploy-$label milestone snapshot on this manager"
  else
    warn "The new snapshot is safe, but older k3sdeploy-$label snapshots could not be pruned automatically."
  fi
  warn 'A local snapshot shares this node failure domain. Copy snapshots and the server token to protected off-node storage.'
}

create_milestone_etcd_snapshot(){
  create_etcd_snapshot "$1"
}

offer_initial_etcd_snapshot(){
  local directory existing
  managed_etcd_snapshots || { skip 'Baseline snapshot omitted because external backup ownership is selected'; return 0; }
  systemd_unit_exists k3s || return 0
  as_root_capture test -d "$(k3s_data_directory)/server/db/etcd/member" || return 0
  as_root_capture k3s kubectl get --raw=/readyz >/dev/null 2>&1 || return 0
  directory=$(etcd_snapshot_directory)
  existing=$(newest_snapshot_matching "$directory" k3sdeploy- || true)
  if [[ -n $existing ]]; then
    info "A K3sDeploy milestone snapshot already exists on this manager: $existing"
    return 0
  fi
  section 'Etcd snapshot protection'
  printf '%s\n' \
    '  No K3sDeploy milestone snapshot was found on this manager.' \
    '  K3s already schedules local snapshots, but a named baseline is useful' \
    '  after adopting this release on an existing manager.'
  if confirm_yes 'Create an official K3s etcd baseline snapshot now?'; then
    create_milestone_etcd_snapshot healthy-baseline
  else
    skip 'No baseline snapshot was requested. Scheduled K3s snapshots remain unchanged'
  fi
}

collect_local_etcd_snapshots(){
  local directory=$1
  as_root_capture find "$directory" -maxdepth 1 -type f -size +0c -printf '%T@|%s|%f\n' 2>/dev/null |
    sort -t '|' -k1,1nr
}

choose_local_etcd_snapshot(){
  local directory records epoch bytes name choice size_mib selected
  local -a paths=() choices=()
  directory=$(etcd_snapshot_directory)
  as_root_capture test -d "$directory" || die "No local K3s snapshot directory was found at $directory."
  records=$(collect_local_etcd_snapshots "$directory")
  [[ -n $records ]] || die "No local K3s etcd snapshots were found in $directory."
  while IFS='|' read -r epoch bytes name; do
    [[ -n $name && $bytes =~ ^[0-9]+$ ]] || continue
    selected="$directory/$name"
    snapshot_path_is_local_and_safe "$selected" "$directory" || continue
    size_mib=$(( (bytes + 1048575) / 1048576 ))
    paths+=("$selected")
    choices+=("$name - ${size_mib} MiB - $(date -d "@$epoch" '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || printf 'time unavailable')")
  done <<<"$records"
  ((${#paths[@]} > 0)) || die "No safe regular snapshot files were found in $directory."
  choices+=('Cancel and return to the main menu')
  section 'Available local K3s etcd snapshots'
  printf '%s\n' \
    "  Location: $directory" \
    '  Newest snapshots are listed first.' \
    '  A snapshot restores Kubernetes objects and cluster configuration.' \
    '  It does not restore Longhorn, NFS, or application volume contents.'
  printf '\n'
  menu_select choice 'Choose the snapshot to restore' 1 "${choices[@]}"
  if ((choice == ${#choices[@]})); then
    skip 'Snapshot restore cancelled before any cluster change'
    return "$ETCD_RESTORE_CANCEL_RC"
  fi
  [[ $choice =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#paths[@]})) || die 'Invalid snapshot selection.'
  ETCD_RESTORE_SELECTED=${paths[choice-1]}
}

show_snapshot_restore_warning(){
  local node=$1 snapshot=$2
  section 'Embedded-etcd snapshot restore warning'
  printf '%s\n' \
    "  Selected snapshot: $(basename "$snapshot")" \
    "  Restore manager:  $node" \
    '' \
    '  This rolls Kubernetes cluster state back to the snapshot time.' \
    '  Objects created later can disappear and older object definitions return.' \
    '  Persistent-volume data is not rolled back with etcd.' \
    '  Every other manager must be stopped or isolated before restoration.' \
    '  Former managers must have their old local server database removed before rejoining.' \
    '  Workers can reconnect after the restored API is healthy.'
}

confirm_snapshot_restore(){
  local node=$1 snapshot=$2 response expected
  expected="RESTORE $(basename "$snapshot") ON $node"
  read -r -p "Type '$expected' to continue: " response
  [[ $response == "$expected" ]]
}

snapshot_restore_exit_cleanup(){
  local rc=$?
  if $ETCD_RESTORE_SERVICE_STOPPED; then
    warn 'The snapshot-restore workflow stopped while the k3s service was down.'
    if as_root_capture test -e "$(k3s_data_directory)/server/db/reset-flag"; then
      warn 'K3s recorded restore completion. The restore will not be repeated.'
    else
      restore_pre_recovery_config
    fi
    as_root systemctl start --no-block k3s || true
    info 'A normal K3s start was requested. Rerun snapshot restore to diagnose and safely resume.'
  fi
  cleanup_join_check
  return "$rc"
}

run_local_snapshot_restore(){
  local snapshot=$1 rc=0
  if as_root timeout 900 k3s server --cluster-reset --cluster-reset-restore-path="$snapshot" --etcd-s3=false; then
    return 0
  else
    rc=$?
  fi
  if as_root_capture test -e "$(k3s_data_directory)/server/db/reset-flag"; then
    warn "The restore command exited with status $rc, but K3s recorded restore completion. K3sDeploy will not repeat it."
    return 0
  fi
  restore_pre_recovery_config
  as_root systemctl start --no-block k3s || true
  ETCD_RESTORE_SERVICE_STOPPED=false
  trap cleanup_join_check EXIT
  die "The snapshot restore failed with exit $rc. The protected pre-restore backup remains at $ETCD_RECOVERY_BACKUP."
}

check_snapshot_restore_eligibility(){
  local dropin data_dir
  command -v k3s >/dev/null 2>&1 || die 'The K3s binary is missing. Snapshot restore must run on an installed manager.'
  systemd_unit_exists k3s || die 'The k3s server service is not installed. Workers cannot restore embedded-etcd snapshots.'
  data_dir=$(k3s_data_directory)
  as_root_capture test -d "$data_dir/server/db/etcd/member" || die 'No local embedded-etcd member data was found on this manager.'
  as_root_capture test -f "$CONFIG_FILE" || die "The K3s server configuration is missing at $CONFIG_FILE."
  as_root_capture test -f "$STATE_FILE" || die "K3sDeploy state is missing at $STATE_FILE. Automatic restore cannot confirm the managed cluster design."
  if as_root_capture grep -Eq '^datastore-endpoint(\+)?:[[:space:]]*' "$CONFIG_FILE"; then
    die 'The K3s configuration selects an external datastore. Embedded-etcd snapshot restore is not applicable.'
  fi
  if dropin=$(etcd_recovery_dropin_join_keys); then
    die "A K3s config drop-in contains a cluster identity key: $dropin. Automatic restore cannot safely determine precedence."
  fi
  check_etcd_recovery_backup_space
}

restore_embedded_etcd_snapshot(){
  local node data_dir
  node=$(short_hostname)
  data_dir=$(k3s_data_directory)
  DESIRED_HOSTNAME=$node
  NODE_ROLE=server
  TARGET_ROLE='restored single-member control-plane + etcd'

  phase 1 6 'Checking this manager and discovering snapshots'
  check_snapshot_restore_eligibility
  if as_root_capture test -e "$data_dir/server/db/reset-flag"; then
    warn 'K3s has a cluster-reset completion flag. No snapshot will be selected or restored again.'
    confirm_etcd_recovery_resume "$node" || die 'Exact restore-resume confirmation failed. No service change was made.'
    phase 2 6 'Skipping pre-restore snapshot because reset already completed'
    phase 3 6 'Skipping protected backup because reset already completed'
    phase 4 6 'Skipping the already-completed snapshot restore'
  else
    local selection_rc
    if choose_local_etcd_snapshot; then
      :
    else
      selection_rc=$?
      return "$selection_rc"
    fi
    show_snapshot_restore_warning "$node" "$ETCD_RESTORE_SELECTED"

    phase 2 6 'Creating a current-state safety snapshot when possible'
    if as_root_capture k3s kubectl get --raw=/readyz >/dev/null 2>&1; then
      create_etcd_snapshot pre-restore
    else
      warn 'The API is unavailable, so no new on-demand snapshot can be created. The protected stopped-state archive is still required below.'
    fi
    confirm 'I confirm every other manager is stopped or isolated' || die 'Snapshot restore cancelled. No service or cluster-state change was made. The new safety snapshot, if created, remains available.'
    confirm_snapshot_restore "$node" "$ETCD_RESTORE_SELECTED" || die 'Exact snapshot-restore confirmation failed. No service or cluster-state change was made. The new safety snapshot, if created, remains available.'
    if $DRY_RUN; then
      change "Would stop K3s, preserve current state, and restore $ETCD_RESTORE_SELECTED"
      change 'Would reset membership to this manager, start K3s, remove stale manager Node objects, and validate'
      return 0
    fi

    phase 3 6 'Stopping K3s and protecting the current server state'
    trap snapshot_restore_exit_cleanup EXIT
    as_root systemctl stop k3s
    ETCD_RESTORE_SERVICE_STOPPED=true
    backup_etcd_recovery_state pre-snapshot-restore

    phase 4 6 'Restoring the selected snapshot and resetting membership'
    prepare_single_member_recovery_config
    run_local_snapshot_restore "$ETCD_RESTORE_SELECTED"
  fi

  phase 5 6 'Starting and cleaning the restored control plane'
  as_root systemctl reset-failed k3s || true
  as_root systemctl start k3s
  ETCD_RESTORE_SERVICE_STOPPED=false
  trap cleanup_join_check EXIT
  wait_k3s
  wait_local_node
  remove_stale_manager_nodes "$node"
  wait_recovered_kube_vip

  phase 6 6 'Validating the restored cluster and saving a milestone snapshot'
  validate_cluster
  if ((${VALIDATION_FAILURES:-0} > 0)); then
    warn 'The datastore restore completed, but the health report still has failures that require review.'
  else
    create_milestone_etcd_snapshot post-restore
    ok 'The selected etcd snapshot was restored and the surviving manager is healthy'
  fi
  show_etcd_recovery_next_steps
}
