# Nephele runbook

What to do when an alert fires. Alerts are defined in
`k8s/addons/monitoring/alerts.yml`; open them at
http://prometheus.localtest.me:8888/alerts or in Grafana ("Nephele: platform",
"Firing alerts" panel).

Shortcuts used below:

```bash
alias kn='kubectl -n nephele'
```

## VoteQueueBacklog (warning)

More than 500 votes have waited for over a minute.

1. Are workers scaling? `kn get scaledobject worker` and `kn get hpa keda-hpa-worker`.
   KEDA should be adding one worker per 50 waiting votes, up to 10.
2. At the maximum already? Check the database is the bottleneck:
   `kn top pod db-0`. If it is at its CPU limit, raise `db.yaml` limits.
3. Workers crash-looping? `kn get pods -l app=worker`, then
   `kn logs <pod> --previous`.
4. A paused ScaledObject? `kn get scaledobject worker -o yaml | grep paused`;
   remove with `kn annotate scaledobject worker autoscaling.keda.sh/paused-replicas-`.

## WorkerStalled (critical)

Votes are waiting but none were saved for two minutes.

1. `kn logs -l app=worker --tail=50 --prefix`. "Waiting for db" or
   "Database unavailable" means PostgreSQL: go to step 2. "Redis unavailable"
   means Redis: step 3.
2. `kn get pod db-0`, `kn describe pod db-0`. A pending pod on a stopped node
   (local volumes cannot move) needs the node back: `docker start <node>`.
3. `kn get pod redis-0`; Redis restarts keep the queue (append-only file).
4. No votes are lost while stalled: they stay in the queue or in a
   processing list and are recovered when workers resume.

## VoteServiceDown (critical)

Prometheus cannot reach any vote pod.

1. `kn get pods -l app=vote -o wide` and `kn describe deploy vote`.
2. Readiness failing? `kn logs -l app=vote --tail=50`; `/readyz` fails when
   Redis is unreachable.
3. Quota exhausted? `kn describe resourcequota nephele-quota`.

## HighErrorRate (critical)

More than 5% of requests return 5xx.

1. Which service? Grafana "Nephele: platform", "Requests per second by
   service" and "Error rate".
2. Recent release? `kn rollout history deploy/vote`; roll back with
   `kn rollout undo deploy/vote`.
3. Check `kn get events --sort-by=.lastTimestamp | tail`.

## SlowResponses (warning)

p95 above 500 ms for two minutes.

1. Is the vote tier at its maximum of 6 pods? `kn get hpa vote`.
2. CPU throttling? Grafana "CPU by pod" against the 300m limit.
3. Redis slow? `kn exec redis-0 -- redis-cli --latency -i 1` (Ctrl+C to stop).

## PodRestartLoop (warning)

A pod restarted more than 3 times in 10 minutes.

1. `kn logs <pod> --previous` for the crash message.
2. `kn describe pod <pod>`: `OOMKilled` means raise its memory limit;
   a failing liveness probe means look at `/healthz` (or the worker heartbeat).

## DeploymentDegraded (warning)

Fewer ready pods than wanted for five minutes.

1. `kn describe deploy <name>` and `kn get events | grep -i fail`.
2. Image not loaded into kind? `kind load docker-image nephele/<svc>:local --name nephele`.

## Routine tasks

| Task | Command |
| --- | --- |
| Back up now | `kn create job --from=cronjob/db-backup backup-$(date +%s)` |
| Prove a backup restores | `kn create -f k8s/jobs/restore-drill.yaml`, then read its log |
| Run the resilience suite | `scripts/chaos-test.sh` |
| Release a new image | `kn rollout restart deploy/<svc>`; watch `kn rollout status deploy/<svc>` |
| Roll back | `kn rollout undo deploy/<svc>` |
