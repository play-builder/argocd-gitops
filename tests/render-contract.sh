#!/usr/bin/env bash
set -Eeuo pipefail

test_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repository_root=$(cd -- "$test_root/.." && pwd)
fixture_root="$test_root/fixtures/values"
render_root=$(mktemp -d "${TMPDIR:-/tmp}/gitops-render-contract.XXXXXX")
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
  if [[ "$actual" != "$expected" ]]; then
    echo "FAIL: expected $expected $kind documents in $manifest, got $actual" >&2
    return 1
  fi
}

run_case() {
  local case_name=$1
  local expected_network_policies

  case "$case_name" in
    stateless-policy-off) expected_network_policies=0 ;;
    stateless-policy-on) expected_network_policies=1 ;;
    stateful-policy-off) expected_network_policies=0 ;;
    stateful-policy-on) expected_network_policies=2 ;;
    *)
      echo "FAIL: unknown render case: $case_name" >&2
      return 2
      ;;
  esac

  local manifest="$render_root/$case_name.yaml"
  render_environment dev "$manifest" "$fixture_root/$case_name.yaml"
  assert_document_count "$manifest" NetworkPolicy "$expected_network_policies"

  if [[ "$case_name" == "stateless-policy-off" ]]; then
    yq eval-all -o=json '
      select(.kind == "Deployment" and .metadata.name == "sample-app") |
      .spec.template.spec.containers[] |
      select(.name == "sample-app") |
      .env
    ' "$manifest" | jq -e '
      (map(select(.name == "DATABASE_ENABLED")) | length) == 1 and
      (map(select(.name == "DATABASE_ENABLED"))[0].value == "false") and
      ([.[].name] | any(startswith("DB_"))) == false
    ' >/dev/null || fail "stateless workload must explicitly disable the database"
  fi
}

