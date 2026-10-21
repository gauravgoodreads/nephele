# 0002. Kustomize base + overlays instead of Helm

## Context

The same application runs in three places: a local kind cluster, the same
cluster with KEDA, and Amazon EKS with managed data services. Most of the
configuration is shared; a few things differ (images, data services, hosts,
secrets, the worker autoscaler).

## Decision

Plain Kubernetes YAML in `k8s/base`, with small Kustomize overlays:
`local`, `local-keda` and `aws`. Kustomize is built into `kubectl`, so no
extra tool is needed.

## Consequences

- Every manifest is readable as-is; reviewers see real YAML, not templates.
- Differences per environment are explicit patches (for example, the AWS
  overlay deletes the in-cluster Postgres and turns the `db` Service into an
  ExternalName pointing at RDS).
- No packaging, versioning or dependency management that Helm would give.
  Acceptable for one application; a Helm chart is listed as future work.

## Evidence

CI renders all overlays and validates every object against the Kubernetes
schema with kubeconform on each push.
