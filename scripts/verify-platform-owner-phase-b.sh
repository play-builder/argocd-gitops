#!/usr/bin/env bash
set -Eeuo pipefail

repository_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

fail() {
  echo "PLATFORM_OWNER_HANDOFF_BLOCKED: $*" >&2
  exit 1
}

usage() {
  echo "Usage: $0 --environment <dev|prod> --handoff <file> --adoption <file> --expected-gitops-revision <40-char-sha>" >&2
  exit 2
}

sha256_file() {
  local path=$1
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$path" | awk '{print $1}'
  else
    fail "sha256sum or shasum is required"
  fi
}

environment=""
handoff=""
adoption=""
expected_gitops_revision=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --environment)
      environment=${2:-}
      shift 2
      ;;
    --handoff)
      handoff=${2:-}
      shift 2
      ;;
    --adoption)
      adoption=${2:-}
      shift 2
      ;;
    --expected-gitops-revision)
      expected_gitops_revision=${2:-}
      shift 2
      ;;
    *) usage ;;
  esac
done

[[ "$environment" == "dev" || "$environment" == "prod" ]] || usage
[[ "$expected_gitops_revision" =~ ^[0-9a-f]{40}$ ]] || \
  fail "expected GitOps revision must be a full 40-character SHA"
[[ -f "$handoff" ]] || fail "handoff evidence file not found: $handoff"
[[ -f "$adoption" ]] || fail "adoption evidence file not found: $adoption"
command -v jq >/dev/null 2>&1 || fail "jq is required"

expected_grade=CLOUD_RUNTIME
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
output_prefix='[CLOUD_RUNTIME]'
if [[ "${COURSE_PHASE_B_TEST_MODE:-0}" == "1" ]]; then
  expected_grade=STATIC
  now=${COURSE_PHASE_B_NOW:-}
  [[ -n "$now" ]] || fail "COURSE_PHASE_B_NOW is required in test mode"
  output_prefix='[STATIC]'
else
  case "$handoff:$adoption" in
    *"$repository_root/tests/fixtures/"*)
      fail "test fixtures cannot authorize a runtime Phase B transition"
      ;;
  esac
fi

handoff_grade=$(jq -r '.evidenceGrade // empty' "$handoff" 2>/dev/null || true)
adoption_grade=$(jq -r '.evidenceGrade // empty' "$adoption" 2>/dev/null || true)
if [[ "$handoff_grade" != "$expected_grade" || "$adoption_grade" != "$expected_grade" ]]; then
  if [[ "$expected_grade" == "CLOUD_RUNTIME" ]]; then
    fail "CLOUD_RUNTIME evidence is required"
  fi
  fail "STATIC fixture evidence is required in test mode"
fi

