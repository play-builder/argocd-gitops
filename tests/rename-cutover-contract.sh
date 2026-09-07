#!/usr/bin/env bash
set -Eeuo pipefail

test_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repository_root=$(cd -- "$test_root/.." && pwd)
render_root=$(mktemp -d "${TMPDIR:-/tmp}/gitops-rename-cutover.XXXXXX")
trap 'rm -rf -- "$render_root"' EXIT

# shellcheck source=tests/lib/render.sh
source "$test_root/lib/render.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

render_application_source() {
  local appset=$1 source_root=$2 output=$3
  shift 3
  local chart release template field value
  local -a helm_arguments=()
  chart=$(yq -r '.spec.template.spec.source.path' "$appset")
  release=$(yq -r '.spec.template.spec.source.helm.releaseName' "$appset")
  while IFS= read -r template; do
    # Resolve the valueFiles contract from the actual list generator in order.
    field=${template#'../../{{ .'}
    field=${field%' }}'}
    value=$(FIELD="$field" yq -er '.spec.generators[0].list.elements[0][strenv(FIELD)]' "$appset") ||
      fail "unresolved ApplicationSet value file: $template"
    helm_arguments+=(--values "$source_root/$value")
  done < <(yq -r '.spec.template.spec.source.helm.valueFiles[]' "$appset")
  while IFS=$'\t' read -r name value; do
    [[ -z "$name" ]] || helm_arguments+=(--set-string "$name=$value")
  done < <(yq -r '.spec.template.spec.source.helm.parameters[]? | [.name,.value] | @tsv' "$appset")
  helm template "$release" "$source_root/$chart" "${helm_arguments[@]}" "$@" >"$output"
}

write_object_keys() {
  local manifest=$1
  local output=$2
  local namespace=$3

  yq eval-all -o=json -I=0 \
    '[select(.apiVersion != null and .kind != null and .metadata.name != null)]' \
    "$manifest" | jq -r --arg namespace "$namespace" \
    '.[] | [.apiVersion, .kind,
      (if (.kind == "Namespace" or .kind == "GatewayClass") then "<cluster>"
       else (.metadata.namespace // $namespace) end), .metadata.name] | @tsv' | \
    sort -u >"$output"
}

write_shared_ownership_overlap() {
  local legacy_manifest=$1
  local current_manifest=$2
  local output=$3
  local namespace=$4
  local legacy_keys="$output.legacy"
  local current_keys="$output.current"

  write_object_keys "$legacy_manifest" "$legacy_keys" "$namespace"
  write_object_keys "$current_manifest" "$current_keys" "$namespace"
  comm -12 "$legacy_keys" "$current_keys" >"$output"
}

for environment in dev prod; do
  current_render="$render_root/$environment-current.yaml"
  root_overlap="$render_root/$environment-root-overlap.tsv"
  negative_render="$render_root/$environment-negative.yaml"
  negative_overlap="$render_root/$environment-negative-overlap.tsv"
  current_appset="$repository_root/argocd/bootstrap/$environment/mini-commerce.yaml"
  namespace=$(yq -r '.spec.generators[0].list.elements[0].namespace' "$current_appset")
  root_namespace="$repository_root/argocd/bootstrap/$environment/application-namespace.yaml"

  # The platform deploys only mini-commerce: its render must not claim bootstrap-owned shared resources.
  render_application_source "$current_appset" "$repository_root" "$current_render"
  write_shared_ownership_overlap "$root_namespace" "$current_render" "$root_overlap" "$namespace"
  [[ ! -s "$root_overlap" ]] || {
    cat "$root_overlap" >&2
    fail "$environment mini-commerce Application renders a resource identity owned by the bootstrap namespace"
  }

  render_application_source "$current_appset" "$repository_root" "$negative_render" \
    --values "$test_root/fixtures/rename/shared-ownership-overlap.yaml"
  write_shared_ownership_overlap "$root_namespace" "$negative_render" "$negative_overlap" "$namespace"
  [[ "$(wc -l <"$negative_overlap" | tr -d ' ')" == "1" ]] || {
    cat "$negative_overlap" >&2
    fail "$environment overlap fixture did not reproduce the root namespace collision"
  }
done

for environment in dev prod; do
  legacy_manifest="$repository_root/argocd/bootstrap/$environment/legacy-sample-app.yaml"
  kustomization="$repository_root/argocd/bootstrap/$environment/kustomization.yaml"
  [[ ! -e "$legacy_manifest" ]] || fail "$environment bootstrap still carries the retired legacy sample-app ApplicationSet"
  ! grep -Fq 'legacy-sample-app' "$kustomization" || fail "$environment bootstrap kustomization still references the legacy ApplicationSet"
  # Inspect the rendered bootstrap, not the directory listing, so a re-added legacy ApplicationSet under any
  # filename or subdirectory is caught.
  legacy_chart_count=$(kubectl kustomize "$repository_root/argocd/bootstrap/$environment" | yq eval-all -N \
    '[select(.kind == "ApplicationSet") | select(.spec.template.spec.source.path == "charts/sample-app" or (.metadata.name | test("^sample-app-")))] | length')
  [[ "$legacy_chart_count" == "0" ]] || fail "$environment bootstrap still renders the legacy sample-app ApplicationSet"

  current_manifest="$repository_root/argocd/bootstrap/$environment/mini-commerce.yaml"
  ownership_values="envs/$environment/pre-cutover-ownership-values.yaml"
  OWNERSHIP_VALUES="$ownership_values" yq -e '
    .spec.generators[0].list.elements[0].ownershipValuesFile == strenv(OWNERSHIP_VALUES) and
    (.spec.template.spec.source.helm.valueFiles | contains(["../../{{ .ownershipValuesFile }}"])) and
    (.spec.template.spec.syncPolicy.syncOptions | contains(["CreateNamespace=true"]) | not) and
    (.spec.template.spec.syncPolicy | has("managedNamespaceMetadata") | not) and
    ((.spec.template.spec.templatePatch // "") | contains("managedNamespaceMetadata") | not) and
    ((.spec.templatePatch // "") | contains("managedNamespaceMetadata") | not)
  ' "$current_manifest" >/dev/null || fail "$environment current ApplicationSet does not reference legacy-owned shared resources"
done

echo "PASS: post-cutover desired state deploys only mini-commerce with one owner for every shared resource"
