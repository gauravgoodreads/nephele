# Creates the local Kubernetes cluster and deploys Nephele to it.
# Run from anywhere:  powershell -ExecutionPolicy Bypass -File scripts\kind-up.ps1
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

function Step($text) { Write-Host "`n==> $text" -ForegroundColor Cyan }

Step "Creating kind cluster 'nephele' (skipped if it already exists)"
$clusters = kind get clusters 2>$null
if ($clusters -notcontains "nephele") {
    kind create cluster --config kind/cluster.yaml
}
kubectl config use-context kind-nephele | Out-Null

Step "Installing the NGINX Ingress controller"
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.12.0/deploy/static/provider/kind/deploy.yaml

Step "Installing metrics-server (needed by the autoscaler)"
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/download/v0.7.2/components.yaml
$msArgs = kubectl -n kube-system get deployment metrics-server -o jsonpath='{.spec.template.spec.containers[0].args}'
if ($msArgs -notmatch "kubelet-insecure-tls") {
    kubectl -n kube-system patch deployment metrics-server --type=json `
        -p '[{\"op\":\"add\",\"path\":\"/spec/template/spec/containers/0/args/-\",\"value\":\"--kubelet-insecure-tls\"}]'
}

Step "Building the three application images"
docker compose -f docker-compose.nephele.yml build vote result worker

Step "Loading images into the cluster"
kind load docker-image nephele/vote:local nephele/result:local nephele/worker:local --name nephele

Step "Waiting for the Ingress controller"
kubectl -n ingress-nginx wait --for=condition=ready pod -l app.kubernetes.io/component=controller --timeout=180s

Step "Deploying Nephele"
kubectl apply -k k8s/overlays/local
foreach ($d in "redis", "vote", "result", "worker") {
    kubectl -n nephele rollout status deployment/$d --timeout=180s
}
kubectl -n nephele rollout status statefulset/db --timeout=180s

Step "Done"
kubectl -n nephele get pods,svc,hpa,ingress,cronjob
Write-Host "`nVote page:    http://vote.localtest.me:8888" -ForegroundColor Green
Write-Host "Results page: http://result.localtest.me:8888" -ForegroundColor Green
