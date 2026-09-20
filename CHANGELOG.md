# Changelog

## Unreleased

- Remove kube-vip's unnecessary `/proc/sys/net` host mount, which current K3s/containerd/runc combinations can reject with `StartError` before the container starts.
- Detect terminal kube-vip startup failures during rollout and print the current termination reason, exit code, logs, and pod events instead of waiting silently for five minutes.
- Run a counted health summary automatically after safe repair, explain that it replaces a second option-5 run, and offer an optional self-cleaning Longhorn provisioning/persistence test.
- Treat an unready kube-vip DaemonSet or unreachable API VIP as a failed health check, offer a pinned-manifest repair, wait for rollout readiness, and use current kube-vip address/subnet fields with control-plane label affinity.
- Validate MetalLB controller, speaker, address-pool, and advertisement readiness instead of checking only that objects exist.
- Wait for the MetalLB speaker and admission-webhook endpoint, then retry pool configuration during temporary webhook startup failures.
- Correct the repeated MetalLB pool in the installation summary and persist pool details so safe repair can resume a partial first-manager installation.
- Add guided shared NFS storage using the pinned Kubernetes NFS CSI driver, NFSv4.1 reachability/mount checks, and a retained dynamic StorageClass.
- Mark MetalLB and three-replica Longhorn as the HA recommendations, enable least-effort replica auto-balancing, and disable K3s local-storage unless an advanced-profile user explicitly accepts its non-HA risk.
- Allow safe repair to continue missing MetalLB, Longhorn, or NFS CSI add-ons from saved installer state.
- Warn when an older installation still exposes the non-selected local-path provisioner instead of removing potentially used storage automatically.
- Add a yellow K3sDeploy identity banner and a startup choice between recommended and advanced/custom installation profiles.
- Let advanced users select MetalLB, built-in K3s ServiceLB, or external load balancing, plus Longhorn, K3s local-path, or external persistent storage; intentionally omitted components are skipped during installation and validation.
- Prevent a normal clean-node Longhorn mount check from aborting phase 2 under strict error handling.
- Group interactive output into clearly separated sections and expand installation workflows so error line numbers identify the failing operation.
- Parse `/etc/os-release` without sourcing it, avoiding a collision between its `VERSION` field and K3sDeploy's read-only installer version.
- Keep the interactive installer open after recoverable workflow failures; invalid VIPs, join credentials, hostnames, address pools, and menu selections can now be corrected without restarting it.
- Detect the operating system and use its `apt`, `dnf`, `yum`, or `zypper` package manager instead of presenting Ubuntu-specific dependency instructions.
- Replace legacy user-facing product wording with “installer” and “K3sDeploy Installer”.
- Correct LVM root-volume discovery when Linux exposes the mounted root as `/dev/dm-*`, so free volume-group extents are reported instead of `0 GiB`.
- Mark ineligible shared-root storage without terminating the installer, and return the operator to the storage menu with physical and virtualization-neutral disk guidance.
- Distinguish a positive ARP duplicate-address response from an operational probe failure; occupied VIPs now stop safely, with ICMP used only as a fallback signal.
- Recommend SSD/NVMe storage for K3s and Longhorn while retaining HDD support for appropriate workloads.
- Default-Yes confirmations for detected hostname/address, network reservations, and safe dependency or service operations; destructive and risk-acceptance prompts remain default-No.
- Optional installation of the detected operating system's arping package before checking whether a new API VIP is already in use.
- Guided creation of a dedicated Longhorn LVM logical volume from free extents in common Linux layouts, with root-headroom checks and exact confirmation.
- Clean-node validation now reports uninstalled components as `MISSING` or `SKIP`, and safe repair no longer offers to start a nonexistent K3s service.
- Manager and worker joins verify the existing API VIP and secure join token before collecting local storage choices.
- Removed hardcoded lab network addresses; hostname and detected node-address confirmations now include beginner-facing guidance.
- Corrected physical OS-disk discovery through LVM/device-mapper ancestry and clarified guided OS-partition creation.
- Replaced the arbitrary 100 GiB Longhorn hard minimum with a 20 GiB small-lab floor plus a 100 GiB general-use recommendation and capacity warning.

## v0.1.0 - 19-09-2026

- Initial interactive first-server, server-join, validation and safe-repair workflows.
- Pinned K3s, kube-vip, MetalLB and Longhorn manifests.
- Conservative root/dedicated storage selection and pure-function tests.
- Normal-user launch with scoped sudo elevation and an explicit phase-progress banner.
- Worker/agent joins for larger clusters; recommends three or five etcd servers rather than making every node an etcd member.
- Guarded worker-to-manager promotion with drain/delete instructions, exact destructive confirmation, protected local backup, server-token join, and post-promotion role validation.
- Three guided Longhorn storage modes with configurable capacity thresholds, standardized UUID mounts, root-space guardrails, and refusal to shrink live OS filesystems.
- Customer-facing prerequisites and operations guide, immediate existing-K3s warnings, numbered disk selection, and guided GPT partition creation from verified unallocated space.
- Public repository clone, pinned-release, and archive instructions, plus a normal-user latest-stable launcher for `cyberpoe.uk/k3sdeploy-latest` with tag-to-version verification.
