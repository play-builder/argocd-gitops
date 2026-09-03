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

project_allows_manifest() {
  local project_manifest=$1
  local project_name=$2
  local rendered_manifest=$3
  local registry="$test_root/fixtures/project-scope/resource-scopes.tsv"
  local allowed resource api_version group kind scope

  allowed=$(PROJECT="$project_name" yq eval-all -o=json '
    select(.kind == "AppProject" and .metadata.name == strenv(PROJECT))
  ' "$project_manifest" | jq -r '
    [
      (.spec.clusterResourceWhitelist[]? | ["cluster", .group, .kind]),
      (.spec.namespaceResourceWhitelist[]? | ["namespace", .group, .kind])
    ] | .[] | @tsv
  ') || return 1

  while IFS=$'\t' read -r api_version kind; do
    [[ -n "$kind" ]] || continue
    if [[ "$api_version" == */* ]]; then
      group=${api_version%%/*}
    else
      group=""
    fi
    scope=$(awk -F '\t' -v group="$group" -v kind="$kind" \
      '$2 == group && $3 == kind { print $1 }' "$registry")
    [[ -n "$scope" ]] || {
      echo "unregistered resource: $group/$kind" >&2
      return 1
    }
    resource=$(printf '%s\t%s\t%s' "$scope" "$group" "$kind")
    grep -Fqx "$resource" <<<"$allowed" || {
      echo "unauthorized resource: $resource" >&2
      return 1
    }
  done < <(yq eval-all -o=json -I=0 '
    select(.apiVersion != null and .kind != null)
  ' "$rendered_manifest" | jq -s -r '.[] | [.apiVersion, .kind] | @tsv' | sort -u)
}

case_project_scope() {
  local synthetic="$render_root/project-scope-synthetic.yaml"
  local dev_project="$repository_root/argocd/bootstrap/dev/project.yaml"
  local prod_project="$repository_root/argocd/bootstrap/prod/project.yaml"
  local manifest

  cat >"$synthetic" <<'YAML'
apiVersion: v1
kind: ConfigMap
metadata: {name: contract}
---
apiVersion: gateway.k8s.aws/v1
kind: LoadBalancerConfiguration
metadata: {name: contract}
YAML
  if project_allows_manifest \
    "$test_root/fixtures/project-scope/missing-configmap-project.yaml" missing-configmap "$synthetic" 2>/dev/null; then
    fail "project without ConfigMap permission accepted the rendered resource"
  fi
  if project_allows_manifest \
    "$test_root/fixtures/project-scope/wrong-load-balancer-scope-project.yaml" wrong-load-balancer-scope "$synthetic" 2>/dev/null; then
    fail "project accepted namespaced LoadBalancerConfiguration as a cluster resource"
  fi

  manifest="$render_root/dev-stateless-project-scope.yaml"
  render_environment dev "$manifest"
  project_allows_manifest "$dev_project" course-dev "$manifest" || \
    fail "dev stateless render exceeds course-dev authorization"

  manifest="$render_root/dev-stateful-project-scope.yaml"
  render_environment dev "$manifest" "$fixture_root/stateful-policy-off.yaml"
  project_allows_manifest "$dev_project" course-dev "$manifest" || \
    fail "dev Stateful render exceeds course-dev authorization"

  manifest="$render_root/dev-snapshot-project-scope.yaml"
  render_environment dev "$manifest" "$repository_root/envs/dev/snapshot-capture-values.yaml"
  project_allows_manifest "$dev_project" course-dev "$manifest" || \
    fail "dev snapshot render exceeds course-dev authorization"

  manifest="$render_root/dev-recovery-project-scope.yaml"
  render_environment dev "$manifest" "$repository_root/envs/dev/recovery-values.yaml"
  project_allows_manifest "$dev_project" course-dev "$manifest" || \
    fail "dev recovery render exceeds course-dev authorization"

  manifest="$render_root/dev-chaos-project-scope.yaml"
  render_environment dev "$manifest" "$repository_root/envs/dev/chaos-values.yaml"
  project_allows_manifest "$dev_project" course-dev "$manifest" || \
    fail "dev Chaos render exceeds course-dev authorization"

  manifest="$render_root/prod-stateless-project-scope.yaml"
  render_environment prod "$manifest"
  project_allows_manifest "$prod_project" course-prod "$manifest" || \
    fail "prod stateless render exceeds course-prod authorization"

  manifest="$render_root/prod-stateful-project-scope.yaml"
  render_environment prod "$manifest" "$fixture_root/stateful-policy-off.yaml"
  project_allows_manifest "$prod_project" course-prod "$manifest" || \
    fail "prod Stateful render exceeds course-prod authorization"

  local phase
  for phase in initial expand contract finalize; do
    manifest="$render_root/prod-$phase-project-scope.yaml"
    render_environment prod "$manifest" "$fixture_root/stateful-policy-off.yaml" \
      "$repository_root/envs/prod/migration-$phase-values.yaml"
    project_allows_manifest "$prod_project" course-prod "$manifest" || \
      fail "prod $phase migration render exceeds course-prod authorization"
  done

  echo "PASS: rendered phase resources are a subset of environment AppProject scopes."
}

run_case() {
  local case_name=$1
  local expected_network_policies

  case "$case_name" in
    stateless-policy-off) expected_network_policies=0 ;;
    stateless-policy-on) expected_network_policies=1 ;;
    stateful-policy-off) expected_network_policies=0 ;;
    stateful-policy-on) expected_network_policies=3 ;;
    recovery-policy-off) expected_network_policies=0 ;;
    recovery-policy-on) expected_network_policies=4 ;;
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

case_network_policy() {
  local stateless_policy_on="$render_root/stateless-policy-on-paths.yaml"
  local stateful_policy_on="$render_root/stateful-policy-on-paths.yaml"
  local recovery_policy_on="$render_root/recovery-policy-on-paths.yaml"

  render_environment dev "$stateless_policy_on" "$fixture_root/stateless-policy-on.yaml"
  render_environment dev "$stateful_policy_on" "$fixture_root/stateful-policy-on.yaml"
  render_environment dev "$recovery_policy_on" "$fixture_root/recovery-policy-on.yaml"

  yq eval-all -o=json -I=0 \
    '[select(.kind == "NetworkPolicy" and .metadata.name == "sample-app")]' \
    "$stateful_policy_on" | jq -e '
      length == 1 and
      any(.[0].spec.ingress[]?.from[]?; .ipBlock.cidr == "10.0.0.0/16")
    ' >/dev/null || fail "app policy lacks the configured Gateway source CIDR"

  yq eval-all -o=json -I=0 \
    '[select(.kind == "NetworkPolicy" and .metadata.name == "sample-app")]' \
    "$stateless_policy_on" | jq -e '
      length == 1 and
      .[0].spec.policyTypes == ["Ingress", "Egress"] and
      .[0].spec.podSelector.matchLabels["app.kubernetes.io/component"] == "application" and
      any(.[0].spec.ingress[]?;
        any(.from[]?;
          .namespaceSelector.matchLabels["kubernetes.io/metadata.name"] == "opentelemetry-operator-system" and
          .podSelector.matchLabels["app.kubernetes.io/name"] == "adot-collector-prometheus-collector") and
        .ports == [{"protocol":"TCP","port":3000}]) and
      any(.[0].spec.egress[]?;
        any(.to[]?;
          .namespaceSelector.matchLabels["kubernetes.io/metadata.name"] == "kube-system" and
          .podSelector.matchLabels["k8s-app"] == "kube-dns") and
        ([.ports[]? | [.protocol, .port]] | sort) == [["TCP",53],["UDP",53]]) and
      any(.[0].spec.egress[]?;
        any(.to[]?;
          .namespaceSelector.matchLabels["kubernetes.io/metadata.name"] == "opentelemetry-operator-system" and
          .podSelector.matchLabels["app.kubernetes.io/name"] == "adot-collector-prometheus-collector") and
        .ports == [{"protocol":"TCP","port":4318}])
    ' >/dev/null || fail "app policy lacks selected DNS or telemetry peers and explicit ports"

  yq eval-all -o=json -I=0 \
    '[select(.kind == "NetworkPolicy" and .metadata.name == "sample-app-postgresql")]' \
    "$recovery_policy_on" | jq -e '
      length == 1 and
      .[0].spec.policyTypes == ["Ingress", "Egress"] and
      .[0].spec.egress == [] and
      ([.[0].spec.ingress[]?.from[]?
        | select(.namespaceSelector.matchLabels["kubernetes.io/metadata.name"] == "app-recovery")
        | .podSelector.matchLabels["app.kubernetes.io/component"]] == ["recovery"])
    ' >/dev/null || fail "database policy lacks the combined recovery namespace and pod peer"

  yq eval-all -o=json -I=0 '[select(.kind == "NetworkPolicy")]' \
    "$recovery_policy_on" | jq -e '
      length == 4 and
      all(.[];
        (.spec.podSelector | length) > 0 and
        ([.spec.ingress[]?.from[]?, .spec.egress[]?.to[]?] |
          all(.[]; (. | length) > 0)) and
        ([.spec.ingress[]?.ports[]?, .spec.egress[]?.ports[]?] |
          all(.[]; .protocol != null and .port != null))) and
      all(.[];
        ([.spec.ingress[]?.from[]?.ipBlock.cidr?, .spec.egress[]?.to[]?.ipBlock.cidr?] |
          all(.[]; . != "0.0.0.0/0" and . != "::/0"))) and
      (map(select(.metadata.name == "sample-app-database-clients")) | length) == 1 and
      (map(select(.metadata.name == "sample-app-recovery")) | length) == 1
    ' >/dev/null || fail "policy set contains a wildcard, unselected peer, missing port, or missing client policy"

  yq eval-all -o=json '
    select(.kind == "NetworkPolicy" and .metadata.name == "sample-app-database-clients")
  ' "$stateful_policy_on" | jq -e '
    .spec.podSelector.matchExpressions == [{
      "key":"app.kubernetes.io/component",
      "operator":"In",
      "values":["application","migration"]
    }] and
    .spec.policyTypes == ["Ingress", "Egress"] and
    .spec.ingress == [] and
    any(.spec.egress[]?;
      any(.to[]?; .podSelector.matchLabels["app.kubernetes.io/component"] == "database") and
      .ports == [{"protocol":"TCP","port":5432}])
  ' >/dev/null || fail "application and migration database egress is not explicitly selected"

  yq eval-all -o=json '
    select(.kind == "NetworkPolicy" and .metadata.name == "sample-app-recovery")
  ' "$recovery_policy_on" | jq -e '
    .metadata.namespace == "app-recovery" and
    .spec.podSelector.matchLabels["app.kubernetes.io/component"] == "recovery" and
    .spec.policyTypes == ["Ingress", "Egress"] and
    .spec.ingress == [] and
    any(.spec.egress[]?;
      any(.to[]?;
        .namespaceSelector.matchLabels["kubernetes.io/metadata.name"] == "app-dev" and
        .podSelector.matchLabels["app.kubernetes.io/component"] == "database") and
      .ports == [{"protocol":"TCP","port":5432}])
  ' >/dev/null || fail "recovery egress lacks a combined source namespace database peer"

  local wildcard_values="$render_root/network-policy-wildcard.yaml"
  printf '%s\n' \
    'networkPolicy:' \
    '  enabled: true' \
    '  gateway:' \
    '    sourceCidrs:' \
    '      - 0.0.0.0/0' >"$wildcard_values"
  if render_environment dev "$render_root/network-policy-wildcard-render.yaml" \
    "$wildcard_values" 2>"$render_root/network-policy-wildcard.err"; then
    fail "NetworkPolicy render accepted a wildcard Gateway CIDR"
  fi
  grep -Fq 'networkPolicy.gateway.sourceCidrs must contain bounded CIDRs' \
    "$render_root/network-policy-wildcard.err" || \
    fail "wildcard Gateway CIDR failed for an unexpected reason"

  echo "PASS: NetworkPolicy paths use selected peers and explicit ports."
}

case_telemetry() {
  local dev_stateless="$render_root/dev-stateless-telemetry.yaml"
  local prod_stateless="$render_root/prod-stateless-telemetry.yaml"
  local environment manifest namespace

  render_environment dev "$dev_stateless" "$fixture_root/stateless-policy-off.yaml"
  render_environment prod "$prod_stateless" "$fixture_root/stateless-policy-off.yaml"

  for environment in dev prod; do
    if [[ "$environment" == "dev" ]]; then
      manifest="$dev_stateless"
      namespace=app-dev
    else
      manifest="$prod_stateless"
      namespace=app-prod
    fi

    yq eval-all -o=json '
      select(.kind == "ConfigMap" and .metadata.name == "sample-app-telemetry")
    ' "$manifest" | ENVIRONMENT="$environment" NAMESPACE="$namespace" jq -e '
      .data.OTEL_SERVICE_NAME == "sample-app" and
      .data.OTEL_EXPORTER_OTLP_ENDPOINT ==
        "http://adot-collector-prometheus-collector.opentelemetry-operator-system.svc.cluster.local:4318/v1/traces" and
      .data.OTEL_EXPORTER_OTLP_PROTOCOL == "http/protobuf" and
      .data.OTEL_RESOURCE_ATTRIBUTES ==
        ("service.name=sample-app,service.namespace=" + env.NAMESPACE +
          ",deployment.environment=" + env.ENVIRONMENT) and
      ([.data[]] | any(test("API_KEY|DB_[A-Z_]+"))) == false
    ' >/dev/null || fail "$environment telemetry metadata or ADOT endpoint contract is invalid"

    yq eval-all -o=json '
      select((.kind == "Deployment" or .kind == "Rollout") and .metadata.name == "sample-app") |
      .spec.template
    ' "$manifest" | jq -e '
      .metadata.annotations["prometheus.io/scrape"] == "true" and
      .metadata.annotations["prometheus.io/path"] == "/metrics" and
      .metadata.annotations["prometheus.io/port"] == "3000" and
      (.spec.containers[0].env |
        map(select(.name | startswith("OTEL_"))) |
        map({name, configMapKeyRef: .valueFrom.configMapKeyRef})) == [
          {"name":"OTEL_SERVICE_NAME","configMapKeyRef":{"name":"sample-app-telemetry","key":"OTEL_SERVICE_NAME"}},
          {"name":"OTEL_RESOURCE_ATTRIBUTES","configMapKeyRef":{"name":"sample-app-telemetry","key":"OTEL_RESOURCE_ATTRIBUTES"}},
          {"name":"OTEL_EXPORTER_OTLP_ENDPOINT","configMapKeyRef":{"name":"sample-app-telemetry","key":"OTEL_EXPORTER_OTLP_ENDPOINT"}},
          {"name":"OTEL_EXPORTER_OTLP_PROTOCOL","configMapKeyRef":{"name":"sample-app-telemetry","key":"OTEL_EXPORTER_OTLP_PROTOCOL"}}
        ] and
      (.spec.containers[0].env |
        map(select(.name == "DATABASE_ENABLED"))) ==
          [{"name":"DATABASE_ENABLED","value":"false"}]
    ' >/dev/null || fail "$environment workload lacks correlated stateless telemetry inputs"
  done

  echo "PASS: Stateless telemetry correlates metrics, logs, and traces without DB runtime claims."
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
  echo "Usage: $0 [--case <matrix|secret-reload|network-policy|telemetry|project-scope|case-name>]" >&2
  exit 2
fi

if [[ "$requested_case" == "secret-reload" ]]; then
  case_secret_reload
elif [[ "$requested_case" == "network-policy" ]]; then
  case_network_policy
elif [[ "$requested_case" == "telemetry" ]]; then
  case_telemetry
elif [[ "$requested_case" == "project-scope" ]]; then
  case_project_scope
elif [[ "$requested_case" == "matrix" ]]; then
  run_case stateless-policy-off
  run_case stateless-policy-on
  run_case stateful-policy-off
  run_case stateful-policy-on
  run_case recovery-policy-off
  run_case recovery-policy-on
else
  run_case "$requested_case"
fi

echo "PASS: Helm render matrix is valid ($requested_case)."
