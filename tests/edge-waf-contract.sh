#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."
[[ -f scripts/validate-mesh-inputs.rb ]] || { echo 'FAIL: release mesh input validator missing'; exit 1; }
ruby tests/edge-waf-contract.rb
