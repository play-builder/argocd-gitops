#!/usr/bin/env bash
set -Eeuo pipefail

test_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$test_root/lib/render.sh"
render_root=$(mktemp -d)
trap 'rm -rf "$render_root"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

for environment in dev prod; do
  manifest="$render_root/$environment.yaml"
  render_environment "$environment" "$manifest"

  yq eval-all -e '
    select(.kind == "Service" and .metadata.name == "mini-commerce-stable") |
    (.spec.ports | length) == 1 and
    .spec.ports[0].port == 80 and
    .spec.ports[0].targetPort == "public"
  ' "$manifest" >/dev/null || fail "$environment public Service must target the named 3000 port"

  yq eval-all -e '
    select((.kind == "Deployment" or .kind == "Rollout") and .metadata.name == "mini-commerce") |
    ([.spec.template.spec.containers[] | select(.name == "mini-commerce") | .ports[] | select(.name == "public" and .containerPort == 3000 and .protocol == "TCP")] | length) == 1 and
    ([.spec.template.spec.containers[] | select(.name == "mini-commerce") | .ports[] | select(.name == "management" and .containerPort == 3001 and .protocol == "TCP")] | length) == 1 and
    ([.spec.template.spec.containers[] | select(.name == "mini-commerce") | select(.livenessProbe.httpGet.path == "/healthz" and .livenessProbe.httpGet.port == "management" and .readinessProbe.httpGet.path == "/readyz" and .readinessProbe.httpGet.port == "management")] | length) == 1
  ' "$manifest" >/dev/null || fail "$environment workload must use management-only probes on 3001"

  yq eval-all -e '
    select((.kind == "Deployment" or .kind == "Rollout") and .metadata.name == "mini-commerce") |
    .spec.template.metadata.annotations["prometheus.io/scrape"] == "true" and
    .spec.template.metadata.annotations["prometheus.io/path"] == "/metrics" and
    .spec.template.metadata.annotations["prometheus.io/port"] == "3001"
  ' "$manifest" >/dev/null || fail "$environment scrape must use management port 3001"

  yq eval-all -e '[select(.kind == "Service") | .spec.ports[] | select(.port == 3001 or .targetPort == 3001 or .targetPort == "management")] | length == 0' "$manifest" >/dev/null || fail "$environment Service exposes management port"
  yq eval-all -e '[select(.kind == "HTTPRoute") | .spec.rules[].backendRefs[]? | select(.port == 3001)] | length == 0' "$manifest" >/dev/null || fail "$environment HTTPRoute exposes management port"
done

health_manifest="$render_root/alb-health.yaml"
render_environment dev "$health_manifest" "$test_root/fixtures/values/stateless-policy-on.yaml"
yq eval-all -e '
  select(.kind == "TargetGroupConfiguration" and (.metadata.name == "mini-commerce-stable" or .metadata.name == "mini-commerce-canary")) |
  .spec.defaultConfiguration.healthCheckConfig.healthCheckPort == "3001" and
  .spec.defaultConfiguration.healthCheckConfig.healthCheckPath == "/readyz" and
  .spec.defaultConfiguration.healthCheckConfig.matcher.httpCode == "200"
' "$health_manifest" >/dev/null || fail "ALB health checks must use management port 3001"

yq eval-all -e '
  select(.kind == "NetworkPolicy" and .metadata.name == "mini-commerce") |
  ([.spec.ingress[] | select(
    (.ports | length) == 1 and
    .ports[0].protocol == "TCP" and
    .ports[0].port == 3001 and
    (([.from[].ipBlock.cidr] | sort | join(",")) == "10.1.0.0/16")
  )] | length) == 1
' "$health_manifest" >/dev/null || fail "NetworkPolicy must admit only the bounded ALB health-check CIDR to 3001"

if helm template mini-commerce "$repository_root/charts/mini-commerce" \
  --values "$repository_root/envs/dev/values.yaml" \
  --values "$test_root/fixtures/values/stateless-policy-on.yaml" \
  --set-string image.repository=example.invalid/mini-commerce \
  --set-string image.digest=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  --set-string database.migrationImage.repository=example.invalid/mini-commerce \
  --set-string database.migrationImage.digest=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  --set-string networkPolicy.gateway.healthCheckSourceCidrs[0]=0.0.0.0/0 >/dev/null 2>&1; then
  fail "wildcard ALB health-check CIDR is accepted"
fi

echo "PASS: public and management port contracts are separated"
