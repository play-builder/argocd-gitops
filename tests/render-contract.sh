#!/usr/bin/env bash
set -Eeuo pipefail

test_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repository_root=$(cd -- "$test_root/.." && pwd)
fixture_root="$test_root/fixtures/values"
render_root=$(mktemp -d "${TMPDIR:-/tmp}/gitops-render-contract.XXXXXX")
trap 'rm -rf -- "$render_root"' EXIT

# shellcheck source=tests/lib/render.sh
source "$test_root/lib/render.sh"

assert_document_count() {
  local manifest=$1
  local kind=$2
  local expected=$3
  local actual

  actual=$(KIND="$kind" yq eval-all \
    '[select(.kind == strenv(KIND))] | length' "$manifest")
  if [[ "$actual" != "$expected" ]]; then
    echo "FAIL: expected $expected $kind documents in $manifest, got $actual" >&2
    return 1
  fi
}

run_case() {
  local case_name=$1
  local expected_network_policies

  case "$case_name" in
    stateless-policy-off) expected_network_policies=0 ;;
    stateless-policy-on) expected_network_policies=1 ;;
    stateful-policy-off) expected_network_policies=0 ;;
    stateful-policy-on) expected_network_policies=2 ;;
    *)
      echo "FAIL: unknown render case: $case_name" >&2
      return 2
      ;;
  esac

  local manifest="$render_root/$case_name.yaml"
  render_environment dev "$manifest" "$fixture_root/$case_name.yaml"
  assert_document_count "$manifest" NetworkPolicy "$expected_network_policies"
}

requested_case=matrix
if [[ "${1:-}" == "--case" ]]; then
  requested_case=${2:-}
elif [[ $# -gt 0 ]]; then
  echo "Usage: $0 [--case <matrix|case-name>]" >&2
  exit 2
fi

if [[ "$requested_case" == "matrix" ]]; then
  run_case stateless-policy-off
  run_case stateless-policy-on
  run_case stateful-policy-off
  run_case stateful-policy-on
else
  run_case "$requested_case"
fi

echo "PASS: Helm render matrix is valid ($requested_case)."
