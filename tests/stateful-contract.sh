#!/usr/bin/env bash
set -Eeuo pipefail

test_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repository_root=$(cd -- "$test_root/.." && pwd)
fixture_root="$test_root/fixtures/values"
render_root=$(mktemp -d "${TMPDIR:-/tmp}/gitops-stateful-contract.XXXXXX")
trap 'rm -rf -- "$render_root"' EXIT

# shellcheck source=tests/lib/render.sh
source "$test_root/lib/render.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_document_count() {
  local manifest=$1
  local kind=$2
  local expected=$3
  local actual

  actual=$(KIND="$kind" yq eval-all \
    '[select(.kind == strenv(KIND))] | length' "$manifest")
  [[ "$actual" == "$expected" ]] || \
    fail "expected $expected $kind documents in $manifest, got $actual"
}

assert_manifest() {
  local manifest=$1
  local expression=$2
  local message=$3

  yq eval-all -e "$expression" "$manifest" >/dev/null || fail "$message"
}

yq eval -e '.database.enabled == false' "$repository_root/envs/dev/stateful-values.yaml" \
  >/dev/null || fail "Dev Stateful opt-in must default to false"
yq eval -e '.database.enabled == false' "$repository_root/envs/prod/stateful-values.yaml" \
  >/dev/null || fail "Prod Stateful opt-in must default to false"

yq eval -e '
  .spec.generators[].list.elements[] |
  select(.environment == "dev") |
  .statefulValuesFile == "envs/dev/stateful-values.yaml"
' "$repository_root/argocd/bootstrap/dev/sample-app.yaml" >/dev/null || \
  fail "Dev ApplicationSet must consume the Dev Stateful opt-in file"
yq eval -e '
  .spec.generators[].list.elements[] |
  select(.environment == "prod") |
  .statefulValuesFile == "envs/prod/stateful-values.yaml"
' "$repository_root/argocd/bootstrap/prod/sample-app.yaml" >/dev/null || \
  fail "Prod ApplicationSet must consume the Prod Stateful opt-in file"

render_environment dev "$render_root/dev-stateless.yaml"
assert_document_count "$render_root/dev-stateless.yaml" StatefulSet 0
assert_document_count "$render_root/dev-stateless.yaml" Job 0

render_environment dev "$render_root/dev-stateful.yaml" \
  "$repository_root/envs/dev/stateful-values.yaml" \
  "$fixture_root/stateful-policy-on.yaml"
render_environment prod "$render_root/prod-stateful.yaml" \
  "$repository_root/envs/prod/stateful-values.yaml" \
  "$fixture_root/stateful-policy-on.yaml"

database_image='docker.io/library/postgres@sha256:ef257d85f76e48da1c64832459b59fcaba1a4dac97bf5d7450c77753542eee94'
application_image='example.invalid/sample-app@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'

for manifest in "$render_root/dev-stateful.yaml" "$render_root/prod-stateful.yaml"; do
  assert_document_count "$manifest" StatefulSet 1
  assert_document_count "$manifest" Job 1
  assert_document_count "$manifest" NetworkPolicy 3

  assert_manifest "$manifest" '
    select(.kind == "StatefulSet" and .metadata.name == "sample-app-postgresql") |
    .metadata.annotations["argocd.argoproj.io/sync-wave"] == "-2" and
    .spec.volumeClaimTemplates[0].spec.storageClassName == "course-gp3"
  ' "PostgreSQL StatefulSet must use sync wave -2 and course-gp3 storage"

  DATABASE_IMAGE="$database_image" assert_manifest "$manifest" '
    select(.kind == "StatefulSet" and .metadata.name == "sample-app-postgresql") |
    .spec.template.spec.containers[] |
    select(.name == "postgresql") |
    .image == strenv(DATABASE_IMAGE)
  ' "PostgreSQL image must be pinned by digest"

  assert_manifest "$manifest" '
    select(.kind == "Job" and .metadata.name == "sample-app-migration") |
    .metadata.annotations["argocd.argoproj.io/sync-wave"] == "-1" and
    .metadata.annotations["argocd.argoproj.io/hook"] == "Sync" and
    .metadata.annotations["argocd.argoproj.io/hook-delete-policy"] == "BeforeHookCreation"
  ' "Migration Job must be a replaceable sync hook at wave -1"

  APPLICATION_IMAGE="$application_image" assert_manifest "$manifest" '
    select((.kind == "Deployment" or .kind == "Rollout") and .metadata.name == "sample-app") |
    .spec.template.spec.containers[] |
    select(.name == "sample-app") |
    .image == strenv(APPLICATION_IMAGE)
  ' "Application workload image must be pinned by digest"

  yq eval-all -o=json '
    select((.kind == "Deployment" or .kind == "Rollout") and .metadata.name == "sample-app") |
    .spec.template.spec.containers[] |
    select(.name == "sample-app") |
    .env
  ' "$manifest" | jq -e '
    map(.name) as $names |
    ($names | index("DATABASE_ENABLED")) != null and
    ($names | index("DB_HOST")) != null
  ' >/dev/null || fail "Application workload must receive the Stateful database contract"

  yq eval-all -o=json '
    select(.kind == "Job" and .metadata.name == "sample-app-migration") |
    .spec.template.spec.containers[] |
    select(.name == "migrate") |
    .env
  ' "$manifest" | jq -e '
    map(.name) | index("DB_PASSWORD") != null
  ' >/dev/null || fail "Migration Job must receive DB_PASSWORD from the Secret"

  assert_manifest "$manifest" '
    select(.kind == "NetworkPolicy" and .metadata.name == "sample-app-postgresql") |
    .spec.podSelector.matchLabels["app.kubernetes.io/name"] == "postgresql" and
    .spec.podSelector.matchLabels["app.kubernetes.io/instance"] == "sample-app" and
    .spec.ingress[0].ports[0].port == 5432
  ' "Database NetworkPolicy must select PostgreSQL and allow its configured port"
done

yq eval-all -o=json '
  select(.kind == "Rollout" and .metadata.name == "sample-app") |
  .spec.strategy.canary.steps
' "$render_root/prod-stateful.yaml" | jq -e '
  (to_entries | map(select(.value.pause == {})) | last | .key) as $pause |
  (to_entries | map(select(.value.setWeight == 100)) | last | .key) as $weight |
  $pause != null and $weight != null and $pause < $weight
' >/dev/null || fail "Prod manual pause must precede the final 100 percent weight"

printf '%s\n' \
  'database:' \
  '  enabled: true' \
  'externalSecrets:' \
  '  enabled: false' >"$render_root/invalid-secret-values.yaml"

if render_environment dev "$render_root/invalid-secret-contract.yaml" \
  "$render_root/invalid-secret-values.yaml" \
  2>"$render_root/invalid-secret-contract.err"; then
  fail "Stateful render must reject a missing ExternalSecret contract"
fi
grep -Fq 'externalSecrets.enabled must be true when database is enabled' \
  "$render_root/invalid-secret-contract.err" || \
  fail "Stateful render failed for an unexpected reason"

echo "PASS: Stateless default and Stateful GitOps contracts are valid."
