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
  .database.migration.rollbackCandidates.enabled == false and
  .database.migration.rollbackCandidates.configMapName == ""
' "$repository_root/charts/mini-commerce/values.yaml" >/dev/null || \
  fail "Rollback candidate handoff must default to disabled"
yq eval -e '
  .database.migration.rollbackCandidates.enabled == true and
  .database.migration.rollbackCandidates.configMapName == "mini-commerce-rollback-candidates"
' "$repository_root/envs/prod/values.yaml" >/dev/null || \
  fail "Prod must opt into the fixed rollback candidate handoff"

yq eval -e '
  .spec.generators[].list.elements[] |
  select(.environment == "dev") |
  .statefulValuesFile == "envs/dev/stateful-values.yaml"
' "$repository_root/argocd/bootstrap/dev/mini-commerce.yaml" >/dev/null || \
  fail "Dev ApplicationSet must consume the Dev Stateful opt-in file"
yq eval -e '
  .spec.generators[].list.elements[] |
  select(.environment == "prod") |
  .statefulValuesFile == "envs/prod/stateful-values.yaml"
' "$repository_root/argocd/bootstrap/prod/mini-commerce.yaml" >/dev/null || \
  fail "Prod ApplicationSet must consume the Prod Stateful opt-in file"

render_environment dev "$render_root/dev-stateless.yaml"
assert_document_count "$render_root/dev-stateless.yaml" StatefulSet 0
assert_document_count "$render_root/dev-stateless.yaml" Job 0
render_environment prod "$render_root/prod-stateless.yaml"
assert_document_count "$render_root/prod-stateless.yaml" Job 0
if rg -q 'ROLLBACK_|rollback-candidates' "$render_root/prod-stateless.yaml"; then
  fail "DB-disabled Prod render must not reference rollback candidate evidence"
fi

render_environment dev "$render_root/dev-stateful.yaml" \
  "$repository_root/envs/dev/stateful-values.yaml" \
  "$fixture_root/stateful-policy-on.yaml"
render_environment prod "$render_root/prod-stateful.yaml" \
  "$repository_root/envs/prod/stateful-values.yaml" \
  "$fixture_root/stateful-policy-on.yaml"

database_image='docker.io/library/postgres@sha256:ef257d85f76e48da1c64832459b59fcaba1a4dac97bf5d7450c77753542eee94'
application_image='example.invalid/mini-commerce@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'

for manifest in "$render_root/dev-stateful.yaml" "$render_root/prod-stateful.yaml"; do
  assert_document_count "$manifest" StatefulSet 1
  assert_document_count "$manifest" Job 1
  assert_document_count "$manifest" NetworkPolicy 3

  assert_manifest "$manifest" '
    select(.kind == "StatefulSet" and .metadata.name == "mini-commerce-postgresql") |
    .metadata.annotations["argocd.argoproj.io/sync-wave"] == "-2" and
    .spec.volumeClaimTemplates[0].spec.storageClassName == "course-gp3"
  ' "PostgreSQL StatefulSet must use sync wave -2 and course-gp3 storage"

  DATABASE_IMAGE="$database_image" assert_manifest "$manifest" '
    select(.kind == "StatefulSet" and .metadata.name == "mini-commerce-postgresql") |
    .spec.template.spec.containers[] |
    select(.name == "postgresql") |
    .image == strenv(DATABASE_IMAGE)
  ' "PostgreSQL image must be pinned by digest"

  assert_manifest "$manifest" '
    select(.kind == "Job" and .metadata.name == "mini-commerce-migration") |
    .metadata.annotations["argocd.argoproj.io/sync-wave"] == "-1" and
    .metadata.annotations["argocd.argoproj.io/hook"] == "Sync" and
    .metadata.annotations["argocd.argoproj.io/hook-delete-policy"] == "BeforeHookCreation"
  ' "Migration Job must be a replaceable sync hook at wave -1"

  APPLICATION_IMAGE="$application_image" assert_manifest "$manifest" '
    select((.kind == "Deployment" or .kind == "Rollout") and .metadata.name == "mini-commerce") |
    .spec.template.spec.containers[] |
    select(.name == "mini-commerce") |
    .image == strenv(APPLICATION_IMAGE)
  ' "Application workload image must be pinned by digest"

  yq eval-all -o=json '
    select((.kind == "Deployment" or .kind == "Rollout") and .metadata.name == "mini-commerce") |
    .spec.template.spec.containers[] |
    select(.name == "mini-commerce") |
    .env
  ' "$manifest" | jq -e '
    map(.name) as $names |
    ($names | index("DATABASE_ENABLED")) != null and
    ($names | index("DB_HOST")) != null
  ' >/dev/null || fail "Application workload must receive the Stateful database contract"

  yq eval-all -o=json '
    select(.kind == "Job" and .metadata.name == "mini-commerce-migration") |
    .spec.template.spec.containers[] |
    select(.name == "migrate") |
    .env
  ' "$manifest" | jq -e '
    map(.name) | index("DB_PASSWORD") != null
  ' >/dev/null || fail "Migration Job must receive DB_PASSWORD from the Secret"

  assert_manifest "$manifest" '
    select(.kind == "NetworkPolicy" and .metadata.name == "mini-commerce-postgresql") |
    .spec.podSelector.matchLabels["app.kubernetes.io/name"] == "postgresql" and
    .spec.podSelector.matchLabels["app.kubernetes.io/instance"] == "mini-commerce" and
    .spec.ingress[0].ports[0].port == 5432
  ' "Database NetworkPolicy must select PostgreSQL and allow its configured port"
