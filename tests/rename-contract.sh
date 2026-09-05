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

yq -e '.schemaVersion == "course.rename-aliases/v1" and (.entries | length) == 17 and ([.entries[] | select(.path != "" and .literal != "" and .reason != "" and .removalEvidence == "course.rename-cutover/v1")] | length) == 17' "$allowlist" >/dev/null || fail "legacy migration allowlist shape is invalid"
LEGACY_APPLICATION="$legacy_application" LEGACY_PVC="$legacy_pvc" LEGACY_REPOSITORY="$legacy_repository" yq -e '[.entries[] | select((.path == "tests/fixtures/rename/live-cutover.yaml" and (.literal == strenv(LEGACY_APPLICATION) or .literal == strenv(LEGACY_PVC))) or (.path != "tests/fixtures/rename/live-cutover.yaml" and .literal == strenv(LEGACY_REPOSITORY)))] | length == 17' "$allowlist" >/dev/null || fail "legacy migration allowlist is not exact"

LEGACY_APPLICATION="$legacy_application" LEGACY_PVC="$legacy_pvc" yq -e '
  .mode == "live-parallel-cutover" and
  .runtimeName == "mini-commerce" and
  .repositoryId == 1352247019 and
  .legacyApplication == strenv(LEGACY_APPLICATION) and
  .legacyPvc == strenv(LEGACY_PVC) and
  .requiredEvidence == "course.rename-cutover/v1" and
  ((.forbiddenActions | sort | join(",")) == "direct-prune,pvc-delete")
' "$live_cutover" >/dev/null || fail "live cutover fixture is unsafe"

yq -e '.delivery.runtime.name == "mini-commerce" and .delivery.runtime.repositoryId == 1352247019' "$repository_root/versions.lock.yaml" >/dev/null || fail "runtime identity lock is missing"

exclude_arguments=(-g '!scripts/mod.md' -g '!tests/fixtures/rename/legacy-alias-allowlist.yaml')
while IFS= read -r allowlisted_path; do
  exclude_arguments+=(-g "!$allowlisted_path")
done < <(yq -r '.entries[].path' "$allowlist" | sort -u)

legacy_matches=$(rg -n -i 'sample[-_]app' \
  "$repository_root/charts" "$repository_root/argocd" "$repository_root/envs" "$repository_root/scripts" "$repository_root/tests" \
  "${exclude_arguments[@]}" || true)
[[ -z "$legacy_matches" ]] || fail "legacy runtime literals escaped the explicit migration allowlist: $legacy_matches"

echo "PASS: runtime rename contract is exact and cutover-safe"
