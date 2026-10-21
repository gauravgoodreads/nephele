#!/usr/bin/env bash
# Builds the whole local platform and deploys Nephele to it:
# a 3-node kind cluster, NGINX Ingress, metrics-server, KEDA, the three
# application images, the app (queue-scaled worker) and the monitoring stack.
#
#   scripts/kind-up.sh                 # everything
#   MONITORING=0 scripts/kind-up.sh    # without Prometheus/Grafana (saves ~400 MB)
#
# Works in Git Bash on Windows, macOS, Linux and GitHub Actions.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CLUSTER=nephele
MONITORING="${MONITORING:-1}"
INGRESS_NGINX_VERSION=controller-v1.12.0
METRICS_SERVER_VERSION=v0.7.2
KEDA_VERSION=2.16.1

step() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

step "Creating kind cluster '$CLUSTER' (1 control plane + 2 workers in zone-a/zone-b)"
if ! kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  kind create cluster --config kind/cluster.yaml --wait 180s
fi
kubectl config use-context "kind-$CLUSTER" >/dev/null
kubectl get nodes -L topology.kubernetes.io/zone

step "Installing the NGINX Ingress controller ($INGRESS_NGINX_VERSION)"
kubectl apply -f "https://raw.githubusercontent.com/kubernetes/ingress-nginx/$INGRESS_NGINX_VERSION/deploy/static/provider/kind/deploy.yaml"
# Request metrics (count, status, latency per Service) are off by default in
# this release; the monitoring stack and its alerts depend on them.
if ! kubectl -n ingress-nginx get deployment ingress-nginx-controller -o jsonpath='{.spec.template.spec.containers[0].args}' | grep -q enable-metrics=true; then
  kubectl -n ingress-nginx patch deployment ingress-nginx-controller --type=json \
    -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--enable-metrics=true"}]'
fi

step "Installing metrics-server ($METRICS_SERVER_VERSION), needed by the CPU autoscaler"
kubectl apply -f "https://github.com/kubernetes-sigs/metrics-server/releases/download/$METRICS_SERVER_VERSION/components.yaml"
if ! kubectl -n kube-system get deployment metrics-server -o jsonpath='{.spec.template.spec.containers[0].args}' | grep -q kubelet-insecure-tls; then
  kubectl -n kube-system patch deployment metrics-server --type=json \
    -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
fi

step "Installing KEDA $KEDA_VERSION (scales the worker on queue length)"
kubectl apply --server-side -f "https://github.com/kedacore/keda/releases/download/v$KEDA_VERSION/keda-$KEDA_VERSION.yaml"

step "Building the application images"
docker build -t nephele/vote:local --target final vote
docker build -t nephele/result:local result
docker build -t nephele/worker:local worker

step "Loading the images into every node"
kind load docker-image nephele/vote:local nephele/result:local nephele/worker:local --name "$CLUSTER"

step "Waiting for the platform components"
kubectl -n ingress-nginx wait --for=condition=ready pod -l app.kubernetes.io/component=controller --timeout=300s
kubectl -n keda wait --for=condition=available deployment --all --timeout=300s
kubectl -n kube-system wait --for=condition=available deployment/metrics-server --timeout=300s

step "Deploying Nephele"
kubectl apply -k k8s/overlays/local-keda
kubectl -n nephele rollout status statefulset/redis --timeout=300s
kubectl -n nephele rollout status statefulset/db --timeout=300s
for d in vote result worker; do
  kubectl -n nephele rollout status "deployment/$d" --timeout=300s
done

if [ "$MONITORING" = "1" ]; then
  step "Deploying monitoring (Prometheus, kube-state-metrics, Grafana)"
  kubectl apply -k k8s/addons/monitoring
  for d in prometheus kube-state-metrics grafana; do
    kubectl -n monitoring rollout status "deployment/$d" --timeout=300s
  done
fi

step "Done"
kubectl -n nephele get pods -o wide
echo
echo "Vote page:    http://vote.localtest.me:8888"
echo "Results page: http://result.localtest.me:8888"
if [ "$MONITORING" = "1" ]; then
  echo "Grafana:      http://grafana.localtest.me:8888"
  echo "Prometheus:   http://prometheus.localtest.me:8888"
fi
