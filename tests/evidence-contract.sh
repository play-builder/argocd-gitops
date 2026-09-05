#!/usr/bin/env bash
set -Eeuo pipefail

test_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repository_root=$(cd -- "$test_root/.." && pwd -P)
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
    def canonical_utc_seconds:
      . as $value |
      type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$") and
      (try ((fromdateiso8601 | strftime("%Y-%m-%dT%H:%M:%SZ")) == $value) catch false);
    . as $root |
    (.image.repository | capture("^(?<account>[0-9]{12})\\.dkr\\.ecr\\.(?<region>ap-northeast-2|us-east-1)\\.amazonaws\\.com/(?<name>[a-z0-9]+([._/-][a-z0-9]+)*)$")) as $ecr |
    (.clusterArn | capture("^arn:aws:eks:(?<region>ap-northeast-2|us-east-1):(?<account>[0-9]{12}):cluster/[A-Za-z0-9][A-Za-z0-9_-]{0,99}$")) as $cluster |
    .schemaVersion == "course.dev-deployment/v1" and .evidenceGrade == "CLOUD_RUNTIME" and
    .status == {sync:"Synced",health:"Healthy"} and
    (.source.repository | test("^[^/\\s]+/cicd-course-sample-app$")) and
    (.source.sha | test("^[0-9a-f]{40}$")) and
    (.image.indexDigest | test("^sha256:[0-9a-f]{64}$")) and
    (.gitopsRevision | test("^[0-9a-f]{40}$")) and
    (.clusterArn | test("^arn:aws:eks:(ap-northeast-2|us-east-1):[0-9]{12}:cluster/[A-Za-z0-9][A-Za-z0-9_-]{0,99}$")) and
    (.region | IN("ap-northeast-2","us-east-1")) and
    (($ecr.name | length) >= 2 and ($ecr.name | length) <= 256) and
    $ecr.region == $root.region and $cluster.region == $root.region and $ecr.account == $cluster.account and
    (.observedAt | canonical_utc_seconds)
  ' "$file" >/dev/null || fail "deployment evidence is not CLOUD_RUNTIME or has invalid identity"
}

validate_slo() {
  local file=$1
  exact_keys "$file" '["schemaVersion","evidenceGrade","status","source","image","gitopsRevision","clusterArn","region","evidenceId","observedAt","expiresAt"]'
  exact_keys "$file" '["repository","sha"]' .source
  exact_keys "$file" '["repository","indexDigest"]' .image
  jq -e '
    def canonical_utc_seconds:
      . as $value |
      type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$") and
      (try ((fromdateiso8601 | strftime("%Y-%m-%dT%H:%M:%SZ")) == $value) catch false);
    def nonblank: type == "string" and test("[^[:space:]\uFEFF]");
    . as $root |
    (.image.repository | capture("^(?<account>[0-9]{12})\\.dkr\\.ecr\\.(?<region>ap-northeast-2|us-east-1)\\.amazonaws\\.com/(?<name>[a-z0-9]+([._/-][a-z0-9]+)*)$")) as $ecr |
    (.clusterArn | capture("^arn:aws:eks:(?<region>ap-northeast-2|us-east-1):(?<account>[0-9]{12}):cluster/[A-Za-z0-9][A-Za-z0-9_-]{0,99}$")) as $cluster |
    .schemaVersion == "course.dev-slo/v1" and .evidenceGrade == "CLOUD_RUNTIME" and .status == "PASS" and
    (.source.repository | test("^[^/\\s]+/cicd-course-sample-app$")) and
    (.source.sha | test("^[0-9a-f]{40}$")) and (.image.indexDigest | test("^sha256:[0-9a-f]{64}$")) and
    (.evidenceId | nonblank) and
    (.gitopsRevision | test("^[0-9a-f]{40}$")) and (.clusterArn | test("^arn:aws:eks:(ap-northeast-2|us-east-1):[0-9]{12}:cluster/[A-Za-z0-9][A-Za-z0-9_-]{0,99}$")) and
    (.region | IN("ap-northeast-2","us-east-1")) and
    (($ecr.name | length) >= 2 and ($ecr.name | length) <= 256) and
    $ecr.region == $root.region and $cluster.region == $root.region and $ecr.account == $cluster.account and
    (.observedAt | canonical_utc_seconds) and (.expiresAt | canonical_utc_seconds) and
    (.observedAt | fromdateiso8601) < (.expiresAt | fromdateiso8601)
  ' "$file" >/dev/null || fail "SLO evidence is not an unexpired PASS CLOUD_RUNTIME record"
}

