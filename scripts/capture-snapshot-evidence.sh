#!/usr/bin/env bash
set -Eeuo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
repository_root=$(cd -- "$script_dir/.." && pwd -P)
canonical_phase="$repository_root/envs/dev/snapshot-maintenance-values.yaml"
canonical_a1="$repository_root/evidence/recovery/snapshot-quiesce-a1.json"
canonical_output="$repository_root/evidence/recovery/snapshot-quiesce.json"
phase_values=$canonical_phase
a1=$canonical_a1
a1_output=$canonical_a1
output=$canonical_output
now_override=
adapter_dir=${COURSE_CHECK_BIN_DIR:-}
overridden=false

fail() { echo "FAIL: $*" >&2; exit 1; }
usage() {
  echo "Usage: $0 prepare | capture | preflight | --fixture <snapshot-quiesce.json>" >&2
  exit 2
}
require_regular_file() { [[ -f "$1" && ! -L "$1" ]] || fail "$2 must be a regular non-symlink file"; }
physical_file() {
  local parent
  parent=$(cd -- "$(dirname -- "$1")" && pwd -P) || return 1
  printf '%s/%s\n' "$parent" "$(basename -- "$1")"
}
sha256_file() { shasum -a 256 "$1" | awk '{print "sha256:" $1}'; }
canonical_clock() {
  jq -en --arg value "$1" '
    $value | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$") and
    (try ((fromdateiso8601 | strftime("%Y-%m-%dT%H:%M:%SZ")) == $value) catch false)
  ' >/dev/null
}

validate_phase() {
  local file=$1 replicas=$2 label=A2
  [[ "$replicas" == 1 ]] && label=A1
  require_regular_file "$file" 'snapshot lifecycle phase values'
  yq -o=json -I=0 '.' "$file" | jq -e --argjson replicas "$replicas" '
    (keys | sort) == ["database","maintenance","recovery","snapshot"] and
    (.database | (keys | sort) == ["enabled","migration","replicaCount"] and
      .enabled == true and .replicaCount == $replicas and
      (.migration | keys) == ["enabled"] and .migration.enabled == false) and
    .maintenance == {writersStopped:true} and
    .snapshot == {captureEnabled:false} and
    .recovery == {restoreEnabled:false}
  ' >/dev/null || fail "snapshot lifecycle values are not the exact $label phase"
}

validate_a1() {
  local file=$1 grade=$2 validation_now=${3:-}
  require_regular_file "$file" 'snapshot A1 record'
  jq -e --arg grade "$grade" --arg now "$validation_now" '
    def nonblank: type == "string" and test("[^[:space:]\uFEFF]");
    def canonical_utc_seconds:
      . as $value | type == "string" and
      test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$") and
      (try ((fromdateiso8601 | strftime("%Y-%m-%dT%H:%M:%SZ")) == $value) catch false);
    . as $record |
    (keys | sort) == ["checksum","clusterArn","environment","evidenceGrade","gitopsRevision","phaseValuesDigest","phaseValuesFile","region","schemaVersion","source","writers"] and
    .schemaVersion == "course.snapshot-quiesce-a1/v1" and .evidenceGrade == $grade and
    .environment == "dev" and (.region | IN("ap-northeast-2","us-east-1")) and
    (.clusterArn | test("^arn:aws:eks:" + $record.region + ":[0-9]{12}:cluster/[A-Za-z0-9][A-Za-z0-9_-]{0,99}$")) and
    (.gitopsRevision | test("^[0-9a-f]{40}$")) and
    .phaseValuesFile == "envs/dev/snapshot-maintenance-values.yaml" and
    (.phaseValuesDigest | test("^sha256:[0-9a-f]{64}$")) and
    (.source | (keys | sort) == ["containerName","databaseImage","namespace","podName","podUid","pvcName","pvcUid","statefulSet","volumeName"] and
      .namespace == "app-dev" and .statefulSet == "mini-commerce-postgresql" and
      .pvcName == "data-mini-commerce-postgresql-0" and .podName == "mini-commerce-postgresql-0" and
      .containerName == "postgresql" and
      ([.podUid,.pvcUid,.volumeName] | all(. | nonblank)) and
      (.databaseImage | test("^[^[:space:]@]+@sha256:[0-9a-f]{64}$"))) and
    .writers == {applicationReplicas:0,migrationActive:0,migrationPending:0} and
    (.checksum | (keys | sort) == ["algorithm","capturedAt","value"] and .algorithm == "sha256" and
      (.value | test("^sha256:[0-9a-f]{64}$")) and (.capturedAt | canonical_utc_seconds)) and
    ($now == "" or (($now | canonical_utc_seconds) and
      (.checksum.capturedAt | fromdateiso8601) <= ($now | fromdateiso8601) and
      (($now | fromdateiso8601) - (.checksum.capturedAt | fromdateiso8601)) <= 1800))
  ' "$file" >/dev/null || fail 'snapshot A1 record failed exact identity, checksum, or freshness validation'
}

