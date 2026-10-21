#!/usr/bin/env bash
# Nephele resilience suite: breaks the system on purpose and measures what a
# user would notice and whether any vote is lost. Writes a Markdown report to
# tests/results/chaos-<timestamp>.md (and chaos-latest.md).
#
#   scripts/chaos-test.sh               # all tests
#   TESTS="1 2 6" scripts/chaos-test.sh # a subset (CI runs 1 2 3 6 7 9)
#
# Needs: kubectl (context kind-nephele), curl, docker (test 5 only).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
NS=nephele
VOTE_URL="${VOTE_URL:-http://vote.localtest.me:8888}"
RESULT_URL="${RESULT_URL:-http://result.localtest.me:8888}"
TESTS="${TESTS:-1 2 3 4 5 6 7 8 9}"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT_DIR=tests/results
REPORT="$OUT_DIR/chaos-$STAMP.md"
mkdir -p "$OUT_DIR"
PASSED=0; FAILED=0

# ---------------------------------------------------------------- helpers ---
now() { date +%s.%N; }
elapsed() { awk -v a="$1" -v b="$2" 'BEGIN { printf "%.1f", b - a }'; }
log() { printf '\033[1;36m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
kc() { kubectl -n "$NS" "$@"; }
rcli() { kc exec -i redis-0 -- redis-cli "$@"; }
sql() { kc exec db-0 -- psql -U postgres -At -c "$1" 2>/dev/null | tr -d '\r'; }
rows_like() { sql "SELECT count(*) FROM votes WHERE id LIKE '$1%'"; }
queue_len() { rcli LLEN votes | tr -d '\r'; }
in_flight() {
  local total=0 key n
  for key in $(rcli --scan --pattern 'votes:processing:*' | tr -d '\r'); do
    n=$(rcli LLEN "$key" | tr -d '\r'); total=$((total + n))
  done
  echo "$total"
}

record() { # record <number> <name> <what was done> <measured> <PASS|FAIL>
  printf '| %s | %s | %s | %s | %s |\n' "$1" "$2" "$3" "$4" "$5" >> "$REPORT"
  if [ "$5" = PASS ]; then PASSED=$((PASSED + 1)); else FAILED=$((FAILED + 1)); fi
  log "Test $1 $2: $5 ($4)"
}

# Puts N votes straight on the queue, as if N people had just voted.
inject_votes() { # inject_votes <count> <voter-id prefix>
  local n="$1" prefix="$2" i opt
  for i in $(seq 1 "$n"); do
    if [ $((i % 2)) -eq 0 ]; then opt=a; else opt=b; fi
    printf 'RPUSH votes "{\\"voter_id\\": \\"%s%s\\", \\"vote\\": \\"%s\\"}"\n' "$prefix" "$i" "$opt"
  done | kc exec -i redis-0 -- redis-cli > /dev/null
}

wait_drained() { # waits until the queue and every processing list are empty
  local deadline=$(( $(date +%s) + ${1:-180} ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if [ "$(queue_len)" = "0" ] && [ "$(in_flight)" = "0" ]; then return 0; fi
    sleep 2
  done
  return 1
}

wait_ready_replicas() { # wait_ready_replicas <deployment> <count> <timeout>
  local deadline=$(( $(date +%s) + $3 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    [ "$(kc get deploy "$1" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)" = "$2" ] && return 0
    sleep 0.5
  done
  return 1
}

# Simulated users: one real vote (POST) through the Ingress every 0.2 s.
probe_start() {
  PROBE_FILE="$(mktemp)"; rm -f "$PROBE_FILE.stop"
  (
    i=0
    while [ ! -f "$PROBE_FILE.stop" ]; do
      i=$((i + 1))
      curl -4 -s -o /dev/null -m 3 -w '%{http_code}\n' -X POST -d "vote=a" \
        -H "Cookie: voter_id=probe-$STAMP-$i" "$VOTE_URL/" >> "$PROBE_FILE"
      sleep 0.2
    done
  ) &
  PROBE_PID=$!
}
probe_stop() { # prints "<failed> of <total>"
  touch "$PROBE_FILE.stop"; wait "$PROBE_PID" 2>/dev/null
  local total failed
  total=$(grep -c . "$PROBE_FILE" || true)
  failed=$(grep -vc '^200$' "$PROBE_FILE" || true)
  rm -f "$PROBE_FILE" "$PROBE_FILE.stop"
  echo "$failed of $total"
}

pause_workers()  { kc annotate scaledobject worker autoscaling.keda.sh/paused-replicas=0 --overwrite >/dev/null; kc scale deploy worker --replicas=0 >/dev/null; sleep 3; }
resume_workers() { kc annotate scaledobject worker autoscaling.keda.sh/paused-replicas- >/dev/null; kc scale deploy worker --replicas=1 >/dev/null; }

restricted_pod() { # a throwaway pod that satisfies the "restricted" Pod Security profile
  local name="$1" labels="$2" cmd="$3"
  cat <<EOF | kc apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata: { name: $name, labels: { $labels } }
spec:
  restartPolicy: Never
  securityContext: { runAsNonRoot: true, runAsUser: 70, seccompProfile: { type: RuntimeDefault } }
  containers:
    - name: c
      image: postgres:15-alpine
      env: [{ name: PGPASSWORD, value: postgres }]
      command: ["sh", "-c", "$cmd"]
      securityContext: { allowPrivilegeEscalation: false, capabilities: { drop: ["ALL"] } }
EOF
}

# ----------------------------------------------------------------- report ---
{
  echo "# Nephele resilience report"
  echo
  echo "- Run: $(date '+%Y-%m-%d %H:%M:%S %Z')"
  echo "- Cluster: $(kubectl config current-context), $(kubectl get nodes --no-headers | wc -l | tr -d ' ') nodes, Kubernetes $(kubectl version -o json 2>/dev/null | grep -m1 gitVersion | tr -d ' ",' | cut -d: -f2)"
  echo "- Simulated users: one real vote through the Ingress every 0.2 s during disruptive tests"
  echo
  echo "| # | Test | What was done | Measured | Result |"
  echo "| --- | --- | --- | --- | --- |"
} > "$REPORT"

wait_drained 120 || log "warning: queue was not empty at start"

run() { case " $TESTS " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# 1 -------------------------------------------------------- vote pod killed
if run 1; then
  log "Test 1: kill a vote pod while users vote"
  probe_start; sleep 2
  pod=$(kc get pod -l app=vote -o jsonpath='{.items[0].metadata.name}')
  want=$(kc get deploy vote -o jsonpath='{.spec.replicas}')
  t0=$(now); kc delete pod "$pod" --wait=false >/dev/null
  sleep 1; wait_ready_replicas vote "$want" 120; ok=$?
  t1=$(now); sleep 2; res=$(probe_stop)
  [ $ok -eq 0 ] && [ "${res%% *}" = "0" ] && r=PASS || r=FAIL
  record 1 "Pod failure (vote)" "Deleted $pod" "Replacement ready in $(elapsed "$t0" "$t1") s; failed votes: $res" $r
fi

# 2 --------------------------------------------- workers killed mid-backlog
if run 2; then
  log "Test 2: hard-kill every worker while 3,000 votes are being processed"
  inject_votes 3000 "t2-$STAMP-"
  sleep 4
  before=$(rows_like "t2-$STAMP-")
  kc delete pod -l app=worker --grace-period=0 --force >/dev/null 2>&1
  t0=$(now); wait_drained 300; ok=$?; t1=$(now)
  sleep 2; saved=$(rows_like "t2-$STAMP-")
  recovered=$(kc logs -l app=worker --tail=-1 2>/dev/null | grep -o 'Recovered [0-9]* unfinished' | awk '{s+=$2} END {print s+0}')
  [ $ok -eq 0 ] && [ "$saved" = "3000" ] && r=PASS || r=FAIL
  record 2 "Worker crash, no vote lost" "Queued 3,000 votes, force-killed all workers after $before were saved" "$saved of 3,000 saved; $recovered in-flight votes recovered from dead workers; drained $(elapsed "$t0" "$t1") s after the kill" $r
fi

# 3 ------------------------------------------------ Redis restarted with a backlog
if run 3; then
  log "Test 3: restart Redis while 1,000 votes wait in the queue"
  pause_workers
  inject_votes 1000 "t3-$STAMP-"
  sleep 2 # appendfsync everysec
  queued=$(queue_len)
  t0=$(now); kc delete pod redis-0 >/dev/null
  kc wait --for=condition=ready pod/redis-0 --timeout=180s >/dev/null; t1=$(now)
  after=$(queue_len)
  resume_workers; wait_drained 300; ok=$?
  sleep 2; saved=$(rows_like "t3-$STAMP-")
  # The queue may grow during the test (workers' own recovery of older
  # in-flight votes), but must never shrink, and every test vote must be saved.
  [ "$after" -ge "$queued" ] && [ "$saved" = "1000" ] && [ $ok -eq 0 ] && r=PASS || r=FAIL
  record 3 "Queue durability (Redis restart)" "Paused workers, queued 1,000 votes, deleted the Redis pod" "Redis back in $(elapsed "$t0" "$t1") s; queue $queued before, $after after; $saved of 1,000 saved" $r
fi

# 4 --------------------------------------------- database restarted under traffic
if run 4; then
  log "Test 4: restart PostgreSQL while users keep voting"
  probe_start; sleep 1
  t0=$(now); kc delete pod db-0 --wait=false >/dev/null
  inject_votes 500 "t4-$STAMP-"
  sleep 3; kc wait --for=condition=ready pod/db-0 --timeout=180s >/dev/null; t1=$(now)
  wait_drained 300; ok=$?; t2=$(now)
  res=$(probe_stop)
  deadline=$(( $(date +%s) + 60 ))
  until curl -4 -sf -o /dev/null "$RESULT_URL/readyz" || [ "$(date +%s)" -gt "$deadline" ]; do sleep 1; done
  t3=$(now)
  saved=$(rows_like "t4-$STAMP-")
  [ $ok -eq 0 ] && [ "$saved" = "500" ] && [ "${res%% *}" = "0" ] && r=PASS || r=FAIL
  record 4 "Database outage" "Deleted the Postgres pod; 500 votes queued during the outage" "DB back in $(elapsed "$t0" "$t1") s; votes accepted throughout (failed: $res); $saved of 500 saved; results page ready again $(elapsed "$t0" "$t3") s after the kill" $r
fi

# 5 ------------------------------------------------------------- node failure
if run 5; then
  log "Test 5: stop a whole worker node (like losing a zone)"
  db_node=$(kc get pod db-0 -o jsonpath='{.spec.nodeName}')
  redis_node=$(kc get pod redis-0 -o jsonpath='{.spec.nodeName}')
  target=""
  for n in $(kubectl get nodes -l '!node-role.kubernetes.io/control-plane' -o jsonpath='{.items[*].metadata.name}'); do
    if [ "$n" != "$db_node" ] && [ "$n" != "$redis_node" ]; then target="$n"; break; fi
  done
  [ -z "$target" ] && target=$(kc get pod -l app=vote -o jsonpath='{.items[0].spec.nodeName}')
  on_target=$(kc get pods --field-selector "spec.nodeName=$target" --no-headers 2>/dev/null | awk '{print $1}' | tr '\n' ' ')
  want=$(kc get deploy vote -o jsonpath='{.spec.replicas}')
  probe_start; sleep 2
  t0=$(now); docker stop "$target" >/dev/null
  deadline=$(( $(date +%s) + 300 )); moved=1
  while [ "$(date +%s)" -lt "$deadline" ]; do
    ready_elsewhere=$(kc get pods -l app=vote -o jsonpath='{range .items[*]}{.spec.nodeName}{" "}{.status.containerStatuses[0].ready}{"\n"}{end}' | grep -v "^$target " | grep -c ' true$' || true)
    if [ "$ready_elsewhere" -ge "$want" ]; then moved=0; break; fi
    sleep 2
  done
  t1=$(now); sleep 3; res=$(probe_stop)
  docker start "$target" >/dev/null
  kubectl wait --for=condition=ready "node/$target" --timeout=180s >/dev/null
  t2=$(now)
  [ $moved -eq 0 ] && r=PASS || r=FAIL
  record 5 "Node failure" "Stopped node $target (ran: $on_target)" "All $want vote pods ready on other nodes after $(elapsed "$t0" "$t1") s; failed votes: $res; node back after $(elapsed "$t1" "$t2") s more" $r
  wait_drained 300 >/dev/null
fi

# 6 ------------------------------------------------ rolling release under load
if run 6; then
  log "Test 6: roll out a new vote release while users vote"
  probe_start; sleep 2
  t0=$(now); kc rollout restart deploy/vote >/dev/null
  kc rollout status deploy/vote --timeout=300s >/dev/null; ok=$?; t1=$(now)
  sleep 2; res=$(probe_stop)
  [ $ok -eq 0 ] && [ "${res%% *}" = "0" ] && r=PASS || r=FAIL
  record 6 "Zero-downtime release" "kubectl rollout restart deploy/vote" "Rollout took $(elapsed "$t0" "$t1") s; failed votes: $res" $r
fi

# 7 --------------------------------------------------------- network policy
if run 7; then
  log "Test 7: only labelled clients may reach the database"
  check='if timeout 8 psql -h db -U postgres -c \"select 1\" >/dev/null 2>/dev/null; then echo REACHED; else echo BLOCKED; fi'
  restricted_pod np-outsider "app: np-test" "$check"
  restricted_pod np-client "app: np-test, db-client: \"true\"" "$check"
  kc wait --for=jsonpath='{.status.phase}'=Succeeded pod/np-outsider pod/np-client --timeout=120s >/dev/null
  outsider=$(kc logs np-outsider | tr -d '\r'); client=$(kc logs np-client | tr -d '\r')
  kc delete pod np-outsider np-client --wait=false >/dev/null
  [ "$outsider" = BLOCKED ] && [ "$client" = REACHED ] && r=PASS || r=FAIL
  record 7 "Network isolation" "Pod without, then with, the db-client label tried Postgres" "without label: $outsider; with label: $client" $r
fi

# 8 ------------------------------------------------- backup and restore drill
if run 8; then
  log "Test 8: back up, then restore into a scratch database and compare"
  wait_drained 120 >/dev/null
  pause_workers # hold the database still so live and restored counts are comparable
  live=$(sql "SELECT count(*) FROM votes")
  kc delete job backup-chaos --ignore-not-found >/dev/null
  kc create job --from=cronjob/db-backup backup-chaos >/dev/null
  kc wait --for=condition=complete job/backup-chaos --timeout=180s >/dev/null
  size=$(kc logs job/backup-chaos | grep -o '([0-9]* bytes)' | tr -d '()')
  job=$(kc create -f k8s/jobs/restore-drill.yaml -o name)
  kc wait --for=condition=complete "$job" --timeout=180s >/dev/null
  restored=$(kc logs "$job" | grep RESTORED_ROWS | cut -d= -f2 | tr -d '\r')
  resume_workers
  [ -n "$restored" ] && [ "$restored" = "$live" ] && r=PASS || r=FAIL
  record 8 "Backup and restore drill" "Ran the backup job, restored the newest dump into a scratch database" "live rows: $live; restored rows: $restored; dump size: $size" $r
fi

# 9 --------------------------------------------------- pod security admission
if run 9; then
  log "Test 9: an insecure pod must be refused"
  msg=$(kc run psa-test --image=busybox:1.36 --restart=Never -- sleep 1 2>&1 || true)
  kc delete pod psa-test --ignore-not-found --wait=false >/dev/null 2>&1
  if echo "$msg" | grep -q 'violates PodSecurity'; then r=PASS; out="refused: violates PodSecurity \"restricted\""; else r=FAIL; out="was admitted"; fi
  record 9 "Pod Security (restricted)" "Tried to start a pod running as root with no security settings" "$out" $r
fi

{
  echo
  echo "**$PASSED passed, $FAILED failed.**"
  echo
  echo "Votes cast by the simulated users are saved with voter IDs starting \`probe-$STAMP\`."
} >> "$REPORT"
cp "$REPORT" "$OUT_DIR/chaos-latest.md"
log "Report: $REPORT"
cat "$REPORT"
[ "$FAILED" -eq 0 ]
