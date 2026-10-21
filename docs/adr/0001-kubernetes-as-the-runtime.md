# 0001. Run on Kubernetes (kind locally, Amazon EKS in the cloud)

## Context

The voting app has three services in three languages plus Redis and
PostgreSQL. It needs to restart failed parts on its own, scale each part
independently, roll out releases without downtime, and run the same way on a
laptop and in the cloud. Docker Compose runs the containers but does none of
the scheduling, healing or scaling. Docker Swarm (supported by the upstream
app) is largely unused in industry and has no managed offering on AWS.

## Decision

Kubernetes is the runtime. Locally, kind ("Kubernetes in Docker") runs a
3-node cluster with two worker nodes labelled as two availability zones. In
the cloud, Amazon EKS runs the same manifests. Docker Compose stays for quick
single-machine development.

## Consequences

- One set of manifests, tested locally and in CI, deploys to EKS unchanged.
- Self-healing (probes, controllers), rolling updates, autoscaling and
  NetworkPolicies come from the platform instead of application code.
- More moving parts to learn and to run than Compose; the laptop needs about
  2.5 GB of RAM for the full cluster with monitoring.

## Evidence

Chaos test 1 (pod killed) and test 5 (node stopped) in
`tests/results/chaos-latest.md`: the platform replaced the lost pods with no
code involved.
