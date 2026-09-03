#!/usr/bin/env bash
set -Eeuo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
repository_root=$(cd -- "$script_dir/.." && pwd -P)
canonical_evidence="$repository_root/evidence/recovery/snapshot-ready.json"
canonical_output="$repository_root/envs/dev/recovery-values.yaml"
mode=live
evidence=$canonical_evidence
output=$canonical_output
validation_now=

fail() { echo "FAIL: $*" >&2; exit 1; }
usage() { echo "Usage: $0 | $0 --fixture <snapshot-ready.json> <output.yaml> --now <UTC>" >&2; exit 2; }
require_regular_file() { [[ -f "$1" && ! -L "$1" ]] || fail "$2 must be a regular non-symlink file"; }
physical_path() {
  local parent
  parent=$(cd -- "$(dirname -- "$1")" && pwd -P) || return 1
  printf '%s/%s\n' "$parent" "$(basename -- "$1")"
}

if (($#)); then
  [[ $# -eq 5 && $1 == --fixture && $4 == --now ]] || usage
  mode=fixture
  evidence=$2
  output=$3
  validation_now=$5
else
  validation_now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
fi

for command in jq mktemp yq; do command -v "$command" >/dev/null || fail "$command is required"; done
require_regular_file "$evidence" 'snapshot-ready evidence'

if [[ "$mode" == live ]]; then
  [[ "$(physical_path "$evidence")" == "$canonical_evidence" ]] || fail 'live evidence escaped its canonical path'
  [[ "$(physical_path "$output")" == "$canonical_output" ]] || fail 'live output escaped its canonical path'
else
  output_parent=$(cd -- "$(dirname -- "$output")" && pwd -P) || fail 'fixture output parent does not exist'
  resolved_output="$output_parent/$(basename -- "$output")"
  [[ "$resolved_output" != "$canonical_output" && "$resolved_output" != "$repository_root/tests/fixtures/"* ]] ||
    fail 'fixture mode cannot write canonical values or test fixtures'
fi

jq -e --arg now "$validation_now" '
  def canonical_utc_seconds:
    . as $value | type == "string" and
    test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$") and
    (try ((fromdateiso8601 | strftime("%Y-%m-%dT%H:%M:%SZ")) == $value) catch false);
  . as $record |
  (keys | sort) == ["clusterArn","environment","evidenceGrade","expiresAt","gitopsRevision","observedAt","recovery","region","schemaVersion","snapshot","source"] and
  .schemaVersion == "course.snapshot-ready/v1" and .evidenceGrade == "CLOUD_RUNTIME" and
  .environment == "dev" and (.region | IN("ap-northeast-2", "us-east-1")) and
  (.clusterArn | test("^arn:aws:eks:" + $record.region + ":[0-9]{12}:cluster/[A-Za-z0-9][A-Za-z0-9_-]{0,99}$")) and
  (.gitopsRevision | test("^[0-9a-f]{40}$")) and
  .source == {
    namespace:"app-dev",
    pvcName:"data-sample-app-postgresql-0",
    pvcUid:.source.pvcUid,
    volumeName:.source.volumeName,
    volumeHandle:.source.volumeHandle
  } and
  (.source.pvcUid | test("^[0-9a-f-]{36}$")) and (.source.volumeName | test("^pvc-[0-9a-f-]{36}$")) and
  (.source.volumeHandle | test("^vol-[0-9a-f]{8,64}$")) and
  .snapshot.namespace == "app-dev" and .snapshot.name == "sample-app-postgresql-snapshot" and
  (.snapshot.uid | test("^[0-9a-f-]{36}$")) and (.snapshot.contentUid | test("^[0-9a-f-]{36}$")) and
  (.snapshot.contentName | test("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$")) and
  .snapshot.className == "course-ebs-snapshots" and .snapshot.driver == "ebs.csi.aws.com" and
  (.snapshot.sourceVolumeHandle | test("^vol-[0-9a-f]{8,64}$")) and
  .snapshot.sourceVolumeHandle == .source.volumeHandle and
  (.snapshot.handle | test("^snap-[0-9a-f]{17}$")) and .snapshot.readyToUse == true and
  (.recovery.readerRoleArn | test("^arn:aws:iam::[0-9]{12}:role/[A-Za-z0-9+=,.@_/-]+$")) and
  (.recovery.normalReaderRoleArn | test("^arn:aws:iam::[0-9]{12}:role/[A-Za-z0-9+=,.@_/-]+$")) and
  .recovery.readerRoleArn != .recovery.normalReaderRoleArn and
  ($record.recovery.readerRoleArn | split(":")[4]) == ($record.recovery.normalReaderRoleArn | split(":")[4]) and
  (.observedAt | canonical_utc_seconds) and (.expiresAt | canonical_utc_seconds) and
  ((.observedAt | fromdateiso8601) < (.expiresAt | fromdateiso8601)) and
  ((.expiresAt | fromdateiso8601) - (.observedAt | fromdateiso8601) <= 3600) and
  ($now | canonical_utc_seconds) and
  ((.observedAt | fromdateiso8601) <= ($now | fromdateiso8601)) and
  (($now | fromdateiso8601) < (.expiresAt | fromdateiso8601))
' "$evidence" >/dev/null || fail 'snapshot-ready evidence is not a canonical live recovery source'

output_parent=$(dirname -- "$output")
mkdir -p "$output_parent"
tmp=$(mktemp "$output_parent/.recovery-values.XXXXXX")
trap 'rm -f -- "$tmp"' EXIT
jq -n --arg handle "$(jq -r '.snapshot.handle' "$evidence")" \
  --arg role "$(jq -r '.recovery.readerRoleArn' "$evidence")" '
  {
    database:{enabled:true,replicaCount:1,migration:{enabled:true}},
    recovery:{
      restoreEnabled:true,
      namespace:"app-recovery",
      readerRoleArn:$role,
      snapshotClassName:"course-ebs-snapshots",
      snapshotDriver:"ebs.csi.aws.com",
      snapshotContentName:"sample-app-postgresql-recovery-content",
      snapshotName:"sample-app-postgresql-recovery-snapshot",
      pvcName:"sample-app-postgresql-recovery",
      snapshotHandle:$handle,
      cleanupLabel:"recovery",
      source:{namespace:"app-dev",pvcName:"data-sample-app-postgresql-0",snapshotName:"sample-app-postgresql-snapshot"}
    },
    snapshot:{captureEnabled:false}
  }
' | yq -P >"$tmp"
chmod 600 "$tmp"
mv -f "$tmp" "$output"
trap - EXIT

if [[ "$mode" == live ]]; then
  echo "[CLOUD_RUNTIME] wrote reviewed recovery values to $output"
else
  echo "[STATIC] wrote noncanonical recovery values to $output"
fi
