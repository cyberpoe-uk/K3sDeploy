# K3sDeploy

K3sDeploy is an interactive Ubuntu Server installer for building and maintaining a small highly available K3s cluster. It guides the operator through networking, node roles, API high availability, application load balancers, ingress, and persistent storage without requiring prior Kubernetes installation experience.

The project favors visible checks and explicit confirmation over unattended destructive changes. It does not reset clusters, erase unidentified disks, retrieve tokens from remote machines, or silently replace existing cluster configuration.

## What it installs

| Component | Version | Purpose |
| --- | --- | --- |
| K3s | `v1.36.4+k3s1` | Kubernetes distribution |
| kube-vip | `v1.2.3` | Highly available Kubernetes API virtual IP |
| MetalLB | `v0.16.1` | `LoadBalancer` addresses for applications |
| Traefik | K3s packaged version | HTTP and HTTPS ingress |
| Longhorn | `v1.12.1` | Replicated persistent storage using the V1 filesystem engine |

Versions are pinned in `config/versions.env`; installations never follow a moving `latest` tag. K3s ServiceLB is disabled because MetalLB owns application load-balancer addresses. kube-vip is used only for the Kubernetes API.

> MetalLB v0.16.1 matches the validated platform, but its released images have a reported fixable gRPC vulnerability as of September 2026. Review upstream security releases and test any pin change before production use.

## Prerequisites

Prepare every node before running the installer.

### Operating system and access

- Ubuntu Server with systemd. Ubuntu Server 24.04 LTS is the primary tested target.
- `amd64`/`x86_64` or `arm64`/`aarch64` CPU architecture.
- A normal user account with `sudo` access.
- A unique lowercase hostname for every node.
- Working DNS, HTTPS Internet access, and synchronized system time.
- A static IPv4 address, DHCP reservation, or another method that prevents the node address from changing.

Run the installer as the normal user. It requests sudo authentication once and elevates only package, service, protected-file, and disk operations.

### Recommended hardware

Longhorn V1 recommends at least:

- 4 CPU cores per storage node.
- 4 GiB RAM per storage node.
- Three storage-capable nodes for replicated availability.
- SSD or NVMe storage where possible. HDDs work but may suffer latency-related instability during rebuilds and busy workloads.

The installer warns and requests explicit confirmation below the CPU or memory recommendation.

### Storage

Each node needs one of the following:

- An ext4 or XFS root filesystem of at least 120 GiB with at least 60 GiB currently free.
- A GPT-formatted OS disk with at least 100 GiB plus alignment margin genuinely unallocated for a new Longhorn partition.
- An empty separate physical disk of at least 100 GiB.

These are conservative installer defaults, not universal workload-sizing guarantees. Change them deliberately in `config/defaults.env` when your capacity plan requires different values.

### Network planning

Decide these addresses before installation:

- One fixed Kubernetes API VIP on the same Layer-2 network as the managers.
- One unique static address per node.
- A MetalLB range excluded from DHCP and all node/VIP addresses.

Allow the required traffic between nodes. Important defaults include TCP `6443` for the API, TCP `2379-2380` between embedded-etcd managers, UDP `8472` for Flannel VXLAN, and TCP `10250` between nodes. Do not expose UDP `8472` to untrusted networks.

## Recommended cluster layout

Use an odd number of manager nodes. Three managers is appropriate for most small and medium installations; five may be useful across additional failure domains. Do not turn all machines in a 20–30 node cluster into etcd voters.

Example ten-node layout:

```text
node-01  manager + etcd + schedulable worker
node-02  manager + etcd + schedulable worker
node-03  manager + etcd + schedulable worker
node-04  worker
...
node-10  worker
```

Two etcd members do not tolerate the loss of either member. Complete the third healthy manager before treating the control plane as highly available.

## Get K3sDeploy

Run K3sDeploy directly on each Ubuntu node, one node at a time. Do not install it on a separate administration machine and do not copy one node's generated K3s configuration to another node.

Run every command in this section as your normal login user, without putting `sudo` in front of it. K3sDeploy asks for your sudo password when a privileged change is actually required.

### Recommended: clone the repository

