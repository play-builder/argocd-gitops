#!/usr/bin/env bash
set -Eeuo pipefail
test_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# Legacy entry point; current operations own bounded Dev-only chaos separately.
case_name=${2:-${1:-dev}}
case "$case_name" in
  dev|prod-deny|namespace-injection) ;;
  *) echo 'FAIL: unknown chaos contract case' >&2; exit 2 ;;
esac
bash "$test_root/chaos-separation-contract.sh"
