#!/usr/bin/env bash
ensure_iscsi(){ local package; if ! command -v iscsiadm >/dev/null; then package=$(package_for iscsi) || die "K3sDeploy does not know the open-iscsi package name for $OS_NAME. Install iscsiadm manually, then retry."; package_refresh; package_install "$package"; fi; as_root systemctl enable --now iscsid; if ! command -v iscsiadm >/dev/null || ! systemctl is-active --quiet iscsid; then die "Longhorn prerequisite iscsid is unavailable"; fi; }
set_longhorn_setting(){ kubectl_local -n longhorn-system patch settings.longhorn.io "$1" --type merge -p "{\"value\":\"$2\"}"; }
install_longhorn(){ ensure_iscsi; kubectl_local apply -f "https://raw.githubusercontent.com/longhorn/longhorn/$LONGHORN_VERSION/deploy/longhorn.yaml"; kubectl_local -n longhorn-system rollout status deploy/longhorn-driver-deployer --timeout=600s; kubectl_local -n longhorn-system rollout status deploy/longhorn-ui --timeout=600s; set_longhorn_setting default-data-path "$LONGHORN_PATH"; set_longhorn_setting storage-minimal-available-percentage "$LONGHORN_MIN_AVAILABLE_PERCENT"; set_longhorn_setting storage-over-provisioning-percentage "$LONGHORN_OVERPROVISIONING_PERCENT"; set_longhorn_setting storage-reserved-percentage-for-default-disk "$LONGHORN_ROOT_RESERVED_PERCENT"; set_longhorn_setting default-replica-count "$LONGHORN_REPLICAS"; set_longhorn_setting default-data-locality best-effort; set_longhorn_setting replica-auto-balance least-effort; local sc; sc=$(sed -e "s#__PATH__#$LONGHORN_PATH#g" -e "s/__REPLICAS__/$LONGHORN_REPLICAS/g" "$PROJECT_ROOT/templates/longhorn/storageclass.yaml"); printf '%s' "$sc" | kubectl_local apply -f -; }
validate_longhorn(){
  if ! kubectl_local get ns longhorn-system >/dev/null 2>&1; then report Longhorn MISSING 'namespace not found'; return 1; fi
  local node=${DESIRED_HOSTNAME:-$(short_hostname)}
  if kubectl_local -n longhorn-system get nodes.longhorn.io "$node" >/dev/null 2>&1; then
    report Longhorn OK 'local node registered'
  else
    report Longhorn FAIL 'local node is not registered'
    return 1
  fi
}
