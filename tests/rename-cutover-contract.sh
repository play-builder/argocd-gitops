#!/usr/bin/env bash
set -Eeuo pipefail

test_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repository_root=$(cd -- "$test_root/.." && pwd)
base_revision=2db9276ce171babd87047eb778a3a39cc0585619
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
  legacy_render="$render_root/$environment-legacy.yaml"
  current_render="$render_root/$environment-current.yaml"
  overlap="$render_root/$environment-overlap.tsv"
  negative_render="$render_root/$environment-negative.yaml"
  negative_overlap="$render_root/$environment-negative-overlap.tsv"
  legacy_appset="$repository_root/argocd/bootstrap/$environment/legacy-sample-app.yaml"
  current_appset="$repository_root/argocd/bootstrap/$environment/mini-commerce.yaml"
  legacy_revision=$(yq -r '.spec.template.spec.source.targetRevision' "$legacy_appset")
  [[ "$legacy_revision" == "$base_revision" ]] || fail "legacy revision is not the immutable base"
  legacy_root="$render_root/legacy-$environment"
  mkdir -p "$legacy_root"
  git archive "$legacy_revision" charts envs | tar -x -C "$legacy_root"
  namespace=$(yq -r '.spec.generators[0].list.elements[0].namespace' "$current_appset")

  render_application_source "$legacy_appset" "$legacy_root" "$legacy_render"
  render_application_source "$current_appset" "$repository_root" "$current_render"
  write_shared_ownership_overlap "$legacy_render" "$current_render" "$overlap" "$namespace"
  [[ ! -s "$overlap" ]] || {
    cat "$overlap" >&2
    fail "$environment legacy and current Applications render the same resource identity"
  }

  render_application_source "$current_appset" "$repository_root" "$negative_render" \
    --values "$test_root/fixtures/rename/shared-ownership-overlap.yaml"
  write_shared_ownership_overlap "$legacy_render" "$negative_render" "$negative_overlap" "$namespace"
  [[ "$(wc -l <"$negative_overlap" | tr -d ' ')" == "1" ]] || {
    cat "$negative_overlap" >&2
    fail "$environment overlap fixture did not reproduce the remaining namespace collision"
  }
done

for environment in dev prod; do
  legacy_manifest="$repository_root/argocd/bootstrap/$environment/legacy-sample-app.yaml"
  kustomization="$repository_root/argocd/bootstrap/$environment/kustomization.yaml"
  git show "$base_revision:argocd/bootstrap/$environment/sample-app.yaml" >/dev/null || fail "$environment immutable base lacks legacy ApplicationSet"
  [[ -f "$legacy_manifest" ]] || fail "$environment pre-cutover legacy ApplicationSet is absent"
  grep -Fqx '  - legacy-sample-app.yaml' "$kustomization" || fail "$environment bootstrap does not retain legacy ownership"
  BASE_REVISION="$base_revision" yq -e '
    .kind == "ApplicationSet" and
    .metadata.name == ("sample-app-" + .spec.generators[0].list.elements[0].environment) and
    .metadata.annotations["argocd.argoproj.io/sync-options"] == "Prune=confirm" and
    .spec.template.metadata.annotations["argocd.argoproj.io/sync-options"] == "Prune=confirm" and
    .spec.syncPolicy.preserveResourcesOnDeletion == true and
    (.spec.template.metadata | has("finalizers") | not) and
    (.spec.template.spec.syncPolicy | has("automated") | not) and
    .spec.template.spec.source.targetRevision == strenv(BASE_REVISION) and
    .spec.template.spec.source.path == "charts/sample-app"
  ' "$legacy_manifest" >/dev/null || fail "$environment legacy ApplicationSet is not immutable and prune-protected"

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

echo "PASS: pre-cutover desired state has one owner for every shared resource"
