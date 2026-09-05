#!/usr/bin/env bash
set -Eeuo pipefail

test_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repository_root=$(cd -- "$test_root/.." && pwd)
allowlist="$test_root/fixtures/rename/legacy-alias-allowlist.yaml"
live_cutover="$test_root/fixtures/rename/live-cutover.yaml"
legacy_runtime="$(printf '%s-%s' sample app)"
legacy_application="${legacy_runtime}-prod"
legacy_pvc="data-${legacy_runtime}-postgresql-0"
legacy_repository="cicd-course-${legacy_runtime}"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

yq -e '.schemaVersion == "course.rename-aliases/v1" and (.entries | length) == 32 and ([.entries[] | select(.path != "" and .literal != "" and (.count | type == "!!int") and .count > 0 and .reason != "" and .removalEvidence == "course.rename-cutover/v1")] | length) == 32' "$allowlist" >/dev/null || fail "legacy migration allowlist shape is invalid"
LEGACY_APPLICATION="$legacy_application" LEGACY_PVC="$legacy_pvc" yq -e '[.entries[] | select(.path == "tests/fixtures/rename/live-cutover.yaml" and (.literal == strenv(LEGACY_APPLICATION) or .literal == strenv(LEGACY_PVC)))] | length == 2' "$allowlist" >/dev/null || fail "legacy migration allowlist must retain the live cutover identities"

LEGACY_APPLICATION="$legacy_application" LEGACY_PVC="$legacy_pvc" yq -e '
  .mode == "live-parallel-cutover" and
  .runtimeName == "mini-commerce" and
  .repositoryId == 1352247019 and
  .legacyApplication == strenv(LEGACY_APPLICATION) and
  .legacyPvc == strenv(LEGACY_PVC) and
  .requiredEvidence == "course.rename-cutover/v1" and
  ((.forbiddenActions | sort | join(",")) == "direct-prune,pvc-delete") and
  .sharedResourceOwnership.preCutover.owner == "legacy-application" and
  .sharedResourceOwnership.preCutover.currentApplicationMode == "reference-only" and
  .sharedResourceOwnership.handoff.removeLegacyApplicationFirst == true and
  .sharedResourceOwnership.handoff.preserveResourcesOnDeletion == true and
  .sharedResourceOwnership.handoff.legacyFinalizersMustBeAbsent == true and
  .sharedResourceOwnership.handoff.deletionMode == "non-cascading" and
  .sharedResourceOwnership.handoff.approveLegacyResourcePrune == false and
  .sharedResourceOwnership.postCutover.owner == "mini-commerce-application"
' "$live_cutover" >/dev/null || fail "live cutover fixture is unsafe"

yq -e '.delivery.runtime.name == "mini-commerce" and .delivery.runtime.repositoryId == 1352247019' "$repository_root/versions.lock.yaml" >/dev/null || fail "runtime identity lock is missing"

expected_total=0
while IFS=$'\t' read -r path literal expected_count; do
  actual_count=$(rg -o -i -F "$literal" "$repository_root/$path" | wc -l | tr -d ' ')
  [[ "$actual_count" == "$expected_count" ]] || fail "allowlisted alias multiset differs for $path:$literal (expected $expected_count, got $actual_count)"
  expected_total=$((expected_total + expected_count))
done < <(yq -r '.entries[] | [.path, .literal, (.count | tostring)] | @tsv' "$allowlist")

# Every real occurrence is counted above; no path is excluded from this scan.
actual_total=$(rg -o -i 'sample[-_]app' \
  "$repository_root/charts" "$repository_root/argocd" "$repository_root/envs" "$repository_root/scripts" "$repository_root/tests" \
  -g '!scripts/mod.md' | wc -l | tr -d ' ')
[[ "$actual_total" == "$expected_total" ]] || fail "legacy runtime literals escaped the exact migration allowlist (expected $expected_total, got $actual_total)"

echo "PASS: runtime rename contract is exact and cutover-safe"
