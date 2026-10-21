#!/usr/bin/env bash
# Smoke test: casts real votes through the Ingress and checks they come out
# the other end (Redis -> worker -> PostgreSQL -> result API), then checks the
# monitoring stack is scraping every target.
set -euo pipefail

NS=nephele
VOTE_URL="${VOTE_URL:-http://vote.localtest.me:8888}"
RESULT_URL="${RESULT_URL:-http://result.localtest.me:8888}"
PROM_URL="${PROM_URL:-http://prometheus.localtest.me:8888}"
N="${N:-40}"
RUN="smoke-$(date +%s)"

fail() { echo "SMOKE TEST FAILED: $*" >&2; exit 1; }

echo "Casting $N votes through $VOTE_URL"
before=$(curl -4 -sf "$RESULT_URL/api/results" | sed -E 's/.*"total":([0-9]+).*/\1/') || fail "result API not reachable"
for i in $(seq 1 "$N"); do
  opt=$([ $((i % 3)) -eq 0 ] && echo b || echo a)
  code=$(curl -4 -s -o /dev/null -w '%{http_code}' -X POST -d "vote=$opt" -H "Cookie: voter_id=$RUN-$i" "$VOTE_URL/")
  [ "$code" = "200" ] || fail "vote $i returned HTTP $code"
done

echo "Waiting for the worker to save them"
deadline=$(( $(date +%s) + 120 ))
while :; do
  saved=$(kubectl -n "$NS" exec db-0 -- psql -U postgres -At -c "SELECT count(*) FROM votes WHERE id LIKE '$RUN-%'" | tr -d '\r')
  [ "$saved" = "$N" ] && break
  [ "$(date +%s)" -gt "$deadline" ] && fail "only $saved of $N votes reached the database"
  sleep 2
done

sleep 2
after=$(curl -4 -sf "$RESULT_URL/api/results" | sed -E 's/.*"total":([0-9]+).*/\1/')
[ $((after - before)) -ge "$N" ] || fail "result API total went from $before to $after, expected +$N"
echo "OK: $N votes accepted, saved and counted (result total $before -> $after)"

if curl -4 -sf -o /dev/null "$PROM_URL/-/ready" 2>/dev/null; then
  echo "Checking Prometheus targets"
  sleep 15
  targets=$(curl -4 -sf "$PROM_URL/api/v1/targets?state=active")
  for job in nephele-pods ingress-nginx kube-state-metrics cadvisor; do
    up=$(echo "$targets" | grep -o "\"job\":\"$job\"[^}]*}[^}]*\"health\":\"up\"" | wc -l | tr -d ' ')
    [ "$up" -ge 1 ] || fail "Prometheus has no healthy target for job $job"
    echo "  $job: $up target(s) up"
  done
  echo "OK: monitoring is scraping every job"
fi