validate_record() {
  local file=$1 grade=$2 validation_now=${3:-}
  require_regular_file "$file" 'snapshot quiesce evidence'
  jq -e --arg grade "$grade" --arg now "$validation_now" '
    def nonblank: type == "string" and test("[^[:space:]\uFEFF]");
    def canonical_utc_seconds:
      . as $value | type == "string" and
      test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$") and
      (try ((fromdateiso8601 | strftime("%Y-%m-%dT%H:%M:%SZ")) == $value) catch false);
    . as $record |
    (keys | sort) == ["checksum","clusterArn","database","environment","evidenceGrade","expiresAt","gitopsRevision","observedAt","region","schemaVersion","source","storage","writers"] and
    .schemaVersion == "course.snapshot-quiesce/v1" and .evidenceGrade == $grade and .environment == "dev" and
    (.region | IN("ap-northeast-2","us-east-1")) and
    (.clusterArn | test("^arn:aws:eks:" + $record.region + ":[0-9]{12}:cluster/[A-Za-z0-9][A-Za-z0-9_-]{0,99}$")) and
    (.gitopsRevision | test("^[0-9a-f]{40}$")) and
    (.source | (keys | sort) == ["namespace","pvcName","pvcUid","statefulSet","volumeName"] and
      .namespace == "app-dev" and .statefulSet == "mini-commerce-postgresql" and
      .pvcName == "data-mini-commerce-postgresql-0" and ([.pvcUid,.volumeName] | all(. | nonblank))) and
    .writers == {applicationReplicas:0,migrationActive:0,migrationPending:0} and
    (.database | (keys | sort) == ["cleanShutdownEvidenceId","cleanShutdownObserved","desiredReplicas","readyReplicas","shutdownSignal","stoppedAt"] and
      .desiredReplicas == 0 and .readyReplicas == 0 and .shutdownSignal == "SIGINT" and
      .cleanShutdownObserved == true and (.cleanShutdownEvidenceId | test("^sha256:[0-9a-f]{64}$")) and
      (.stoppedAt | canonical_utc_seconds)) and
    .storage == {mountedPodUids:[],volumeAttachmentNames:[]} and
    (.checksum | (keys | sort) == ["algorithm","capturedAt","value"] and .algorithm == "sha256" and
      (.value | test("^sha256:[0-9a-f]{64}$")) and (.capturedAt | canonical_utc_seconds)) and
    (.observedAt | canonical_utc_seconds) and (.expiresAt | canonical_utc_seconds) and
    (.checksum.capturedAt | fromdateiso8601) < (.database.stoppedAt | fromdateiso8601) and
    (.database.stoppedAt | fromdateiso8601) <= (.observedAt | fromdateiso8601) and
    (.observedAt | fromdateiso8601) < (.expiresAt | fromdateiso8601) and
    ((.expiresAt | fromdateiso8601) - (.observedAt | fromdateiso8601)) <= 7200 and
    ($now == "" or (($now | canonical_utc_seconds) and
      (.observedAt | fromdateiso8601) <= ($now | fromdateiso8601) and
      ($now | fromdateiso8601) < (.expiresAt | fromdateiso8601)))
  ' "$file" >/dev/null || fail 'snapshot quiesce evidence failed exact identity, detach, timestamp, or ordering validation'
}

write_atomic() {
  local source=$1 destination=$2 label=$3 parent tmp
  mkdir -p "$(dirname -- "$destination")"
  parent=$(cd -- "$(dirname -- "$destination")" && pwd -P) || fail "unable to resolve $label output parent"
  tmp=$(mktemp "$parent/.snapshot-evidence.XXXXXX")
  chmod 600 "$tmp"
  cp "$source" "$tmp"
  chmod 600 "$tmp"
  if [[ -e "$destination" ]]; then
    require_regular_file "$destination" "existing $label"
    cmp -s "$tmp" "$destination" || { rm -f -- "$tmp"; fail "existing $label differs from this immutable capture"; }
    rm -f -- "$tmp"
  else
    mv "$tmp" "$destination"
  fi
}

