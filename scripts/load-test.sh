#!/usr/bin/env bash
# Runs a k6 scenario as a Job inside the cluster (k8s/jobs/k6-load.yaml) and
# samples the cluster every 15 s: vote and worker pods, votes waiting, in
# flight and saved. Writes loadtest/results/<name>-output.txt,
# <name>-summary.json and <name>-scaling.csv.
#
#   scripts/load-test.sh k6-vote.js   v3-standard
#   scripts/load-test.sh k6-stress.js v3-stress
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
SCRIPT="${1:?k6 script name in loadtest/, e.g. k6-vote.js}"
NAME="${2:?result name}"
OUT=loadtest/results
JOB="k6-$(echo "$NAME" | tr -c 'a-z0-9\n' '-')-$(date +%s)"
mkdir -p "$OUT"

metric() { # reads a Nephele metric from a vote pod, inside the cluster
  kubectl -n nephele exec deploy/vote -- python -c \
    "import urllib.request as u; print(u.urlopen('http://127.0.0.1:8080/metrics', timeout=3).read().decode())" 2>/dev/null \
    | awk -v m="$1" '$1 == m { print $2 }'
}

kubectl get ns chaos >/dev/null 2>&1 || kubectl create ns chaos >/dev/null
kubectl label ns chaos pod-security.kubernetes.io/enforce=restricted --overwrite >/dev/null
kubectl -n chaos create configmap k6-scripts --from-file=loadtest/k6-vote.js --from-file=loadtest/k6-stress.js \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
sed -e "s/JOB_NAME/$JOB/" -e "s/K6_SCRIPT/$SCRIPT/" k8s/jobs/k6-load.yaml | kubectl apply -f - >/dev/null
kubectl -n chaos wait --for=condition=ready pod -l "job-name=$JOB" --timeout=180s >/dev/null

echo "seconds,vote_pods,worker_pods,queue,in_flight,saved" > "$OUT/$NAME-scaling.csv"
start=$(date +%s)
while :; do
  t=$(( $(date +%s) - start ))
  vote=$(kubectl -n nephele get deploy vote -o jsonpath='{.status.readyReplicas}')
  worker=$(kubectl -n nephele get deploy worker -o jsonpath='{.status.readyReplicas}')
  m=$(kubectl -n nephele exec deploy/vote -- python -c \
    "import urllib.request as u; print(u.urlopen('http://127.0.0.1:8080/metrics', timeout=3).read().decode())" 2>/dev/null)
  q=$(echo "$m" | awk '$1=="nephele_queue_depth"{print $2}')
  f=$(echo "$m" | awk '$1=="nephele_votes_in_flight"{print $2}')
  s=$(echo "$m" | awk '$1=="nephele_votes_saved"{print $2}')
  echo "$t,${vote:-0},${worker:-0},$q,$f,$s" >> "$OUT/$NAME-scaling.csv"
  done_=$(kubectl -n chaos get job "$JOB" -o jsonpath='{.status.succeeded}{.status.failed}')
  if [ -n "$done_" ] && [ "${q%.*}" = "0" ]; then break; fi
  sleep 15
done

kubectl -n chaos logs "job/$JOB" > "$OUT/$NAME-raw.log"
sed '/===SUMMARY===/,$d' "$OUT/$NAME-raw.log" > "$OUT/$NAME-output.txt"
sed '1,/===SUMMARY===/d' "$OUT/$NAME-raw.log" > "$OUT/$NAME-summary.json"
rm -f "$OUT/$NAME-raw.log"
grep -E 'http_req_duration|http_req_failed|http_reqs|vus_max|checks_succeeded' "$OUT/$NAME-output.txt" | head -8
cat "$OUT/$NAME-scaling.csv"
[ "$(kubectl -n chaos get job "$JOB" -o jsonpath='{.status.succeeded}')" = "1" ]
