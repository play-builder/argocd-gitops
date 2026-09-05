#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."
bash tests/platform-handoff-contract.sh
bash tests/argocd-tenancy-contract.sh
bash tests/notification-contract.sh
bash tests/burn-rate-contract.sh
bash tests/source-integrity-contract.sh
bash tests/istio-platform-contract.sh
bash tests/edge-waf-contract.sh
bash tests/kubeconform-contract.sh
bash tests/render-lock-contract.sh
ruby tests/istio-analyze-contract.rb
echo 'STATIC_VERIFIED: Batch 2 contracts only; Tasks 9-12 and live gates remain pending'
