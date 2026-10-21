# 0007. Application metrics from shared Redis counters; Prometheus + Grafana in-cluster

## Context

The vote service runs as 2 to 6 pods, each with several Gunicorn worker
processes. Per-process counters would differ by which process served the
scrape, and summing pods would double count.

## Decision

- Counters that describe the whole system (votes received, votes saved,
  queue depth, votes in flight) live in Redis. Every vote pod reports the
  same values, and dashboards take `max()` across pods.
- Traffic metrics (requests, status codes, latency per service) come from the
  NGINX Ingress controller, so every service is measured the same way
  without code changes.
- Container CPU and memory come from the kubelets (cAdvisor), and object
  state (ready replicas, restarts, autoscaler targets) from kube-state-metrics.
- Prometheus evaluates seven alert rules; Grafana shows two provisioned
  dashboards (application and platform). Both run in a `monitoring` namespace.

## Consequences

- Correct totals regardless of how many pods or processes exist.
- Each scrape costs a few Redis commands; negligible at this scale.
- Alertmanager (sending alerts to email or chat) is not deployed; alerts are
  visible in Prometheus and Grafana. Listed as future work.

## Evidence

`scripts/smoke-test.sh` fails unless Prometheus reports healthy targets for all
four scrape jobs.
