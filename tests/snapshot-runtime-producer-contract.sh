#!/usr/bin/env bash
set -Eeuo pipefail

test_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
repository_root=$(cd -- "$test_root/.." && pwd -P)
script="$repository_root/scripts/capture-snapshot-evidence.sh"
canonical="$repository_root/evidence/recovery/snapshot-quiesce.json"
tmp_root=$(mktemp -d)
trap 'rm -rf -- "$tmp_root"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
fingerprint() {
  if [[ -f "$canonical" ]]; then shasum -a 256 "$canonical" | awk '{print "file:" $1}'
  elif [[ -e "$canonical" ]]; then echo other
  else echo absent
  fi
}
file_mode() { stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1"; }

before=$(fingerprint)
[[ -x "$script" ]] || fail 'snapshot runtime producer is missing or not executable'
head -1 "$script" | grep -Fqx '#!/usr/bin/env bash' || fail 'snapshot producer has the wrong shebang'
grep -Fq 'set -Eeuo pipefail' "$script" || fail 'snapshot producer is not fail-fast'

fake_bin="$tmp_root/bin"
runtime="$tmp_root/runtime"
mkdir -p "$fake_bin" "$runtime/a1" "$runtime/a2" "$runtime/ready"
for command in argocd aws git kubectl; do
  ln -s "$test_root/helpers/fake-snapshot-cli.sh" "$fake_bin/$command"
done
: >"$runtime/calls.log"
cp "$repository_root/envs/dev/snapshot-maintenance-values.yaml" "$runtime/a1/phase-values.yaml"
cp "$runtime/a1/phase-values.yaml" "$runtime/a2/phase-values.yaml"
yq -i '.database.replicaCount=0' "$runtime/a2/phase-values.yaml"
cat >"$runtime/ready/phase-values.yaml" <<'YAML'
database:
  enabled: true
  replicaCount: 0
  migration: {enabled: false}
maintenance: {writersStopped: true}
snapshot: {captureEnabled: true}
recovery:
  restoreEnabled: false
  namespace: app-recovery
  snapshotClassName: course-ebs-snapshots
  source:
    namespace: app-dev
    pvcName: data-sample-app-postgresql-0
    snapshotName: sample-app-postgresql-snapshot
YAML
printf '%s\n' 1111111111111111111111111111111111111111 >"$runtime/a1/git-revision.txt"
printf '%s\n' 2222222222222222222222222222222222222222 >"$runtime/a2/git-revision.txt"
printf '%s\n' 3333333333333333333333333333333333333333 >"$runtime/ready/git-revision.txt"
: >"$runtime/a1/git-status.txt"; : >"$runtime/a2/git-status.txt"; : >"$runtime/ready/git-status.txt"
printf '%s\n' envs/dev/snapshot-maintenance-values.yaml >"$runtime/a2/git-diff-names.txt"

for phase in a1 a2; do
  revision=$(cat "$runtime/$phase/git-revision.txt")
  jq -n --arg revision "$revision" '
    {metadata:{name:"sample-app-dev"},
     spec:{source:{repoURL:"https://github.com/OWNER/argocd-gitops.git",helm:{valueFiles:[
       "../../envs/dev/values.yaml","../../envs/dev/stateful-values.yaml","../../envs/dev/snapshot-maintenance-values.yaml"]}},
       syncPolicy:{automated:{prune:true,selfHeal:true}}},
     status:{sync:{status:"Synced",revision:$revision},health:{status:"Healthy"},operationState:{phase:"Succeeded"}}}
  ' >"$runtime/$phase/application.json"
  jq -n '{apiVersion:"batch/v1",kind:"JobList",items:[{status:{succeeded:1}}]}' >"$runtime/$phase/jobs.json"
  jq -n '{apiVersion:"snapshot.storage.k8s.io/v1",kind:"VolumeSnapshotList",items:[]}' >"$runtime/$phase/volumesnapshots.json"
done
jq -n '{metadata:{name:"sample-app-dev"},
  spec:{source:{repoURL:"https://github.com/OWNER/argocd-gitops.git",helm:{valueFiles:[
    "../../envs/dev/values.yaml","../../envs/dev/stateful-values.yaml","../../envs/dev/snapshot-capture-values.yaml"]}},
    syncPolicy:{automated:{prune:true,selfHeal:true}}},
  status:{sync:{status:"Synced",revision:"3333333333333333333333333333333333333333"},health:{status:"Healthy"},operationState:{phase:"Succeeded"}}}
