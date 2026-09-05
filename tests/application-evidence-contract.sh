#!/usr/bin/env bash
set -Eeuo pipefail

test_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repository_root=$(cd -- "$test_root/.." && pwd)
legacy_runtime="$(printf '%s-%s' sample app)"
legacy_workflow="play-builder/cicd-course-${legacy_runtime}/.github/workflows/ci.yml@refs/heads/main"
new_workflow="play-builder/mini-commerce/.github/workflows/ci.yml@refs/heads/main"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

LEGACY_WORKFLOW="$legacy_workflow" NEW_WORKFLOW="$new_workflow" yq -e '
  .applicationAttestation.repositoryId == 1352247019 and
  .applicationAttestation.issuer == "https://token.actions.githubusercontent.com" and
  (.applicationAttestation.predicates | sort | join(",")) == "https://slsa.dev/provenance/v1,https://spdx.dev/Document/v2.3" and
  (.applicationAttestation.preCutoverWorkflows | sort | join(",")) == (strenv(LEGACY_WORKFLOW) + "," + strenv(NEW_WORKFLOW))
' "$repository_root/contracts/platform-requirements.yaml" >/dev/null || fail "application attestation consumer contract is incomplete"

valid="$test_root/fixtures/application-evidence/pre-cutover-valid.json"
invalid="$test_root/fixtures/application-evidence/wrong-repository-id.json"

LEGACY_WORKFLOW="$legacy_workflow" NEW_WORKFLOW="$new_workflow" jq -e '
  .issuer == "https://token.actions.githubusercontent.com" and
  .repositoryId == 1352247019 and
  (.workflow == env.LEGACY_WORKFLOW or .workflow == env.NEW_WORKFLOW) and
  (.indexDigest | test("^sha256:[0-9a-f]{64}$")) and
  (.sourceSha | test("^[0-9a-f]{40}$")) and
  (.predicates | sort) == ["https://slsa.dev/provenance/v1", "https://spdx.dev/Document/v2.3"]
' "$valid" >/dev/null || fail "valid evidence fixture is rejected"

if jq -e '.repositoryId == 1352247019' "$invalid" >/dev/null; then
  fail "different repository ID is accepted"
fi

echo "PASS: application evidence consumer contract is exact"
