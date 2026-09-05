#!/usr/bin/env bash
set -Eeuo pipefail

test_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repository_root=$(cd -- "$test_root/.." && pwd)
fixture_root="$test_root/fixtures/source-integrity"
trusted_repository=$(yq -r '.outputs.mini_commerce_ecr_repository_url' "$fixture_root/platform-handoff.yaml")

fail() { echo "FAIL: $*" >&2; exit 1; }

yq -e '.applicationAttestation.trustedEcrOutput == "mini_commerce_ecr_repository_url" and .applicationAttestation.postCutoverWorkflow == "play-builder/mini-commerce/.github/workflows/ci.yml@refs/heads/main" and .applicationAttestation.cutoverEvidenceSchema == "course.rename-cutover/v1"' "$repository_root/contracts/platform-requirements.yaml" >/dev/null || fail "typed ECR and post-cutover contract is incomplete"

validate() {
  local mode=$1 evidence=$2
  TRUSTED_REPOSITORY="$trusted_repository" MODE="$mode" CUTOVER_SOURCE_SHA="${cutover_source_sha:-}" jq -e '
    .issuer == "https://token.actions.githubusercontent.com" and
    .repositoryId == 1352247019 and
    .imageRepository == env.TRUSTED_REPOSITORY and
    (.indexDigest | test("^sha256:[0-9a-f]{64}$")) and
    (.sourceSha | test("^[0-9a-f]{40}$")) and
    ((.predicates | sort | join(",")) == "https://slsa.dev/provenance/v1,https://spdx.dev/Document/v2.3") and
    (if env.MODE == "pre" then (.workflow == "play-builder/cicd-course-sample-app/.github/workflows/ci.yml@refs/heads/main" or .workflow == "play-builder/mini-commerce/.github/workflows/ci.yml@refs/heads/main") else (.workflow == "play-builder/mini-commerce/.github/workflows/ci.yml@refs/heads/main" and .sourceSha == env.CUTOVER_SOURCE_SHA) end)
  ' "$evidence" >/dev/null
}

validate pre "$fixture_root/pre-cutover-valid.json" || fail "pre-cutover valid evidence is rejected"
yq -e '.schemaVersion == "course.rename-cutover/v1" and .evidenceGrade == "CLOUD_RUNTIME" and .repositoryId == 1352247019 and (.sourceSha | test("^[0-9a-f]{40}$"))' "$fixture_root/cutover-evidence.yaml" >/dev/null || fail "fresh cutover evidence fixture is invalid"
cutover_source_sha=$(yq -r '.sourceSha' "$fixture_root/cutover-evidence.yaml")
validate post "$fixture_root/post-cutover-valid.json" || fail "post-cutover evidence is not bound to fresh cutover evidence"
if validate post "$fixture_root/pre-cutover-valid.json"; then fail "post-cutover accepts legacy workflow"; fi
if validate pre "$fixture_root/public-image.json"; then fail "untrusted image repository is accepted"; fi
for invalid_fixture in wrong-issuer wrong-workflow wrong-repository-id wrong-source-sha wrong-digest missing-spdx; do
  if validate pre "$fixture_root/$invalid_fixture.json"; then
    fail "invalid source-integrity fixture was accepted: $invalid_fixture"
  fi
done
echo "PASS: source integrity binds exact ECR and cutover workflow state"