' >"$runtime/ready/application.json"
jq -n '{cluster:{name:"course-dev",arn:"arn:aws:eks:ap-northeast-2:123456789012:cluster/course-dev",status:"ACTIVE",endpoint:"https://dev.eks.example"}}' >"$runtime/cluster.json"
jq -n '{clusters:[{cluster:{server:"https://dev.eks.example"}}]}' >"$runtime/kubeconfig.json"
jq -n '{metadata:{name:"sample-app",namespace:"app-dev"},spec:{replicas:0},status:{replicas:0,readyReplicas:0,availableReplicas:0}}' >"$runtime/deployment.json"
jq -n '{metadata:{name:"sample-app-postgresql",namespace:"app-dev",uid:"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",generation:7},spec:{replicas:1},status:{observedGeneration:7,currentReplicas:1,readyReplicas:1,updatedReplicas:1}}' >"$runtime/a1/statefulset.json"
jq -n '{metadata:{name:"sample-app-postgresql",namespace:"app-dev",uid:"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",generation:8},spec:{replicas:0},status:{observedGeneration:8,currentReplicas:0,readyReplicas:0,updatedReplicas:0}}' >"$runtime/a2/statefulset.json"
jq -n '{apiVersion:"v1",kind:"PodList",items:[{metadata:{name:"sample-app-postgresql-0",namespace:"app-dev",uid:"bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",ownerReferences:[{apiVersion:"apps/v1",kind:"StatefulSet",name:"sample-app-postgresql",uid:"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",controller:true}]},spec:{volumes:[{name:"data",persistentVolumeClaim:{claimName:"data-sample-app-postgresql-0"}}],containers:[{name:"postgresql",image:"docker.io/library/postgres@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]},status:{phase:"Running",conditions:[{type:"Ready",status:"True"}],containerStatuses:[{name:"postgresql",ready:true}]}}]}' >"$runtime/a1/pods.json"
cp "$runtime/a1/pods.json" "$runtime/a1/all-pods.json"
jq '.items[0]' "$runtime/a1/pods.json" >"$runtime/a1/start-pod.json"
jq -n '{apiVersion:"v1",kind:"PodList",items:[]}' >"$runtime/a2/pods.json"
cp "$runtime/a2/pods.json" "$runtime/a2/all-pods.json"
cp "$runtime/a2/pods.json" "$runtime/ready/pods.json"
cp "$runtime/a2/all-pods.json" "$runtime/ready/all-pods.json"
cp "$runtime/a2/statefulset.json" "$runtime/ready/statefulset.json"
cp "$runtime/a2/jobs.json" "$runtime/ready/jobs.json"
cp "$runtime/a1/start-pod.json" "$runtime/a2/start-pod.json"
cp "$runtime/a1/start-pod.json" "$runtime/ready/start-pod.json"
jq -n '{metadata:{name:"data-sample-app-postgresql-0",namespace:"app-dev",uid:"11111111-1111-1111-1111-111111111111"},spec:{volumeName:"pvc-11111111-1111-1111-1111-111111111111"},status:{phase:"Bound"}}' >"$runtime/pvc.json"
jq -n '{metadata:{name:"pvc-11111111-1111-1111-1111-111111111111"},spec:{claimRef:{namespace:"app-dev",name:"data-sample-app-postgresql-0",uid:"11111111-1111-1111-1111-111111111111"},csi:{driver:"ebs.csi.aws.com",volumeHandle:"vol-0123456789abcdef0"}},status:{phase:"Bound"}}' >"$runtime/pv.json"
jq -n '{apiVersion:"storage.k8s.io/v1",kind:"VolumeAttachmentList",items:[{metadata:{name:"csi-attach-a"},spec:{source:{persistentVolumeName:"pvc-11111111-1111-1111-1111-111111111111"}},status:{attached:true}}]}' >"$runtime/a1/volumeattachments.json"
jq -n '{apiVersion:"storage.k8s.io/v1",kind:"VolumeAttachmentList",items:[]}' >"$runtime/a2/volumeattachments.json"
cp "$runtime/a2/volumeattachments.json" "$runtime/ready/volumeattachments.json"
jq -n '{metadata:{name:"sample-app-postgresql-snapshot",namespace:"app-dev",uid:"22222222-2222-2222-2222-222222222222"},spec:{volumeSnapshotClassName:"course-ebs-snapshots",source:{persistentVolumeClaimName:"data-sample-app-postgresql-0"}},status:{readyToUse:true,boundVolumeSnapshotContentName:"snapcontent-22222222-2222-2222-2222-222222222222"}}' >"$runtime/ready/snapshot.json"
jq -n '{metadata:{name:"snapcontent-22222222-2222-2222-2222-222222222222",uid:"33333333-3333-3333-3333-333333333333"},spec:{driver:"ebs.csi.aws.com",volumeSnapshotClassName:"course-ebs-snapshots",volumeSnapshotRef:{name:"sample-app-postgresql-snapshot",namespace:"app-dev",uid:"22222222-2222-2222-2222-222222222222"},source:{volumeHandle:"vol-0123456789abcdef0"}},status:{readyToUse:true,snapshotHandle:"snap-0123456789abcdef0"}}' >"$runtime/ready/snapshot-content.json"
jq -c -n '{schemaVersion:"course.snapshot-checksum/v1",foreignKeyViolations:0,duplicateIdempotencyKeys:0,negativeInventoryRows:0,canonicalRows:[{table:"products",rows:[{id:"p1"}]},{table:"inventory",rows:[{product_id:"p1",available_quantity:10}]},{table:"orders",rows:[]},{table:"order_items",rows:[]}]}' >"$runtime/a1/checksum.json"
cat >"$runtime/a2/shutdown.log" <<'LOG'
2026-09-03T01:00:10.000000000Z LOG:  received fast shutdown request
2026-09-03T01:00:20.000000000Z LOG:  database system is shut down
LOG

