#!/usr/bin/env bash
set -Eeuo pipefail

test_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
output=$(mktemp)
trap 'rm -f "$output"' EXIT

if bash "$test_root/enterprise-contract-suite.sh" >"$output" 2>&1; then
  echo "FAIL: incomplete enterprise suite must fail" >&2
  exit 1
fi

grep -Fq 'argocd-tenancy-contract.sh' "$output" || {
  echo "FAIL: suite must name the first unavailable contract" >&2
  cat "$output" >&2
  exit 1
}

echo "PASS: enterprise suite reports its first unavailable contract"
