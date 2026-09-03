#!/usr/bin/env bash
set -Eeuo pipefail

test_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
repository_root=$(cd -- "$test_root/.." && pwd -P)
fixture_root="$test_root/fixtures"
scratch_root=$(mktemp -d "${TMPDIR:-/tmp}/cluster-arn-contract.XXXXXX")
trap 'rm -rf -- "$scratch_root"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

max_name="A$(printf 'a%.0s' {1..99})"
long_name="A$(printf 'a%.0s' {1..100})"
invalid_arns=(
  'arn:aws-cn:eks:ap-northeast-2:123456789012:cluster/course-dev'
  'arn:aws:eks:ap-northeast-2:123456789012:cluster/'
  'arn:aws:eks:ap-northeast-2:123456789012:cluster/course-dev/extra'
  'arn:aws:eks:ap-northeast-2:123456789012:cluster/course dev'
  'arn:aws:eks:ap-northeast-2:123456789012:cluster/course.dev'
  'arn:aws:eks:ap-northeast-2:123456789012:cluster/-course-dev'
  'arn:aws:eks:ap-northeast-2:123456789012:cluster/course-dev '
  "arn:aws:eks:ap-northeast-2:123456789012:cluster/$long_name"
)

valid_special="$scratch_root/valid-special.json"
jq '.clusterArn="arn:aws:eks:ap-northeast-2:123456789012:cluster/Prod_Cluster-1"' \
  "$fixture_root/evidence/baseline-valid.json" >"$valid_special"
bash "$repository_root/scripts/capture-prod-baseline-evidence.sh" --fixture "$valid_special" >/dev/null ||
  fail 'a valid EKS cluster ARN containing uppercase, underscore, and hyphen was rejected'
for valid_name in A "$max_name"; do
  valid_boundary="$scratch_root/valid-boundary.json"
  jq --arg arn "arn:aws:eks:ap-northeast-2:123456789012:cluster/$valid_name" \
    '.clusterArn=$arn' "$fixture_root/evidence/baseline-valid.json" >"$valid_boundary"
  bash "$repository_root/scripts/capture-prod-baseline-evidence.sh" --fixture "$valid_boundary" >/dev/null ||
    fail "a valid EKS cluster ARN boundary was rejected: $valid_name"
done

for arn in "${invalid_arns[@]}"; do
  baseline="$scratch_root/baseline.json"
  prod_slo="$scratch_root/prod-slo.json"
  snapshot="$scratch_root/snapshot.json"
  deployment="$scratch_root/deployment.json"
  dev_slo="$scratch_root/dev-slo.json"
  promotion="$scratch_root/promotion.yaml"
  freeze="$scratch_root/freeze.json"
  removal="$scratch_root/removal.json"
  handoff="$scratch_root/handoff.json"
  adoption="$scratch_root/adoption.json"

  jq --arg arn "$arn" '.clusterArn=$arn' "$fixture_root/evidence/baseline-valid.json" >"$baseline"
  if bash "$repository_root/scripts/capture-prod-baseline-evidence.sh" --fixture "$baseline" >/dev/null 2>&1; then
    fail "Prod baseline fixture accepted invalid EKS cluster ARN: $arn"
  fi

  jq --arg arn "$arn" '.clusterArn=$arn' "$fixture_root/evidence/prod-slo-valid.json" >"$prod_slo"
  if bash "$repository_root/scripts/capture-prod-slo-evidence.sh" --fixture "$prod_slo" >/dev/null 2>&1; then
    fail "Prod SLO fixture accepted invalid EKS cluster ARN: $arn"
  fi

  jq --arg arn "$arn" '.clusterArn=$arn' "$fixture_root/recovery/snapshot-quiesce-valid.json" >"$snapshot"
  if bash "$repository_root/scripts/capture-snapshot-evidence.sh" --fixture "$snapshot" >/dev/null 2>&1; then
    fail "snapshot evidence accepted invalid EKS cluster ARN: $arn"
  fi

  jq --arg arn "$arn" '.clusterArn=$arn' "$fixture_root/evidence/deployment-valid.json" >"$deployment"
  jq --arg arn "$arn" '.clusterArn=$arn' "$fixture_root/evidence/slo-valid.json" >"$dev_slo"
  if bash "$test_root/evidence-contract.sh" --case raw --deployment "$deployment" --slo "$dev_slo" \
    --baseline "$fixture_root/evidence/baseline-valid.json" >/dev/null 2>&1; then
    fail "raw evidence consumer accepted invalid EKS cluster ARN: $arn"
  fi

  ARN_VALUE="$arn" yq '.cluster.arn=strenv(ARN_VALUE)' \
    "$fixture_root/promotion/valid-ap-northeast-2.yaml" >"$promotion"
  if bash "$test_root/promotion-contract.sh" --evidence "$promotion" \
    --rollback "$fixture_root/rollback/inside-window.json" \
    --baseline "$fixture_root/evidence/baseline-valid.json" --now 2026-09-03T01:00:00Z >/dev/null 2>&1; then
    fail "promotion consumer accepted invalid EKS cluster ARN: $arn"
  fi

  jq --arg arn "$arn" '.clusters[0].clusterArn=$arn' "$fixture_root/cleanup/freeze-valid.json" >"$freeze"
  if bash "$repository_root/scripts/capture-cleanup-evidence.sh" freeze --fixture "$freeze" >/dev/null 2>&1; then
    fail "freeze evidence accepted invalid EKS cluster ARN: $arn"
  fi

  jq --arg arn "$arn" '.clusters[0].clusterArn=$arn' "$fixture_root/cleanup/removal-valid.json" >"$removal"
  if bash "$repository_root/scripts/capture-cleanup-evidence.sh" removal --fixture "$removal" \
    --eks-repo-root "$fixture_root/cleanup" >/dev/null 2>&1; then
    fail "removal evidence accepted invalid EKS cluster ARN: $arn"
  fi

  jq --arg arn "$arn" '.clusterArn=$arn' "$fixture_root/platform-owner-handoff/dev-handoff.json" >"$handoff"
  handoff_digest="sha256:$(sha256_file "$handoff")"
  jq --arg arn "$arn" --arg digest "$handoff_digest" \
    '.clusterArn=$arn | .handoffSha256=$digest' \
    "$fixture_root/platform-owner-handoff/dev-adoption.json" >"$adoption"
  if COURSE_PHASE_B_TEST_MODE=1 COURSE_PHASE_B_NOW=2026-09-03T00:20:00Z \
    bash "$repository_root/scripts/verify-platform-owner-phase-b.sh" --environment dev \
      --handoff "$handoff" --adoption "$adoption" \
      --expected-gitops-revision 1111111111111111111111111111111111111111 >/dev/null 2>&1; then
    fail "platform ownership consumer accepted invalid EKS cluster ARN: $arn"
  fi
done

echo 'PASS: all EKS cluster ARN producers and consumers enforce the canonical grammar.'
