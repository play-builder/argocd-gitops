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

render_gateway_cidr() {
  local field=$1 cidr=$2
  helm template mini-commerce "$repository_root/charts/mini-commerce" \
    --values "$repository_root/envs/dev/values.yaml" \
    --values "$test_root/fixtures/values/stateless-policy-on.yaml" \
    --set-string "networkPolicy.gateway.$field[0]=$cidr"
}

assert_gateway_cidr_rejected() {
  local field=$1 cidr=$2
  local error_output="$render_root/health-cidr-rejected.err"

  if render_gateway_cidr "$field" "$cidr" >/dev/null 2>"$error_output"; then
    fail "invalid $field CIDR is accepted: $cidr"
  fi

  grep -Fq "networkPolicy.gateway.$field must contain" "$error_output" ||
    fail "CIDR rejected for an unrelated reason: $field=$cidr"
}

for invalid_cidr in \
  10.0.0.0/0 \
  10.0.0.0/7 \
  172.16.0.0/0 \
  172.16.0.0/11 \
  192.168.0.0/0 \
  192.168.0.0/15 \
  0.0.0.0/0 \
  8.8.8.8/32 \
  172.15.0.0/16 \
  172.32.0.0/16 \
  10.999.0.0/16 \
  10.1.2.3/16 \
  10.01.0.0/16 \
  10.0.0.0/08 \
  10.0.0.0/33 \
  10.0.0.0/-1 \
  ::/0; do
  assert_gateway_cidr_rejected healthCheckSourceCidrs "$invalid_cidr"
done

for invalid_cidr in 10.0.0.0/0 203.0.113.0/0 203.0.113.999/24 \
  203.0.113.1/24 203.00.113.0/24 203.0.113.0/33 ::/0; do
  assert_gateway_cidr_rejected sourceCidrs "$invalid_cidr"
done

# Literal boundary cases protect against both an overly broad and an overly
# restrictive validator. A standard parser independently checks emitted CIDRs.
for field in healthCheckSourceCidrs sourceCidrs; do
  for valid_cidr in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 \
    172.31.255.255/32 192.168.255.254/31; do
    render_gateway_cidr "$field" "$valid_cidr" >"$health_manifest"
    yq eval-all -o=json -I=0 \
      '[select(.kind == "NetworkPolicy" and .metadata.name == "mini-commerce") | .spec.ingress[] | .from[] | .ipBlock.cidr | select(. != null)]' \
      "$health_manifest" | FIELD="$field" CIDR="$valid_cidr" python3 -c '
import ipaddress, json, os, sys
cidrs = json.load(sys.stdin)
assert os.environ["CIDR"] in cidrs
private = [ipaddress.ip_network(n) for n in ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16")]
for cidr in cidrs:
    network = ipaddress.ip_network(cidr, strict=True)
    assert str(network) == cidr and network.prefixlen > 0
if os.environ["FIELD"] == "healthCheckSourceCidrs":
    assert any(ipaddress.ip_network(os.environ["CIDR"]).subnet_of(n) for n in private)
' || fail "rendered $field does not preserve a valid canonical CIDR: $valid_cidr"
  done
done

render_gateway_cidr sourceCidrs 203.0.113.0/24 >"$health_manifest"
yq eval-all -o=json -I=0 '[select(.kind == "NetworkPolicy" and .metadata.name == "mini-commerce") | .spec.ingress[].from[].ipBlock.cidr]' \
  "$health_manifest" | jq -e 'index("203.0.113.0/24") != null' >/dev/null || fail "public-port source CIDR was not preserved"

echo "PASS: public and management port contracts are separated"
