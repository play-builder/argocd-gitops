#!/usr/bin/env bash
set -Eeuo pipefail

test_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repository_root=$(cd -- "$test_root/.." && pwd)
default_candidate="$repository_root/docs/github-ruleset.example.json"

validate_ruleset() {
  local candidate=$1
  jq -e '
    .name == "main-protection" and
    .target == "branch" and
    .enforcement == "active" and
    .bypass_actors == [] and
    ([.rules[] | select(.type == "pull_request")] | length) == 1 and
    ([.rules[] | select(.type == "pull_request") |
      .parameters.required_approving_review_count] == [0]) and
    ([.rules[] | select(.type == "pull_request") |
      .parameters.require_code_owner_review] == [true]) and
    ([.rules[] | select(.type == "required_status_checks") |
      .parameters.required_status_checks[].context] == ["validate"])
  ' "$candidate" >/dev/null
}

candidate=${1:-$default_candidate}
if ! validate_ruleset "$candidate"; then
  echo "FAIL: Ruleset must require validate, zero global approvals, CODEOWNERS review, and no bypass" >&2
  exit 1
fi

if [[ $# -eq 0 ]]; then
  fixture_root=$(mktemp -d "${TMPDIR:-/tmp}/gitops-governance-contract.XXXXXX")
  trap 'rm -rf -- "$fixture_root"' EXIT
  jq '(.rules[] | select(.type == "pull_request") |
    .parameters.required_approving_review_count) = 1' \
    "$candidate" >"$fixture_root/approval-drift.json"
  if validate_ruleset "$fixture_root/approval-drift.json"; then
    echo "FAIL: Ruleset contract accepted approval count drift" >&2
    exit 1
  fi
fi

echo "PASS: Ruleset governance contract is structurally valid."
