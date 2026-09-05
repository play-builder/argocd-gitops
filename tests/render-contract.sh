#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."
# Keep the incident catalog's named entry point bound to actual rendered owners.
requested=matrix
if [[ "${1:-}" == --case && $# == 2 ]]; then
  requested=$2
elif [[ $# != 0 ]]; then
  echo "Usage: $0 [--case matrix|network-policy|telemetry|secret-reload]" >&2
  exit 2
fi
case "$requested" in
  network-policy)
    ruby tests/data-governance-contract.rb
    ruby tests/management-mesh-contract.rb
    ;;
  telemetry) ruby tests/management-mesh-contract.rb; ruby tests/rc-integration-contract.rb telemetry ;;
  project-scope) ruby tests/rc-integration-contract.rb project-scope ;;
  secret-reload) ruby tests/application-secrets-contract.rb ;;
  matrix)
    ruby tests/data-governance-contract.rb
    ruby tests/isolated-operations-contract.rb
    ;;
  *) echo "FAIL: unknown render case: $requested" >&2; exit 2 ;;
esac