validate_baseline() {
  local file=$1
  jq -e '
    def canonical_utc_seconds:
      . as $value |
      type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$") and
      (try ((fromdateiso8601 | strftime("%Y-%m-%dT%H:%M:%SZ")) == $value) catch false);
    def nonblank: type == "string" and test("[^[:space:]\uFEFF]");
    . as $root |
    (.image.repository | capture("^(?<account>[0-9]{12})\\.dkr\\.ecr\\.(?<region>ap-northeast-2|us-east-1)\\.amazonaws\\.com/(?<name>[a-z0-9]+([._/-][a-z0-9]+)*)$")) as $ecr |
    (.clusterArn | capture("^arn:aws:eks:(?<region>ap-northeast-2|us-east-1):(?<account>[0-9]{12}):cluster/[A-Za-z0-9][A-Za-z0-9_-]{0,99}$")) as $cluster |
    (keys | sort) == ["clusterArn","evidenceGrade","gitopsRevision","image","observedAt","region","rollout","schemaVersion"] and
    .schemaVersion == "course.prod-baseline/v1" and .evidenceGrade == "CLOUD_RUNTIME" and
    (.image | (keys | sort) == ["indexDigest","repository"]) and
    (.image.repository | type == "string" and length > 0) and
    (.image.indexDigest | test("^sha256:[0-9a-f]{64}$")) and
    (.gitopsRevision | test("^[0-9a-f]{40}$")) and
    (.rollout | (keys | sort) == ["revision","stableHash","trafficWeight"]) and
    (.rollout.stableHash | nonblank) and
    .rollout.revision == 1 and .rollout.trafficWeight == 100 and
    (.region | IN("ap-northeast-2","us-east-1")) and
    (($ecr.name | length) >= 2 and ($ecr.name | length) <= 256) and
    $ecr.region == $root.region and $cluster.region == $root.region and $ecr.account == $cluster.account and
    (.observedAt | canonical_utc_seconds) and (.observedAt | fromdateiso8601) <= now
  ' "$file" >/dev/null || fail "Prod baseline must prove stable ReplicaSet revision 1 at 100 percent"
}

case_raw() {
  local deployment=${DEPLOYMENT:-$fixture_root/deployment-valid.json}
  local slo=${SLO:-$fixture_root/slo-valid.json}
  local baseline=${BASELINE:-$fixture_root/baseline-valid.json}
  validate_deployment "$deployment"
  validate_slo "$slo"
  validate_baseline "$baseline"
  jq -s -e '.[0].source == .[1].source and .[0].image == .[1].image and .[0].gitopsRevision == .[1].gitopsRevision and .[0].clusterArn == .[1].clusterArn and .[0].region == .[1].region' "$deployment" "$slo" >/dev/null || fail "deployment and SLO source identity mismatch"
  echo "PASS: raw Dev evidence schemas and shared provenance are valid."
}

