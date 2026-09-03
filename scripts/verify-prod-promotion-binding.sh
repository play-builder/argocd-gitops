#!/usr/bin/env bash
set -Eeuo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
repository_root=$(cd -- "$script_dir/.." && pwd -P)

fail() { echo "FAIL: $*" >&2; exit 1; }

[[ $# -eq 1 ]] || fail "Usage: $0 BASE_SHA"
base_sha=$1
[[ "$base_sha" =~ ^[0-9a-f]{40}$ ]] || fail "BASE_SHA must be a full lowercase commit SHA"
git -C "$repository_root" cat-file -e "$base_sha^{commit}" 2>/dev/null ||
  fail "BASE_SHA is not an available commit"

values="$repository_root/envs/prod/values.yaml"
image_identity_query='[.image.repository, .image.digest, .database.migrationImage.repository, .database.migrationImage.digest]'
base_image_identity=$(git -C "$repository_root" show "${base_sha}:envs/prod/values.yaml" |
  yq -o=json -I=0 "$image_identity_query" -) ||
  fail "cannot read base Prod image identity"
current_image_identity=$(yq -o=json -I=0 "$image_identity_query" "$values") ||
  fail "cannot read current Prod image identity"

if [[ "$base_image_identity" == "$current_image_identity" ]]; then
  echo "PASS: Prod image identity is unchanged; no promotion binding is required."
  exit 0
fi

evidence="$repository_root/envs/prod/promotion-evidence.yaml"
[[ -f "$evidence" && ! -L "$evidence" ]] ||
  fail "changed Prod image identity requires canonical non-symlink DEV_READY evidence"

physical_parent=$(cd -- "$(dirname -- "$evidence")" && pwd -P) ||
  fail "cannot resolve canonical DEV_READY parent"
[[ "$physical_parent/$(basename -- "$evidence")" == "$evidence" ]] ||
  fail "canonical DEV_READY evidence escaped the repository"

evidence_repository=$(yq -er '.image.repository' "$evidence") ||
  fail "DEV_READY image repository is missing"
evidence_digest=$(yq -er '.image.indexDigest' "$evidence") ||
  fail "DEV_READY image digest is missing"
application_repository=$(yq -er '.image.repository' "$values") ||
  fail "Prod application repository is missing"
application_digest=$(yq -er '.image.digest' "$values") ||
  fail "Prod application digest is missing"
migration_repository=$(yq -er '.database.migrationImage.repository' "$values") ||
  fail "Prod migration repository is missing"
migration_digest=$(yq -er '.database.migrationImage.digest' "$values") ||
  fail "Prod migration digest is missing"

evidence_repository_name=${evidence_repository#*/}
[[ "$evidence_repository" =~ ^[0-9]{12}\.dkr\.ecr\.(ap-northeast-2|us-east-1)\.amazonaws\.com/[a-z0-9]+([._/-][a-z0-9]+)*$ &&
   ${#evidence_repository_name} -ge 2 && ${#evidence_repository_name} -le 256 ]] ||
  fail "DEV_READY repository is not canonical ECR identity"
[[ "$evidence_digest" =~ ^sha256:[0-9a-f]{64}$ ]] ||
  fail "DEV_READY digest is not canonical"
[[ "$application_repository" == "$evidence_repository" && "$migration_repository" == "$evidence_repository" ]] ||
  fail "Prod application and migration repositories must match current DEV_READY"
[[ "$application_digest" == "$evidence_digest" && "$migration_digest" == "$evidence_digest" ]] ||
  fail "Prod application and migration digests must match current DEV_READY"

echo "PASS: changed Prod image identity matches current canonical DEV_READY evidence."