run_prepare() {
  local source_dir=$1 output=$2 now=${3:-2026-09-03T01:00:00Z}
  COURSE_CHECK_BIN_DIR="$fake_bin" FAKE_SNAPSHOT_DIR="$source_dir" FAKE_SNAPSHOT_PHASE=a1 \
    AWS_REGION=ap-northeast-2 EKS_CLUSTER_NAME=course-dev \
    bash "$script" prepare --a1-output "$output" --phase-values "$source_dir/a1/phase-values.yaml" --now "$now"
}
run_capture() {
  local source_dir=$1 a1=$2 output=$3 now=${4:-2026-09-03T01:00:30Z}
  COURSE_CHECK_BIN_DIR="$fake_bin" FAKE_SNAPSHOT_DIR="$source_dir" FAKE_SNAPSHOT_PHASE=a2 \
    AWS_REGION=ap-northeast-2 EKS_CLUSTER_NAME=course-dev \
    bash "$script" capture --a1 "$a1" --output "$output" --phase-values "$source_dir/a2/phase-values.yaml" --now "$now"
}
run_ready() {
  local source_dir=$1 a2=$2 output=$3 now=${4:-2026-09-03T01:10:00Z}
  COURSE_CHECK_BIN_DIR="$fake_bin" FAKE_SNAPSHOT_DIR="$source_dir" FAKE_SNAPSHOT_PHASE=ready \
    AWS_REGION=ap-northeast-2 EKS_CLUSTER_NAME=course-dev \
    RECOVERY_DB_SECRET_READER_ROLE_ARN=arn:aws:iam::123456789012:role/dev-course-recovery-db-secret-reader-role \
    EXTERNAL_SECRETS_READER_ROLE_ARN=arn:aws:iam::123456789012:role/dev-course-external-secrets-reader-role \
    bash "$script" ready --a2 "$a2" --output "$output" \
      --phase-values "$source_dir/ready/phase-values.yaml" --now "$now"
}

