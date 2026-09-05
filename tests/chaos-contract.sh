#!/usr/bin/env bash
set -Eeuo pipefail

test_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repository_root=$(cd -- "$test_root/.." && pwd)
fixture_root="$test_root/fixtures/values"
tmp_root=$(mktemp -d "${TMPDIR:-/tmp}/gitops-chaos.XXXXXX")
trap 'rm -rf -- "$tmp_root"' EXIT
source "$test_root/lib/render.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

validate_resources() {
  local manifest=$1
  yq eval-all -o=json -I=0 '[select(.kind == "PodChaos" or .kind == "NetworkChaos")]' "$manifest" |
    jq -e '
      length == 2 and all(.[].metadata;
        .namespace == "app-dev" and
        .labels["course.playbuilder.io/incident"] != null) and
      all(.[].spec; (.duration | capture("^(?<n>[1-9][0-9]*)(?<u>[sm])$") |
        ((.n|tonumber) * (if .u == "m" then 60 else 1 end)) <= 300))
    ' >/dev/null || fail "Chaos resource is not a bounded dev-only incident fixture"
  yq eval-all -o=json -I=0 '[select(.kind == "PodChaos" or .kind == "NetworkChaos")]' "$manifest" |
    jq -e 'map(.spec.selector.namespaces[]?) | unique == ["app-dev"]' >/dev/null ||
    fail "Chaos selectors must be restricted to app-dev"
}

case_name=${2:-${1:-dev}}
if [[ "${1:-}" == "--case" ]]; then case_name=${2:?missing case}; fi
case "$case_name" in
  dev)
    render_environment dev "$tmp_root/dev.yaml" "$repository_root/envs/dev/chaos-values.yaml"
    validate_resources "$tmp_root/dev.yaml"
    echo "PASS: bounded Chaos resources are Dev-only."
    ;;
  prod-deny)
    set +e
    render_environment prod "$tmp_root/prod.yaml" "$fixture_root/chaos-prod-invalid.yaml" 2>"$tmp_root/error"
    status=$?
    set -e
    [[ $status -ne 0 ]] || fail "Chaos must be rejected for Prod"
    grep -Fq "chaos is allowed only in dev" "$tmp_root/error" || fail "Chaos failed for an unexpected reason"
    echo "PASS: Prod Chaos request is rejected."
    ;;
  namespace-injection)
    namespace_owner="$repository_root/argocd/bootstrap/dev/legacy-sample-app.yaml"
    yq -o=json '.' "$namespace_owner" | jq -e '
      .spec.generators[0].list.elements[0].chaosInjectionEnabled == false and
      (.spec.template.spec.syncPolicy.syncOptions | index("CreateNamespace=true")) != null and
      (.spec.templatePatch | contains("chaos-mesh.org/inject: enabled")) and
      .spec.template.spec.templatePatch == null
    ' >/dev/null || fail "Dev namespace owner must carry the disabled-by-default Chaos annotation patch"
    ! grep -Fq 'chaos-values.yaml' "$repository_root/argocd/bootstrap/prod/mini-commerce.yaml" || fail "Prod must not reference Chaos values"
    echo "PASS: Chaos Namespace injection is explicitly staged for Dev."
    ;;
  *) echo "Usage: $0 --case dev|prod-deny|namespace-injection" >&2; exit 2 ;;
esac
