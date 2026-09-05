#!/usr/bin/env bash
set -Eeuo pipefail

test_root=${CONTRACT_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)}
contracts=(
  argocd-tenancy-contract.sh
  notification-contract.sh
  source-integrity-contract.sh
  sigstore-policy-contract.sh
  resource-governance-contract.sh
  istio-platform-contract.sh
  mesh-security-contract.sh
  istio-routing-contract.sh
  ignore-differences-contract.sh
  managed-database-contract.sh
  chaos-separation-contract.sh
  recovery-separation-contract.sh
  kubeconform-contract.sh
  runbook-contract.sh
  burn-rate-contract.sh
)

for contract in "${contracts[@]}"; do
  contract_path="$test_root/$contract"
  if [[ ! -f "$contract_path" ]]; then
    echo "FAIL: required enterprise contract is unavailable: $contract" >&2
    exit 1
  fi
  bash "$contract_path"
done

echo "[STATIC] PASS: enterprise GitOps contract suite"
