#!/usr/bin/env bash
set -Eeuo pipefail

repository_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
render_root=$(mktemp -d "${TMPDIR:-/tmp}/gitops-stateful-contract.XXXXXX")
trap 'rm -rf -- "$render_root"' EXIT

digest="sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
repository="example.invalid/sample-app"

render() {
  local environment=$1
  shift
  helm template sample-app "$repository_root/charts/sample-app" \
    --values "$repository_root/envs/$environment/values.yaml" \
    "$@" \
    --set-string image.repository="$repository" \
    --set-string image.digest="$digest" \
    --set-string database.migrationImage.repository="$repository" \
    --set-string database.migrationImage.digest="$digest"
}

render dev >"$render_root/dev-stateless.yaml"
if grep -Eq '^kind: (StatefulSet|PersistentVolumeClaim)$|^  name: sample-app-postgresql$' "$render_root/dev-stateless.yaml"; then
  echo "Stateless render must not contain PostgreSQL resources" >&2
  exit 1
fi

grep -q 'enabled: false' "$repository_root/envs/dev/stateful-values.yaml"
grep -q 'enabled: false' "$repository_root/envs/prod/stateful-values.yaml"
grep -q 'statefulValuesFile: envs/dev/stateful-values.yaml' "$repository_root/argocd/bootstrap/dev/sample-app.yaml"
grep -q 'statefulValuesFile: envs/prod/stateful-values.yaml' "$repository_root/argocd/bootstrap/prod/sample-app.yaml"

render dev --values "$repository_root/envs/dev/stateful-values.yaml" \
  --set database.enabled=true >"$render_root/dev-stateful.yaml"
render prod --values "$repository_root/envs/prod/stateful-values.yaml" \
  --set database.enabled=true >"$render_root/prod-stateful.yaml"

for manifest in "$render_root/dev-stateful.yaml" "$render_root/prod-stateful.yaml"; do
  grep -q '^kind: StatefulSet$' "$manifest"
  grep -q '^kind: Job$' "$manifest"
  grep -q '^kind: NetworkPolicy$' "$manifest"
  grep -q 'storageClassName: course-gp3' "$manifest"
  grep -q 'argocd.argoproj.io/sync-wave: "-2"' "$manifest"
  grep -q 'argocd.argoproj.io/sync-wave: "-1"' "$manifest"
  grep -q 'argocd.argoproj.io/hook: Sync' "$manifest"
  grep -q 'argocd.argoproj.io/hook-delete-policy: BeforeHookCreation' "$manifest"
  grep -q "example.invalid/sample-app@$digest" "$manifest"
  grep -q 'docker.io/library/postgres@sha256:ef257d85f76e48da1c64832459b59fcaba1a4dac97bf5d7450c77753542eee94' "$manifest"
  grep -q 'name: DATABASE_ENABLED' "$manifest"
  grep -q 'name: DB_PASSWORD' "$manifest"
done

pause_line=$(grep -n -- '- pause: {}' "$render_root/prod-stateful.yaml" | tail -1 | cut -d: -f1)
weight_line=$(grep -n -- 'setWeight: 100' "$render_root/prod-stateful.yaml" | tail -1 | cut -d: -f1)
[[ -n "$pause_line" && -n "$weight_line" && "$pause_line" -lt "$weight_line" ]]

grep -q 'port: 5432' "$render_root/dev-stateful.yaml"
grep -q 'app.kubernetes.io/component: database' "$render_root/dev-stateful.yaml"

if render dev --set database.enabled=true --set externalSecrets.enabled=false \
  >"$render_root/invalid-secret-contract.yaml" 2>"$render_root/invalid-secret-contract.err"; then
  echo "Stateful render must reject a missing ExternalSecret contract" >&2
  exit 1
fi
grep -q 'externalSecrets.enabled must be true when database is enabled' \
  "$render_root/invalid-secret-contract.err"

echo "PASS: Stateless default and Stateful GitOps contracts are valid."
