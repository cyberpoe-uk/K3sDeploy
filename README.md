# K3sDeploy

K3sDeploy is an interactive Linux installer for building and maintaining a small highly available K3s cluster. It guides the operator through networking, node roles, API high availability, application load balancers, ingress, and persistent storage without requiring prior Kubernetes installation experience.

The project favors visible checks and explicit confirmation over unattended destructive changes. Cluster membership reset and snapshot restore exist only in clearly labelled disaster-recovery workflows with protected backups and exact confirmation. K3sDeploy does not erase unidentified disks, retrieve tokens from remote machines, or silently replace existing cluster configuration.

## What it installs

| Component | Version | Purpose |
| --- | --- | --- |
| K3s | `v1.36.4+k3s1` | Kubernetes distribution |
| kube-vip | `v1.2.3` | Highly available Kubernetes API virtual IP |
| MetalLB | `v0.16.1` | Recommended-profile `LoadBalancer` addresses for applications |
| Traefik | K3s packaged version | HTTP and HTTPS ingress |
| Longhorn | `v1.12.1` | Recommended-profile replicated persistent storage using the V1 filesystem engine |
| NFS CSI driver | `v4.13.4` | Optional shared NFS storage using an existing NFSv4.1 server/export |

Versions are pinned in `config/versions.env`. Installations never follow a moving `latest` tag. The recommended profile disables K3s ServiceLB because MetalLB owns application load-balancer addresses, and disables K3s local-path because Longhorn owns persistent storage. Local-path is enabled only when an advanced-profile user explicitly accepts its non-HA risk. The advanced profile can retain either built-in component or leave that responsibility to an external system. kube-vip is used only for the Kubernetes API.

> MetalLB v0.16.1 matches the validated platform, but its released images have a reported fixable gRPC vulnerability as of September 2026. Review upstream security releases and test any pin change before production use.

## Prerequisites

Prepare every node before running the installer.

### Operating system and access

- A systemd-based Linux distribution using `apt`, `dnf`, `yum`, or `zypper`. Ubuntu Server 24.04 LTS is the primary tested target. Verify a non-Ubuntu distribution in a disposable node before production use.
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

When using the recommended profile or choosing Longhorn in the advanced profile, each node needs one of the following:

- An ext4 or XFS root filesystem of at least 120 GiB with at least 60 GiB currently free.
- A GPT-formatted OS disk with at least 20 GiB plus alignment margin genuinely unallocated for a new Longhorn partition.
- A Linux LVM volume group containing at least 20 GiB plus a 1 GiB safety margin in free extents.
- An empty separate physical or virtual disk of at least 20 GiB.

Longhorn and K3s do not define one universal capacity minimum because the correct size depends on PVC sizes, replicas, snapshots, backups, and expected growth. K3sDeploy uses 20 GiB as a small-lab installation floor and recommends planning at least 100 GiB per storage node for general use. These are project guardrails, not upstream guarantees. Change them deliberately in `config/defaults.env` when your capacity plan requires different values.

### Network planning

Decide these addresses before installation:

- One fixed Kubernetes API VIP on the same Layer-2 network as the managers.
- One unique static address per node.
- A MetalLB range excluded from DHCP and all node/VIP addresses when MetalLB is selected.
- TCP `2049` access from every node to the same NFS server when shared NFS is selected.

Allow the required traffic between nodes. Important defaults include TCP `6443` for the API, TCP `2379-2380` between embedded-etcd managers, UDP `8472` for Flannel VXLAN, and TCP `10250` between nodes. Do not expose UDP `8472` to untrusted networks.

## Recommended cluster layout

Use an odd number of manager nodes. Three managers is appropriate for most small and medium installations. Five may be useful across additional failure domains. Do not turn all machines in a 20–30 node cluster into etcd voters.

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

Run K3sDeploy directly on each cluster node, one node at a time. Do not install it on a separate administration machine and do not copy one node's generated K3s configuration to another node.

Run every command in this section as your normal login user, without putting `sudo` in front of it. K3sDeploy asks for your sudo password when a privileged change is actually required.