query_cluster() {
  local cluster kubeconfig
  cluster=$(aws eks describe-cluster --name "$EKS_CLUSTER_NAME" --region "$AWS_REGION" --output json) || fail 'unable to describe the Dev EKS cluster'
  cluster_arn=$(jq -er '.cluster.arn' <<<"$cluster") || fail 'Dev EKS cluster ARN is missing'
  cluster_endpoint=$(jq -er '.cluster.endpoint' <<<"$cluster") || fail 'Dev EKS endpoint is missing'
  jq -e --arg name "$EKS_CLUSTER_NAME" --arg region "$AWS_REGION" '
    .cluster.name == $name and .cluster.status == "ACTIVE" and
    (.cluster.arn | test("^arn:aws:eks:"+$region+":[0-9]{12}:cluster/"+$name+"$")) and
    (.cluster.endpoint | type == "string" and startswith("https://"))
  ' <<<"$cluster" >/dev/null || fail 'Dev EKS identity, Region, account, or status is invalid'
  kubeconfig=$(kubectl config view --minify -o json) || fail 'unable to inspect the active Kubernetes context'
  [[ $(jq -r '.clusters | length' <<<"$kubeconfig") == 1 && $(jq -r '.clusters[0].cluster.server' <<<"$kubeconfig") == "$cluster_endpoint" ]] ||
    fail 'active Kubernetes context differs from the Dev EKS cluster'
}

