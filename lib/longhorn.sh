#!/usr/bin/env bash
ensure_iscsi(){ local package; if ! command -v iscsiadm >/dev/null; then package=$(package_for iscsi) || die "K3sDeploy does not know the open-iscsi package name for $OS_NAME. Install iscsiadm manually, then retry."; package_refresh; package_install "$package"; fi; as_root systemctl enable --now iscsid; if ! command -v iscsiadm >/dev/null || ! systemctl is-active --quiet iscsid; then die "Longhorn prerequisite iscsid is unavailable"; fi; }
set_longhorn_setting(){ kubectl_local -n longhorn-system patch settings.longhorn.io "$1" --type merge -p "{\"value\":\"$2\"}"; }
install_longhorn(){ ensure_iscsi; kubectl_local apply -f "https://raw.githubusercontent.com/longhorn/longhorn/$LONGHORN_VERSION/deploy/longhorn.yaml"; kubectl_local -n longhorn-system rollout status deploy/longhorn-driver-deployer --timeout=600s; kubectl_local -n longhorn-system rollout status deploy/longhorn-ui --timeout=600s; set_longhorn_setting default-data-path "$LONGHORN_PATH"; set_longhorn_setting storage-minimal-available-percentage "$LONGHORN_MIN_AVAILABLE_PERCENT"; set_longhorn_setting storage-over-provisioning-percentage "$LONGHORN_OVERPROVISIONING_PERCENT"; set_longhorn_setting storage-reserved-percentage-for-default-disk "$LONGHORN_ROOT_RESERVED_PERCENT"; set_longhorn_setting default-replica-count "$LONGHORN_REPLICAS"; set_longhorn_setting default-data-locality best-effort; set_longhorn_setting replica-auto-balance least-effort; local sc; sc=$(sed -e "s#__PATH__#$LONGHORN_PATH#g" -e "s/__REPLICAS__/$LONGHORN_REPLICAS/g" "$PROJECT_ROOT/templates/longhorn/storageclass.yaml"); printf '%s' "$sc" | kubectl_local apply -f -; }
validate_longhorn(){
  if ! kubectl_local get ns longhorn-system >/dev/null 2>&1; then report Longhorn FAIL 'namespace not found'; return 1; fi
  local node=${DESIRED_HOSTNAME:-$(short_hostname)}
  if kubectl_local -n longhorn-system get nodes.longhorn.io "$node" >/dev/null 2>&1; then
    report Longhorn OK 'local node registered'
  else
    report Longhorn FAIL 'local node is not registered'
    return 1
  fi
}

cleanup_longhorn_smoke(){
  local namespace=$1 storage_class=$2
  kubectl_local delete namespace "$namespace" --ignore-not-found --wait=true --timeout=120s >/dev/null 2>&1 || warn "Smoke-test namespace $namespace is still terminating; Kubernetes will continue cleaning it up."
  kubectl_local delete storageclass "$storage_class" --ignore-not-found >/dev/null 2>&1 || warn "Remove temporary StorageClass $storage_class manually."
}

run_longhorn_smoke(){
  local suffix namespace storage_class token manifest
  suffix="$(date +%s)-$RANDOM"
  namespace="k3sdeploy-smoke-$suffix"
  storage_class="k3sdeploy-longhorn-smoke-$suffix"
  token="k3sdeploy-$suffix"
  info 'This temporary test creates a 128 MiB one-replica volume, writes unique data, reattaches it to another pod, verifies the data, and removes all test resources.'
  info 'It verifies provisioning and persistence on this node; it does not prove three-node replica availability or replace backups.'
  manifest=$(cat <<EOF
apiVersion: v1
kind: Namespace
metadata: {name: $namespace}
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata: {name: $storage_class}
provisioner: driver.longhorn.io
allowVolumeExpansion: true
reclaimPolicy: Delete
volumeBindingMode: Immediate
parameters:
  numberOfReplicas: "1"
  dataLocality: best-effort
  dataEngine: v1
  fsType: ext4
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: storage-check, namespace: $namespace}
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: $storage_class
  resources: {requests: {storage: 128Mi}}
---
apiVersion: v1
kind: Pod
metadata: {name: writer, namespace: $namespace}
spec:
  restartPolicy: Never
  containers:
  - name: test
    image: busybox:1.37
    command: [sh, -c, "echo '$token' > /data/value; sync; grep -Fx '$token' /data/value"]
    volumeMounts: [{name: data, mountPath: /data}]
  volumes: [{name: data, persistentVolumeClaim: {claimName: storage-check}}]
EOF
)
  if ! printf '%s' "$manifest" | kubectl_local apply -f -; then
    cleanup_longhorn_smoke "$namespace" "$storage_class"
    error 'Longhorn smoke-test resources could not be created.'
    return 1
  fi
  if ! kubectl_local -n "$namespace" wait --for=jsonpath='{.status.phase}'=Bound pvc/storage-check --timeout=10m; then
    kubectl_local -n "$namespace" describe pvc storage-check || true
    cleanup_longhorn_smoke "$namespace" "$storage_class"
    error 'Longhorn did not bind the temporary test claim.'
    return 1
  fi
  if ! kubectl_local -n "$namespace" wait --for=jsonpath='{.status.phase}'=Succeeded pod/writer --timeout=10m; then
    kubectl_local -n "$namespace" describe pod writer || true
    cleanup_longhorn_smoke "$namespace" "$storage_class"
    error 'The Longhorn smoke-test writer pod did not succeed.'
    return 1
  fi
  kubectl_local -n "$namespace" delete pod writer --wait=true
  manifest=$(cat <<EOF
apiVersion: v1
kind: Pod
metadata: {name: reader, namespace: $namespace}
spec:
  restartPolicy: Never
  containers:
  - name: test
    image: busybox:1.37
    command: [sh, -c, "grep -Fx '$token' /data/value"]
    volumeMounts: [{name: data, mountPath: /data}]
  volumes: [{name: data, persistentVolumeClaim: {claimName: storage-check}}]
EOF
)
  if ! printf '%s' "$manifest" | kubectl_local apply -f - ||
     ! kubectl_local -n "$namespace" wait --for=jsonpath='{.status.phase}'=Succeeded pod/reader --timeout=10m; then
    kubectl_local -n "$namespace" describe pod reader || true
    cleanup_longhorn_smoke "$namespace" "$storage_class"
    error 'Longhorn reattachment or persisted-data verification failed.'
    return 1
  fi
  cleanup_longhorn_smoke "$namespace" "$storage_class"
  ok 'Longhorn provisioning, write, reattachment, and persisted-data smoke test passed'
}
