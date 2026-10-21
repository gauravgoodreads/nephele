#!/usr/bin/env bash
# Removes the whole AWS deployment so it stops costing money.
#
#   scripts/aws-down.sh                # AWS_PROFILE selects the account
#
# The load balancer belongs to Kubernetes, not Terraform, and it holds network
# interfaces in the VPC, so it is deleted first; otherwise destroying the VPC
# fails. Then Terraform removes everything it created.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
CTX=nephele-aws

step() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

if kubectl config get-contexts "$CTX" >/dev/null 2>&1; then
  step "Deleting the load balancer (ingress-nginx namespace)"
  kubectl --context "$CTX" delete namespace ingress-nginx --ignore-not-found --wait=true --timeout=300s || true
  # Give AWS time to release the balancer's network interfaces.
  sleep 60
fi

step "Destroying the Terraform-managed infrastructure"
terraform -chdir=infra/terraform destroy -auto-approve -input=false

kubectl config delete-context "$CTX" >/dev/null 2>&1 || true
step "Done: nothing from Nephele is left running on AWS"