case_secret_reload() {
  local dev_stateful="$render_root/dev-stateful-secret-reload.yaml"
  local prod_stateful="$render_root/prod-stateful-secret-reload.yaml"
  local dev_stateless="$render_root/dev-stateless-secret-reload.yaml"

  render_environment dev "$dev_stateful" "$fixture_root/stateful-policy-off.yaml"
  render_environment prod "$prod_stateful" "$fixture_root/stateful-policy-off.yaml"
  render_environment dev "$dev_stateless" "$fixture_root/stateless-policy-off.yaml"

  yq eval-all -o=json -I=0 '[select(.kind == "ExternalSecret")]' \
    "$dev_stateful" | jq -e '
      (map(.spec.target.name) | sort) == ["sample-app-db", "sample-app-runtime"]
    ' >/dev/null || fail "runtime and database ExternalSecret targets are not separated"

  local environment manifest expected_runtime_remote expected_database_remote
  for environment in dev prod; do
    if [[ "$environment" == "dev" ]]; then
      manifest="$dev_stateful"
    else
      manifest="$prod_stateful"
    fi
    expected_runtime_remote="sample-app/$environment/sample-app-runtime"
    expected_database_remote="sample-app/$environment/sample-app-db"

    yq eval-all -o=json -I=0 '[select(.kind == "ExternalSecret")]' \
      "$manifest" | EXPECTED_RUNTIME_REMOTE="$expected_runtime_remote" \
      EXPECTED_DATABASE_REMOTE="$expected_database_remote" jq -e '
        length == 2 and
        all(.[];
          .metadata.annotations["argocd.argoproj.io/sync-wave"] == "-3" and
          .spec.target.creationPolicy == "Owner" and
          .spec.target.deletionPolicy == "Retain"
        ) and
        (map(select(.spec.target.name == "sample-app-runtime")) | length) == 1 and
        (map(select(.spec.target.name == "sample-app-db")) | length) == 1 and
        (map(select(.spec.target.name == "sample-app-runtime"))[0].spec.data |
          map(.secretKey)) == ["API_KEY"] and
        (map(select(.spec.target.name == "sample-app-runtime"))[0].spec.data |
          all(.[];
            .remoteRef.key == env.EXPECTED_RUNTIME_REMOTE and
            .remoteRef.property == .secretKey)) and
        (map(select(.spec.target.name == "sample-app-db"))[0].spec.data |
          map(.secretKey) | sort) ==
          ["DB_HOST", "DB_NAME", "DB_PASSWORD", "DB_PORT", "DB_USER"] and
        (map(select(.spec.target.name == "sample-app-db"))[0].spec.data |
          all(.[];
            .remoteRef.key == env.EXPECTED_DATABASE_REMOTE and
            .remoteRef.property == .secretKey))
      ' >/dev/null || fail "ExternalSecret key, ownership, retention, or wave contract is invalid"

    yq eval-all -o=json '
      select((.kind == "Deployment" or .kind == "Rollout") and .metadata.name == "sample-app")
    ' "$manifest" | jq -e '
      .metadata.annotations["secret.reloader.stakater.com/reload"] == "sample-app-runtime" and
      ([.metadata.annotations[]] | index("sample-app-db")) == null and
      .spec.template.spec.containers[0].envFrom ==
        [{"secretRef":{"name":"sample-app-runtime"}}] and
      (.spec.template.spec.containers[0].env |
        map(select(.name == "DB_HOST" or .name == "DB_PORT" or .name == "DB_NAME" or
          .name == "DB_USER" or .name == "DB_PASSWORD"))) as $db_env |
      ($db_env | length) == 5 and
      all($db_env[]; .valueFrom.secretKeyRef.name == "sample-app-db")
    ' >/dev/null || fail "application Secret consumption or Reloader target is invalid"

    yq eval-all -o=json '
      select(.kind == "StatefulSet" and .metadata.name == "sample-app-postgresql") |
      .spec.template.spec.containers[0].env
    ' "$manifest" | jq -e '
      map(select(.name == "POSTGRES_DB" or .name == "POSTGRES_USER" or .name == "POSTGRES_PASSWORD")) as $postgres_env |
      ($postgres_env | length) == 3 and
      all($postgres_env[]; .valueFrom.secretKeyRef.name == "sample-app-db")
    ' >/dev/null || fail "PostgreSQL must consume only the database Secret"

    yq eval-all -o=json '
      select(.kind == "Job" and .metadata.name == "sample-app-migration") |
      .spec.template.spec.containers[0].env
    ' "$manifest" | jq -e '
      (map(select(.name == "DB_HOST" or .name == "DB_PORT" or .name == "DB_NAME" or
        .name == "DB_USER" or .name == "DB_PASSWORD"))) as $db_env |
      (($db_env | length) == 5 and
        all($db_env[]; .valueFrom.secretKeyRef.name == "sample-app-db")) and
      (map(select(.name == "DB_SSL"))) == [{"name":"DB_SSL","value":"false"}]
    ' >/dev/null || fail "migration must consume only the database Secret"

    yq eval-all -o=json -I=0 \
      '[select(.metadata.annotations["argocd.argoproj.io/sync-wave"] != null) |
        .metadata.annotations["argocd.argoproj.io/sync-wave"]]' \
      "$manifest" | jq -e '
        index("-3") != null and index("-2") != null and
        index("-1") != null and index("0") != null
      ' >/dev/null || fail "Secret, database, migration, and application waves are incomplete"
  done

  yq eval-all -o=json '
    select(.kind == "Rollout" and .metadata.name == "sample-app")
  ' "$prod_stateful" | jq -e '
    .metadata.annotations["reloader.stakater.com/rollout-strategy"] == "rollout" and
    .metadata.annotations["secret.reloader.stakater.com/reload"] == "sample-app-runtime"
  ' >/dev/null || fail "Rollout lacks the runtime-only Reloader strategy"

  yq eval-all -o=json '
    select(.kind == "Deployment" and .metadata.name == "sample-app") |
    .spec.template.spec.containers[0]
  ' "$dev_stateless" | jq -e '
    (.env | map(select(.name == "DATABASE_ENABLED"))) ==
      [{"name":"DATABASE_ENABLED","value":"false"}] and
    .envFrom == [{"secretRef":{"name":"sample-app-runtime"}}] and
    ([.env[].name] | any(startswith("DB_"))) == false
  ' >/dev/null || fail "stateless app must consume only runtime Secret and disable database"

  yq eval-all -o=json -I=0 '[select(.kind == "ExternalSecret")]' \
    "$dev_stateless" | jq -e '
      length == 1 and
      .[0].spec.target.name == "sample-app-runtime" and
      (.[0].spec.data | map(.secretKey)) == ["API_KEY"]
    ' >/dev/null || fail "stateless render must not reconcile the unused database Secret"

  echo "PASS: Secret targets, consumers, reload annotations, and waves are separated."
}

requested_case=matrix
if [[ "${1:-}" == "--case" ]]; then
  requested_case=${2:-}
elif [[ $# -gt 0 ]]; then
  echo "Usage: $0 [--case <matrix|secret-reload|case-name>]" >&2
  exit 2
fi

if [[ "$requested_case" == "secret-reload" ]]; then
  case_secret_reload
elif [[ "$requested_case" == "matrix" ]]; then
  run_case stateless-policy-off
  run_case stateless-policy-on
  run_case stateful-policy-off
  run_case stateful-policy-on
else
  run_case "$requested_case"
fi

echo "PASS: Helm render matrix is valid ($requested_case)."