query_application() {
  local revision=$1 final=${2:-false} application
  application=$(argocd app get mini-commerce-dev -o json) || fail 'unable to query mini-commerce-dev from Argo CD'
  jq -e --arg revision "$revision" --argjson final "$final" '
    .metadata.name == "mini-commerce-dev" and .status.sync.revision == $revision and
    (.spec.source.repoURL | test("^https://github\\.com/[^/[:space:]]+/argocd-gitops(\\.git)?$")) and
    .spec.source.helm.valueFiles == ["../../envs/dev/values.yaml","../../envs/dev/stateful-values.yaml","../../envs/dev/snapshot-maintenance-values.yaml"] and
    .spec.syncPolicy.automated.prune == true and .spec.syncPolicy.automated.selfHeal == true and
    (if $final then
      .status.sync.status == "Synced" and .status.health.status == "Healthy" and ((.status.operationState.phase // "") | IN("","Succeeded"))
     else
      (.status.sync.status | IN("Synced","OutOfSync")) and (.status.health.status | IN("Healthy","Progressing")) and
      ((.status.operationState.phase // "") | IN("","Succeeded","Running"))
     end)
  ' <<<"$application" >/dev/null || fail 'Argo desired revision, phase values, automation, or health is not the reviewed snapshot phase'
}

query_writers() {
  local deployment jobs
  deployment=$(kubectl -n app-dev get deployment mini-commerce -o json) || fail 'unable to query application writer Deployment'
  application_replicas=$(jq -er '(.status.readyReplicas // 0) as $ready |
    if .metadata.name == "mini-commerce" and .metadata.namespace == "app-dev" and .spec.replicas == 0 and
       (.status.replicas // 0) == 0 and $ready == 0 and (.status.availableReplicas // 0) == 0 then 0 else empty end' <<<"$deployment") ||
    fail 'application writers are not fully stopped'
  jobs=$(kubectl -n app-dev get jobs -l app.kubernetes.io/part-of=mini-commerce,app.kubernetes.io/component=migration -o json) || fail 'unable to query migration writers'
  migration_active=$(jq '[.items[] | (.status.active // 0)] | add // 0' <<<"$jobs")
  migration_pending=$(jq '[.items[] | select((.status.active // 0) == 0 and (.status.succeeded // 0) == 0 and (.status.failed // 0) == 0)] | length' <<<"$jobs")
  [[ "$migration_active" == 0 && "$migration_pending" == 0 ]] || fail 'migration writers are active or pending'
}

query_pvc_pv() {
  local pvc pv
  pvc=$(kubectl -n app-dev get pvc data-mini-commerce-postgresql-0 -o json) || fail 'unable to query source PVC'
  pvc_uid=$(jq -er '.metadata.uid' <<<"$pvc") || fail 'source PVC UID is missing'
  volume_name=$(jq -er '.spec.volumeName' <<<"$pvc") || fail 'source PVC volumeName is missing'
  jq -e '
    def nonblank: type == "string" and test("[^[:space:]\uFEFF]");
    .metadata.name == "data-mini-commerce-postgresql-0" and .metadata.namespace == "app-dev" and
    (.metadata.uid | nonblank) and (.spec.volumeName | nonblank) and .status.phase == "Bound"
  ' <<<"$pvc" >/dev/null || fail 'source PVC is not the exact Bound snapshot source'
  pv=$(kubectl get pv "$volume_name" -o json) || fail 'unable to query source PV'
  jq -e --arg name "$volume_name" --arg uid "$pvc_uid" '
    .metadata.name == $name and .status.phase == "Bound" and
    .spec.claimRef == {namespace:"app-dev",name:"data-mini-commerce-postgresql-0",uid:$uid} and
    .spec.csi.driver == "ebs.csi.aws.com" and (.spec.csi.volumeHandle | test("^vol-[0-9a-f]{8,64}$"))
  ' <<<"$pv" >/dev/null || fail 'source PV claim, CSI driver, or EBS volume identity differs'
}

require_no_snapshot() {
  local snapshots
  snapshots=$(kubectl -n app-dev get volumesnapshot -o json --ignore-not-found) || fail 'unable to prove that no source VolumeSnapshot exists'
  [[ $(jq -r '.items | length' <<<"$snapshots") == 0 ]] || fail 'VolumeSnapshot already exists before A3'
}

query_a1_database() {
  local statefulset pods attachments
  statefulset=$(kubectl -n app-dev get statefulset mini-commerce-postgresql -o json) || fail 'unable to query the A1 database StatefulSet'
  statefulset_uid=$(jq -er '.metadata.uid' <<<"$statefulset") || fail 'database StatefulSet UID is missing'
  jq -e '
    .metadata.name == "mini-commerce-postgresql" and .metadata.namespace == "app-dev" and .spec.replicas == 1 and
    .status.observedGeneration == .metadata.generation and .status.currentReplicas == 1 and
    .status.updatedReplicas == 1 and .status.readyReplicas == 1
  ' <<<"$statefulset" >/dev/null || fail 'A1 database must have exactly one current ready replica'
  pods=$(kubectl -n app-dev get pods -l app.kubernetes.io/name=postgresql,app.kubernetes.io/instance=mini-commerce -o json) || fail 'unable to query the A1 database Pod'
  jq -e --arg owner "$statefulset_uid" '
    .items | length == 1 and .[0].metadata.name == "mini-commerce-postgresql-0" and
    ([.[0].metadata.ownerReferences[] | select(.apiVersion == "apps/v1" and .kind == "StatefulSet" and
      .name == "mini-commerce-postgresql" and .uid == $owner and .controller == true)] | length) == 1 and
    .[0].status.phase == "Running" and any(.[0].status.conditions[]; .type == "Ready" and .status == "True") and
    any(.[0].spec.volumes[]; .persistentVolumeClaim.claimName == "data-mini-commerce-postgresql-0") and
    ([.[0].spec.containers[] | select(.name == "postgresql" and (.image | test("^[^[:space:]@]+@sha256:[0-9a-f]{64}$")))] | length) == 1
  ' <<<"$pods" >/dev/null || fail 'A1 database Pod ownership, readiness, mount, or digest is invalid'
  pod_name=$(jq -r '.items[0].metadata.name' <<<"$pods")
  pod_uid=$(jq -r '.items[0].metadata.uid' <<<"$pods")
  database_image=$(jq -r '.items[0].spec.containers[] | select(.name == "postgresql") | .image' <<<"$pods")
  attachments=$(kubectl get volumeattachment -o json) || fail 'unable to query A1 VolumeAttachments'
  jq -e --arg volume "$volume_name" '[.items[] | select(.spec.source.persistentVolumeName == $volume and .status.attached == true)] | length == 1' <<<"$attachments" >/dev/null ||
    fail 'A1 source volume must have exactly one live attachment'
}

query_a2_detach() {
  local statefulset db_pods all_pods attachments
  statefulset=$(kubectl -n app-dev get statefulset mini-commerce-postgresql -o json) || fail 'unable to query the A2 database StatefulSet'
  jq -e '
    .metadata.name == "mini-commerce-postgresql" and .metadata.namespace == "app-dev" and .spec.replicas == 0 and
    .status.observedGeneration == .metadata.generation and (.status.currentReplicas // 0) == 0 and
    (.status.updatedReplicas // 0) == 0 and (.status.readyReplicas // 0) == 0
  ' <<<"$statefulset" >/dev/null || fail 'A2 database has not converged to zero replicas'
  db_pods=$(kubectl -n app-dev get pods -l app.kubernetes.io/name=postgresql,app.kubernetes.io/instance=mini-commerce -o json) ||
    fail 'unable to query remaining database Pods'
  [[ $(jq -r '.items | length' <<<"$db_pods") == 0 ]] || fail 'database Pod remains after A2 scale-to-zero'
  all_pods=$(kubectl -n app-dev get pods -o json) || fail 'unable to query PVC mounts'
  mounted_pod_uids=$(jq -c --arg pvc data-mini-commerce-postgresql-0 '[.items[] | select(any(.spec.volumes[]?; .persistentVolumeClaim.claimName == $pvc)) | .metadata.uid]' <<<"$all_pods")
  [[ "$mounted_pod_uids" == '[]' ]] || fail 'source PVC remains mounted by a Pod'
  attachments=$(kubectl get volumeattachment -o json) || fail 'unable to query final VolumeAttachments'
  volume_attachment_names=$(jq -c --arg volume "$volume_name" '[.items[] | select(.spec.source.persistentVolumeName == $volume) | .metadata.name]' <<<"$attachments")
  [[ "$volume_attachment_names" == '[]' ]] || fail 'source PV remains attached through CSI'
}

live_preflight() {
  local evidence=$1 revision
  revision=$(jq -r '.gitopsRevision' "$evidence")
  query_application "$revision" true
  query_cluster
  [[ "$cluster_arn" == "$(jq -r '.clusterArn' "$evidence")" ]] || fail 'fresh EKS identity differs from snapshot evidence'
  query_writers
  query_pvc_pv
  [[ "$pvc_uid" == "$(jq -r '.source.pvcUid' "$evidence")" && "$volume_name" == "$(jq -r '.source.volumeName' "$evidence")" ]] ||
    fail 'fresh PVC or PV identity differs from snapshot evidence'
  query_a2_detach
  require_no_snapshot
}

fixture=
mode=${1:-}
if [[ "$mode" == --fixture ]]; then
  fixture=${2:?missing fixture}
  [[ $# -eq 2 ]] || usage
  validate_record "$fixture" CLOUD_RUNTIME
  echo '[STATIC] snapshot quiesce fixture validated; no runtime evidence written.'
  exit 0
fi
[[ "$mode" == prepare || "$mode" == capture || "$mode" == preflight ]] || usage
shift
while (($#)); do
  case "$1" in
    --a1) a1=${2:?missing A1 record}; overridden=true; shift 2 ;;
    --a1-output) a1_output=${2:?missing A1 output}; overridden=true; shift 2 ;;
    --output) output=${2:?missing output}; overridden=true; shift 2 ;;
    --phase-values) phase_values=${2:?missing phase values}; overridden=true; shift 2 ;;
    --now) now_override=${2:?missing clock}; overridden=true; shift 2 ;;
    *) usage ;;
  esac
done

evidence_grade=CLOUD_RUNTIME
clock_now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
if [[ -n "$adapter_dir" ]]; then
  [[ "$overridden" == true && -n "$now_override" ]] || fail 'static runtime adapter requires explicit noncanonical paths and clock'
  PATH="$adapter_dir:$PATH"
  evidence_grade=STATIC
  clock_now=$now_override
  if [[ "$mode" == prepare ]]; then adapter_paths=("$phase_values" "$a1_output"); else adapter_paths=("$phase_values" "$a1" "$output"); fi
  for candidate in "${adapter_paths[@]}"; do
    [[ "$candidate" != "$repository_root/evidence/"* && "$candidate" != "$repository_root/tests/fixtures/"* ]] ||
      fail 'static runtime adapter path must be noncanonical and outside fixtures'
  done
else
  [[ "$overridden" == false ]] || fail 'live snapshot producer phase, evidence paths, and clock are fixed'
  [[ "$(physical_file "$phase_values")" == "$canonical_phase" ]] || fail 'live snapshot phase values escaped the canonical path'
fi
canonical_clock "$clock_now" || fail 'capture clock must be canonical UTC seconds'
for command in argocd aws git kubectl; do command -v "$command" >/dev/null || fail "$command is required for live snapshot capture"; done
[[ ${AWS_REGION:-} == ap-northeast-2 || ${AWS_REGION:-} == us-east-1 ]] || fail 'AWS_REGION must be ap-northeast-2 or us-east-1'
[[ ${EKS_CLUSTER_NAME:-} =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,99}$ ]] || fail 'EKS_CLUSTER_NAME is invalid'

if [[ "$mode" == preflight ]]; then
  [[ -z "$adapter_dir" && "$overridden" == false ]] || fail 'preflight uses only canonical CLOUD_RUNTIME evidence'
  [[ -f "$canonical_output" ]] || fail 'SNAPSHOT_QUIESCE_BLOCKED: A2 evidence is missing'
  validate_record "$canonical_output" CLOUD_RUNTIME "$clock_now"
  live_preflight "$canonical_output"
  echo '[CLOUD_RUNTIME] snapshot preflight passed fresh GitOps, writer, replica, PVC, mount, attachment, and no-snapshot checks.'
  exit 0
fi

[[ -z $(git -C "$repository_root" status --short --untracked-files=no) ]] || fail 'tracked GitOps source must match the checked-out commit'
local_revision=$(git -C "$repository_root" rev-parse HEAD)
[[ "$local_revision" =~ ^[0-9a-f]{40}$ ]] || fail 'local GitOps revision is not a full commit SHA'
if [[ "$mode" == prepare ]]; then expected_replicas=1; final_application=true; else expected_replicas=0; final_application=false; fi
validate_phase "$phase_values" "$expected_replicas"
query_application "$local_revision" "$final_application"
query_cluster
query_writers
query_pvc_pv
require_no_snapshot

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/snapshot-evidence.XXXXXX")
watcher_pid=
cleanup_work() {
  if [[ -n "$watcher_pid" ]] && kill -0 "$watcher_pid" 2>/dev/null; then kill "$watcher_pid" 2>/dev/null || true; fi
  rm -rf -- "$work_dir"
}
trap cleanup_work EXIT

if [[ "$mode" == prepare ]]; then
  query_a1_database
  checksum_command=$(cat <<'COMMAND'
psql -X -A -t -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<'SQL'
SELECT jsonb_build_object(
  'schemaVersion', 'course.snapshot-checksum/v1',
  'foreignKeyViolations', (SELECT count(*) FROM order_items oi LEFT JOIN orders o ON o.id=oi.order_id LEFT JOIN products p ON p.id=oi.product_id WHERE o.id IS NULL OR p.id IS NULL),
  'duplicateIdempotencyKeys', (SELECT count(*) FROM (SELECT idempotency_key FROM orders GROUP BY idempotency_key HAVING count(*) > 1) duplicates),
  'negativeInventoryRows', (SELECT count(*) FROM inventory WHERE available_quantity < 0),
  'canonicalRows', jsonb_build_array(
    jsonb_build_object('table','products','rows',(SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY id),'[]'::jsonb) FROM products t)),
    jsonb_build_object('table','inventory','rows',(SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY product_id),'[]'::jsonb) FROM inventory t)),
    jsonb_build_object('table','orders','rows',(SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY id),'[]'::jsonb) FROM orders t)),
    jsonb_build_object('table','order_items','rows',(SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY id),'[]'::jsonb) FROM order_items t))
  )
);
SQL
COMMAND
)
  checksum_payload=$(kubectl -n app-dev exec "$pod_name" -c postgresql -- sh -ec "$checksum_command") ||
    fail 'canonical invariant/checksum query failed against the readable A1 database'
  jq -e '
    (keys | sort) == ["canonicalRows","duplicateIdempotencyKeys","foreignKeyViolations","negativeInventoryRows","schemaVersion"] and
    .schemaVersion == "course.snapshot-checksum/v1" and
    .foreignKeyViolations == 0 and .duplicateIdempotencyKeys == 0 and .negativeInventoryRows == 0 and
    [.canonicalRows[].table] == ["products","inventory","orders","order_items"]
  ' <<<"$checksum_payload" >/dev/null || fail 'A1 checksum query reported an invariant violation or malformed row set'
  checksum_canonical=$(jq -cS '.' <<<"$checksum_payload") || fail 'unable to canonicalize the A1 checksum row set'
  checksum_value="sha256:$(printf '%s\n' "$checksum_canonical" | shasum -a 256 | awk '{print $1}')"
  unset checksum_payload checksum_canonical
  phase_digest=$(sha256_file "$phase_values")
  record="$work_dir/a1.json"
  jq -n --arg grade "$evidence_grade" --arg region "$AWS_REGION" --arg arn "$cluster_arn" \
    --arg revision "$local_revision" --arg phaseDigest "$phase_digest" --arg podUid "$pod_uid" \
    --arg pvcUid "$pvc_uid" --arg volume "$volume_name" --arg image "$database_image" \
    --arg checksum "$checksum_value" --arg captured "$clock_now" '
    {schemaVersion:"course.snapshot-quiesce-a1/v1",evidenceGrade:$grade,environment:"dev",
     region:$region,clusterArn:$arn,gitopsRevision:$revision,
     phaseValuesFile:"envs/dev/snapshot-maintenance-values.yaml",phaseValuesDigest:$phaseDigest,
     source:{namespace:"app-dev",statefulSet:"mini-commerce-postgresql",pvcName:"data-mini-commerce-postgresql-0",
       pvcUid:$pvcUid,volumeName:$volume,podName:"mini-commerce-postgresql-0",podUid:$podUid,
       containerName:"postgresql",databaseImage:$image},
     writers:{applicationReplicas:0,migrationActive:0,migrationPending:0},
     checksum:{algorithm:"sha256",value:$checksum,capturedAt:$captured}}
  ' >"$record"
  validate_a1 "$record" "$evidence_grade" "$clock_now"
  write_atomic "$record" "$a1_output" 'snapshot A1 record'
  echo "[$evidence_grade] wrote A1 checksum handoff $a1_output; commit only replicaCount 1 to 0, then run capture during Argo Sync."
  exit 0
