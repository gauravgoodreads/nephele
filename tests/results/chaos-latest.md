# Nephele resilience report

- Run: 2026-10-21 14:07:51 IST
- Cluster: kind-nephele, 3 nodes, Kubernetes v1.36.1
- Simulated users: one real vote every 0.2 s from a probe pod inside the cluster to the Ingress controller; failed = any non-200 answer or none within 15 s

| # | Test | What was done | Measured | Result |
| --- | --- | --- | --- | --- |
| 1 | Pod failure (vote) | Deleted vote-6666fc848f-4pzdg | Replacement ready in 3.4 s; failed votes: 0 of 8, 0 slower than 2 s | PASS |
| 2 | Worker crash, no vote lost | Queued 3,000 votes, force-killed all workers after 755 were saved | 3000 of 3,000 saved; 1 in-flight votes recovered from dead workers; drained 42.4 s after the kill | PASS |
| 3 | Queue durability (Redis restart) | Paused workers, queued 1,000 votes, deleted the Redis pod | Redis back in 14.2 s; queue 1000 before, 1000 after; 1000 of 1,000 saved | PASS |
| 4 | Database outage | Deleted the Postgres pod; 500 votes queued during the outage | DB back in 5.8 s; votes accepted throughout (failed: 0 of 31, 0 slower than 2 s); 500 of 500 saved; results page ready again 12.4 s after the kill | PASS |
| 5 | Node failure | Stopped node nephele-worker2 (ran: backup-chaos-cxkb4 vote-6666fc848f-nlfx8 vote-6666fc848f-qgxn2 vote-6666fc848f-wgdzp worker-856644f879-4n56b worker-856644f879-96r88 worker-856644f879-cmb6p worker-856644f879-hp4d8 worker-856644f879-txsdx ) | All 6 vote pods ready on other nodes after 90.5 s; failed votes: 2 of 148 (000 x1, 504 x1), 5 slower than 2 s; node back after 10.3 s more | PASS |
| 6 | Zero-downtime release | kubectl rollout restart deploy/vote | Rollout took 45.8 s; failed votes: 0 of 172, 1 slower than 2 s | PASS |
| 7 | Network isolation | Pod without, then with, the db-client label tried Postgres | without label: BLOCKED; with label: REACHED | PASS |
| 8 | Backup and restore drill | Ran the backup job, restored the newest dump into a scratch database | live rows: 113017; restored rows: 113017; dump size: 913117 bytes | PASS |
| 9 | Pod Security (restricted) | Tried to start a pod running as root with no security settings | refused: violates PodSecurity "restricted" | PASS |

**9 passed, 0 failed.**

Votes cast by the simulated users are saved with voter IDs starting `probe-20261021-140751`.