a1="$tmp_root/a1.json"
prepare_log=$(run_prepare "$runtime" "$a1") || fail 'valid A1 runtime adapter was rejected'
grep -Fq '[STATIC]' <<<"$prepare_log" || fail 'fake A1 execution was not labelled STATIC'
[[ "$(file_mode "$a1")" == 600 ]] || fail 'A1 record mode must be 0600'
phase_digest="sha256:$(shasum -a 256 "$runtime/a1/phase-values.yaml" | awk '{print $1}')"
checksum_value="sha256:$(jq -cS . "$runtime/a1/checksum.json" | shasum -a 256 | awk '{print $1}')"
jq -e --arg phaseDigest "$phase_digest" --arg checksum "$checksum_value" '
  .schemaVersion == "course.snapshot-quiesce-a1/v1" and .evidenceGrade == "STATIC" and
  .environment == "dev" and .region == "ap-northeast-2" and
  .clusterArn == "arn:aws:eks:ap-northeast-2:123456789012:cluster/course-dev" and
  .gitopsRevision == "1111111111111111111111111111111111111111" and
  .phaseValuesFile == "envs/dev/snapshot-maintenance-values.yaml" and .phaseValuesDigest == $phaseDigest and
  .source.namespace == "app-dev" and .source.statefulSet == "sample-app-postgresql" and
  .source.pvcName == "data-sample-app-postgresql-0" and .source.pvcUid == "11111111-1111-1111-1111-111111111111" and
  .source.volumeName == "pvc-11111111-1111-1111-1111-111111111111" and
  .source.podName == "sample-app-postgresql-0" and .source.podUid == "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb" and
  .writers == {applicationReplicas:0,migrationActive:0,migrationPending:0} and
  .checksum == {algorithm:"sha256",value:$checksum,capturedAt:"2026-09-03T01:00:00Z"}
' "$a1" >/dev/null || { jq . "$a1" >&2; fail 'A1 output is not exactly bound to live checksum and storage identity'; }

final="$tmp_root/snapshot-quiesce.json"
capture_log=$(run_capture "$runtime" "$a1" "$final") || fail 'valid A2 runtime adapter was rejected'
grep -Fq '[STATIC]' <<<"$capture_log" || fail 'fake A2 execution was not labelled STATIC'
[[ "$(file_mode "$final")" == 600 ]] || fail 'snapshot quiesce record mode must be 0600'
shutdown_digest="sha256:$(shasum -a 256 "$runtime/a2/shutdown.log" | awk '{print $1}')"
jq -e --arg checksum "$checksum_value" --arg shutdown "$shutdown_digest" '
  (keys | sort) == ["checksum","clusterArn","database","environment","evidenceGrade","expiresAt","gitopsRevision","observedAt","region","schemaVersion","source","storage","writers"] and
  .schemaVersion == "course.snapshot-quiesce/v1" and .evidenceGrade == "STATIC" and
  .gitopsRevision == "2222222222222222222222222222222222222222" and
  .database == {desiredReplicas:0,readyReplicas:0,shutdownSignal:"SIGINT",cleanShutdownObserved:true,cleanShutdownEvidenceId:$shutdown,stoppedAt:"2026-09-03T01:00:20Z"} and
  .storage == {mountedPodUids:[],volumeAttachmentNames:[]} and
  .checksum == {algorithm:"sha256",value:$checksum,capturedAt:"2026-09-03T01:00:00Z"} and
  .observedAt == "2026-09-03T01:00:30Z" and .expiresAt == "2026-09-03T02:00:30Z"
