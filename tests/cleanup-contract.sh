#!/usr/bin/env bash
set -Eeuo pipefail
test_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repository_root=$(cd -- "$test_root/.." && pwd)
fixture_root="$test_root/fixtures/cleanup"
incident_fixture_root="$test_root/fixtures/incidents"
fail() { echo "FAIL: $*" >&2; exit 1; }

validate_fixture() {
  local file=$1
  yq -o=json '.' "$file" | jq -e '
    .cleanup.externalSecretLifecycle.targetSecretOwnerReferenceGC == true and
    .cleanup.externalSecretLifecycle.providerSecretRetained == true and
    ((.cleanup.externalSecretLifecycle.providerSecretDeletion // false) == false)
  ' >/dev/null || fail "incident cleanup permits provider Secret deletion"
}

case_all() {
  set +e
  invalid_output=$(bash "$repository_root/tests/incident-contract.sh" --fixture "$incident_fixture_root/invalid-provider-delete.yaml" 2>&1)
  invalid_status=$?
  set -e
  [[ $invalid_status -ne 0 ]] && grep -Fq "incomplete incident lifecycle" <<<"$invalid_output" || fail "invalid provider deletion fixture was not rejected"
  local cleanup_fixture cleanup_output cleanup_status
  for cleanup_fixture in \
    "$fixture_root/removal-unclassified-retained.json" \
    "$fixture_root/removal-writer-active.json" \
    "$fixture_root/provider-secret-digest-mismatch.json"; do
    set +e
    cleanup_output=$(bash "$repository_root/scripts/capture-cleanup-evidence.sh" removal \
      --fixture "$cleanup_fixture" --eks-repo-root "$fixture_root" 2>&1)
    cleanup_status=$?
    set -e
    [[ $cleanup_status -ne 0 ]] || fail "invalid cleanup fixture was accepted: $(basename "$cleanup_fixture")"
  done
  jq -e '.courseCleanup.workloadsDisabled == true' "$repository_root/envs/dev/cleanup-values.yaml" >/dev/null 2>&1 || yq -e '.courseCleanup.workloadsDisabled == true' "$repository_root/envs/dev/cleanup-values.yaml" >/dev/null || fail "Dev cleanup values must disable workloads"
  yq -e '.courseCleanup.workloadsDisabled == true' "$repository_root/envs/prod/cleanup-values.yaml" >/dev/null || fail "Prod cleanup values must disable workloads"
  for file in "$fixture_root"/freeze-valid.json "$fixture_root"/removal-valid.json; do jq -e '.evidenceGrade == "CLOUD_RUNTIME"' "$file" >/dev/null || fail "$(basename "$file") is not CLOUD_RUNTIME"; done
  bash "$repository_root/scripts/capture-cleanup-evidence.sh" freeze --fixture "$fixture_root/freeze-valid.json" >/dev/null || fail "valid freeze evidence fixture was rejected"
  bash "$repository_root/scripts/capture-cleanup-evidence.sh" removal --fixture "$fixture_root/removal-valid.json" --eks-repo-root "$fixture_root" >/dev/null || fail "provider Secret projection validation failed"
  echo "PASS: cleanup ownership and evidence boundaries are valid."
}

case_fixture() { validate_fixture "$1"; echo "PASS: cleanup lifecycle is retained and recoverable."; }
requested=all; fixture=
while (($#)); do case "$1" in --all) requested=all; shift ;; --fixture) requested=fixture; fixture=${2:?missing fixture}; shift 2 ;; *) echo "Usage: $0 --all|--fixture path" >&2; exit 2 ;; esac; done
if [[ "$requested" == fixture ]]; then case_fixture "$fixture"; else case_all; fi