done

assert_document_count "$render_root/prod-stateful.yaml" ConfigMap 1
yq eval-all -e '
  [select(.kind == "ConfigMap" and .metadata.name == "mini-commerce-rollback-candidates")] | length == 0
' "$render_root/prod-stateful.yaml" >/dev/null ||
  fail "Helm must reference, not render, the out-of-band rollback candidate ConfigMap"

yq eval-all -o=json '
  select(.kind == "Job" and .metadata.name == "mini-commerce-migration") |
  .spec.template.spec.containers[] | select(.name == "migrate")
' "$render_root/dev-stateful.yaml" | jq -e '
  ([.env[].name | select(startswith("ROLLBACK_"))] | length) == 0 and
  ([.volumeMounts[].name | select(. == "rollback-candidates")] | length) == 0
' >/dev/null || fail "Dev migration Job must not consume Prod rollback evidence"

yq eval-all -o=json '
  select(.kind == "Job" and .metadata.name == "mini-commerce-migration")
' "$render_root/prod-stateful.yaml" | jq -e '
  .spec.template.spec as $pod |
  ($pod.containers[] | select(.name == "migrate")) as $container |
  ([ $container.env[] | select(.name | startswith("ROLLBACK_")) ] | sort_by(.name)) ==
    ([
      {name:"ROLLBACK_CANDIDATES_FILE",value:"/var/run/course-evidence/rollback-candidates.json"},
      {name:"ROLLBACK_EXPECTED_CLUSTER_ARN",valueFrom:{configMapKeyRef:{name:"mini-commerce-rollback-candidates",key:"clusterArn"}}},
      {name:"ROLLBACK_EXPECTED_ENVIRONMENT",valueFrom:{configMapKeyRef:{name:"mini-commerce-rollback-candidates",key:"environment"}}},
      {name:"ROLLBACK_EXPECTED_GITOPS_REVISION",valueFrom:{configMapKeyRef:{name:"mini-commerce-rollback-candidates",key:"gitopsRevision"}}},
      {name:"ROLLBACK_EXPECTED_REGION",valueFrom:{configMapKeyRef:{name:"mini-commerce-rollback-candidates",key:"region"}}},
      {name:"ROLLBACK_EXPECTED_ROLLOUT_NAME",valueFrom:{configMapKeyRef:{name:"mini-commerce-rollback-candidates",key:"rolloutName"}}},
      {name:"ROLLBACK_EXPECTED_SOURCE_EVIDENCE_DIGEST",valueFrom:{configMapKeyRef:{name:"mini-commerce-rollback-candidates",key:"sourceEvidenceDigest"}}}
    ] | sort_by(.name)) and
  ([ $container.volumeMounts[] | select(.name == "rollback-candidates") ] ==
    [{name:"rollback-candidates",mountPath:"/var/run/course-evidence",readOnly:true}]) and
  ([ $pod.volumes[] | select(.name == "rollback-candidates") ] == [{
    name:"rollback-candidates",
    configMap:{name:"mini-commerce-rollback-candidates",defaultMode:444,
      items:[{key:"rollback-candidates.json",path:"rollback-candidates.json"}]}
  }])
' >/dev/null || fail "Prod migration Job must receive the exact read-only rollback candidate handoff"
grep -Fq 'defaultMode: 0444' "$render_root/prod-stateful.yaml" ||
  fail "Rollback candidate volume must render the Kubernetes 0444 file mode"

printf '%s\n' \
  'database:' \
  '  enabled: true' \
  '  migration:' \
  '    rollbackCandidates:' \
  '      enabled: true' \
  '      configMapName: ""' >"$render_root/invalid-rollback-configmap.yaml"
if render_environment prod "$render_root/invalid-rollback-configmap-render.yaml" \
  "$render_root/invalid-rollback-configmap.yaml" 2>"$render_root/invalid-rollback-configmap.err"; then
  fail "Prod migration render accepted an empty rollback candidate ConfigMap name"
fi
grep -Fq 'database.migration.rollbackCandidates.configMapName is required when rollback candidate handoff is enabled' \
  "$render_root/invalid-rollback-configmap.err" ||
  fail "Rollback candidate ConfigMap name failed for an unexpected reason"

yq eval-all -o=json '
  select(.kind == "Rollout" and .metadata.name == "mini-commerce") |
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