' "$final" >/dev/null || fail 'A2 output is not the exact canonical detached snapshot contract'
[[ $(grep -c 'get statefulset sample-app-postgresql' "$runtime/calls.log") -ge 3 ]] || fail 'capture did not immediately re-query final StatefulSet state'
[[ "$before" == "$(fingerprint)" ]] || fail 'fake runtime adapter changed canonical runtime evidence'

ready="$tmp_root/snapshot-ready.json"
ready_log=$(run_ready "$runtime" "$final" "$ready") || fail 'valid ready snapshot runtime adapter was rejected'
grep -Fq '[STATIC]' <<<"$ready_log" || fail 'fake ready snapshot execution was not labelled STATIC'
[[ "$(file_mode "$ready")" == 600 ]] || fail 'ready snapshot evidence mode must be 0600'
jq -e '
  .schemaVersion == "course.snapshot-ready/v1" and .evidenceGrade == "STATIC" and
  .environment == "dev" and .region == "ap-northeast-2" and
  .clusterArn == "arn:aws:eks:ap-northeast-2:123456789012:cluster/course-dev" and
  .gitopsRevision == "3333333333333333333333333333333333333333" and
  .source == {namespace:"app-dev",pvcName:"data-sample-app-postgresql-0",pvcUid:"11111111-1111-1111-1111-111111111111",volumeName:"pvc-11111111-1111-1111-1111-111111111111"} and
  .snapshot == {namespace:"app-dev",name:"sample-app-postgresql-snapshot",uid:"22222222-2222-2222-2222-222222222222",contentName:"snapcontent-22222222-2222-2222-2222-222222222222",contentUid:"33333333-3333-3333-3333-333333333333",className:"course-ebs-snapshots",driver:"ebs.csi.aws.com",handle:"snap-0123456789abcdef0",readyToUse:true} and
  .recovery == {readerRoleArn:"arn:aws:iam::123456789012:role/dev-course-recovery-db-secret-reader-role",normalReaderRoleArn:"arn:aws:iam::123456789012:role/dev-course-external-secrets-reader-role"} and
  .observedAt == "2026-09-03T01:10:00Z" and .expiresAt == "2026-09-03T02:10:00Z"
' "$ready" >/dev/null || fail 'ready snapshot evidence is not bound to actual content, handle, class, driver, and Role identities'

cloud="$tmp_root/snapshot-quiesce-cloud.json"
jq '.evidenceGrade="CLOUD_RUNTIME"' "$final" >"$cloud"
bash "$script" --fixture "$cloud" >/dev/null || fail 'canonical CLOUD_RUNTIME snapshot fixture was rejected'
for mutation in \
  '.source.pvcUid=" "' \
  '.source.volumeName="\uFEFF"' \
  '.database.stoppedAt="2026-02-30T01:00:20Z"' \
  '.observedAt="2026-09-03T01:00:30.000Z"' \
  '.checksum.capturedAt=.database.stoppedAt' \
  '.storage.mountedPodUids=["pod-uid"]' \
  '.unexpected=true'; do
  invalid="$tmp_root/invalid-$(printf '%s' "$mutation" | shasum | cut -c1-8).json"
  jq "$mutation" "$cloud" >"$invalid"
  if bash "$script" --fixture "$invalid" >/dev/null 2>&1; then fail "snapshot fixture accepted mutation $mutation"; fi
done