Cloning leaves a local copy that you can inspect, rerun for validation, and use later for safe repair:

```bash
sudo apt-get update
sudo apt-get install -y git
git clone https://github.com/cyberpoe-uk/K3sDeploy.git
cd K3sDeploy
./k3s-bootstrap.sh
```

Before a production deployment, use a published release tag instead of an unreviewed development branch. For example:

```bash
git clone --branch v0.1.0 --depth 1 https://github.com/cyberpoe-uk/K3sDeploy.git
cd K3sDeploy
./k3s-bootstrap.sh
```

Replace `v0.1.0` with the release you have reviewed and want to deploy. Use the same K3sDeploy release on every node in one cluster.

### Convenient: latest stable release launcher

The public launcher finds the highest stable semantic-version tag, downloads that release into a temporary directory, verifies that its tag matches the `VERSION` file, and opens the same interactive menu:

Install `curl` first if your minimal Ubuntu image does not include it:

```bash
sudo apt-get update
sudo apt-get install -y curl
```

```bash
bash <(curl -fsSL https://cyberpoe.uk/k3sdeploy-latest)
```

For the inspect-before-running form:

```bash
curl -fsSLo k3s-deploy-latest https://cyberpoe.uk/k3sdeploy-latest
less k3sdeploy-latest
bash k3sdeploy-latest
```

The launcher installs Git only after asking permission if Git is missing. It never runs the main installer with `sudo`. Its temporary download is removed when the menu exits, so clone the repository instead if you want to keep the exact files used on the node.

The short URL works only after the website endpoint and at least one matching Git tag, such as `v0.1.0`, have been published. It intentionally refuses development branches and prerelease tag names.

### Already downloaded

If you downloaded a release archive instead of using Git, extract the complete archive first. K3sDeploy is a multi-file project; downloading only `k3s-bootstrap.sh` will not work.

```bash
cd K3sDeploy-0.1.0
./k3s-bootstrap.sh
```

## Running the installer

Available flags:

```text
--dry-run   Display intended host changes where practical
--verbose   Display commands that do not contain secrets
--help      Show command help
--version   Show the installer version
```

The menu provides:

```text
1. Create new K3s cluster (Node 1 manager setup)
2. Join existing K3s cluster as a manager node (control-plane + etcd)
3. Join K3s cluster as a worker node
4. Upgrade K3s cluster worker node to manager (control-plane + etcd)
5. Validate this node and cluster
6. Repair safe local differences
7. Exit
```

If K3s is already present, the installer displays a warning before the menu. Fresh-create and fresh-join operations are then blocked before asking for a token or making storage changes. This protects operators who accidentally run the script on an existing node.

## Creating a new cluster

Run option 1 on the first manager. The installer:

1. Collects and validates the hostname, node address, API VIP, MetalLB range, and storage choice.
2. Shows a complete preflight and change summary.
3. Makes no storage change until the operator accepts the summary.
4. Creates root-owned K3s configuration with ServiceLB disabled and the VIP in the TLS SAN list.
5. Installs the pinned K3s version and waits for authenticated API, Ready, control-plane, and etcd checks.
6. Installs kube-vip, MetalLB, and Longhorn declaratively.
7. Runs a final health report.

Run option 2 on manager two and manager three, one at a time. Paste the server token at the hidden prompt. The token is never echoed or written to the general installer state file.

Run option 3 on remaining workers. Cluster-wide components are not reinstalled; the script prepares local prerequisites and waits until the worker is registered and Ready.

## Longhorn storage choices

All storage modes expose `/var/lib/longhorn`, allowing first servers, joining managers, and workers to use the same Longhorn default path.

### Option 1: shared root filesystem

This is the simplest choice. It is permitted only when root is ext4 or XFS, at least 120 GiB total, and at least 60 GiB free.

The default guardrails are:

```text
Longhorn scheduling reservation: 30%
Minimum available percentage:    25%
Over-provisioning:               100%
```

The 30% reservation is a Longhorn scheduling rule, not a filesystem quota. The operating system and Longhorn still consume the same real free space. Use a separate partition or disk when a hard capacity boundary is required.

