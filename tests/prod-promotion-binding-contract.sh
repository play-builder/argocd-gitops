#!/usr/bin/env bash
set -Eeuo pipefail

test_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
repository_root=$(cd -- "$test_root/.." && pwd -P)
fixture_root="$test_root/fixtures/promotion"
work_root=$(mktemp -d "${TMPDIR:-/tmp}/prod-promotion-binding.XXXXXX")
trap 'rm -rf -- "$work_root"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

prepare_repository() {
  local target=$1
  mkdir -p "$target/scripts" "$target/envs/prod"
  cp "$repository_root/scripts/verify-prod-promotion-binding.sh" "$target/scripts/"
  cp "$repository_root/envs/prod/values.yaml" "$target/envs/prod/values.yaml"
  cp "$fixture_root/valid-ap-northeast-2.yaml" "$target/envs/prod/promotion-evidence.yaml"
  git -C "$target" init -q
  git -C "$target" config user.name contract-test
  git -C "$target" config user.email contract-test@example.invalid
  git -C "$target" add .
  git -C "$target" commit -qm baseline
}

set_bound_repository() {
  local target=$1 value=$2
  export bound_repository=$value
  yq -i '.image.repository = strenv(bound_repository)' "$target/envs/prod/promotion-evidence.yaml"
  yq -i '.image.repository = strenv(bound_repository) |
    .database.migrationImage.repository = strenv(bound_repository)' "$target/envs/prod/values.yaml"
}

candidate="$work_root/candidate"
prepare_repository "$candidate"
base_sha=$(git -C "$candidate" rev-parse HEAD)

if bash "$candidate/scripts/verify-prod-promotion-binding.sh" HEAD >/dev/null 2>&1; then
  fail "symbolic or abbreviated base revision was accepted"
fi

bash "$candidate/scripts/verify-prod-promotion-binding.sh" "$base_sha" >/dev/null ||
  fail "unchanged Prod values must not require the current evidence image"

configuration_candidate="$work_root/configuration-candidate"
prepare_repository "$configuration_candidate"
configuration_base_sha=$(git -C "$configuration_candidate" rev-parse HEAD)
rm "$configuration_candidate/envs/prod/promotion-evidence.yaml"
yq -i '.telemetry.enabled = false' "$configuration_candidate/envs/prod/values.yaml"
bash "$configuration_candidate/scripts/verify-prod-promotion-binding.sh" "$configuration_base_sha" >/dev/null ||
  fail "non-image Prod configuration changes must not require DEV_READY evidence"

export repository
export digest
repository=$(yq -r '.image.repository' "$candidate/envs/prod/promotion-evidence.yaml")
digest=$(yq -r '.image.indexDigest' "$candidate/envs/prod/promotion-evidence.yaml")
yq -i '.image.repository = strenv(repository) |
  .image.digest = strenv(digest) |
  .database.migrationImage.repository = strenv(repository) |
  .database.migrationImage.digest = strenv(digest)' "$candidate/envs/prod/values.yaml"
bash "$candidate/scripts/verify-prod-promotion-binding.sh" "$base_sha" >/dev/null ||
  fail "changed Prod values matching canonical DEV_READY must pass"

set_bound_repository "$candidate" '123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/a'
if bash "$candidate/scripts/verify-prod-promotion-binding.sh" "$base_sha" >/dev/null 2>&1; then
  fail "promotion binding accepted a one-character ECR repository name"
fi
set_bound_repository "$candidate" '123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/ab'
bash "$candidate/scripts/verify-prod-promotion-binding.sh" "$base_sha" >/dev/null ||
  fail "promotion binding rejected a two-character ECR repository name"
set_bound_repository "$candidate" "$repository"

yq -i '.image.digest = "sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"' \
  "$candidate/envs/prod/values.yaml"
if bash "$candidate/scripts/verify-prod-promotion-binding.sh" "$base_sha" >/dev/null 2>&1; then
  fail "changed Prod values with a mismatched application digest were accepted"
fi

yq -i '.image.digest = strenv(digest) |
  .database.migrationImage.digest = "sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"' \
  "$candidate/envs/prod/values.yaml"
if bash "$candidate/scripts/verify-prod-promotion-binding.sh" "$base_sha" >/dev/null 2>&1; then
  fail "changed Prod values with a mismatched migration digest were accepted"
fi

rm "$candidate/envs/prod/promotion-evidence.yaml"
if bash "$candidate/scripts/verify-prod-promotion-binding.sh" "$base_sha" >/dev/null 2>&1; then
  fail "changed Prod values without canonical DEV_READY were accepted"
fi

workflow_json=$(yq -o=json '.jobs.validate.steps[] | select(.name == "Bind changed Prod values to current DEV_READY")' \
  "$repository_root/.github/workflows/validate.yml")
jq -e '
  .if == "github.event_name == '\''pull_request'\''" and
  .env.BASE_SHA == "${{ github.event.pull_request.base.sha }}" and
  .run == "bash scripts/verify-prod-promotion-binding.sh \"$BASE_SHA\""
' <<<"$workflow_json" >/dev/null || fail "validate workflow does not run the merge-time Prod binding gate"

yq -o=json '.jobs.validate.steps[] | select(.name == "Checkout")' \
  "$repository_root/.github/workflows/validate.yml" |
  jq -e '.with["fetch-depth"] == 0' >/dev/null || fail "checkout must fetch the PR base commit"

echo "PASS: changed Prod image identity remains bound to the current canonical DEV_READY evidence."
