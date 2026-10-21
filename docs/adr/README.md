# Architecture decision records

Each record explains one significant choice: the situation, what was decided,
what it costs, and the evidence behind it. Format: Context, Decision,
Consequences, Evidence.

| # | Decision | Status |
| --- | --- | --- |
| [0001](0001-kubernetes-as-the-runtime.md) | Run on Kubernetes (kind locally, Amazon EKS in the cloud) | Accepted |
| [0002](0002-kustomize-base-and-overlays.md) | Kustomize base + overlays instead of Helm | Accepted |
| [0003](0003-reliable-queue-at-least-once.md) | Reliable queue: move, save, then acknowledge (at-least-once + idempotent upsert) | Accepted |
| [0004](0004-scale-workers-on-queue-length.md) | Scale workers on queue length with KEDA, not CPU | Accepted |
| [0005](0005-managed-data-services-on-aws.md) | Managed RDS and ElastiCache on AWS, wired in with ExternalName Services | Accepted |
| [0006](0006-defence-in-depth.md) | Defence in depth: restricted Pod Security, NetworkPolicies, non-root images | Accepted |
| [0007](0007-observability-from-shared-counters.md) | Application metrics from shared Redis counters; Prometheus + Grafana in-cluster | Accepted |