### Option 2: new or existing partition on the OS disk

The installer can guide creation of a Longhorn partition without resizing existing filesystems:

1. It identifies the physical OS disk and requires a GPT partition table.
2. It reads the partition table and finds the largest genuinely unallocated region.
3. It reports the available GiB and recommends using the region minus approximately 1 GiB for alignment and recovery margin.
4. It asks for the desired whole-number partition size, with a minimum of 100 GiB.
5. It records the plan but changes nothing until the complete installation summary is accepted.
6. It rechecks that the same byte range is still unallocated.
7. It requires the operator to type an exact `CREATE ... ON /dev/...` confirmation.
8. It creates only the new partition, formats it as ext4 with label `longhorn-data`, and mounts it by UUID.

If the standard `parted` utility is missing, the installer explains why it is needed and asks before installing the Ubuntu package. Installing that utility does not alter the partition table.

The installer never shrinks, moves, or reformats an existing OS partition. If no unallocated region exists, create space using an appropriate offline/rescue workflow or choose a separate disk. An already-created empty partition of at least 100 GiB can also be selected from a numbered list.

If partition creation succeeds but Linux cannot expose the new device immediately, the installer stops with recovery instructions. Reboot and rerun; the empty partition will be offered as an existing candidate instead of creating another blindly.

### Option 3: separate physical disk

This is the recommended choice for important data. The installer displays a numbered list containing only disks that:

- Are not the OS disk.
- Have no partitions.
- Have no partition table, filesystem signature, or mount.
- Are at least 100 GiB.

The operator selects a number, reviews the complete plan, and must then type the exact disk path before any destructive action. The installer creates GPT, one ext4 partition, label `longhorn-data`, and a UUID-based `/etc/fstab` mount.

For separate storage, systemd drop-ins require `/var/lib/longhorn` to be mounted before either `k3s` or `k3s-agent` starts. Existing data at the mount path causes a hard stop rather than being hidden or overwritten.

Longhorn replication is not a backup. Maintain tested backups outside the cluster.

## Promoting a worker to manager

Option 4 is a controlled role reinstall, not a label change. K3s cannot run separate agent and server services simultaneously.

The workflow requires the worker to be drained and deleted from Kubernetes using a healthy manager. It then:

- Requires the exact confirmation `DRAINED-AND-DELETED`.
- Requests the more privileged K3s server token silently.
- Backs up protected local configuration under `/etc/k3s-bootstrap/promotion-backup-TIMESTAMP`.
- Warns that the official agent uninstaller removes local K3s, kubelet, `emptyDir`, and local-path provisioner data.
- Requires an exact `PROMOTE NODE_NAME` confirmation.
- Reinstalls the node as a server and validates Ready, control-plane, and etcd membership.

Longhorn data is not intentionally removed, but verify healthy replicas and backups first. When replacing a failed manager, remove the failed etcd member safely and confirm that the remaining cluster has quorum before promotion.

## Validation and safe repair

Option 5 produces a read-only health report covering the OS, network, K3s service, Kubernetes API, node readiness and roles, API VIP, kube-vip, ServiceLB, MetalLB, Traefik, iSCSI, Longhorn, and the expected storage mount/UUID.

Option 6 offers only narrow repairs such as starting a stopped service or installing `open-iscsi`. It does not reset etcd, recreate cluster identity, delete workloads, or overwrite ambiguous configuration automatically.

## Safety and idempotency

- Existing K3s is announced immediately and blocks fresh installation modes.
- Existing Longhorn data blocks initialization or joining until reviewed manually.
- Files are compared before replacement and receive timestamped backups.
- K3s restarts only when its configuration changes.
- Disk devices are never automatically chosen.
- Destructive storage work requires both the overall installation confirmation and a device-specific exact-text confirmation.
- The OS disk is rejected by dedicated-disk mode.
- Existing partitions, filesystems, and mounted disks are rejected by dedicated-disk mode.
- Join tokens are read silently and never written to logs or general state.
- `/etc/k3s-bootstrap/config` stores non-secret installation intent with mode `0600`.
- There is no general cluster reset or uninstall mode.