fi

validate_a1 "$a1" "$evidence_grade" "$clock_now"
a1_revision=$(jq -r '.gitopsRevision' "$a1")
[[ "$local_revision" != "$a1_revision" ]] || fail 'A2 must be a new Git commit after A1'
git -C "$repository_root" merge-base --is-ancestor "$a1_revision" HEAD || fail 'A1 revision is not an ancestor of the A2 HEAD'
diff_names=$(git -C "$repository_root" diff --name-only "$a1_revision" HEAD) || fail 'unable to compare A1 and A2 Git revisions'
[[ "$diff_names" == 'envs/dev/snapshot-maintenance-values.yaml' ]] || fail 'A2 commit must change only the canonical snapshot maintenance values file'
git -C "$repository_root" show "$a1_revision:envs/dev/snapshot-maintenance-values.yaml" >"$work_dir/a1-phase-values.yaml" ||
  fail 'unable to read A1 phase values from the captured revision'
validate_phase "$work_dir/a1-phase-values.yaml" 1
[[ "$(sha256_file "$work_dir/a1-phase-values.yaml")" == "$(jq -r '.phaseValuesDigest' "$a1")" ]] ||
  fail 'A1 phase values bytes differ from the captured digest'
a2_phase_digest=$(sha256_file "$phase_values")
[[ "$(jq -r '.clusterArn' "$a1")" == "$cluster_arn" ]] || fail 'A2 EKS identity differs from A1'
[[ "$(jq -r '.source.pvcUid' "$a1")" == "$pvc_uid" && "$(jq -r '.source.volumeName' "$a1")" == "$volume_name" ]] ||
  fail 'A2 source PVC/PV identity differs from A1'

