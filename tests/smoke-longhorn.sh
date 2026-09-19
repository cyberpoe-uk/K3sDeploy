#!/usr/bin/env bash
set -Eeuo pipefail
echo 'This creates and then removes a test Pod and PVC; the PVC uses a Delete reclaim workflow.'
read -r -p 'Run Longhorn smoke test? [y/N] ' yes; [[ $yes =~ ^[Yy]$ ]] || exit 0
name=k3s-bootstrap-storage-test
token="k3s-bootstrap-$(date +%s)-$RANDOM"
cleanup(){ kubectl delete pod "$name-reader" "$name-writer" --ignore-not-found --wait=false; kubectl delete pvc "$name" --ignore-not-found; }
trap cleanup EXIT
kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: $name}
spec: {accessModes: [ReadWriteOnce], storageClassName: longhorn-retain, resources: {requests: {storage: 128Mi}}}
---
apiVersion: v1
kind: Pod
metadata: {name: $name-writer}
spec:
  restartPolicy: Never
  containers: [{name: test, image: busybox:1.37, command: [sh,-c,"echo '$token' > /data/value; cat /data/value"], volumeMounts: [{name: data, mountPath: /data}]}]
  volumes: [{name: data, persistentVolumeClaim: {claimName: $name}}]
EOF
kubectl wait --for=jsonpath='{.status.phase}'=Succeeded "pod/$name-writer" --timeout=10m
kubectl delete pod "$name-writer" --wait=true
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata: {name: $name-reader}
spec:
  restartPolicy: Never
  containers: [{name: test, image: busybox:1.37, command: [sh,-c,"grep -Fx '$token' /data/value"], volumeMounts: [{name: data, mountPath: /data}]}]
  volumes: [{name: data, persistentVolumeClaim: {claimName: $name}}]
EOF
kubectl wait --for=jsonpath='{.status.phase}'=Succeeded "pod/$name-reader" --timeout=10m
echo 'Longhorn persistence smoke test passed.'
