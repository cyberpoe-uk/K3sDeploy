# Changelog

## v0.1.0 - 19-09-2026

- Initial interactive first-server, server-join, validation and safe-repair workflows.
- Pinned K3s, kube-vip, MetalLB and Longhorn manifests.
- Conservative root/dedicated storage selection and pure-function tests.
- Normal-user launch with scoped sudo elevation and an explicit phase-progress banner.
- Worker/agent joins for larger clusters; recommends three or five etcd servers rather than making every node an etcd member.
- Guarded worker-to-manager promotion with drain/delete instructions, exact destructive confirmation, protected local backup, server-token join, and post-promotion role validation.
- Three guided Longhorn storage modes with configurable capacity thresholds, standardized UUID mounts, root-space guardrails, and refusal to shrink live OS filesystems.
- Customer-facing prerequisites and operations guide, immediate existing-K3s warnings, numbered disk selection, and guided GPT partition creation from verified unallocated space.
- Public repository clone, pinned-release, and archive instructions, plus a normal-user latest-stable launcher for `cyberpoe.uk/k3s-deploy-latest` with tag-to-version verification.