start_pod=$(kubectl -n app-dev get pod "$(jq -r '.source.podName' "$a1")" -o json --ignore-not-found) ||
  fail 'unable to query the A1 database Pod before its GitOps termination'
jq -e --arg uid "$(jq -r '.source.podUid' "$a1")" --arg image "$(jq -r '.source.databaseImage' "$a1")" '
  .metadata.name == "mini-commerce-postgresql-0" and .metadata.uid == $uid and
  any(.spec.volumes[]; .persistentVolumeClaim.claimName == "data-mini-commerce-postgresql-0") and
  any(.spec.containers[]; .name == "postgresql" and .image == $image)
' <<<"$start_pod" >/dev/null || fail 'A1 database Pod identity changed before the A2 shutdown watcher started'

shutdown_log="$work_dir/postgresql-shutdown.log"
kubectl -n app-dev logs -f mini-commerce-postgresql-0 -c postgresql --timestamps >"$shutdown_log" 2>"$work_dir/log-error" &
watcher_pid=$!
converged=false
for _ in {1..60}; do
  if statefulset=$(kubectl -n app-dev get statefulset mini-commerce-postgresql -o json 2>/dev/null) &&
     jq -e '.spec.replicas == 0 and .status.observedGeneration == .metadata.generation and
       (.status.currentReplicas // 0) == 0 and (.status.readyReplicas // 0) == 0 and (.status.updatedReplicas // 0) == 0' <<<"$statefulset" >/dev/null; then
    converged=true
    break
  fi
  sleep 2
done
[[ "$converged" == true ]] || fail 'A2 GitOps scale-to-zero did not converge within the bounded wait'
for _ in {1..30}; do
  kill -0 "$watcher_pid" 2>/dev/null || break
  sleep 1
done
if kill -0 "$watcher_pid" 2>/dev/null; then fail 'PostgreSQL shutdown log watcher exceeded its bounded wait'; fi
if ! wait "$watcher_pid"; then fail 'PostgreSQL shutdown log watcher failed'; fi
watcher_pid=

smart_entry=$(grep -nF 'received fast shutdown request' "$shutdown_log" | tail -1) || fail 'PostgreSQL did not log the expected image SIGINT fast-shutdown request'
clean_entry=$(grep -nF 'database system is shut down' "$shutdown_log" | tail -1) || fail 'PostgreSQL did not log clean shutdown completion'
smart_line=${smart_entry%%:*}; clean_line=${clean_entry%%:*}
((smart_line < clean_line)) || fail 'PostgreSQL clean-shutdown log preceded its SIGINT request'
stopped_raw=${clean_entry#*:}; stopped_raw=${stopped_raw%% *}
if [[ "$stopped_raw" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(\.[0-9]+)?Z$ ]]; then
  stopped_at="${BASH_REMATCH[1]}Z"
else
  fail 'PostgreSQL clean-shutdown log timestamp is not canonicalizable UTC'
fi
canonical_clock "$stopped_at" || fail 'PostgreSQL shutdown timestamp is not a real UTC second'
shutdown_digest=$(sha256_file "$shutdown_log")

query_application "$local_revision" true
query_writers
query_pvc_pv
[[ "$(jq -r '.source.pvcUid' "$a1")" == "$pvc_uid" && "$(jq -r '.source.volumeName' "$a1")" == "$volume_name" ]] ||
  fail 'source PVC/PV identity changed during A2 shutdown'
query_a2_detach
require_no_snapshot
[[ -z $(git -C "$repository_root" status --short --untracked-files=no) &&
   $(git -C "$repository_root" rev-parse HEAD) == "$local_revision" &&
   $(sha256_file "$phase_values") == "$a2_phase_digest" ]] || fail 'GitOps HEAD or A2 phase values changed during snapshot capture'
expires_at=$(jq -nr --arg now "$clock_now" '(($now | fromdateiso8601) + 3600) | strftime("%Y-%m-%dT%H:%M:%SZ")')
record="$work_dir/snapshot-quiesce.json"
jq -n --arg grade "$evidence_grade" --arg region "$AWS_REGION" --arg arn "$cluster_arn" \
  --arg revision "$local_revision" --arg pvcUid "$pvc_uid" --arg volume "$volume_name" \
  --arg shutdown "$shutdown_digest" --arg stopped "$stopped_at" \
  --arg checksum "$(jq -r '.checksum.value' "$a1")" --arg captured "$(jq -r '.checksum.capturedAt' "$a1")" \
  --arg observed "$clock_now" --arg expires "$expires_at" '
  {schemaVersion:"course.snapshot-quiesce/v1",evidenceGrade:$grade,environment:"dev",
   region:$region,clusterArn:$arn,gitopsRevision:$revision,
   source:{namespace:"app-dev",statefulSet:"mini-commerce-postgresql",pvcName:"data-mini-commerce-postgresql-0",pvcUid:$pvcUid,volumeName:$volume},
   writers:{applicationReplicas:0,migrationActive:0,migrationPending:0},
   database:{desiredReplicas:0,readyReplicas:0,shutdownSignal:"SIGINT",cleanShutdownObserved:true,
     cleanShutdownEvidenceId:$shutdown,stoppedAt:$stopped},
   storage:{mountedPodUids:[],volumeAttachmentNames:[]},
   checksum:{algorithm:"sha256",value:$checksum,capturedAt:$captured},observedAt:$observed,expiresAt:$expires}
' >"$record"
validate_record "$record" "$evidence_grade" "$clock_now"
live_preflight "$record"
write_atomic "$record" "$output" 'snapshot quiesce evidence'
echo "[$evidence_grade] wrote $output after an immediate live preflight; A3 snapshot capture remains a separate Git commit."
