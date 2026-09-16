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

snapshot=$(mktemp -d)
trap 'rm -rf -- "$snapshot"' EXIT
git -C "$repository_root" archive "$base_sha" | tar -xf - -C "$snapshot" || fail "cannot extract base source"
base_rendered=$(ruby "$script_dir/render-prod-release.rb" "$snapshot" --base) || fail "cannot render base Prod source"
current_rendered=$(ruby "$script_dir/render-prod-release.rb" "$repository_root") || fail "cannot render current Prod source"

new_images=$(jq -cn --argjson base "$base_rendered" --argjson current "$current_rendered" \
  '($current | map(.[4]) | unique) - ($base | map(.[4]) | unique)')
if [[ "$base_image_identity" == "$current_image_identity" && "$new_images" == '[]' ]]; then
  echo "PASS: Prod image identity is unchanged; no promotion binding is required."
  exit 0
fi

# Compare with Dev on the PR base, not a Dev value modified in this same PR.
dev_identity=$(git -C "$repository_root" show "${base_sha}:envs/dev/values.yaml" |
  yq -o=json -I=0 "$image_identity_query" -) || fail "cannot read approved Dev image identity"
repository=$(jq -er '.[0]' <<<"$dev_identity")
digest=$(jq -er '.[1]' <<<"$dev_identity")
repository_name=${repository#*/}
[[ "$repository" =~ ^[0-9]{12}\.dkr\.ecr\.(ap-northeast-2|us-east-1)\.amazonaws\.com/[a-z0-9]+([._/-][a-z0-9]+)*$ &&
   ${#repository_name} -ge 2 && ${#repository_name} -le 256 ]] || fail "Dev must use an explicit ECR repository"
[[ "$digest" =~ ^sha256:[0-9a-f]{64}$ && "$digest" != sha256:0000000000000000000000000000000000000000000000000000000000000000 ]] ||
  fail "Dev must use a real immutable image digest"
jq -e '.[0] == .[2] and .[1] == .[3]' <<<"$dev_identity" >/dev/null ||
  fail "Dev application and migration images must match"
[[ "$current_image_identity" == "$dev_identity" ]] || fail "Prod must promote the image already committed to Dev"
jq -e --arg image "$repository@$digest" 'length > 0 and all(.[]; .[4] == $image)' \
  <<<"$current_rendered" >/dev/null || fail "rendered Prod image differs from approved Dev"
echo "PASS: Prod image matches reviewed Dev; environment approval and runtime observation remain required."
