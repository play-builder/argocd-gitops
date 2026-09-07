#!/usr/bin/env bash
set -Eeuo pipefail
test_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cd "$test_root/.."
bash "$test_root/rename-contract.sh"
bash "$test_root/rename-cutover-contract.sh"
ruby "$test_root/ci-tool-path-contract.rb"
ruby "$test_root/chart-download-contract.rb"
ruby "$test_root/data-governance-contract.rb"
ruby "$test_root/management-mesh-contract.rb"
ruby "$test_root/argocd-tenancy-contract.rb"
ruby "$test_root/notification-contract.rb"
ruby "$test_root/sigstore-policy-contract.rb"
ruby "$test_root/platform-governance-contract.rb"
ruby "$test_root/istio-platform-contract.rb"
ruby "$test_root/istio-routing-contract.rb"
ruby "$test_root/ignore-differences-contract.rb"
ruby "$test_root/isolated-operations-contract.rb"
ruby "$test_root/operation-schema-contract.rb"
ruby "$test_root/incident-binding-contract.rb"
ruby "$test_root/burn-rate-contract.rb"
ruby "$test_root/edge-waf-contract.rb"
ruby "$test_root/platform-handoff-contract.rb"
ruby "$test_root/platform-mirror-handoff-contract.rb"
ruby "$test_root/platform-mirror-contract.rb"
ruby "$test_root/rollout-promql-contract.rb"
ruby "$test_root/cross-repository-contract.rb"
ruby "$test_root/chart-package-contract.rb"
ruby "$test_root/istio-analyze-contract.rb"
ruby "$test_root/istio-cni-contract.rb"
ruby "$test_root/istio-cni-readiness-contract.rb"
ruby "$test_root/application-secrets-contract.rb"
ruby "$test_root/activation-contract.rb"
ruby "$test_root/rc-integration-contract.rb"
ruby "$test_root/rc-recovery-contract.rb"
bash "$test_root/bootstrap-contract.sh" --case all
bash "$test_root/evidence-contract.sh" --case all
bash "$test_root/cluster-arn-contract.sh"
bash "$test_root/prod-baseline-runtime-producer-contract.sh"
bash "$test_root/prod-slo-runtime-producer-contract.sh"
bash "$test_root/runtime-evidence-producer-contract.sh"
bash "$test_root/promotion-contract.sh" --case all
bash "$test_root/prod-promotion-binding-contract.sh"
bash "$test_root/sample-verifier-binding-contract.sh"
if [[ -n ${SAMPLE_APP_REPO_ROOT:-} || -n ${SAMPLE_APP_VERIFIER_PATH:-} ||
      ${CROSS_REPO_CONTRACT_MODE:-repository-local} == exact-sha ]]; then
  bash "$test_root/rollback-candidates-runtime-contract.sh"
else
  SAMPLE_APP_VERIFIER_OPTIONAL=1 bash "$test_root/rollback-candidates-runtime-contract.sh"
fi
bash "$test_root/snapshot-runtime-producer-contract.sh"
bash "$test_root/governance-contract.sh"
bash "$test_root/cleanup-contract.sh" --all
echo "STATIC_VERIFIED: local contract suite; cloud/notification/DB/mesh recovery runtime not executed"
