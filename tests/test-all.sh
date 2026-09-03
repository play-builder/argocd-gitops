#!/usr/bin/env bash
set -Eeuo pipefail
test_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
bash "$test_root/render-contract.sh" --case matrix
bash "$test_root/bootstrap-contract.sh" --case namespace-pss
bash "$test_root/evidence-contract.sh" --case raw
bash "$test_root/promotion-contract.sh" --case render
bash "$test_root/stateful-contract.sh"
bash "$test_root/chaos-contract.sh" --case dev
bash "$test_root/incident-contract.sh" --all
bash "$test_root/cleanup-contract.sh" --all
echo "[STATIC] PASS: complete local contract suite"
