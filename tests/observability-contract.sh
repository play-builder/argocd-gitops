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
done

echo "PASS: public and management port contracts are separated"
