#!/usr/bin/env bash

ensure_nfs_client(){
  local package
  command -v mount.nfs >/dev/null 2>&1 && return 0
  package=$(package_for nfs) || die "K3sDeploy does not know the NFS client package for $OS_NAME. Install mount.nfs manually, then retry."
  info "Installing the NFS client package for $OS_NAME ($package)"
  package_refresh
  package_install "$package"
  command -v mount.nfs >/dev/null 2>&1 || die "$package was installed, but mount.nfs is still unavailable."
}

verify_nfs_share(){
  local test_mount write_probe
  ensure_nfs_client
  if $DRY_RUN; then
    change "Would temporarily mount $NFS_SERVER:$NFS_EXPORT and verify NFSv4.1 write access"
    return 0
  fi
  test_mount=$(mktemp -d -t k3sdeploy-nfs-check-XXXXXX)
  if ! as_root mount -t nfs -o rw,nosuid,nodev,noexec,nfsvers=4.1 "$NFS_SERVER:$NFS_EXPORT" "$test_mount"; then
    if findmnt -rn --target "$test_mount" >/dev/null 2>&1; then
      as_root umount "$test_mount" || warn "The failed NFS check left $test_mount mounted. Unmount it manually."
    fi
    rmdir "$test_mount" 2>/dev/null || true
    die "Could not mount $NFS_SERVER:$NFS_EXPORT using NFSv4.1. Check the export, permissions, firewall, and server availability."
  fi
  write_probe="$test_mount/.k3sdeploy-write-test-$$-$RANDOM"
  if ! as_root mkdir "$write_probe"; then
    as_root umount "$test_mount" || warn "The NFS check left $test_mount mounted. Unmount it manually."
    rmdir "$test_mount" 2>/dev/null || true
    die "The NFS export mounted but did not allow directory creation. Grant the CSI provisioner write access to $NFS_EXPORT, then retry."
  fi
  if ! as_root rmdir "$write_probe"; then
    warn "The NFS write probe $write_probe could not be removed. Remove it from the server manually."
    as_root umount "$test_mount" || true
    rmdir "$test_mount" 2>/dev/null || true
    die 'The NFS write-access check could not clean up safely.'
  fi
  if ! as_root umount "$test_mount"; then
    error "The NFS test mount at $test_mount could not be unmounted. Resolve it manually before continuing."
    return 1
  fi
  rmdir "$test_mount"
  ok "NFS share $NFS_SERVER:$NFS_EXPORT passed the NFSv4.1 mount and write-access check"
}

install_nfs_csi(){
  local base="https://raw.githubusercontent.com/kubernetes-csi/csi-driver-nfs/$NFS_CSI_VERSION/deploy/${NFS_CSI_VERSION}"
  local manifest storage_class
  for manifest in rbac-csi-nfs.yaml csi-nfs-driverinfo.yaml csi-nfs-controller.yaml csi-nfs-node.yaml; do
    kubectl_local apply -f "$base/$manifest"
  done
  kubectl_local -n kube-system rollout status deploy/csi-nfs-controller --timeout=600s
  kubectl_local -n kube-system rollout status daemonset/csi-nfs-node --timeout=600s
  storage_class=$(render_nfs_storageclass)
  printf '%s' "$storage_class" | kubectl_local apply -f -
  ok "NFS CSI storage is configured for $NFS_SERVER:$NFS_EXPORT"
}

render_nfs_storageclass(){ sed -e "s#__NFS_SERVER__#$NFS_SERVER#g" -e "s#__NFS_EXPORT__#$NFS_EXPORT#g" "$PROJECT_ROOT/templates/nfs/storageclass.yaml"; }

validate_nfs(){
  if ! kubectl_local get csidriver nfs.csi.k8s.io >/dev/null 2>&1; then
    report 'NFS CSI driver' FAIL 'nfs.csi.k8s.io is not registered'
    return 1
  fi
  if kubectl_local get storageclass nfs-csi-retain >/dev/null 2>&1; then
    report 'NFS storage' OK "$NFS_SERVER:$NFS_EXPORT"
  else
    report 'NFS storage' FAIL 'nfs-csi-retain StorageClass is missing'
    return 1
  fi
}
