#!/usr/bin/env bash
set -Eeuo pipefail
test_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
bash "$test_root/rename-contract.sh"
ruby "$test_root/ci-tool-path-contract.rb"
bash "$test_root/observability-contract.sh"
bash "$test_root/application-evidence-contract.sh"
bash "$test_root/source-integrity-contract.sh"
bash "$test_root/rename-cutover-contract.sh"
bash "$test_root/enterprise-contract-suite.test.sh"
bash "$test_root/enterprise-contract-suite.sh"
bash "$test_root/platform-handoff-contract.sh"
ruby "$test_root/platform-mirror-handoff-contract.rb"
ruby "$test_root/platform-mirror-contract.rb"
ruby "$test_root/rollout-promql-contract.rb"
ruby "$test_root/management-mesh-contract.rb"
bash "$test_root/cross-repository-contract.sh"
bash "$test_root/render-lock-contract.sh"
ruby "$test_root/chart-package-contract.rb"
ruby "$test_root/istio-analyze-contract.rb"
ruby "$test_root/istio-cni-contract.rb"
ruby "$test_root/istio-cni-readiness-contract.rb"
bash "$test_root/render-contract.sh" --case matrix
bash "$test_root/render-contract.sh" --case secret-reload
bash "$test_root/render-contract.sh" --case network-policy
bash "$test_root/render-contract.sh" --case telemetry
bash "$test_root/render-contract.sh" --case project-scope
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
bash "$test_root/stateful-contract.sh"
bash "$test_root/recovery-contract.sh" --case all
bash "$test_root/snapshot-runtime-producer-contract.sh"
bash "$test_root/governance-contract.sh"
bash "$test_root/chaos-separation-contract.sh"
bash "$test_root/incident-contract.sh" --all
bash "$test_root/cleanup-contract.sh" --all
echo "STATIC_VERIFIED: complete local contract suite; cloud/notification/DB/mesh recovery runtime not executed"