negative_prepare() {
  local label=$1 expression=$2 candidate
  candidate="$tmp_root/prepare-$label"
  cp -R "$runtime" "$candidate"
  eval "$expression"
  if run_prepare "$candidate" "$tmp_root/$label-a1.json" >/dev/null 2>&1; then fail "A1 accepted $label"; fi
}
negative_prepare dirty 'printf "%s\n" " M envs/dev/snapshot-maintenance-values.yaml" >"$candidate/a1/git-status.txt"'
negative_prepare writer 'jq ".spec.replicas=1 | .status.readyReplicas=1" "$candidate/deployment.json" >"$candidate/m" && mv "$candidate/m" "$candidate/deployment.json"'
negative_prepare database-zero 'jq ".spec.replicas=0 | .status.readyReplicas=0 | .status.currentReplicas=0 | .status.updatedReplicas=0" "$candidate/a1/statefulset.json" >"$candidate/m" && mv "$candidate/m" "$candidate/a1/statefulset.json"'
negative_prepare checksum-invariant 'jq ".foreignKeyViolations=1" "$candidate/a1/checksum.json" >"$candidate/m" && mv "$candidate/m" "$candidate/a1/checksum.json"'
negative_prepare snapshot-present 'jq ".items=[{metadata:{name:\"too-early\"}}]" "$candidate/a1/volumesnapshots.json" >"$candidate/m" && mv "$candidate/m" "$candidate/a1/volumesnapshots.json"'

negative_capture() {
  local label=$1 expression=$2 candidate candidate_a1
  candidate="$tmp_root/capture-$label"
  candidate_a1="$tmp_root/$label-source-a1.json"
  cp -R "$runtime" "$candidate"
  run_prepare "$candidate" "$candidate_a1" >/dev/null
  eval "$expression"
  if run_capture "$candidate" "$candidate_a1" "$tmp_root/$label-final.json" >/dev/null 2>&1; then fail "A2 accepted $label"; fi
}
negative_capture same-revision 'cp "$candidate/a1/git-revision.txt" "$candidate/a2/git-revision.txt"; jq --arg revision "$(cat "$candidate/a1/git-revision.txt")" ".status.sync.revision=\$revision" "$candidate/a2/application.json" >"$candidate/m" && mv "$candidate/m" "$candidate/a2/application.json"'
negative_capture extra-git-change 'printf "%s\n" envs/dev/snapshot-maintenance-values.yaml README.md >"$candidate/a2/git-diff-names.txt"'
negative_capture wrong-phase-change 'yq -i ".database.replicaCount=0 | .snapshot.captureEnabled=true" "$candidate/a2/phase-values.yaml"'
negative_capture unclean-log 'grep -v "database system is shut down" "$candidate/a2/shutdown.log" >"$candidate/m" && mv "$candidate/m" "$candidate/a2/shutdown.log"'
negative_capture still-mounted 'cp "$candidate/a1/all-pods.json" "$candidate/a2/all-pods.json"'
negative_capture still-attached 'cp "$candidate/a1/volumeattachments.json" "$candidate/a2/volumeattachments.json"'
negative_capture pvc-drift 'jq ".metadata.uid=\"99999999-9999-9999-9999-999999999999\"" "$candidate/pvc.json" >"$candidate/m" && mv "$candidate/m" "$candidate/pvc.json"'
negative_capture snapshot-present 'jq ".items=[{metadata:{name:\"too-early\"}}]" "$candidate/a2/volumesnapshots.json" >"$candidate/m" && mv "$candidate/m" "$candidate/a2/volumesnapshots.json"'

for option in --a1 --a1-output --output --phase-values --now; do
  if AWS_REGION=ap-northeast-2 EKS_CLUSTER_NAME=course-dev bash "$script" capture "$option" "$tmp_root/override" >/dev/null 2>&1; then
    fail "live snapshot producer accepted arbitrary $option override"
  fi
done
echo 'PASS: snapshot A1/A2 runtime producer is revision-bound, ordered, detached, and fail-closed.'