### Recommended: clone the repository

Cloning leaves a local copy that you can inspect, rerun for validation, and use later for safe repair:

```bash
# Debian or Ubuntu
sudo apt-get update
sudo apt-get install -y git

# Fedora, RHEL, Rocky Linux, AlmaLinux, or another dnf system
sudo dnf install -y git

# SUSE or openSUSE
sudo zypper install git

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

Install `curl` first if the operating system image does not include it:

```bash
# Debian or Ubuntu
sudo apt-get update
sudo apt-get install -y curl

# dnf-based systems
sudo dnf install -y curl

# SUSE or openSUSE
sudo zypper install curl
```

```bash
bash <(curl -fsSL https://cyberpoe.uk/k3sdeploy-latest)
```

For the inspect-before-running form:

```bash
curl -fsSLo k3sdeploy-latest https://cyberpoe.uk/k3sdeploy-latest
less k3sdeploy-latest
bash k3sdeploy-latest
```

The launcher installs Git only after asking permission if Git is missing. It never runs the main installer with `sudo`. Its temporary download is removed when the menu exits, so clone the repository instead if you want to keep the exact files used on the node.

The short URL works only after the website endpoint and at least one matching Git tag, such as `v0.1.0`, have been published. It intentionally refuses development branches and prerelease tag names.

### Already downloaded

If you downloaded a release archive instead of using Git, extract the complete archive first. K3sDeploy is a multi-file project. Downloading only `k3s-bootstrap.sh` will not work.

```bash
cd K3sDeploy-0.1.0
./k3s-bootstrap.sh
```

## Running the installer

K3sDeploy starts with its yellow identity banner and asks for an installation profile before displaying the node-action menu:

When stdin and stdout are attached to an interactive terminal, menus use an arrow-key selector. Move with Up/Down or `j`/`k`, then confirm with Enter or Space. Number keys also move directly to the matching item. Redirected input, basic terminals, and automated runs receive ordinary numbered prompts instead. Use `--plain-menu` to request those prompts explicitly for screen readers or terminal compatibility. Titles and progress panels use the K3sDeploy yellow identity colour. Informational, successful, warning, and error messages use distinct terminal colours. Set the conventional `NO_COLOR=1` environment variable or use `--no-color` to disable colour without disabling interactive menus. If your shell already exports `NO_COLOR`, K3sDeploy explains why its output is plain. Use `--color` to override that variable for one run.

Unavailable choices remain visible so the reason is clear, but they are grey and cannot be selected. Arrow navigation skips them, and numbered-prompt mode asks again if an unavailable number is entered.

- **Recommended installation:** the guided path used throughout this README. K3sDeploy configures kube-vip, MetalLB, and Longhorn.
- **Advanced/custom installation:** MetalLB remains the recommended load balancer, but K3s ServiceLB or an externally managed system can be selected. Storage choices are Longhorn, guided shared NFS, explicitly accepted non-HA local-path, or another externally managed system.

“External” means K3sDeploy deliberately leaves that component uninstalled. For Longhorn, NFS, or external storage, it disables K3s local-storage so an unintended node-local StorageClass does not compete with the selected provider. The local-path choice retains K3s's simple node-local provisioner, displays a data-loss warning, and requires the exact confirmation `ACCEPT-NON-HA-STORAGE`. It does not provide replication or failover. K3sDeploy does not guess how to configure Cilium, a cloud controller, another load balancer, or another CSI provider. Install and validate an unmanaged external system using its own documentation. Use the same advanced choices on every node in one cluster.

Available flags:

```text
--dry-run   Display intended host changes where practical
--verbose   Display commands that do not contain secrets
--yes       Accept ordinary confirmations. Exact destructive confirmations remain required
--color     Force terminal colours even when NO_COLOR is set
--no-color  Disable terminal colours without disabling arrow-key menus
--plain-menu Use numbered prompts instead of the interactive arrow-key selector
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
7. Recover lost embedded-etcd quorum (disaster recovery)
8. Restore an embedded-etcd snapshot (disaster recovery)
9. Exit
```

If K3s is already present, the installer displays a warning before the menu. Fresh-create and fresh-join operations are then blocked before asking for a token or making storage changes. This protects operators who accidentally run the installer on an existing node.

Input mistakes are recoverable. Invalid addresses, occupied VIPs, rejected join tokens, invalid MetalLB ranges, and unavailable storage choices return to the relevant prompt or installer menu. A workflow still stops immediately when continuing could damage existing data or compound a partial installation. The main installer remains open so the operator can review the message, correct the condition, and choose an option again.

## Creating a new cluster

Run option 1 on the first manager. The installer:

1. Collects and validates the hostname, node address, API VIP, and the selected load-balancer and storage choices.
2. Shows a complete preflight and change summary.
3. Makes no storage change until the operator accepts the summary.
4. Creates root-owned K3s configuration with the VIP in the TLS SAN list and the selected ServiceLB policy.
5. Installs the pinned K3s version and waits for authenticated API, Ready, control-plane, and etcd checks.
6. Installs kube-vip and any supported load-balancer and storage components selected in the profile.
7. Runs a final health report.
8. After health checks pass, creates an official K3s on-demand etcd snapshot on the manager.

Run option 2 on manager two and manager three, one at a time. K3sDeploy asks for the existing API VIP first. After confirming that the API is reachable, it explains how to retrieve the full secure server token with `sudo cat /var/lib/rancher/k3s/server/token` on a healthy manager and opens a hidden token field. Before collecting hostname or storage choices, K3sDeploy verifies the cluster CA and authenticates against the existing manager. The token is never echoed or written to the general installer state file.

Treat the server token as a cluster-administrator secret. If it is accidentally pasted into a visible prompt, terminal recording, issue, or chat, rotate it before relying on the cluster in production. Follow the [official K3s server-token rotation procedure](https://docs.k3s.io/cli/token#k3s-token-rotate), update and restart every server or agent that originally joined with the old token, and retain the old token with any older datastore snapshot that still requires it.

After K3s reports the new node Ready, K3sDeploy waits for the existing kube-vip, MetalLB, and selected storage workloads to expand onto that node. Final validation starts only after those managed add-ons are ready, preventing normal startup time from being reported as a failure. A successful manager join or worker-to-manager promotion also creates an official local milestone snapshot on that new manager.

Run option 3 on remaining workers. Cluster-wide components are not reinstalled. The installer prepares local prerequisites and waits until the worker is registered and Ready.

## Longhorn storage choices

This section applies when Longhorn is selected. All Longhorn storage modes expose `/var/lib/longhorn`, allowing first servers, joining managers, and workers to use the same default path.

### Option 1: shared root filesystem

This is the simplest choice, but it is not recommended. Longhorn and the operating system consume capacity from the same filesystem, so unexpected storage growth can put the node and its workloads under pressure. They also share the same physical disk failure domain. The option is permitted only when root is ext4 or XFS, at least 120 GiB total, and at least 60 GiB free.

The storage menu marks this choice `Unavailable` when those requirements are not met, includes the reason in brackets, greys it out, and skips it during selection. The size of the underlying disk does not make a smaller root filesystem eligible automatically.

The default guardrails are:

```text
Longhorn scheduling reservation: 30%
Minimum available percentage:    25%
Over-provisioning:               100%
```

The 30% reservation is a Longhorn scheduling rule, not a filesystem quota. The operating system and Longhorn still consume the same real free space. Prefer option 2 or option 3 for a dedicated capacity boundary.

### Option 2: separate storage on the OS disk (LVM or partition)

This is a recommended choice when a separate physical or virtual disk is not available. It gives Longhorn a separate filesystem and protects root capacity without resizing existing filesystems. It still shares the OS disk, so it does not protect a Longhorn replica from failure of that physical or virtual disk. The installer understands both ordinary partition layouts and common Linux LVM layouts.

Seeing a smaller root filesystem and a larger OS disk is not an error. For example, a Linux installer may place a 59 GiB root logical volume on a 120 GiB physical or virtual disk while the rest remains free inside the LVM volume group. That space is not visible to `parted` as unallocated disk space, so K3sDeploy checks both layers separately.

The same rule applies after a virtual disk is expanded. A VM can report a 220 GiB `/dev/sda` while `/` remains a 59 GiB logical volume. Shared-root storage is still unavailable because its guardrails apply to the mounted root filesystem, not the capacity of the disk beneath it. Choose separate OS-disk storage so K3sDeploy can inspect free LVM extents and unallocated space. The installer never grows the root filesystem automatically.

If `lsblk` already reports the intended virtual-disk size, the guest can see that capacity. Hypervisor thin or thick provisioning does not explain a smaller root logical volume. The unused capacity may simply be free inside LVM. Check it with `sudo vgs` and `sudo lvs`. In that layout, option 2 creates separate Longhorn storage from the free extents without expanding or shrinking root.

For an LVM-based root, the installer:

1. Identifies the root volume group and reports its genuinely free extents.
2. Confirms that the existing root allocation is approximately 30% or more of the OS disk and still has at least 15 GiB available.
3. Recommends a Longhorn logical-volume size while leaving approximately 1 GiB free in the volume group.
4. Shows the complete plan and requires the exact confirmation `CREATE`.
5. Creates a new logical volume without shrinking or changing the existing root volume.
6. Formats it as ext4 and mounts it by UUID at `/var/lib/longhorn`.

For a non-LVM layout with physical unallocated space, the installer:

1. Identifies the physical OS disk and requires a GPT partition table.
2. Reads the partition table and finds the largest genuinely unallocated region.
3. Reports the available GiB and recommends using the region minus approximately 1 GiB for alignment and recovery margin.
4. Asks for the desired whole-number partition size, with a 20 GiB small-lab floor and a warning below the 100 GiB general-use recommendation.
5. Records the plan but changes nothing until the complete installation summary is accepted.
6. Rechecks that the same byte range is still unallocated.
7. Requires the operator to type the exact confirmation `CREATE`.
8. Creates only the new partition, formats it as ext4 with label `longhorn-data`, and mounts it by UUID.

If the standard `parted` utility is missing, the installer explains why it is needed and asks before installing the distribution package. Installing that utility does not alter the partition table.

The installer never shrinks, moves, or reformats an existing root filesystem, logical volume, or OS partition. If neither LVM free extents nor physical unallocated space exists, it recommends returning to root storage when eligible or adding an empty virtual/physical disk. An already-created empty partition of at least 20 GiB can also be selected from a numbered list.

If partition creation succeeds but Linux cannot expose the new device immediately, the installer stops with recovery instructions. Reboot and rerun. The empty partition will be offered as an existing candidate instead of creating another blindly.

### Option 3: separate disk (physical or virtual)

This is the recommended choice for the strongest storage isolation. Longhorn capacity is independent of the operating-system disk, and failure of the Longhorn disk does not directly consume or damage the root filesystem. The installer displays a numbered list containing only disks that:

- Are not the OS disk.
- Have no partitions.
- Have no partition table, filesystem signature, or mount.
- Are at least 20 GiB. Disks below the 100 GiB general-use recommendation receive a clear capacity warning.

The operator selects a number, reviews the complete plan, and must then type the exact disk path before any destructive action. The installer creates GPT, one ext4 partition, label `longhorn-data`, and a UUID-based `/etc/fstab` mount.

For a virtual machine, attach a new empty virtual disk using the controls provided by the hypervisor or cloud platform. Follow that platform's instructions about whether the VM must be shut down or can hot-add storage. After Linux shows the new device in `lsblk`, rerun K3sDeploy and choose option 3. This applies to Proxmox, VMware, Hyper-V, KVM/libvirt, and cloud VMs. K3sDeploy does not assume one virtualization platform.

For a physical machine, install an empty SSD or NVMe device, boot the machine, verify the new device with `lsblk`, and rerun option 3. K3s recommends SSD-backed storage when possible because cluster performance depends on database performance. Longhorn also recommends SSD/NVMe for performance and stability, especially during replica rebuilds and concurrent I/O. HDD storage is supported but is better suited to lighter or less latency-sensitive workloads.

For separate storage, systemd drop-ins require `/var/lib/longhorn` to be mounted before either `k3s` or `k3s-agent` starts. Existing data at the mount path causes a hard stop rather than being hidden or overwritten.

Longhorn replication is not a backup. Maintain tested backups outside the cluster.

K3sDeploy configures a desired count of three replicas for new Longhorn volumes and enables Longhorn's `least-effort` replica auto-balancing. The desired count is deliberately capped at three. It does not increase to 5, 10, or 20 replicas as more nodes join. A one-node bootstrap is not storage-HA: three storage-capable nodes are required before new three-replica volumes can become fully healthy. Depending on Longhorn's degraded-availability policy, early volume creation may remain degraded or wait for enough eligible nodes. As eligible nodes and disks appear, Longhorn can schedule or rebuild the missing copies toward the existing three-replica target, so K3sDeploy does not rewrite every volume during each node join.

Changing a StorageClass affects only volumes created afterward. K3sDeploy therefore sets the final desired count from the beginning instead of starting at one and repeatedly changing it. Volumes deliberately created with another StorageClass or replica count are not silently rewritten. Do not treat the cluster as storage-HA until all required replicas are healthy on separate nodes.

## Shared NFS storage

The advanced profile can configure the pinned Kubernetes NFS CSI driver against an existing NFSv4.1 service. K3sDeploy asks for values such as:

```text
NFS server: 10.10.20.40
NFS export: /mnt/pool/k3s
```

The same server and export must be reachable from every cluster node. K3sDeploy installs the operating system's NFS client package, checks TCP port `2049`, temporarily mounts the export with restrictive mount options, creates and removes a probe directory to verify provisioning access, installs the pinned CSI driver on the first manager, and creates the default `nfs-csi-retain` StorageClass with retained backing directories and a `Retain` reclaim policy.

Shared does not automatically mean highly available. A single NFS server, network path, or underlying pool can still be a single point of failure. Use an HA NFS service and independently protected data when the cluster requires storage availability. The NFS CSI driver dynamically provisions subdirectories. It does not create, replicate, back up, or repair the NFS server itself.

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

Option 5 produces a read-only health report covering the OS, network, K3s service, Kubernetes API, node readiness and roles, API VIP, kube-vip, ServiceLB, MetalLB, Traefik, iSCSI, Longhorn, and the expected storage mount/UUID. It finishes with a counted health result so failed checks cannot be mistaken for a successful workflow. Components intentionally omitted by the advanced profile are reported as `SKIP`. On a clean node, software that has never been installed is reported as `MISSING` or `SKIP` rather than failed. If the local datastore and current-boot K3s logs strongly indicate lost embedded-etcd quorum, validation explains that add-on failures may be consequences of the unavailable API and asks `[Y/n]` whether to continue directly into option 7. Answering `n` leaves validation fully read only. Answering Yes starts option 7 as a separate workflow, which repeats its eligibility checks and still requires the exact reset confirmation.

If a node created by an older K3sDeploy release still exposes the local-path provisioner while Longhorn, NFS, or external storage is selected, validation reports a warning instead of deleting or reconfiguring potentially used storage automatically.

Option 6 offers only narrow repairs such as starting an existing stopped service, installing a required storage client, repairing the managed kube-vip DaemonSet, or continuing a saved MetalLB, Longhorn, or NFS CSI installation that stopped partway through. It asks before reconciling a missing add-on. kube-vip repair first waits for K3s to accept the current template, then detects terminal container startup failures and prints the termination reason, exit code, logs, and pod events without waiting through the full rollout timeout. Repair always runs the same health report as option 5 afterward and explains that a second manual validation run is unnecessary. When Longhorn is selected, no failed checks remain, and at least two ready schedulable storage nodes exist, it offers an optional functional storage test. On a first-node cluster it explains what that test can and cannot prove and defers the automatic prompt. Workers direct the operator to run the cluster-wide test from a manager because they do not hold an administrative kubeconfig. On a clean node repair explains that there is nothing to repair and points to installation options 1–3. It never attempts to start a nonexistent service. It does not reset etcd, recreate cluster identity, delete workloads, or overwrite ambiguous configuration automatically. If it detects strong lost-quorum evidence, it runs the read-only health report and offers the same default-Yes transition to option 7. Lost-quorum recovery remains isolated there because it changes datastore membership.

## Lost embedded-etcd quorum recovery

Option 7 is a disaster-recovery workflow for a specific failure: an embedded-etcd manager still has its local datastore, but the cluster can no longer reach a majority of its manager members. It is not a general K3s repair and it is not offered automatically by option 6.

Embedded etcd requires a majority of managers to make progress. A two-manager cluster requires both managers. If either one disappears, the remaining manager cannot form quorum. Build to three managers before testing failures because a three-manager cluster can tolerate one unavailable manager. Joining a second manager is only an intermediate deployment state, not HA.

Use option 7 only when the missing manager or managers cannot be returned with their current datastore. If they can be brought back safely, restoring the original quorum is preferable to resetting membership. Before selecting recovery, power off or isolate every other former manager. An old manager must never reconnect using its pre-reset `/var/lib/rancher/k3s/server/db` data.

The workflow refuses to reset unless all of these conditions are true:

- The machine has the K3s server service and local embedded-etcd member data.
- The protected K3sDeploy state file is present and no external datastore configuration is detected.
- The Kubernetes readiness endpoint is unavailable.
- Recent K3s service logs contain a strong lost-quorum pattern, such as failure to publish the local member through Raft with a deadline exceeded error.
- The managed K3s configuration can be converted unambiguously to a single-member configuration.
- The local filesystem has enough room for the current protected state plus 100 MiB of backup headroom.
- No prior reset-completion flag indicates that the reset has already run.
- The operator types the exact confirmation `RESET ETCD TO HOSTNAME`. The `--yes` flag cannot bypass it.

After confirmation, K3sDeploy:

1. Stops K3s so the local datastore copy is consistent.
2. Creates and verifies a root-only archive under `/var/lib/rancher/k3s/server/etcd-recovery/`. This archive contains tokens and private keys and must be protected.
3. Preserves the accepted node, networking, TLS SAN, and component settings while removing old join-server and join-token settings.
4. Runs `k3s server --cluster-reset` once without a snapshot, making the current manager the sole etcd member.
5. Starts K3s normally and verifies that the API, local node, control-plane role, and etcd role return.
6. Deletes stale Kubernetes Node objects only for other etcd-labelled managers so manager DaemonSets can converge. Worker Node objects and Longhorn node records are not deleted.
7. Runs the normal health report and prints the required rebuild and rejoin order.

If K3s already recorded reset completion but the normal service was not restarted, option 7 enters resume mode and requires `RESUME ETCD ON HOSTNAME`. It starts and verifies K3s without running the reset again.

After recovery, review Longhorn volume health, replica placement, and stale Longhorn node records before deleting anything storage-related. Restore each former manager from a clean pre-join snapshot or rebuild it. If an experienced operator deliberately reuses its installation, the old `/var/lib/rancher/k3s/server/db` must be removed before it joins the recovered cluster. Join manager two and then manager three one at a time, validating after each join. Do not treat the recovered one-member or intermediate two-member control plane as highly available.

This workflow resets membership from the surviving manager's current data. It does not restore an etcd snapshot, recover application data that is already absent, or reconcile a rolled-back Longhorn disk. Virtual-machine snapshots taken at different times are not a coordinated cluster backup. Maintain K3s etcd snapshots and application backups outside the cluster. See the [official K3s snapshot and restore documentation](https://docs.k3s.io/cli/etcd-snapshot) and [embedded-etcd HA guidance](https://docs.k3s.io/datastore/ha-embedded).

## Embedded-etcd snapshots and restore

Every manager installed by K3sDeploy explicitly enables K3s's native compressed embedded-etcd snapshots. Each manager saves its own local snapshot every 12 hours and retains the five newest scheduled snapshots. This gives more than one manager a local recovery point, but copies on cluster nodes still share the cluster's failure domains.

K3sDeploy also creates an on-demand milestone snapshot after a successful first-manager installation, manager join, worker promotion, quorum recovery, or snapshot restore. First-manager snapshots are created after kube-vip, the selected load balancer, and the selected storage controller are installed and health validation has passed. On a healthy manager installed by an older K3sDeploy release, option 6 offers a one-time baseline when it cannot find an existing K3sDeploy milestone. Scheduled snapshots then capture later Kubernetes changes, including deployed application objects. On-demand snapshots are not removed by K3s's scheduled-snapshot retention, so review old milestone and pre-restore snapshots during planned maintenance.

The normal local snapshot directory is `/var/lib/rancher/k3s/server/db/snapshots`. K3sDeploy reads `data-dir` or `etcd-snapshot-dir` from the managed K3s configuration when either value changes that location. Use `sudo k3s etcd-snapshot list` to inspect snapshots. Copy important snapshots and `/var/lib/rancher/k3s/server/token` to encrypted off-node storage. A local snapshot is lost if that manager or its disk is lost. K3s also supports S3-compatible snapshot storage, but this release does not collect or store S3 credentials.

Option 8 restores an official local K3s snapshot. It does not accept the raw `pre-quorum-reset-*.tar.gz` safety archives. The workflow:

1. Requires an installed manager with local embedded-etcd data and K3sDeploy state.
2. Finds the configured local snapshot directory and lists safe regular snapshot files with newest first.
3. Explains that etcd contains Kubernetes objects and configuration, but not Longhorn, NFS, or application volume contents.
4. Creates a current-state on-demand snapshot first when the API is healthy.
5. Requires confirmation that every other manager is stopped or isolated, followed by an exact `RESTORE SNAPSHOT ON HOSTNAME` confirmation. The `--yes` flag cannot bypass the exact confirmation.
6. Stops K3s and creates a verified root-only archive of the current configuration, token, and server database under `/var/lib/rancher/k3s/server/etcd-recovery/`.
7. Runs the official local K3s snapshot restore with `--cluster-reset-restore-path`, making the selected manager the sole etcd member.
8. Starts K3s, removes stale Kubernetes Node objects for other managers, validates the restored cluster, and creates a new post-restore snapshot when health checks pass.

Restoration rolls Kubernetes state back to the selected time. Kubernetes objects created later may disappear, but their external or persistent data is not rolled back in step with etcd. This can leave storage records and actual volume contents at different points in time, so inspect applications and Longhorn carefully before changing or deleting storage. Clean or rebuild every former manager before it rejoins. Never reconnect an old manager using its pre-restore server database.

After any successful menu workflow, K3sDeploy prints an action-specific completion summary, the final health counts, the log location, and exits normally. A workflow that stops safely because of an invalid input or system condition returns to the menu so the operator can correct it without downloading or starting the installer again.

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
- Embedded-etcd membership reset and snapshot restore exist only in the guarded option-7 and option-8 disaster-recovery workflows. There is no general reset or uninstall shortcut.

## MetalLB and Traefik

The MetalLB pool is checked for ordering and overlap with the node address and API VIP. The operator must confirm that the range is reserved outside DHCP. Existing pools are inspected rather than silently replaced during joins.

K3s manages packaged Traefik. Reserve a specific MetalLB address using a K3s `HelmChartConfig`. Do not edit generated resources that K3s will overwrite. `templates/traefik/helmchartconfig-example.yaml` provides a starting point.

`examples/external-service/grafana.yaml` shows how a selectorless Service, EndpointSlice, and Ingress can expose an application running outside Kubernetes through the same Traefik instance.

## Backups and operational security

- Copy etcd snapshots and the matching server token to protected off-node storage. Local snapshots alone do not survive loss of the manager or its disk.
- Back up application data, `/etc/rancher/k3s`, and installer state before maintenance.
- Store Longhorn backups on independent NFS or object storage. Replicas alone do not protect against deletion, corruption, or cluster loss.
- Protect the server token as an administrative secret.
- Coordinate manager maintenance and reboots one node at a time.
- Optional unattended upgrades are restricted to security updates and automatic reboot is disabled.
- Restrict access to installer logs under `/var/log/k3s-bootstrap/`. They are created with mode `0600`.

## Testing

Static and unit checks:

```bash
shellcheck k3sdeploy-latest.sh k3s-bootstrap.sh lib/*.sh tests/*.sh
bash tests/test-bootstrap.sh
bash tests/test-functions.sh
bash tests/test-interaction.sh
```

The optional Longhorn test creates an isolated namespace, a temporary `Delete` StorageClass, and a 128 MiB one-replica volume. It writes a unique value, removes the writer pod, reattaches the claim to a reader pod, verifies the same value, and removes the namespace and StorageClass. It tests provisioning and persistence without leaving the normal retained StorageClass's PV behind. It does not prove multi-node HA, replica-loss recovery, or backup correctness. K3sDeploy records a successful result in the `k3sdeploy-longhorn-smoke-status` ConfigMap so later validation reports the last pass instead of continuing to say `NOT TESTED`. The first-manager workflow does not offer it automatically. A joining manager and option 6 can offer it once at least two Longhorn storage nodes are ready. A joining worker explains that the test must be started from a manager. It remains available explicitly with `bash tests/smoke-longhorn.sh` after the cluster is healthy.

## Known limitations

- Nodes are installed one at a time. This release is not a remote multi-node orchestrator.
- Join tokens must be entered manually on each joining node.
- Existing volume replica counts are never changed automatically.
- Snapshot restore currently discovers official local K3s snapshots only. S3-compatible remote restore remains a manual K3s operation.
- The installer does not restore Longhorn backups, external storage, or application manifests.
- Guided same-disk partition creation supports GPT only and consumes existing unallocated space. It does not shrink filesystems.
- Address-conflict and Layer-2 checks reduce common mistakes but cannot prove the surrounding network configuration is correct.

## Troubleshooting

Start with option 5 and the latest file under `/var/log/k3s-bootstrap/`. Useful commands include:

```bash
systemctl status k3s
systemctl status k3s-agent
journalctl -u k3s
sudo k3s kubectl get nodes -o wide
sudo k3s kubectl get pods -A
sudo k3s kubectl -n kube-system describe pod -l app=kube-vip
findmnt /var/lib/longhorn
```

K3sDeploy releases before v0.2.8 could create a kube-vip DaemonSet that mounted the host's `/proc/sys/net`. Some current container runtimes reject that procfs bind mount with `StartError` and exit code `128`. Run option 6 with v0.2.8 or newer to replace that template safely. kube-vip uses host networking and the `NET_ADMIN` and `NET_RAW` capabilities without that mount.

An unauthenticated HTTP `401 Unauthorized` only means the API endpoint answered. The installer uses authenticated Kubernetes requests for health decisions. Never delete `/var/lib/rancher` or `/var/lib/longhorn` as a troubleshooting shortcut.

## License

This project is released under the MIT License. See `LICENSE`.

## Upstream documentation

- [K3s installation requirements](https://docs.k3s.io/installation/requirements)
- [K3s high availability with embedded etcd](https://docs.k3s.io/datastore/ha-embedded)
- [K3s packaged components and disable flags](https://docs.k3s.io/installation/packaged-components)
- [K3s volumes and local-path storage](https://docs.k3s.io/add-ons/storage)
- [Kubernetes NFS CSI driver](https://github.com/kubernetes-csi/csi-driver-nfs)
- [NFS CSI driver parameters](https://github.com/kubernetes-csi/csi-driver-nfs/blob/master/docs/driver-parameters.md)
- [Longhorn v1.12.1 best practices](https://longhorn.io/docs/1.12.1/best-practices/)
- [Longhorn disk and scheduling settings](https://longhorn.io/docs/1.12.1/references/settings/)
- [Longhorn filesystem disk configuration](https://longhorn.io/docs/1.12.1/nodes-and-volumes/nodes/multidisk/)
