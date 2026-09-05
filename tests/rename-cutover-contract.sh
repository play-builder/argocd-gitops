#!/usr/bin/env bash
set -Eeuo pipefail

test_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repository_root=$(cd -- "$test_root/.." && pwd)
base_revision=2db9276ce171babd87047eb778a3a39cc0585619

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

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
    (.spec.template.metadata.finalizers | contains(["resources-finalizer.argocd.argoproj.io"])) and
    .spec.template.spec.source.targetRevision == strenv(BASE_REVISION) and
    .spec.template.spec.source.path == "charts/sample-app"
  ' "$legacy_manifest" >/dev/null || fail "$environment legacy ApplicationSet is not immutable and prune-protected"
done

echo "PASS: pre-cutover desired state retains immutable legacy ownership"