case_identity_edges() {
  local invalid invalid_slo invalid_baseline variant
  invalid=$(mktemp "${TMPDIR:-/tmp}/evidence-identity.XXXXXX")
  invalid_slo=$(mktemp "${TMPDIR:-/tmp}/evidence-slo-identity.XXXXXX")
  invalid_baseline=$(mktemp "${TMPDIR:-/tmp}/evidence-baseline-identity.XXXXXX")
  jq '.source.repository="OWNER/other-app" | .image.repository="not-ecr" | .clusterArn="arn:aws:eks:us-east-1:999999999999:cluster/foreign"' \
    "$fixture_root/deployment-valid.json" >"$invalid"
  jq '.source.repository="OWNER/other-app" | .image.repository="not-ecr" | .clusterArn="arn:aws:eks:us-east-1:999999999999:cluster/foreign"' \
    "$fixture_root/slo-valid.json" >"$invalid_slo"
  if (DEPLOYMENT="$invalid" SLO="$invalid_slo" BASELINE="$fixture_root/baseline-valid.json" case_raw) >/dev/null 2>&1; then
    rm -f -- "$invalid" "$invalid_slo" "$invalid_baseline"
    fail "raw deployment evidence accepted a noncanonical source/ECR/EKS identity"
  fi
  jq '.source.repository="OWNER /cicd-course-sample-app"' \
    "$fixture_root/deployment-valid.json" >"$invalid"
  jq '.source.repository="OWNER /cicd-course-sample-app"' \
    "$fixture_root/slo-valid.json" >"$invalid_slo"
  if (DEPLOYMENT="$invalid" SLO="$invalid_slo" BASELINE="$fixture_root/baseline-valid.json" case_raw) >/dev/null 2>&1; then
    rm -f -- "$invalid" "$invalid_slo" "$invalid_baseline"
    fail "raw evidence accepted a source owner containing whitespace"
  fi
  jq '.image.repository="123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/a"' \
    "$fixture_root/deployment-valid.json" >"$invalid"
  jq '.image.repository="123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/a"' \
    "$fixture_root/slo-valid.json" >"$invalid_slo"
  jq '.image.repository="123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/a"' \
    "$fixture_root/baseline-valid.json" >"$invalid_baseline"
  if (DEPLOYMENT="$invalid" SLO="$invalid_slo" BASELINE="$invalid_baseline" case_raw) >/dev/null 2>&1; then
    rm -f -- "$invalid" "$invalid_slo" "$invalid_baseline"
    fail "raw evidence accepted a one-character ECR repository name"
  fi
  for variant in deployment-impossible-time slo-impossible-time slo-bom-evidence-id baseline-impossible-time baseline-bom-stable-hash; do
    cp "$fixture_root/deployment-valid.json" "$invalid"
    cp "$fixture_root/slo-valid.json" "$invalid_slo"
    cp "$fixture_root/baseline-valid.json" "$invalid_baseline"
    case "$variant" in
      deployment-impossible-time) jq '.observedAt="2026-02-31T00:30:00Z"' "$invalid" >"$invalid.tmp" && mv "$invalid.tmp" "$invalid" ;;
      slo-impossible-time) jq '.observedAt="2026-02-31T00:30:00Z"' "$invalid_slo" >"$invalid_slo.tmp" && mv "$invalid_slo.tmp" "$invalid_slo" ;;
      slo-bom-evidence-id) jq '.evidenceId="\uFEFF"' "$invalid_slo" >"$invalid_slo.tmp" && mv "$invalid_slo.tmp" "$invalid_slo" ;;
      baseline-impossible-time) jq '.observedAt="2026-02-31T00:30:00Z"' "$invalid_baseline" >"$invalid_baseline.tmp" && mv "$invalid_baseline.tmp" "$invalid_baseline" ;;
      baseline-bom-stable-hash) jq '.rollout.stableHash="\uFEFF"' "$invalid_baseline" >"$invalid_baseline.tmp" && mv "$invalid_baseline.tmp" "$invalid_baseline" ;;
    esac
    if (DEPLOYMENT="$invalid" SLO="$invalid_slo" BASELINE="$invalid_baseline" case_raw) >/dev/null 2>&1; then
      rm -f -- "$invalid" "$invalid_slo" "$invalid_baseline"
      fail "raw evidence accepted noncanonical $variant"
    fi
  done
  jq '.image.repository="123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/ab"' \
    "$fixture_root/deployment-valid.json" >"$invalid"
  jq '.image.repository="123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/ab"' \
    "$fixture_root/slo-valid.json" >"$invalid_slo"
  jq '.image.repository="123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/ab"' \
    "$fixture_root/baseline-valid.json" >"$invalid_baseline"
  (DEPLOYMENT="$invalid" SLO="$invalid_slo" BASELINE="$invalid_baseline" case_raw) >/dev/null || {
    rm -f -- "$invalid" "$invalid_slo" "$invalid_baseline"
    fail "raw evidence rejected a two-character ECR repository name"
  }
  if (DEPLOYMENT="$fixture_root/deployment-valid.json" SLO="$fixture_root/slo-valid.json" \
    BASELINE="$fixture_root/baseline-valid.json" case_real_path) >/dev/null 2>&1; then
    rm -f -- "$invalid" "$invalid_slo" "$invalid_baseline"
    fail "real-path gate accepted fixture paths in place of canonical runtime evidence"
  fi
  rm -f -- "$invalid" "$invalid_slo" "$invalid_baseline"
  echo "PASS: raw evidence rejects noncanonical source, ECR, and EKS identities."
}

case_real_path() {
  local canonical_deployment="$repository_root/evidence/dev/deployment.json"
  local canonical_slo="$repository_root/evidence/dev/slo.json"
  local canonical_baseline="$repository_root/evidence/prod/baseline.json"
  local deployment="${DEPLOYMENT:-$canonical_deployment}"
  local slo="${SLO:-$canonical_slo}"
  local baseline="${BASELINE:-$canonical_baseline}"
  local file expected physical_parent resolved
  [[ "$deployment" == "$canonical_deployment" && "$slo" == "$canonical_slo" && "$baseline" == "$canonical_baseline" ]] ||
    fail "real-path gate accepts only canonical repository evidence paths"
  for file in "$deployment" "$slo" "$baseline"; do
    [[ -f "$file" ]] || continue
    [[ ! -L "$file" ]] || fail "real evidence must be a regular non-symlink file"
    case "$file" in
      "$deployment") expected=$canonical_deployment ;;
      "$slo") expected=$canonical_slo ;;
      "$baseline") expected=$canonical_baseline ;;
    esac
    physical_parent=$(cd -- "$(dirname -- "$file")" && pwd -P) || fail "cannot resolve canonical evidence parent"
    resolved="$physical_parent/$(basename -- "$file")"
    [[ "$resolved" == "$expected" ]] || fail "real evidence escaped its canonical repository path"
    jq -e '.evidenceGrade == "CLOUD_RUNTIME"' "$file" >/dev/null || fail "real evidence requires CLOUD_RUNTIME"
    ! jq -e 'tostring | contains("example.invalid") or contains("0000000000000000000000000000000000000000")' "$file" >/dev/null || fail "real evidence contains fixture markers"
  done
  [[ ! -f "$deployment" ]] || validate_deployment "$deployment"
  [[ ! -f "$slo" ]] || validate_slo "$slo"
  [[ ! -f "$baseline" ]] || validate_baseline "$baseline"
  for file in "$baseline" "$repository_root/evidence/prod/slo.json" "$repository_root/evidence/prod/rollback-candidates.json"; do
    [[ ! -f "$file" ]] || ruby "$repository_root/scripts/verify-incident-companion.rb" "$file"
  done
  echo "PASS: deployment, SLO, and Prod baseline real evidence paths are absent or provenance-guarded."
}

