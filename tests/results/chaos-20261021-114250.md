# Nephele resilience report

- Run: 2026-10-21 11:42:50 IST
- Cluster: kind-nephele, 3 nodes, Kubernetes v1.36.1
- Simulated users: one real vote through the Ingress every 0.2 s during disruptive tests

| # | Test | What was done | Measured | Result |
| --- | --- | --- | --- | --- |
| 1 | Pod failure (vote) | Deleted vote-5695c4d7c4-7c8hx | Replacement ready in 1.7 s; failed votes: 0 of 17 | PASS |
| 2 | Worker crash, no vote lost | Queued 3,000 votes, force-killed all workers after 1687 were saved | 3000 of 3,000 saved; 0 in-flight votes recovered from dead workers; drained 10.6 s after the kill | PASS |
| 3 | Queue durability (Redis restart) | Paused workers, queued 1,000 votes, deleted the Redis pod | Redis back in 3.2 s; queue 1039 before, 1041 after; 1000 of 1,000 saved | PASS |
| 4 | Database outage | Deleted the Postgres pod; 500 votes queued during the outage | DB back in 5.1 s; votes accepted throughout (failed: 0 of 36); 500 of 500 saved; results page ready again 12.8 s after the kill | PASS |
| 5 | Node failure | Stopped node nephele-worker2 (ran: backup-chaos-zfrpq restore-drill-bdr9w-v56pn vote-6b4dfdc977-p877s vote-6b4dfdc977-prjwz worker-856644f879-g4k5p worker-856644f879-jccls worker-856644f879-m68cr worker-856644f879-mk5t4 ) | All 3 vote pods ready on other nodes after 87.5 s; failed votes: 2 of 130; node back after 6.6 s more | PASS |
| 6 | Zero-downtime release | kubectl rollout restart deploy/vote | Rollout took 30.4 s; failed votes: 0 of 89 | PASS |
| 7 | Network isolation | Pod without, then with, the db-client label tried Postgres | without label: BLOCKED; with label: REACHED | PASS |
| 8 | Backup and restore drill | Ran the backup job, restored the newest dump into a scratch database | live rows: 11405; restored rows: 11405; dump size: 33093 bytes | PASS |
| 9 | Pod Security (restricted) | Tried to start a pod running as root with no security settings | refused: violates PodSecurity "restricted" | PASS |

**9 passed, 0 failed.**

Votes cast by the simulated users are saved with voter IDs starting `probe-20261021-114250`.
