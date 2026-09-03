#!/usr/bin/env bash
set -Eeuo pipefail
test_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
bash "$test_root/render-contract.sh" --case matrix
bash "$test_root/render-contract.sh" --case secret-reload
bash "$test_root/render-contract.sh" --case network-policy
bash "$test_root/render-contract.sh" --case telemetry
bash "$test_root/bootstrap-contract.sh" --case all
bash "$test_root/evidence-contract.sh" --case all
bash "$test_root/cluster-arn-contract.sh"
bash "$test_root/prod-baseline-runtime-producer-contract.sh"
bash "$test_root/prod-slo-runtime-producer-contract.sh"
bash "$test_root/runtime-evidence-producer-contract.sh"
bash "$test_root/promotion-contract.sh" --case all
bash "$test_root/prod-promotion-binding-contract.sh"
bash "$test_root/rollback-candidates-runtime-contract.sh"
bash "$test_root/stateful-contract.sh"
bash "$test_root/recovery-contract.sh" --case all
bash "$test_root/snapshot-runtime-producer-contract.sh"
bash "$test_root/chaos-contract.sh" --case dev
bash "$test_root/chaos-contract.sh" --case prod-deny
bash "$test_root/chaos-contract.sh" --case namespace-injection
bash "$test_root/incident-contract.sh" --all
bash "$test_root/cleanup-contract.sh" --all
echo "[STATIC] PASS: complete local contract suite"
