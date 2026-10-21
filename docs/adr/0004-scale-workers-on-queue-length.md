# 0004. Scale workers on queue length with KEDA, not CPU

## Context

The first design scaled the worker with a HorizontalPodAutoscaler on CPU,
like the web tier. Under a 3-minute load test (60 virtual users, about 63
votes per second) the queue grew to 5,692 waiting votes while worker CPU sat
at about 27% of its request, so the autoscaler never added a worker. The
worker is I/O-bound: it waits on Redis and PostgreSQL, not on the CPU.

## Decision

Scale the worker with KEDA's Redis list scaler: one worker per 50 waiting
votes, from 1 to 10, polled every 5 seconds. Keep the CPU autoscaler for the
vote web tier, where CPU does track load.

## Consequences

- The worker count follows the actual backlog.
- One more component in the cluster (KEDA operator and metrics adapter,
  about 150 MB of memory).
- KEDA must be allowed to reach Redis; a NetworkPolicy in the `local-keda`
  overlay permits exactly that.

## Evidence

Same load test, measured on the local cluster:

| | CPU autoscaler | KEDA |
| --- | --- | --- |
| Workers at peak | 4 (no reaction to load) | 10 |
| Most votes waiting | 5,692 | 1,183 |
| Queue empty after load stopped | about 3.5 minutes | about 15 seconds |
| p95 response time | 84.1 ms | 63.8 ms |

Raw data: `loadtest/results/scaling-log.txt` and `scaling-log-keda.txt`.
A later worker optimisation (no fixed delay between votes) is measured in
`loadtest/results/` as the third iteration.
