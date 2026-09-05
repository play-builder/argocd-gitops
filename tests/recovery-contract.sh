#!/usr/bin/env bash
set -Eeuo pipefail

test_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repository_root=$(cd -- "$test_root/.." && pwd)
fixture_root="$test_root/fixtures/values"
render_root=$(mktemp -d "${TMPDIR:-/tmp}/gitops-recovery-contract.XXXXXX")
trap 'rm -rf -- "$render_root"' EXIT
source "$test_root/lib/render.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }

render_recovery() {
  local output=$1 overlay=$2
  helm template mini-commerce "$repository_root/charts/mini-commerce" \
    --values "$repository_root/envs/dev/values.yaml" \
    --values "$repository_root/envs/dev/stateful-values.yaml" \
    --values "$overlay" \
    --set-string image.repository=example.invalid/mini-commerce \
    --set-string image.digest=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    --set-string database.migrationImage.repository=example.invalid/mini-commerce \
    --set-string database.migrationImage.digest=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa >"$output"
}

case_invalid_same_pvc() {
  local out="$render_root/invalid.yaml" err="$render_root/invalid.err"
  set +e
  render_recovery "$out" "$fixture_root/invalid-same-pvc.yaml" 2>"$err"
  local status=$?
  set -e
  [[ $status -ne 0 ]] || fail "recovery must reject source/recovery PVC identity collision"
  grep -Fq 'recovery PVC equals source PVC' "$err" || fail "recovery PVC collision failed for an unexpected reason"
  echo "PASS: invalid same-PVC restore is rejected semantically."
}

case_capture_only() {
  local manifest="$render_root/capture.yaml"
  render_recovery "$manifest" "$fixture_root/recovery-capture-only.yaml"
  yq eval-all -e 'select(.kind == "VolumeSnapshot" and .metadata.namespace == "app-dev") | .spec.source.persistentVolumeClaimName == "data-mini-commerce-postgresql-0"' "$manifest" >/dev/null || fail "capture phase lacks source PVC VolumeSnapshot"
  [[ "$(KIND=VolumeSnapshot yq eval-all '[select(.kind == strenv(KIND))] | length' "$manifest")" == 1 ]] || fail "capture phase must render exactly one source snapshot"
  [[ "$(KIND=VolumeSnapshotContent yq eval-all '[select(.kind == strenv(KIND))] | length' "$manifest")" == 0 ]] || fail "capture phase must not pre-provision restore content"
  [[ "$(KIND=PersistentVolumeClaim yq eval-all '[select(.kind == strenv(KIND))] | length' "$manifest")" == 0 ]] || fail "capture phase must not render a recovery PVC"
  yq eval-all -o=json -I=0 '[select(.kind == "Deployment" or .kind == "Rollout")]' "$manifest" | jq -e 'length == 1 and .[0].spec.replicas == 0' >/dev/null || fail "capture phase must stop application writers"
  yq eval-all -o=json -I=0 '[select(.kind == "StatefulSet" and .metadata.name == "mini-commerce-postgresql")]' "$manifest" | jq -e 'length == 1 and .[0].spec.replicas == 0' >/dev/null || fail "capture phase must keep the database scaled to zero"
  echo "PASS: snapshot capture phase is source-only."
}

case_quiesce_phases() {
  local a1_manifest="$render_root/quiesce-a1.yaml" a2_manifest="$render_root/quiesce-a2.yaml"
  render_recovery "$a1_manifest" "$repository_root/envs/dev/snapshot-maintenance-values.yaml"
  yq eval-all -o=json -I=0 '[select(.kind == "StatefulSet" and .metadata.name == "mini-commerce-postgresql")]' "$a1_manifest" | jq -e 'length == 1 and .[0].spec.replicas == 1' >/dev/null || fail "A1 must keep one readable database replica"
  yq eval-all -o=json -I=0 '[select(.kind == "StatefulSet" and .metadata.name == "mini-commerce-postgresql")]' "$a1_manifest" | jq -e 'length == 1 and .[0].spec.template.spec.terminationGracePeriodSeconds == 120 and (.[0].spec.template.spec.containers[] | select(.name == "postgresql") | has("lifecycle") | not)' >/dev/null || fail "database must reserve bounded shutdown grace without a competing preStop signal"
  yq eval-all -o=json -I=0 '[select(.kind == "Deployment" or .kind == "Rollout")]' "$a1_manifest" | jq -e 'length == 1 and .[0].spec.replicas == 0' >/dev/null || fail "A1 must stop application writers"
  [[ "$(KIND=Job yq eval-all '[select(.kind == strenv(KIND))] | length' "$a1_manifest")" == 0 ]] || fail "A1 must disable migration writers"
  [[ "$(KIND=HorizontalPodAutoscaler yq eval-all '[select(.kind == strenv(KIND))] | length' "$a1_manifest")" == 0 ]] || fail "A1 must remove the autoscaler while writers are stopped"
  [[ "$(KIND=VolumeSnapshot yq eval-all '[select(.kind == strenv(KIND))] | length' "$a1_manifest")" == 0 ]] || fail "A1 must not create a snapshot"

  render_recovery "$a2_manifest" "$fixture_root/snapshot-quiesce-zero.yaml"
  yq eval-all -o=json -I=0 '[select(.kind == "StatefulSet" and .metadata.name == "mini-commerce-postgresql")]' "$a2_manifest" | jq -e 'length == 1 and .[0].spec.replicas == 0' >/dev/null || fail "A2 explicit database replicaCount zero was not preserved"
  yq eval-all -o=json -I=0 '[select(.kind == "Deployment" or .kind == "Rollout")]' "$a2_manifest" | jq -e 'length == 1 and .[0].spec.replicas == 0' >/dev/null || fail "A2 must keep application writers stopped"
  [[ "$(KIND=Job yq eval-all '[select(.kind == strenv(KIND))] | length' "$a2_manifest")" == 0 ]] || fail "A2 must keep migration writers disabled"
  [[ "$(KIND=HorizontalPodAutoscaler yq eval-all '[select(.kind == strenv(KIND))] | length' "$a2_manifest")" == 0 ]] || fail "A2 must keep the autoscaler absent while writers are stopped"
  [[ "$(KIND=VolumeSnapshot yq eval-all '[select(.kind == strenv(KIND))] | length' "$a2_manifest")" == 0 ]] || fail "A2 must not race database shutdown with snapshot creation"
  echo "PASS: A1 readable-checksum and A2 detached-database renders are distinct."
}

