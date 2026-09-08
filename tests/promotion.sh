#!/usr/bin/env bash
# Exercise the actual merge-time renderer and digest policy in a temporary repository.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
for path in scripts envs argocd charts; do cp -R "$root/$path" "$tmp/"; done
export image_repository=123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/mini-commerce
export image_digest=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
yq -i '.image.repository=strenv(image_repository) | .image.digest=strenv(image_digest) |
  .database.migrationImage.repository=strenv(image_repository) |
  .database.migrationImage.digest=strenv(image_digest)' "$tmp/envs/dev/values.yaml"
git -C "$tmp" init -q
git -C "$tmp" -c user.name=test -c user.email=test@example.invalid add .
git -C "$tmp" -c user.name=test -c user.email=test@example.invalid commit -qm baseline
base=$(git -C "$tmp" rev-parse HEAD)
verify() { bash "$tmp/scripts/verify-prod-promotion-binding.sh" "$base"; }
deny() { if verify >/dev/null 2>&1; then echo "FAIL: $1" >&2; exit 1; fi; }
verify
# A promotion must use the Dev image without changing other production settings.
yq -i '.image.repository=strenv(image_repository) | .image.digest=strenv(image_digest) |
  .database.migrationImage.repository=strenv(image_repository) |
  .database.migrationImage.digest=strenv(image_digest)' "$tmp/envs/prod/values.yaml"
verify
cp "$tmp/envs/prod/values.yaml" "$tmp/valid.yaml"
yq -i '.image.digest="sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"' "$tmp/envs/prod/values.yaml"
deny 'unreviewed digest accepted'
# Editing Dev and Prod together cannot manufacture an approved Dev release.
cp "$tmp/envs/prod/values.yaml" "$tmp/envs/dev/values.yaml"
deny 'same-PR Dev rewrite accepted'
cp "$tmp/valid.yaml" "$tmp/envs/prod/values.yaml"
yq -i '.database.migrationImage.digest="sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"' "$tmp/envs/prod/values.yaml"
deny 'different migration image accepted'
cp "$tmp/valid.yaml" "$tmp/envs/prod/values.yaml"
yq -i '.image.digest="sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"' "$tmp/envs/prod/stateful-values.yaml"
deny 'overlay bypass accepted'
git -C "$tmp" restore envs/prod/stateful-values.yaml
yq -i '.spec.template.spec.source.helm.parameters=[{"name":"image.digest","value":"unreviewed"}]' "$tmp/argocd/bootstrap/prod/mini-commerce.yaml"
deny 'inline override accepted'
echo 'PASS: promotion allows approved Dev identity and rejects image/overlay/source bypasses'
