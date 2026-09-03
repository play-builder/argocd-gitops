#!/usr/bin/env bash
set -Eeuo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repository_root=$(cd -- "$script_dir/.." && pwd)
output="$repository_root/evidence/recovery/snapshot-quiesce.json"
fixture=""
fail() { echo "FAIL: $*" >&2; exit 1; }

if [[ "${1:-}" == "--fixture" ]]; then fixture=${2:?missing fixture}; fi

validate() {
  local file=$1
  jq -e '
    (keys | sort) == ["checksum","clusterArn","database","environment","evidenceGrade","expiresAt","gitopsRevision","observedAt","region","schemaVersion","source","storage","writers"] and
    .schemaVersion == "course.snapshot-quiesce/v1" and .evidenceGrade == "CLOUD_RUNTIME" and .environment == "dev" and
    (.gitopsRevision | test("^[0-9a-f]{40}$")) and (.clusterArn | test("^arn:aws:eks:[a-z0-9-]+:[0-9]{12}:cluster/.+")) and
    (.source | (keys | sort) == ["namespace","pvcName","pvcUid","statefulSet","volumeName"] and .namespace == "app-dev" and .statefulSet == "sample-app-postgresql") and
    (.writers == {applicationReplicas:0,migrationActive:0,migrationPending:0}) and
    (.database | .desiredReplicas == 0 and .readyReplicas == 0 and .shutdownSignal == "SIGTERM" and .cleanShutdownObserved == true and (.cleanShutdownEvidenceId | test("^sha256:[0-9a-f]{64}$"))) and
    (.storage == {mountedPodUids:[],volumeAttachmentNames:[]}) and
    (.checksum.algorithm == "sha256" and (.checksum.value | test("^sha256:[0-9a-f]{64}$")) and (.checksum.capturedAt | fromdateiso8601)) and
    (.checksum.capturedAt | fromdateiso8601) < (.database.stoppedAt | fromdateiso8601) and
    (.database.stoppedAt | fromdateiso8601) <= (.observedAt | fromdateiso8601) and (.observedAt | fromdateiso8601) < (.expiresAt | fromdateiso8601)
  ' "$file" >/dev/null || fail "snapshot quiesce evidence failed exact-key, writer, detach, or ordering contract"
}

if [[ -n "$fixture" ]]; then
  [[ "$fixture" != "$output" ]] || fail "fixture cannot be the runtime evidence path"
  validate "$fixture"
  echo "[STATIC] snapshot quiesce fixture validated; no runtime evidence written."
  exit 0
fi

[[ "${1:-}" == "preflight" ]] || { echo "Usage: $0 preflight [--fixture path]" >&2; exit 2; }
[[ -f "$output" ]] || fail "SNAPSHOT_QUIESCE_BLOCKED: A1 evidence is missing"
validate "$output"
namespace=app-dev
ss=$(kubectl -n "$namespace" get statefulset sample-app-postgresql -o json)
[[ $(jq -r '.spec.replicas' <<<"$ss") == 0 ]] || fail "SNAPSHOT_QUIESCE_BLOCKED: database is not scaled to zero"
source_pvc=$(jq -r '.source.pvcName' "$output")
[[ $(kubectl -n "$namespace" get pods -o json | jq --arg pvc "$source_pvc" '[.items[] | select(any(.spec.volumes[]?; .persistentVolumeClaim.claimName == $pvc))] | length') == 0 ]] || fail "SNAPSHOT_QUIESCE_BLOCKED: source PVC remains mounted"
source_volume=$(jq -r '.source.volumeName' "$output")
[[ $(kubectl get volumeattachment -o json | jq --arg volume "$source_volume" '[.items[] | select(.spec.source.persistentVolumeName == $volume)] | length') == 0 ]] || fail "SNAPSHOT_QUIESCE_BLOCKED: source volume attachment remains"
echo "[CLOUD_RUNTIME] snapshot preflight passed live writer, replica, and mount checks; capture remains a separate approved phase."