## MetalLB and Traefik

The MetalLB pool is checked for ordering and overlap with the node address and API VIP. The operator must confirm that the range is reserved outside DHCP. Existing pools are inspected rather than silently replaced during joins.

K3s manages packaged Traefik. Reserve a specific MetalLB address using a K3s `HelmChartConfig`; do not edit generated resources that K3s will overwrite. `templates/traefik/helmchartconfig-example.yaml` provides a starting point.

`examples/external-service/grafana.yaml` shows how a selectorless Service, EndpointSlice, and Ingress can expose an application running outside Kubernetes through the same Traefik instance.

## Backups and operational security

- Back up etcd snapshots, application data, `/etc/rancher/k3s`, and installer state before maintenance.
- Store Longhorn backups on independent NFS or object storage; replicas alone do not protect against deletion, corruption, or cluster loss.
- Protect the server token as an administrative secret.
- Coordinate manager maintenance and reboots one node at a time.
- Optional unattended upgrades are restricted to security updates and automatic reboot is disabled.
- Restrict access to installer logs under `/var/log/k3s-bootstrap/`; they are created with mode `0600`.

## Testing

Static and unit checks:

```bash
shellcheck bootstrap.sh k3s-bootstrap.sh lib/*.sh tests/*.sh
bash tests/test-bootstrap.sh
bash tests/test-functions.sh
```

The optional `tests/smoke-longhorn.sh` test creates a small PVC, writes a unique value, removes the writer pod, reattaches the claim, and verifies the same value. Run it only after the cluster is healthy. A retained PV may require deliberate administrative cleanup because the StorageClass reclaim policy is `Retain`.

## Known limitations

- Nodes are installed one at a time; this release is not a remote multi-node orchestrator.
- Join tokens must be entered manually on each joining node.
- Existing volume replica counts are never changed automatically.
- The installer does not restore etcd snapshots, Longhorn backups, or application manifests.
- Guided same-disk partition creation supports GPT only and consumes existing unallocated space; it does not shrink filesystems.
- Address-conflict and Layer-2 checks reduce common mistakes but cannot prove the surrounding network configuration is correct.

## Publishing releases

This section is for project maintainers, not cluster operators.

1. Update `VERSION` and `CHANGELOG.md`, and run all tests.
2. Commit the release, then create a stable semantic-version tag that exactly matches `VERSION`, for example `v0.1.0`.
3. Push the commit and tag to `https://github.com/cyberpoe-uk/K3sDeploy`.
4. Publish `bootstrap.sh` unchanged at `https://cyberpoe.uk/k3s-deploy-latest`.
5. Download the public endpoint, compare it with `bootstrap.sh`, and test it on a disposable supported Ubuntu node before announcing the release.

The launcher deliberately selects tags shaped like `vMAJOR.MINOR.PATCH` (or the same form without `v`) and rejects a release when its tag and `VERSION` disagree. This prevents the convenient URL from silently running the default development branch.

## Troubleshooting

Start with option 5 and the latest file under `/var/log/k3s-bootstrap/`. Useful commands include:

```bash
systemctl status k3s
systemctl status k3s-agent
journalctl -u k3s
sudo k3s kubectl get nodes -o wide
sudo k3s kubectl get pods -A
findmnt /var/lib/longhorn
```

An unauthenticated HTTP `401 Unauthorized` only means the API endpoint answered. The installer uses authenticated Kubernetes requests for health decisions. Never delete `/var/lib/rancher` or `/var/lib/longhorn` as a troubleshooting shortcut.

## License

This project is released under the MIT License. See `LICENSE`.

## Upstream documentation

- [K3s installation requirements](https://docs.k3s.io/installation/requirements)
- [K3s high availability with embedded etcd](https://docs.k3s.io/datastore/ha-embedded)
- [Longhorn v1.12.1 best practices](https://longhorn.io/docs/1.12.1/best-practices/)
- [Longhorn disk and scheduling settings](https://longhorn.io/docs/1.12.1/references/settings/)
- [Longhorn filesystem disk configuration](https://longhorn.io/docs/1.12.1/nodes-and-volumes/nodes/multidisk/)
