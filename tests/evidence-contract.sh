#!/usr/bin/env bash
set -Eeuo pipefail

test_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repository_root=$(cd -- "$test_root/.." && pwd)
fixture_root="$test_root/fixtures/evidence"

fail() { echo "FAIL: $*" >&2; exit 1; }

exact_keys() {
  local file=$1 expected=$2 path=${3:-.}
  EXPECTED="$expected" PATH_EXPR="$path" jq -e 'getpath((env.PATH_EXPR | split(".") | map(select(length > 0)))) | (keys | sort) == (env.EXPECTED | fromjson | sort)' "$file" >/dev/null ||
    fail "$(basename "$file") has an unexpected key set at $path"
}

validate_deployment() {
  local file=$1
  exact_keys "$file" '["schemaVersion","evidenceGrade","status","source","image","gitopsRevision","clusterArn","region","observedAt"]'
  exact_keys "$file" '["sync","health"]' .status
  exact_keys "$file" '["repository","sha"]' .source
  exact_keys "$file" '["repository","indexDigest"]' .image
  jq -e '
    .schemaVersion == "course.dev-deployment/v1" and .evidenceGrade == "CLOUD_RUNTIME" and
    .status == {sync:"Synced",health:"Healthy"} and
    (.source.repository | type == "string" and length > 0) and
    (.source.sha | test("^[0-9a-f]{40}$")) and
    (.image.indexDigest | test("^sha256:[0-9a-f]{64}$")) and
    (.gitopsRevision | test("^[0-9a-f]{40}$")) and
    (.clusterArn | test("^arn:aws:eks:[a-z0-9-]+:[0-9]{12}:cluster/.+")) and
    (.region | IN("ap-northeast-2","us-east-1")) and
    (.observedAt | fromdateiso8601 != null)
  ' "$file" >/dev/null || fail "deployment evidence is not CLOUD_RUNTIME or has invalid identity"
}

validate_slo() {
  local file=$1
  exact_keys "$file" '["schemaVersion","evidenceGrade","status","source","image","gitopsRevision","clusterArn","region","evidenceId","observedAt","expiresAt"]'
  exact_keys "$file" '["repository","sha"]' .source
  exact_keys "$file" '["repository","indexDigest"]' .image
  jq -e '
    .schemaVersion == "course.dev-slo/v1" and .evidenceGrade == "CLOUD_RUNTIME" and .status == "PASS" and
    (.source.sha | test("^[0-9a-f]{40}$")) and (.image.indexDigest | test("^sha256:[0-9a-f]{64}$")) and
    (.gitopsRevision | test("^[0-9a-f]{40}$")) and (.clusterArn | test("^arn:aws:eks:[a-z0-9-]+:[0-9]{12}:cluster/.+")) and
    (.region | IN("ap-northeast-2","us-east-1")) and
    (.observedAt | fromdateiso8601) < (.expiresAt | fromdateiso8601)
  ' "$file" >/dev/null || fail "SLO evidence is not an unexpired PASS CLOUD_RUNTIME record"
}

validate_baseline() {
  local file=$1
  jq -e '
    (keys | sort) == ["clusterArn","evidenceGrade","gitopsRevision","image","observedAt","region","rollout","schemaVersion"] and
    .schemaVersion == "course.prod-baseline/v1" and .evidenceGrade == "CLOUD_RUNTIME" and
    (.image | (keys | sort) == ["indexDigest","repository"]) and
    (.image.indexDigest | test("^sha256:[0-9a-f]{64}$")) and
    (.rollout | (keys | sort) == ["revision","stableHash","trafficWeight"]) and
    .rollout.revision == 1 and .rollout.trafficWeight == 100
  ' "$file" >/dev/null || fail "Prod baseline must prove stable ReplicaSet revision 1 at 100 percent"
}

case_raw() {
  local deployment=${DEPLOYMENT:-$fixture_root/deployment-valid.json}
  local slo=${SLO:-$fixture_root/slo-valid.json}
  validate_deployment "$deployment"
  validate_slo "$slo"
  validate_baseline "$fixture_root/baseline-valid.json"
  jq -s -e '.[0].source == .[1].source and .[0].image == .[1].image and .[0].gitopsRevision == .[1].gitopsRevision and .[0].clusterArn == .[1].clusterArn and .[0].region == .[1].region' "$deployment" "$slo" >/dev/null || fail "deployment and SLO source identity mismatch"
  echo "PASS: raw Dev evidence schemas and shared provenance are valid."
}

case_real_path() {
  local deployment="${DEPLOYMENT:-$repository_root/evidence/dev/deployment.json}"
  local slo="${SLO:-$repository_root/evidence/dev/slo.json}"
  for file in "$deployment" "$slo"; do
    [[ -f "$file" ]] || continue
    if [[ "$file" == "$repository_root/evidence/"* && "$file" == *"tests/fixtures"* ]]; then
      fail "real evidence path points below tests/fixtures"
    fi
    jq -e '.evidenceGrade == "CLOUD_RUNTIME"' "$file" >/dev/null || fail "real evidence requires CLOUD_RUNTIME"
    ! jq -e 'tostring | contains("example.invalid") or contains("0000000000000000000000000000000000000000")' "$file" >/dev/null || fail "real evidence contains fixture markers"
  done
  echo "PASS: real evidence paths are absent or provenance-guarded."
}

case_expiry() {
  local now=${NOW:-2026-09-03T01:00:00Z}
  NOW="$now" jq -e '(.observedAt | fromdateiso8601) <= (env.NOW | fromdateiso8601) and (env.NOW | fromdateiso8601) < (.expiresAt | fromdateiso8601)' "$fixture_root/slo-valid.json" >/dev/null || fail "SLO evidence is outside the promotion clock"
  echo "PASS: SLO observedAt/expiresAt bounds are valid."
}

case_prod_slo_terminal() {
  local valid="$fixture_root/prod-slo-valid.json"
  local invalid="$fixture_root/prod-slo-analysis-failed.json"
  local output

  output=$(bash "$repository_root/scripts/capture-prod-slo-evidence.sh" --fixture "$valid")
  grep -Fq '[STATIC] fake Prod SLO adapter validated' <<<"$output" ||
    fail "valid Prod SLO fixture was not accepted by the runtime validator"

  if output=$(bash "$repository_root/scripts/capture-prod-slo-evidence.sh" --fixture "$invalid" 2>&1); then
    fail "failed AnalysisRun fixture was accepted as Prod SLO evidence"
  fi
  grep -Fq 'canonical metric or terminal-state validation' <<<"$output" ||
    fail "failed AnalysisRun fixture was rejected for an unexpected reason"
  echo "PASS: Prod SLO terminal AnalysisRun and finished measurement edge cases fail closed."
}

requested=all
while (($#)); do
  case "$1" in
    --case) requested=${2:?missing case}; shift 2 ;;
    --deployment) DEPLOYMENT=${2:?missing deployment}; shift 2 ;;
    --slo) SLO=${2:?missing slo}; shift 2 ;;
    --now) NOW=${2:?missing now}; shift 2 ;;
    *) echo "Usage: $0 [--case raw|real-path|expiry|prod-slo-terminal|all] [--deployment path --slo path]" >&2; exit 2 ;;
  esac
done
case "$requested" in
  raw) case_raw ;;
  real-path) case_real_path ;;
  expiry) case_expiry ;;
  prod-slo-terminal) case_prod_slo_terminal ;;
  all) case_raw; case_real_path; case_expiry; case_prod_slo_terminal ;;
  *) echo "Usage: $0 [--case raw|real-path|expiry|all]" >&2; exit 2 ;;
esac
