#!/usr/bin/env bash
# Deploys Nephele to the EKS cluster built by infra/terraform:
# pushes the three images to ECR, installs the NGINX Ingress controller
# (behind an AWS Network Load Balancer), metrics-server, KEDA and the
# monitoring stack, then applies the aws overlay with the real RDS and
# ElastiCache endpoints and checks that a vote goes all the way through.
#
#   (cd infra/terraform && terraform apply)
#   scripts/aws-up.sh                  # AWS_PROFILE selects the account
#   MONITORING=0 scripts/aws-up.sh     # without Prometheus/Grafana
#
# The pages are published as vote.<ip>.nip.io and result.<ip>.nip.io, where
# <ip> is the load balancer's address, so no domain name is needed.
# Grafana and Prometheus are NOT published: open them with port-forward.
#
# kubectl gets a context named nephele-aws; the current context is left as it was.
# Works in Git Bash on Windows, macOS and Linux.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

MONITORING="${MONITORING:-1}"
INGRESS_NGINX_VERSION=controller-v1.12.0
METRICS_SERVER_VERSION=v0.7.2
KEDA_VERSION=2.16.1
CTX=nephele-aws
TAG="$(git rev-parse --short HEAD)"

step() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
tf() { terraform -chdir=infra/terraform output -raw "$1"; }
k() { kubectl --context "$CTX" "$@"; }
resolve() { # first IPv4 address of a host name
  local py
  for py in python3 python; do
    "$py" -c 'import socket, sys; print(socket.gethostbyname(sys.argv[1]))' "$1" 2>/dev/null && return 0
  done
  return 1
}

REGION="$(tf region)"
CLUSTER="$(tf cluster_name)"
DB_HOST="$(tf db_endpoint)"
REDIS_HOST="$(tf redis_endpoint)"
ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
REGISTRY="$ACCOUNT.dkr.ecr.$REGION.amazonaws.com"

step "Connecting kubectl to EKS cluster '$CLUSTER' in $REGION"
previous="$(kubectl config current-context 2>/dev/null || true)"
aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION" --alias "$CTX" >/dev/null
if [ -n "$previous" ]; then kubectl config use-context "$previous" >/dev/null; fi
k get nodes -L topology.kubernetes.io/zone

step "Building the images and pushing them to ECR (tag $TAG)"
aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "$REGISTRY" >/dev/null
for svc in vote result worker; do
  docker build -q -t "$REGISTRY/nephele-$svc:$TAG" "$svc" >/dev/null
  docker push -q "$REGISTRY/nephele-$svc:$TAG"
done

step "Installing the NGINX Ingress controller ($INGRESS_NGINX_VERSION) behind a Network Load Balancer"
k apply -f "https://raw.githubusercontent.com/kubernetes/ingress-nginx/$INGRESS_NGINX_VERSION/deploy/static/provider/aws/deploy.yaml" >/dev/null
# Request metrics for Prometheus (off by default).
if ! k -n ingress-nginx get deployment ingress-nginx-controller -o jsonpath='{.spec.template.spec.containers[0].args}' | grep -q enable-metrics=true; then
  k -n ingress-nginx patch deployment ingress-nginx-controller --type=json \
    -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--enable-metrics=true"}]' >/dev/null
fi

step "Installing metrics-server ($METRICS_SERVER_VERSION) and KEDA ($KEDA_VERSION)"
k apply -f "https://github.com/kubernetes-sigs/metrics-server/releases/download/$METRICS_SERVER_VERSION/components.yaml" >/dev/null
k apply --server-side -f "https://github.com/kedacore/keda/releases/download/v$KEDA_VERSION/keda-$KEDA_VERSION.yaml" >/dev/null
k -n ingress-nginx rollout status deployment/ingress-nginx-controller --timeout=300s
k -n keda wait --for=condition=available deployment --all --timeout=300s
k -n kube-system wait --for=condition=available deployment/metrics-server --timeout=300s

step "Waiting for the load balancer's address"
LB=""
for _ in $(seq 60); do
  LB="$(k -n ingress-nginx get service ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"
  [ -n "$LB" ] && break
  sleep 5
done
[ -n "$LB" ] || { echo "The load balancer got no address" >&2; exit 1; }
# A Network Load Balancer keeps one fixed IP per Availability Zone, so
# nip.io names built from it stay valid for the life of the balancer.
LB_IP=""
for _ in $(seq 60); do
  LB_IP="$(resolve "$LB" || true)"
  [ -n "$LB_IP" ] && break
  sleep 10
done
[ -n "$LB_IP" ] || { echo "$LB does not resolve yet; run this script again in a few minutes" >&2; exit 1; }
VOTE_HOST="vote.$LB_IP.nip.io"
RESULT_HOST="result.$LB_IP.nip.io"
echo "$LB -> $LB_IP"

step "Deploying Nephele (aws overlay: RDS, ElastiCache, ECR images, KEDA)"
pw="$(tf db_password)"
printf 'DB_PASSWORD=%s\nDATABASE_URL=postgres://postgres:%s@db/postgres\n' "$pw" "$pw" > k8s/overlays/aws/secrets.env
unset pw
kubectl kustomize k8s/overlays/aws \
  | sed -e "s#ACCOUNT_ID\.dkr\.ecr\.ap-south-1\.amazonaws\.com\(/nephele-[a-z]*\):latest#$REGISTRY\1:$TAG#" \
        -e "s#nephele-db\.REPLACE_ME\.ap-south-1\.rds\.amazonaws\.com#$DB_HOST#" \
        -e "s#nephele-redis\.REPLACE_ME\.cache\.amazonaws\.com#$REDIS_HOST#" \
        -e "s#vote\.nephele\.example\.com#$VOTE_HOST#" \
        -e "s#result\.nephele\.example\.com#$RESULT_HOST#" \
  | k apply -f - >/dev/null
for d in vote result worker; do
  k -n nephele rollout status "deployment/$d" --timeout=300s
done

if [ "$MONITORING" = "1" ]; then
  step "Deploying the monitoring stack (private: no Ingress on AWS)"
  kubectl kustomize k8s/addons/monitoring \
    | awk 'BEGIN { RS = "\n---\n"; ORS = "\n---\n" } !/(^|\n)kind: Ingress\n/' \
    | k apply -f - >/dev/null
  k -n monitoring rollout status deployment/prometheus --timeout=300s
  k -n monitoring rollout status deployment/grafana --timeout=300s
fi

step "Smoke test: one vote in through the load balancer, out through the result API"
code="$(curl -s -o /dev/null -w '%{http_code}' --retry 12 --retry-delay 10 --retry-all-errors "http://$VOTE_HOST/")"
[ "$code" = "200" ] || { echo "vote page answered $code" >&2; exit 1; }
curl -s -o /dev/null -X POST -d vote=a "http://$VOTE_HOST/"
sleep 5
curl -s "http://$RESULT_HOST/api/results"; echo

step "Nephele is running on AWS"
cat <<EOF
Vote:       http://$VOTE_HOST
Results:    http://$RESULT_HOST
Grafana:    kubectl --context $CTX -n monitoring port-forward svc/grafana 3000:3000
Prometheus: kubectl --context $CTX -n monitoring port-forward svc/prometheus 9090:9090
Remove everything: scripts/aws-down.sh
EOF
