# 0003. Reliable queue: move, save, then acknowledge

## Context

The original worker did `LPOP votes` and then saved the vote. Two defects:

1. If the worker crashed between the pop and the save, the vote was gone.
2. If the database connection had dropped, the worker reconnected but
   skipped the vote it was holding.

Kubernetes kills and moves pods routinely (scale-down, node drain, rolling
updates), so "the worker never crashes" is not a safe assumption.

## Decision

Use the reliable-queue pattern with at-least-once delivery:

1. `LMOVE votes -> votes:processing:<worker>` takes a vote atomically into the
   worker's own processing list.
2. Save it with an upsert (`INSERT ... ON CONFLICT (id) DO UPDATE`), which
   makes saving the same vote twice harmless (idempotent).
3. Only then `LREM` it from the processing list.
4. Each worker sets a 30-second `worker:alive:<name>` key every 5 seconds.
   Any worker that starts, and every worker every 30 seconds, moves votes
   from the processing lists of workers without a live key back onto the queue.
5. On SIGTERM the worker finishes the vote in hand and exits; on a database
   error it puts the vote back on the queue and reconnects.

Redis runs with append-only-file persistence (`appendfsync everysec`) on a
persistent volume, so the queue itself survives a Redis restart.

## Consequences

- No vote is lost when a worker or Redis crashes; a vote may be processed
  twice, which the upsert absorbs.
- Requires Redis 6.2+ (`LMOVE`) and StackExchange.Redis 2.8.
- Up to about one second of queued votes can be lost if Redis itself dies
  between fsyncs; `appendfsync always` would close that at a throughput cost.

## Evidence

Chaos test 2 force-kills every worker while 3,000 votes are in progress; test 3
restarts Redis with 1,000 votes queued; test 4 restarts PostgreSQL while
votes keep arriving. All three require every vote to be saved exactly once.