case_restore_only() {
  local manifest="$render_root/restore.yaml"
  render_recovery "$manifest" "$repository_root/envs/dev/recovery-values.yaml"
  yq eval-all -o=json -I=0 '[select(.kind == "VolumeSnapshotContent")]' "$manifest" | jq -e 'length == 1 and .[0].metadata.name == "mini-commerce-postgresql-recovery-content" and .[0].spec.driver == "ebs.csi.aws.com" and .[0].spec.sourceVolumeMode == "Filesystem" and .[0].spec.source.snapshotHandle == "snap-0123456789abcdef" and .[0].spec.volumeSnapshotRef.namespace == "app-recovery" and .[0].spec.volumeSnapshotRef.name == "mini-commerce-postgresql-recovery-snapshot"' >/dev/null || fail "restore content lacks immutable driver/handle/local binding"
  yq eval-all -o=json -I=0 '[select(.kind == "PersistentVolumeClaim" and .metadata.name == "mini-commerce-postgresql-recovery")]' "$manifest" | jq -e 'length == 1 and .[0].metadata.namespace == "app-recovery" and .[0].spec.dataSource.kind == "VolumeSnapshot" and .[0].spec.dataSource.name == "mini-commerce-postgresql-recovery-snapshot"' >/dev/null || fail "recovery PVC is not isolated to local snapshot"
  yq eval-all -o=json -I=0 '[select(.kind == "ExternalSecret" and .metadata.name == "mini-commerce-db-recovery")]' "$manifest" | jq -e 'length == 1 and .[0].metadata.namespace == "app-recovery" and .[0].spec.secretStoreRef.name == "aws-secrets-manager-recovery" and .[0].spec.target.name == "mini-commerce-db-recovery" and .[0].spec.target.creationPolicy == "Owner" and .[0].spec.target.deletionPolicy == "Retain"' >/dev/null || fail "recovery DB Secret is not local Owner/Retain"
  yq eval-all -o=json -I=0 '[select(.kind == "StatefulSet" and .metadata.name == "mini-commerce-postgresql-recovery")]' "$manifest" | jq -e 'length == 1 and .[0].metadata.namespace == "app-recovery" and .[0].spec.template.spec.containers[0].env[0].valueFrom.secretKeyRef.name == "mini-commerce-db-recovery"' >/dev/null || fail "recovery PostgreSQL does not consume local DB Secret"
  yq eval-all -o=json -I=0 '[select(.kind == "VolumeSnapshotContent" or .kind == "VolumeSnapshot" or .kind == "PersistentVolumeClaim" or (.kind == "StatefulSet" and .metadata.name == "mini-commerce-postgresql-recovery"))]' "$manifest" | jq -e 'length == 4 and all(.[]; .metadata.labels["course.playbuilder.io/cleanup-scope"] == "recovery")' >/dev/null || fail "recovery objects lack cleanup identity"
  yq eval-all -o=json -I=0 '[select(.kind == "StatefulSet" and .metadata.name == "mini-commerce-postgresql")]' "$manifest" | jq -e 'length == 1 and .[0].spec.persistentVolumeClaimRetentionPolicy == {whenDeleted:"Retain",whenScaled:"Retain"}' >/dev/null || fail "source StatefulSet retention policy was changed"
  echo "PASS: isolated recovery resources and local Secret access are valid."
}

case_ordering() {
  local manifest="$render_root/order.yaml"
  render_recovery "$manifest" "$repository_root/envs/dev/recovery-values.yaml"
  yq eval-all -o=json -I=0 '[select(.metadata.annotations["argocd.argoproj.io/sync-wave"] != null)]' "$manifest" | jq -e 'any(.[]; .kind == "ExternalSecret" and .metadata.annotations["argocd.argoproj.io/sync-wave"] == "-3") and any(.[]; .kind == "StatefulSet" and .metadata.name == "mini-commerce-postgresql" and .metadata.annotations["argocd.argoproj.io/sync-wave"] == "-2") and any(.[]; .kind == "Job" and .metadata.annotations["argocd.argoproj.io/sync-wave"] == "-1") and any(.[]; (.kind == "Deployment" or .kind == "Rollout") and .metadata.annotations["argocd.argoproj.io/sync-wave"] == "0")' >/dev/null || fail "normal application sync waves are incomplete"
  echo "PASS: Stateful application sync waves remain -3/-2/-1/0."
}

requested=${1:-all}; [[ "$requested" == "--case" ]] && requested=${2:-all}
case "$requested" in
  invalid-same-pvc) case_invalid_same_pvc ;;
  quiesce-phases) case_quiesce_phases ;;
  capture-only) case_capture_only ;;
  restore-only) case_restore_only ;;
  ordering) case_ordering ;;
  all) case_invalid_same_pvc; case_quiesce_phases; case_capture_only; case_restore_only; case_ordering ;;
  *) echo "Usage: $0 --case invalid-same-pvc|quiesce-phases|capture-only|restore-only|ordering|all" >&2; exit 2 ;;
esac
