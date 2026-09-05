#!/usr/bin/env bash
set -Eeuo pipefail

test_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repository_root=$(cd -- "$test_root/.." && pwd)
render_root=$(mktemp -d "${TMPDIR:-/tmp}/gitops-bootstrap-contract.XXXXXX")
trap 'rm -rf -- "$render_root"' EXIT

# shellcheck source=tests/lib/render.sh
source "$test_root/lib/render.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

render_bootstrap() {
  local environment=$1
  local output=$2
  kubectl kustomize "$repository_root/argocd/bootstrap/$environment" >"$output"
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

case_namespace_pss() {
  local bootstrap_dev="$render_root/bootstrap-dev.yaml"
  local bootstrap_prod="$render_root/bootstrap-prod.yaml"
  local helm_dev="$render_root/helm-dev.yaml"

  render_bootstrap dev "$bootstrap_dev"
  render_bootstrap prod "$bootstrap_prod"
  render_environment dev "$helm_dev"

  assert_manifest "$bootstrap_dev" '
    select(.kind == "ApplicationSet" and .metadata.name == "mini-commerce-dev") |
    .spec.generators[0].list.elements[0].podSecurityVersion as $version |
    $version == "v1.36" and
    .spec.template.spec.syncPolicy.managedNamespaceMetadata.labels["pod-security.kubernetes.io/warn"] == "restricted" and
    .spec.template.spec.syncPolicy.managedNamespaceMetadata.labels["pod-security.kubernetes.io/audit"] == "restricted" and
    .spec.template.spec.syncPolicy.managedNamespaceMetadata.labels["pod-security.kubernetes.io/warn-version"] == "{{ .podSecurityVersion }}" and
    .spec.template.spec.syncPolicy.managedNamespaceMetadata.labels["pod-security.kubernetes.io/audit-version"] == "{{ .podSecurityVersion }}" and
    .spec.template.spec.syncPolicy.managedNamespaceMetadata.labels["pod-security.kubernetes.io/enforce"] == null and
    .spec.template.spec.syncPolicy.managedNamespaceMetadata.labels["pod-security.kubernetes.io/enforce-version"] == null
  ' "dev ApplicationSet lacks version-pinned PSS warn/audit labels"

  assert_manifest "$bootstrap_prod" '
    select(.kind == "ApplicationSet" and .metadata.name == "mini-commerce-prod") |
    .spec.generators[0].list.elements[0].podSecurityVersion as $version |
    $version == "v1.36" and
    .spec.template.spec.syncPolicy.managedNamespaceMetadata.labels["pod-security.kubernetes.io/warn"] == "restricted" and
    .spec.template.spec.syncPolicy.managedNamespaceMetadata.labels["pod-security.kubernetes.io/audit"] == "restricted" and
    .spec.template.spec.syncPolicy.managedNamespaceMetadata.labels["pod-security.kubernetes.io/warn-version"] == "{{ .podSecurityVersion }}" and
    .spec.template.spec.syncPolicy.managedNamespaceMetadata.labels["pod-security.kubernetes.io/audit-version"] == "{{ .podSecurityVersion }}" and
    .spec.template.spec.syncPolicy.managedNamespaceMetadata.labels["pod-security.kubernetes.io/enforce"] == null and
    .spec.template.spec.syncPolicy.managedNamespaceMetadata.labels["pod-security.kubernetes.io/enforce-version"] == null
  ' "prod ApplicationSet lacks version-pinned PSS warn/audit labels"

  yq eval-all -o=json '
    select(.kind == "ApplicationSet" and .metadata.name == "mini-commerce-dev")
  ' "$bootstrap_dev" | jq -e '
    .spec.template.spec.syncPolicy.automated.prune == true and
    .spec.template.spec.syncPolicy.automated.selfHeal == true and
    (.spec.template.spec.syncPolicy.syncOptions | index("CreateNamespace=true")) != null and
    (.spec.template.spec.syncPolicy.syncOptions | index("Replace=true")) == null
  ' >/dev/null || fail "Dev must retain auto-sync/prune/self-heal without Replace=true"

  yq eval-all -o=json '
    select(.kind == "ApplicationSet" and .metadata.name == "mini-commerce-prod")
  ' "$bootstrap_prod" | jq -e '
    .spec.template.spec.syncPolicy.automated == null and
    (.spec.template.spec.syncPolicy.syncOptions | index("CreateNamespace=true")) != null and
    (.spec.template.spec.syncPolicy.syncOptions | index("Replace=true")) == null
  ' >/dev/null || fail "Prod must remain manual without Replace=true"

  assert_document_count "$helm_dev" Namespace 1
  assert_manifest "$helm_dev" '
    select(.kind == "Namespace" and .metadata.name == "app-dev") |
    .metadata.annotations["argocd.argoproj.io/sync-options"] == "Prune=false"
  ' "Phase A Helm Namespace must carry Prune=false"

  assert_manifest "$bootstrap_dev" '
    select(.kind == "Namespace" and .metadata.name == "app-recovery") |
    .metadata.labels["course.playbuilder.io/cleanup-scope"] == "recovery" and
    .metadata.labels["pod-security.kubernetes.io/warn"] == "restricted" and
    .metadata.labels["pod-security.kubernetes.io/audit"] == "restricted" and
    .metadata.labels["pod-security.kubernetes.io/warn-version"] == "v1.36" and
    .metadata.labels["pod-security.kubernetes.io/audit-version"] == "v1.36" and
    .metadata.labels["pod-security.kubernetes.io/enforce"] == null
  ' "app-recovery must start at version-pinned PSS warn/audit"

  echo "PASS: Namespace Phase A and PSS audit boundary are valid."
}

case_phase_a_controller() {
  local environment manifest application

  for environment in dev prod; do
    manifest="$render_root/bootstrap-$environment.yaml"
    application="external-secrets-$environment"
    render_bootstrap "$environment" "$manifest"

    APPLICATION="$application" yq eval-all -o=json '
      select(.kind == "Application" and .metadata.name == strenv(APPLICATION))
    ' "$manifest" | jq -e '
      (.metadata.finalizers // []) == [] and
      .spec.syncPolicy.automated == null and
      .spec.syncPolicy.syncOptions == ["CreateNamespace=true", "ServerSideApply=true"]
    ' >/dev/null || fail "Phase A must keep $application inactive and non-cascading"
  done

  echo "PASS: External Secrets ownership handoff remains in safe Phase A."
}

case_least_privilege() {
  local bootstrap_dev="$render_root/bootstrap-dev.yaml"
  local bootstrap_prod="$render_root/bootstrap-prod.yaml"
  render_bootstrap dev "$bootstrap_dev"
  render_bootstrap prod "$bootstrap_prod"

  for manifest in "$bootstrap_dev" "$bootstrap_prod"; do
    assert_document_count "$manifest" AppProject 2
    yq eval-all -o=json '[select(.kind == "AppProject")]' "$manifest" | jq -e '
      all(.[].spec.sourceRepos[]; . != "*") and
      all(.[].spec.destinations[]; .namespace != "*") and
      all(.[].spec.clusterResourceWhitelist[]?; .group != "*" and .kind != "*") and
      all(.[].spec.namespaceResourceWhitelist[]?; .group != "*" and .kind != "*")
    ' >/dev/null || fail "AppProjects must not contain wildcard repositories, destinations, groups, or kinds"

    assert_document_count "$manifest" ValidatingAdmissionPolicy 1
    assert_document_count "$manifest" ValidatingAdmissionPolicyBinding 1
    yq eval-all -o=json '
      select(.kind == "ValidatingAdmissionPolicyBinding" and .metadata.name == "course-workload-security")
    ' "$manifest" | jq -e '
      .spec.validationActions == ["Audit", "Warn"] and
      .spec.matchResources.namespaceSelector.matchLabels["course.playbuilder.io/admission"] == "enabled"
    ' >/dev/null || fail "Default admission stage must audit and warn without denying"

    yq eval-all -o=json '
      select(.kind == "ValidatingAdmissionPolicy" and .metadata.name == "course-workload-security")
    ' "$manifest" | jq -e '
      ([.spec.matchConstraints.resourceRules[].resources[]] | sort) ==
        ["deployments", "jobs", "pods", "rollouts", "statefulsets"] and
      (.spec.validations | length) == 3 and
      ([.spec.validations[].expression] | any(contains("@sha256:[0-9a-f]{64}"))) and
      ([.spec.validations[].expression] | any(contains("runAsNonRoot"))) and
      ([.spec.validations[].expression] | any(contains("allowPrivilegeEscalation")))
    ' >/dev/null || fail "Admission policy must cover Pod templates, immutable images, and restricted security"

  done

  yq eval-all -o=json '
    select(.kind == "AppProject" and .metadata.name == "course-dev")
  ' "$bootstrap_dev" | jq -e '
    [.spec.destinations[].namespace] == ["app-dev", "app-recovery"] and
    .spec.sourceRepos == ["https://github.com/REPLACE_ME/argocd-gitops.git"] and
    (.spec.roles | map(.name)) == ["developer"] and
    .spec.roles[0].groups == ["course:dev-developers"] and
    (.spec.roles[0].policies | index("p, proj:course-dev:developer, applications, sync, course-dev/*, allow")) != null and
    ([.spec.roles[].policies[]] | any(contains("applications, delete"))) == false
  ' >/dev/null || fail "Dev project must map the developer group to scoped Dev sync"

  yq eval-all -o=json '
    select(.kind == "AppProject" and .metadata.name == "course-prod")
  ' "$bootstrap_prod" | jq -e '
    [.spec.destinations[].namespace] == ["app-prod"] and
    .spec.sourceRepos == ["https://github.com/REPLACE_ME/argocd-gitops.git"] and
    ([.spec.roles[].name] | sort) == ["observer", "operator"] and
    (.spec.roles | map(select(.name == "observer"))[0].groups) == ["course:prod-observers"] and
    (.spec.roles | map(select(.name == "operator"))[0].groups) == ["course:prod-operators"] and
    ([.spec.roles[].policies[]] | any(contains("applications, delete"))) == false
  ' >/dev/null || fail "Prod project must separate observer/operator groups and forbid application deletion"

  for manifest in "$bootstrap_dev" "$bootstrap_prod"; do
    if yq eval-all -e '
      select(.kind == "ConfigMap" and
        (.metadata.name == "argocd-cm" or .metadata.name == "argocd-rbac-cm"))
    ' "$manifest" >/dev/null 2>&1; then
      fail "GitOps bootstrap must not claim Terraform-owned Argo configuration ConfigMaps"
    fi
  done

  yq eval -o=json '.' "$repository_root/contracts/platform-requirements.yaml" | jq -e '
    .schemaVersion == "course.platform-requirements/v1" and
    .ownerRepository == "EKS-infra" and
    .argoConfigMap == "argocd-cm" and
    [.argoHealthCustomizations[].id] == [
      "external-secret-ready-health/v1",
      "volume-snapshot-ready-health/v1"
    ]
  ' >/dev/null || fail "Platform requirements must name both EKS-infra-owned health contracts"

  echo "PASS: Argo projects, admission audit, RBAC, and platform ownership are least-privilege."
}

case_pss_enforce() {
  local environment manifest appset

  for environment in dev prod; do
    manifest="$render_root/bootstrap-$environment-enforce.yaml"
    appset="mini-commerce-$environment"
    kubectl kustomize "$repository_root/argocd/overlays/pss-enforce/$environment" >"$manifest"

    assert_manifest "$manifest" "
      select(.kind == \"ApplicationSet\" and .metadata.name == \"$appset\") |
      .spec.generators[0].list.elements[0].podSecurityVersion == \"v1.36\" and
      .spec.template.spec.syncPolicy.managedNamespaceMetadata.labels[\"pod-security.kubernetes.io/enforce\"] == \"restricted\" and
      .spec.template.spec.syncPolicy.managedNamespaceMetadata.labels[\"pod-security.kubernetes.io/enforce-version\"] == \"{{ .podSecurityVersion }}\"
    " "$environment PSS enforcement must use the generator-pinned version"

    yq eval-all -o=json '
      select(.kind == "ValidatingAdmissionPolicyBinding" and .metadata.name == "course-workload-security")
    ' "$manifest" | jq -e '.spec.validationActions == ["Deny"]' >/dev/null || \
      fail "$environment admission enforcement must switch to Deny"
  done

  assert_manifest "$render_root/bootstrap-dev-enforce.yaml" '
    select(.kind == "Namespace" and .metadata.name == "app-recovery") |
    .metadata.labels["pod-security.kubernetes.io/enforce"] == "restricted" and
    .metadata.labels["pod-security.kubernetes.io/enforce-version"] == "v1.36"
  ' "app-recovery enforce labels must use v1.36"

  echo "PASS: PSS and admission enforcement overlay is explicit and version-pinned."
}

case_reloader_diff() {
  local environment manifest appset

  for environment in dev prod; do
    manifest="$render_root/bootstrap-$environment-reloader.yaml"
    appset="mini-commerce-$environment"
    render_bootstrap "$environment" "$manifest"

    APPSET="$appset" yq eval-all -o=json '
      select(.kind == "ApplicationSet" and .metadata.name == strenv(APPSET)) |
      .spec.template.spec.ignoreDifferences
    ' "$manifest" | jq -e '
      (map(select(.group == "apps" and .kind == "Deployment")) |
        length == 1 and .[0].jsonPointers ==
          ["/spec/template/metadata/annotations/reloader.stakater.com~1last-reloaded-from"]) and
      (map(select(.group == "argoproj.io" and .kind == "Rollout")) |
        length == 1 and .[0].jsonPointers ==
          ["/spec/template/metadata/annotations/reloader.stakater.com~1last-reloaded-from"]) and
      (map(select(
        (.jsonPointers // []) | any(
          . == "/metadata/annotations" or
          . == "/spec/template/metadata/annotations"
        )
      )) | length) == 0
    ' >/dev/null || fail "$environment ApplicationSet lacks narrow Reloader diff rules"
  done

  echo "PASS: Reloader-generated metadata has exact narrow diff rules."
}

case_platform_health_interface() {
  local contract="$repository_root/contracts/platform-requirements.yaml"
  local environment manifest

  yq eval -o=json '.' "$contract" | jq -e '
    .ownerRepository == "EKS-infra" and
    .argoConfigMap == "argocd-cm" and
    (.argoHealthCustomizations |
      map(select(.id == "external-secret-ready-health/v1"))) == [{
        "id": "external-secret-ready-health/v1",
        "apiGroup": "external-secrets.io",
        "kind": "ExternalSecret",
        "healthyWhen": "Ready=True at observedGeneration",
        "requiredBeforeSyncWave": -2,
        "implementationOwner": "EKS-infra"
      }]
  ' >/dev/null || fail "ExternalSecret health interface lacks its exact EKS-owned readiness boundary"

  for environment in dev prod; do
    manifest="$render_root/bootstrap-$environment-health.yaml"
    render_bootstrap "$environment" "$manifest"
    if yq eval-all -e '
      select(.kind == "ConfigMap" and .metadata.name == "argocd-cm")
    ' "$manifest" >/dev/null 2>&1; then
      fail "$environment bootstrap must not render the EKS-owned argocd-cm"
    fi
  done

  echo "PASS: ExternalSecret readiness contract has one EKS-infra implementation owner."
}

case_recovery_wiring() {
  local dev="$render_root/bootstrap-dev-recovery.yaml" prod="$render_root/bootstrap-prod-recovery.yaml"
  local appset="$repository_root/argocd/bootstrap/dev/mini-commerce.yaml" default_manifest="$render_root/default-dev-application.yaml"
  render_bootstrap dev "$dev"; render_bootstrap prod "$prod"
  yq eval-all -o=json -I=0 '[.]' "$dev" | jq -s -e 'add | . as $all |
    ([ $all[] | select(.kind == "ApplicationSet" and .metadata.name == "mini-commerce-dev") ] | length) == 1 and
    ([ $all[] | select(.kind == "AppProject" and .metadata.name == "course-dev") | .spec.destinations[].namespace] | sort) == ["app-dev","app-recovery"] and
    ([ $all[] | select(.kind == "AppProject" and .metadata.name == "course-dev") | .spec.clusterResourceWhitelist[] | select(.group == "snapshot.storage.k8s.io" and .kind == "VolumeSnapshotContent")] | length) == 1
  ' >/dev/null || fail "Dev bootstrap must explicitly wire app-recovery and VolumeSnapshotContent"
  yq -o=json '.' "$appset" | jq -e '
    .spec.generators[0].list.elements[0].phaseValuesFile == "envs/dev/phase-default-values.yaml" and
    .spec.template.spec.source.helm.valueFiles == ["../../{{ .valuesFile }}","../../{{ .statefulValuesFile }}","../../{{ .phaseValuesFile }}"]
  ' >/dev/null || fail "Dev must select exactly one explicit safe-default lifecycle phase values file"
  helm template mini-commerce "$repository_root/charts/mini-commerce" \
    --values "$repository_root/$(yq -r '.spec.generators[0].list.elements[0].valuesFile' "$appset")" \
    --values "$repository_root/$(yq -r '.spec.generators[0].list.elements[0].statefulValuesFile' "$appset")" \
    --values "$repository_root/$(yq -r '.spec.generators[0].list.elements[0].phaseValuesFile' "$appset")" >"$default_manifest"
  yq eval-all -o=json -I=0 '[select(.kind == "StatefulSet" or .kind == "Job" or .kind == "VolumeSnapshot" or .kind == "VolumeSnapshotContent" or .kind == "PodChaos" or .kind == "NetworkChaos")]' "$default_manifest" | jq -e 'length == 0' >/dev/null || fail "default Dev ApplicationSet values rendered stateful, recovery, or Chaos resources"
  if yq -o=json '.' "$repository_root/argocd/bootstrap/prod/mini-commerce.yaml" | jq -e '.spec.template.spec.source.helm.valueFiles[] | select(contains("recovery-values.yaml"))' >/dev/null; then fail "Prod ApplicationSet must not consume recovery values"; fi
  yq -o=json '.' "$repository_root/contracts/platform-requirements.yaml" | jq -e '.argoHealthCustomizations | any(.[]; .id == "volume-snapshot-ready-health/v1" and .implementationOwner == "EKS-infra" and .healthyWhen == "readyToUse=true with a bound content name")' >/dev/null || fail "VolumeSnapshot health must remain EKS-infra owned"
  echo "PASS: Dev recovery destination, snapshot allowlist, and platform health wiring are explicit."
}

requested_case=all
if [[ "${1:-}" == "--case" ]]; then
  requested_case=${2:-}
elif [[ $# -gt 0 ]]; then
  echo "Usage: $0 [--case <namespace-pss|phase-a-controller|least-privilege|pss-enforce|reloader-diff|platform-health-interface|all>]" >&2
  exit 2
fi

case "$requested_case" in
  namespace-pss) case_namespace_pss ;;
  phase-a-controller) case_phase_a_controller ;;
  least-privilege) case_least_privilege ;;
  pss-enforce) case_pss_enforce ;;
  reloader-diff) case_reloader_diff ;;
  platform-health-interface) case_platform_health_interface ;;
  recovery-wiring) case_recovery_wiring ;;
  all)
    case_namespace_pss
    case_phase_a_controller
    case_least_privilege
    case_pss_enforce
    case_reloader_diff
    case_platform_health_interface
    case_recovery_wiring
    ;;
  *) fail "unknown bootstrap contract case: $requested_case" ;;
esac
