# Changelog

## Unreleased

- Discover and validate snapshots through privileged path resolution so the
  guarded restore menu can read the root-only snapshot directory it protects.
- Give milestone snapshots a readable UTC date and time in their K3s-managed
  names. Snapshot save and prune commands now use an isolated command
  configuration, preventing server-only settings and the configured retention
  alias from colliding with the prune request.
- Replace the ambiguous root-headroom warning with the current root size, free
  capacity, calculated allocation recommendation, and a precise explanation of
  which K3s files continue using root when Longhorn has separate storage.
- Replace the README cover with the clearer K3sDeploy artwork.
- Clarify that the validated MetalLB pin will be updated after a patched stable
  release is published, and explain why the installer does not follow a floating
  `latest` version.
- Restructure the public README around the recommended curl launcher, with repository cloning as the second installation method. Add the K3sDeploy cover image, make the fresh Ubuntu Server requirement explicit, condense operational guidance, and include an AI-assisted development disclosure.
- Add an explicit embedded-etcd backup policy to manager installation and promotion. The recommended policy keeps five scheduled snapshots per manager and prunes each named milestone category to its newest copy. The advanced opt-out requires exact acknowledgement, disables new K3s and milestone snapshots, and preserves existing snapshot files.
- Explain that one surviving manager can restore the control plane with its snapshot and matching token, while a surviving worker cannot. Clarify the need for protected off-node copies and the limits of uncoordinated hypervisor snapshots.
- Detect virtual machines before showing expanded-virtual-disk and hypervisor guidance. Physical machines now receive only relevant physical-disk guidance.
- Configure compressed embedded-etcd snapshots on every managed server with a twice-daily schedule and five-snapshot retention, then create official milestone snapshots after healthy manager installation, join, promotion, quorum recovery, and snapshot restore workflows. Safe repair offers one baseline snapshot when an older healthy manager has no K3sDeploy milestone.
- Add guarded local embedded-etcd snapshot restore as option 8. It discovers the configured snapshot directory, creates a current-state safety snapshot when possible, preserves stopped server state, requires manager-isolation and exact restore confirmation, resets membership through the official K3s restore path, and validates the result without claiming to restore persistent-volume contents.
- Explain why increasing an underlying physical or virtual disk does not enlarge the root filesystem or make shared-root Longhorn storage eligible, while directing the operator to the separate LVM and unallocated-space checks.
- Make read-only validation and safe repair recognize a lost-quorum signature and offer a default-Yes transition directly into the separate option-7 workflow. Declining keeps validation read only, while accepting still runs every recovery safeguard and exact confirmation.
- Report the actual systemd service state instead of describing every non-active K3s service as inactive, and explain that unavailable add-ons during quorum loss may be blocked behind the API rather than deleted.
- Add a separate, guarded embedded-etcd lost-quorum recovery workflow. It requires a local server datastore, an unavailable API, strong recent quorum-failure evidence, a protected pre-reset backup, and exact operator confirmation before resetting the selected manager to one-member etcd. It never runs from safe repair or through `--yes`.
- Resume rather than repeat a reset when K3s has already written its reset-completion flag, remove stale Kubernetes Node objects only for former managers, preserve Longhorn records for data review, and print mandatory clean-rejoin guidance.
- Ask for the existing API VIP before showing token-retrieval instructions, avoid repeating a token pasted into a visible address field, and warn that an exposed token should be rotated.
- Prepare storage clients before a node joins, then wait for kube-vip, MetalLB, and the selected storage add-on to become ready on the new node before final validation. Longhorn must also report the new node ready and schedulable.
- Prevent installation and promotion workflows from reporting success when final health validation still has failed checks.
- Shorten unavailable storage labels so their complete bracketed reasons remain visible in an 80-column terminal.
- Make unavailable storage choices grey and non-selectable, include the reason in square brackets, and shorten guided LVM or partition confirmation to `CREATE`.
- Replace the long dash and prose semicolon styles with plain punctuation in installer output and documentation.
- Stop repeatedly offering an already-completed Longhorn repair by comparing each workload's available replicas with its configured desired count instead of assuming every deployment has exactly one replica.
- Restore installer colours by detecting the output terminal before colour command substitutions redirect stdout, and add `--color` to override an inherited `NO_COLOR` setting.
- Add terminal-aware arrow-key menus with Enter/Space confirmation and automatic numbered-prompt fallback for redirected or non-interactive sessions.
- Extend the K3sDeploy yellow identity colour to section titles and progress panels, with distinct cyan information, green success, orange warning, and red error/failed-check output plus `NO_COLOR` support.
- End successful menu workflows with an action-specific summary and normal installer exit, while retaining the menu after recoverable failures.
- Defer the automatic Longhorn smoke-test prompt on a one-storage-node cluster, offer it after manager joins and repairs when multiple storage nodes are ready, and direct worker operators to a manager with administrative access.
- Record successful Longhorn functional tests in a cluster ConfigMap so later validation reports the last passing test instead of `NOT TESTED`.
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
- Let advanced users select MetalLB, built-in K3s ServiceLB, or external load balancing, plus Longhorn, K3s local-path, or external persistent storage. Intentionally omitted components are skipped during installation and validation.
- Prevent a normal clean-node Longhorn mount check from aborting phase 2 under strict error handling.
- Group interactive output into clearly separated sections and expand installation workflows so error line numbers identify the failing operation.
- Parse `/etc/os-release` without sourcing it, avoiding a collision between its `VERSION` field and K3sDeploy's read-only installer version.
- Keep the interactive installer open after recoverable workflow failures. Invalid VIPs, join credentials, hostnames, address pools, and menu selections can now be corrected without restarting it.
- Detect the operating system and use its `apt`, `dnf`, `yum`, or `zypper` package manager instead of presenting Ubuntu-specific dependency instructions.
- Replace legacy user-facing product wording with “installer” and “K3sDeploy Installer”.
- Correct LVM root-volume discovery when Linux exposes the mounted root as `/dev/dm-*`, so free volume-group extents are reported instead of `0 GiB`.
- Mark ineligible shared-root storage without terminating the installer, and return the operator to the storage menu with physical and virtualization-neutral disk guidance.
- Distinguish a positive ARP duplicate-address response from an operational probe failure. Occupied VIPs now stop safely, with ICMP used only as a fallback signal.
- Recommend SSD/NVMe storage for K3s and Longhorn while retaining HDD support for appropriate workloads.
- Default-Yes confirmations for detected hostname/address, network reservations, and safe dependency or service operations. Destructive and risk-acceptance prompts remain default-No.
- Optional installation of the detected operating system's arping package before checking whether a new API VIP is already in use.
- Guided creation of a dedicated Longhorn LVM logical volume from free extents in common Linux layouts, with root-headroom checks and exact confirmation.
- Clean-node validation now reports uninstalled components as `MISSING` or `SKIP`, and safe repair no longer offers to start a nonexistent K3s service.
- Manager and worker joins verify the existing API VIP and secure join token before collecting local storage choices.
- Removed hardcoded lab network addresses. Hostname and detected node-address confirmations now include beginner-facing guidance.
- Corrected physical OS-disk discovery through LVM/device-mapper ancestry and clarified guided OS-partition creation.
- Replaced the arbitrary 100 GiB Longhorn hard minimum with a 20 GiB small-lab floor plus a 100 GiB general-use recommendation and capacity warning.

## v0.1.0 - 19-09-2026

- Initial interactive first-server, server-join, validation and safe-repair workflows.
- Pinned K3s, kube-vip, MetalLB and Longhorn manifests.
- Conservative root/dedicated storage selection and pure-function tests.
- Normal-user launch with scoped sudo elevation and an explicit phase-progress banner.
- Worker/agent joins for larger clusters. Recommends three or five etcd servers rather than making every node an etcd member.
- Guarded worker-to-manager promotion with drain/delete instructions, exact destructive confirmation, protected local backup, server-token join, and post-promotion role validation.
- Three guided Longhorn storage modes with configurable capacity thresholds, standardized UUID mounts, root-space guardrails, and refusal to shrink live OS filesystems.
- Customer-facing prerequisites and operations guide, immediate existing-K3s warnings, numbered disk selection, and guided GPT partition creation from verified unallocated space.
- Public repository clone, pinned-release, and archive instructions, plus a normal-user latest-stable launcher for `cyberpoe.uk/k3sdeploy-latest` with tag-to-version verification.
