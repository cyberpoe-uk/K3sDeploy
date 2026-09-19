# Changelog

## Unreleased

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
