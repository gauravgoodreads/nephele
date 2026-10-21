#!/usr/bin/env bash
# Runs a k6 scenario and samples the cluster every 15 seconds: vote and worker
# pods, votes waiting, votes in flight, votes saved. Writes
# loadtest/results/<name>-summary.json, <name>-output.txt and <name>-scaling.csv.
#
#   scripts/load-test.sh loadtest/k6-vote.js   v3-standard
#   scripts/load-test.sh loadtest/k6-stress.js v3-stress
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
SCRIPT="${1:?k6 script}"
NAME="${2:?result name}"
OUT=loadtest/results
VOTE_URL="${VOTE_URL:-http://vote.localtest.me:8888}"
mkdir -p "$OUT"
K6="$(command -v k6 || echo '/c/Program Files/k6/k6.exe')"

metric() { curl -4 -s --max-time 3 "$VOTE_URL/metrics" | awk -v m="$1" '$1 == m { print $2 }'; }

"$K6" run --summary-export "$OUT/$NAME-summary.json" "$SCRIPT" > "$OUT/$NAME-output.txt" 2>&1 &
K6_PID=$!

echo "seconds,vote_pods,worker_pods,queue,in_flight,saved" > "$OUT/$NAME-scaling.csv"
start=$(date +%s)
while :; do
  t=$(( $(date +%s) - start ))
  vote=$(kubectl -n nephele get deploy vote -o jsonpath='{.status.readyReplicas}')
  worker=$(kubectl -n nephele get deploy worker -o jsonpath='{.status.readyReplicas}')
  echo "$t,${vote:-0},${worker:-0},$(metric nephele_queue_depth),$(metric nephele_votes_in_flight),$(metric nephele_votes_saved)" >> "$OUT/$NAME-scaling.csv"
  if ! kill -0 "$K6_PID" 2>/dev/null; then
    # keep sampling until the queue is empty, then stop
    q=$(metric nephele_queue_depth); [ "${q%.*}" = "0" ] && break
  fi
  sleep 15
done
wait "$K6_PID"; rc=$?
tail -n 30 "$OUT/$NAME-output.txt"
cat "$OUT/$NAME-scaling.csv"
exit $rc