case_expiry() {
  local now=${NOW:-2026-09-03T01:00:00Z}
  NOW="$now" jq -e '(.observedAt | fromdateiso8601) <= (env.NOW | fromdateiso8601) and (env.NOW | fromdateiso8601) < (.expiresAt | fromdateiso8601)' "$fixture_root/slo-valid.json" >/dev/null || fail "SLO evidence is outside the promotion clock"
  echo "PASS: SLO observedAt/expiresAt bounds are valid."
}

case_prod_slo_terminal() {
  local valid="$fixture_root/prod-slo-valid.json"
  local invalid="$fixture_root/prod-slo-analysis-failed.json"
  local output malformed value

  output=$(bash "$repository_root/scripts/capture-prod-slo-evidence.sh" --fixture "$valid")
  grep -Fq '[STATIC] fake Prod SLO adapter validated' <<<"$output" ||
    fail "valid Prod SLO fixture was not accepted by the runtime validator"

  if output=$(bash "$repository_root/scripts/capture-prod-slo-evidence.sh" --fixture "$invalid" 2>&1); then
    fail "failed AnalysisRun fixture was accepted as Prod SLO evidence"
  fi
  grep -Fq 'canonical metric or terminal-state validation' <<<"$output" ||
    fail "failed AnalysisRun fixture was rejected for an unexpected reason"

  for value in NaN Infinity not-a-number; do
    malformed=$(mktemp "${TMPDIR:-/tmp}/prod-slo-value.XXXXXX")
    jq --arg value "$value" '.metricResults[0].measurements[0].value=$value' "$valid" >"$malformed"
    if bash "$repository_root/scripts/capture-prod-slo-evidence.sh" --fixture "$malformed" >/dev/null 2>&1; then
      rm -f -- "$malformed"
      fail "non-finite or non-numeric measurement value was accepted: $value"
    fi
    rm -f -- "$malformed"
  done
  malformed=$(mktemp "${TMPDIR:-/tmp}/prod-slo-number.XXXXXX")
  jq '.metricResults[0].measurements[0].value=12.5' "$valid" >"$malformed"
  if bash "$repository_root/scripts/capture-prod-slo-evidence.sh" --fixture "$malformed" >/dev/null 2>&1; then
    rm -f -- "$malformed"
    fail "JSON number measurement was accepted instead of the raw Argo Rollouts string"
  fi
  rm -f -- "$malformed"
  echo "PASS: Prod SLO terminal AnalysisRun and finished measurement edge cases fail closed."
}

requested=all
while (($#)); do
  case "$1" in
    --case) requested=${2:?missing case}; shift 2 ;;
    --deployment) DEPLOYMENT=${2:?missing deployment}; shift 2 ;;
    --slo) SLO=${2:?missing slo}; shift 2 ;;
    --baseline) BASELINE=${2:?missing baseline}; shift 2 ;;
    --now) NOW=${2:?missing now}; shift 2 ;;
    *) echo "Usage: $0 [--case raw|real-path|expiry|identity-edges|prod-slo-terminal|all] [--deployment path --slo path --baseline path]" >&2; exit 2 ;;
  esac
done
case "$requested" in
  raw) case_raw ;;
  real-path) case_real_path ;;
  expiry) case_expiry ;;
  identity-edges) case_identity_edges ;;
  prod-slo-terminal) case_prod_slo_terminal ;;
  all) case_raw; case_real_path; case_expiry; case_identity_edges; case_prod_slo_terminal ;;
  *) echo "Usage: $0 [--case raw|real-path|expiry|all]" >&2; exit 2 ;;
esac