jq -e \
  --arg grade "$expected_grade" \
  --arg environment "$environment" \
  --arg revision "$expected_gitops_revision" \
  --arg now "$now" '
  def canonical_utc_seconds:
    . as $value |
    ($value | type == "string") and
    ($value | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")) and
    ((try ($value | fromdateiso8601 | strftime("%Y-%m-%dT%H:%M:%SZ")) catch "") == $value);
  .region as $region |
  keys == [
    "application", "clusterArn", "environment", "evidenceGrade", "expiresAt",
    "gitopsRevision", "observedAt", "ownership", "readiness", "region",
    "release", "schemaVersion"
  ] and
  (.application | keys) == [
    "automated", "name", "operationInProgress", "present",
    "resourcesFinalizerPresent", "uid"
  ] and
  (.release | keys) == [
    "chart", "crdUids", "helmStorageObjectUid", "name", "namespace", "revision",
    "status", "valuesSha256", "version", "workloadUids"
  ] and
  (.readiness | keys) == ["crdsEstablished", "deploymentsAvailable"] and
  (.ownership | keys) == ["from", "terraformAddress", "to"] and
  .schemaVersion == "course.platform-release-handoff/v1" and
  .evidenceGrade == $grade and
  .environment == $environment and
  ($region == "ap-northeast-2" or $region == "us-east-1") and
  (.clusterArn | test("^arn:aws:eks:" + $region + ":[0-9]{12}:cluster/[A-Za-z0-9][A-Za-z0-9_-]{0,99}$")) and
  .gitopsRevision == $revision and
  .application.name == ("external-secrets-" + $environment) and
  .application.uid != "" and
  .application.present == true and
  .application.automated == false and
  .application.resourcesFinalizerPresent == false and
  .application.operationInProgress == false and
  .release.namespace == "external-secrets" and
  .release.name == "external-secrets" and
  .release.chart == "external-secrets" and
  .release.version != "" and
  .release.revision >= 1 and
  .release.status == "deployed" and
  (.release.valuesSha256 | test("^sha256:[0-9a-f]{64}$")) and
  .release.helmStorageObjectUid != "" and
  (.release.workloadUids | length) > 0 and
  all(.release.workloadUids[]; keys == ["kind", "name", "uid"] and .uid != "") and
  (.release.crdUids | length) > 0 and
  all(.release.crdUids[]; keys == ["name", "uid"] and .uid != "") and
  .readiness == {"crdsEstablished": true, "deploymentsAvailable": true} and
  .ownership == {
    "from": "argocd",
    "terraformAddress": "module.external_secrets[0].helm_release.this",
    "to": "terraform"
  } and
  (.observedAt | canonical_utc_seconds) and
  (.expiresAt | canonical_utc_seconds) and
  ($now | canonical_utc_seconds) and
  ((.observedAt | fromdateiso8601) < (.expiresAt | fromdateiso8601)) and
  ((.observedAt | fromdateiso8601) <= ($now | fromdateiso8601)) and
  ((.expiresAt | fromdateiso8601) > ($now | fromdateiso8601))
' "$handoff" >/dev/null || fail "handoff evidence is malformed, stale, or not frozen"

handoff_sha="sha256:$(sha256_file "$handoff")"
handoff_release=$(jq -cS '.release' "$handoff")
handoff_region=$(jq -r '.region' "$handoff")
handoff_cluster=$(jq -r '.clusterArn' "$handoff")
handoff_observed=$(jq -r '.observedAt' "$handoff")

jq -e \
  --arg grade "$expected_grade" \
  --arg environment "$environment" \
  --arg handoffSha "$handoff_sha" \
  --argjson handoffRelease "$handoff_release" \
  --arg region "$handoff_region" \
  --arg cluster "$handoff_cluster" \
  --arg handoffObserved "$handoff_observed" \
  --arg now "$now" '
  def canonical_utc_seconds:
    . as $value |
    ($value | type == "string") and
    ($value | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")) and
    ((try ($value | fromdateiso8601 | strftime("%Y-%m-%dT%H:%M:%SZ")) catch "") == $value);
  keys == [
    "clusterArn", "environment", "evidenceGrade", "expiresAt", "handoffSha256",
    "observedAt", "region", "release", "schemaVersion", "terraform"
  ] and
  (.release | keys) == ["after", "before"] and
  (.release.before | keys) == [
    "chart", "crdUids", "helmStorageObjectUid", "name", "namespace", "revision",
    "status", "valuesSha256", "version", "workloadUids"
  ] and
  (.release.after | keys) == (.release.before | keys) and
  (.terraform | keys) == [
    "address", "imported", "planActions", "stateLineage", "stateSerial"
  ] and
  .schemaVersion == "course.platform-release-adoption/v1" and
  .evidenceGrade == $grade and
  .environment == $environment and
  .region == $region and
  .clusterArn == $cluster and
  .handoffSha256 == $handoffSha and
  .release.before == $handoffRelease and
  .release.after == .release.before and
  .terraform.address == "module.external_secrets[0].helm_release.this" and
  .terraform.imported == true and
  .terraform.planActions == [] and
  (.terraform.stateLineage | test("^[0-9a-fA-F-]{36}$")) and
  .terraform.stateSerial >= 1 and
  (.observedAt | canonical_utc_seconds) and
  (.expiresAt | canonical_utc_seconds) and
  ($handoffObserved | canonical_utc_seconds) and
  ($now | canonical_utc_seconds) and
  ((.observedAt | fromdateiso8601) >= ($handoffObserved | fromdateiso8601)) and
  ((.observedAt | fromdateiso8601) < (.expiresAt | fromdateiso8601)) and
  ((.observedAt | fromdateiso8601) <= ($now | fromdateiso8601)) and
  ((.expiresAt | fromdateiso8601) > ($now | fromdateiso8601))
' "$adoption" >/dev/null || {
  if jq -e '.terraform.imported != true or .terraform.planActions != []' \
    "$adoption" >/dev/null 2>&1; then
    fail "adoption proof is not a no-op import"
  fi
  if ! jq -e --argjson release "$handoff_release" '
    .release.before == $release and .release.after == $release
  ' "$adoption" >/dev/null 2>&1; then
    fail "release identity or UID changed during adoption"
  fi
  fail "adoption evidence is malformed, stale, or does not bind the handoff"
}

echo "$output_prefix PASS: $environment platform owner adoption permits Phase B preparation"
