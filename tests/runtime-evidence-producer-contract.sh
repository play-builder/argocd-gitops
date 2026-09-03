#!/usr/bin/env bash
set -Eeuo pipefail

test_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repository_root=$(cd -- "$test_root/.." && pwd)
fixture_root="$test_root/fixtures"
tmp_root=$(mktemp -d)
trap 'rm -rf -- "$tmp_root"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
fingerprint() {
  local path=$1
  if [[ -f "$path" ]]; then shasum -a 256 "$path" | awk '{print "file:" $1}'
  elif [[ -e "$path" ]]; then echo other
  else echo absent
  fi
}

baseline_output="$repository_root/evidence/prod/baseline.json"
freeze_output="$repository_root/evidence/cleanup/freeze.json"
removal_output="$repository_root/evidence/cleanup/removal.json"
before_baseline=$(fingerprint "$baseline_output")
before_freeze=$(fingerprint "$freeze_output")
before_removal=$(fingerprint "$removal_output")

baseline_log=$(bash "$repository_root/scripts/capture-prod-baseline-evidence.sh" \
  --fixture "$fixture_root/evidence/baseline-valid.json")
freeze_log=$(bash "$repository_root/scripts/capture-cleanup-evidence.sh" freeze \
  --fixture "$fixture_root/cleanup/freeze-valid.json")
removal_log=$(bash "$repository_root/scripts/capture-cleanup-evidence.sh" removal \
  --fixture "$fixture_root/cleanup/removal-valid.json" --eks-repo-root "$fixture_root/cleanup")

grep -Fq '[STATIC]' <<<"$baseline_log" || fail 'baseline fixture adapter was not labelled STATIC'
grep -Fq '[STATIC]' <<<"$freeze_log" || fail 'freeze fixture adapter was not labelled STATIC'
grep -Fq '[STATIC]' <<<"$removal_log" || fail 'removal fixture adapter was not labelled STATIC'
[[ "$before_baseline" == "$(fingerprint "$baseline_output")" ]] || fail 'baseline fixture adapter changed canonical runtime evidence'
[[ "$before_freeze" == "$(fingerprint "$freeze_output")" ]] || fail 'freeze fixture adapter changed canonical runtime evidence'
[[ "$before_removal" == "$(fingerprint "$removal_output")" ]] || fail 'removal fixture adapter changed canonical runtime evidence'

invalid="$tmp_root/invalid-freeze.json"
jq '.clusters[0].application.extra=true' "$fixture_root/cleanup/freeze-valid.json" >"$invalid"
if bash "$repository_root/scripts/capture-cleanup-evidence.sh" freeze --fixture "$invalid" >/dev/null 2>&1; then
  fail 'freeze fixture adapter accepted an extra nested key'
fi
jq '.writers.loadGenerators=false' "$fixture_root/cleanup/freeze-valid.json" >"$invalid"
if bash "$repository_root/scripts/capture-cleanup-evidence.sh" freeze --fixture "$invalid" >/dev/null 2>&1; then
  fail 'freeze fixture adapter accepted boolean false as a zero writer count'
fi
jq '.clusters[1].clusterArn="arn:aws:eks:us-east-1:999999999999:cluster/prod"' \
  "$fixture_root/cleanup/freeze-valid.json" >"$invalid"
if bash "$repository_root/scripts/capture-cleanup-evidence.sh" freeze --fixture "$invalid" >/dev/null 2>&1; then
  fail 'freeze fixture adapter accepted cross-account or cross-Region clusters'
fi

invalid="$tmp_root/invalid-removal.json"
jq '.remaining.jobs=false' "$fixture_root/cleanup/removal-valid.json" >"$invalid"
if bash "$repository_root/scripts/capture-cleanup-evidence.sh" removal --fixture "$invalid" \
  --eks-repo-root "$fixture_root/cleanup" >/dev/null 2>&1; then
  fail 'removal fixture adapter accepted boolean false as a zero count'
fi
jq '.clusters[0].extra=true' "$fixture_root/cleanup/removal-valid.json" >"$invalid"
if bash "$repository_root/scripts/capture-cleanup-evidence.sh" removal --fixture "$invalid" \
  --eks-repo-root "$fixture_root/cleanup" >/dev/null 2>&1; then
  fail 'removal fixture adapter accepted an extra cluster key'
fi

symlink_root="$tmp_root/symlink-inventory-root"
mkdir -p "$symlink_root/evidence/cleanup"
ln -s "$fixture_root/cleanup/ownership-valid.json" "$symlink_root/evidence/cleanup/ownership-inventory.json"
if bash "$repository_root/scripts/capture-cleanup-evidence.sh" removal \
  --fixture "$fixture_root/cleanup/removal-valid.json" --eks-repo-root "$symlink_root" >/dev/null 2>&1; then
  fail 'cleanup fixture adapter accepted a symlinked canonical ownership inventory'
fi
symlink_fixture_parent_root="$tmp_root/symlink-fixture-parent-root"
mkdir -p "$symlink_fixture_parent_root/evidence"
ln -s "$fixture_root/cleanup/evidence/cleanup" "$symlink_fixture_parent_root/evidence/cleanup"
if bash "$repository_root/scripts/capture-cleanup-evidence.sh" removal \
  --fixture "$fixture_root/cleanup/removal-valid.json" --eks-repo-root "$symlink_fixture_parent_root" >/dev/null 2>&1; then
  fail 'cleanup fixture adapter accepted an ownership inventory through a symlinked parent directory'
fi

for script in capture-prod-baseline-evidence.sh capture-cleanup-evidence.sh; do
  [[ -x "$repository_root/scripts/$script" ]] || fail "$script is not executable"
  head -1 "$repository_root/scripts/$script" | grep -Fqx '#!/usr/bin/env bash' || fail "$script has the wrong shebang"
  grep -Fq 'set -Eeuo pipefail' "$repository_root/scripts/$script" || fail "$script is not fail-fast"
done

grep -Fq 'rollout.argoproj.io/revision' "$repository_root/scripts/capture-prod-baseline-evidence.sh" ||
  fail 'baseline producer does not derive revision from the stable ReplicaSet annotation'
if grep -Fq 'rollouts.argoproj.io/revision' "$repository_root/scripts/capture-prod-baseline-evidence.sh"; then
  fail 'baseline producer still uses the non-canonical plural revision annotation'
fi
grep -Fq 'get httproute sample-app' "$repository_root/scripts/capture-prod-baseline-evidence.sh" ||
  fail 'baseline producer does not inspect live 100/0 traffic routing'
grep -Fq 'status --porcelain --untracked-files=all' "$repository_root/scripts/capture-prod-baseline-evidence.sh" ||
  fail 'baseline producer does not enforce a clean GitOps source tree'
grep -Fq 'status --porcelain --untracked-files=all' "$repository_root/scripts/capture-cleanup-evidence.sh" ||
  fail 'cleanup producer does not enforce a clean GitOps source tree'
if grep -Fq 'GITOPS_REVISION' "$repository_root/scripts/capture-cleanup-evidence.sh"; then
  fail 'cleanup producer allows caller-supplied GitOps revision spoofing'
fi
grep -Fq 'get testruns.k6.io' "$repository_root/scripts/capture-cleanup-evidence.sh" ||
  fail 'freeze producer does not inspect live load writers'
grep -Fq 'get podchaos.chaos-mesh.org,networkchaos.chaos-mesh.org' "$repository_root/scripts/capture-cleanup-evidence.sh" ||
  fail 'freeze producer does not inspect live Chaos writers'
grep -Fq 'aws eks describe-cluster' "$repository_root/scripts/capture-cleanup-evidence.sh" ||
  fail 'cleanup producer does not bind Kubernetes contexts to EKS identity'
grep -Fq 'get application "sample-app-$environment"' "$repository_root/scripts/capture-cleanup-evidence.sh" ||
  fail 'freeze producer does not read each Application through its bound Kubernetes context'
if grep -Fq 'argocd app' "$repository_root/scripts/capture-cleanup-evidence.sh"; then
  fail 'cleanup producer queries one global Argo CD endpoint instead of each cluster context'
fi
grep -Fq 'scan_namespace recovery dev "$dev_context" app-recovery' "$repository_root/scripts/capture-cleanup-evidence.sh" ||
  fail 'removal producer does not scan the isolated recovery namespace'

fake_bin="$tmp_root/cleanup-bin"
runtime="$tmp_root/cleanup-runtime"
eks_root="$tmp_root/EKS-infra"
mkdir -p "$fake_bin" "$runtime" "$eks_root/evidence/cleanup"
for command in aws git kubectl; do
  ln -s "$test_root/helpers/fake-cleanup-cli.sh" "$fake_bin/$command"
done
printf '%s\n' 1111111111111111111111111111111111111111 >"$runtime/git-revision.txt"
: >"$runtime/git-status.txt"
for environment in dev prod; do
  jq -n --arg name "course-$environment" --arg arn "arn:aws:eks:ap-northeast-2:111111111111:cluster/course-$environment" \
    --arg endpoint "https://$environment.eks.example" '{cluster:{name:$name,arn:$arn,status:"ACTIVE",endpoint:$endpoint}}' \
    >"$runtime/$environment-cluster.json"
  jq -n --arg endpoint "https://$environment.eks.example" '{clusters:[{cluster:{server:$endpoint}}]}' \
    >"$runtime/$environment-kubeconfig.json"
  jq -n --arg environment "$environment" '{metadata:{name:("sample-app-"+$environment)},spec:{syncPolicy:{}},status:{sync:{status:"Synced",revision:"1111111111111111111111111111111111111111"},health:{status:"Healthy"}}}' \
    >"$runtime/$environment-application.json"
  : >"$runtime/$environment-application-name.txt"
  printf '%s\n' testruns.k6.io podchaos.chaos-mesh.org networkchaos.chaos-mesh.org \
    volumesnapshots.snapshot.storage.k8s.io volumesnapshotcontents.snapshot.storage.k8s.io \
    >"$runtime/$environment-api-resources.txt"
  for kind in jobs statefulsets load chaos snapshotcontents; do
    printf '%s\n' '{"apiVersion":"v1","kind":"List","items":[]}' >"$runtime/$environment-$kind.json"
  done
done
for environment_namespace in dev-app-recovery prod-app-prod; do
  : >"$runtime/$environment_namespace-namespace.json"
  printf '%s\n' '{"apiVersion":"v1","kind":"List","items":[]}' >"$runtime/$environment_namespace-workloads.json"
  printf '%s\n' '{"apiVersion":"v1","kind":"List","items":[]}' >"$runtime/$environment_namespace-pvcs.json"
  printf '%s\n' '{"apiVersion":"v1","kind":"List","items":[]}' >"$runtime/$environment_namespace-snapshots.json"
done
jq -n '{apiVersion:"v1",kind:"Namespace",metadata:{name:"app-dev",uid:"namespace-u-1"}}' >"$runtime/dev-app-dev-namespace.json"
printf '%s\n' '{"apiVersion":"v1","kind":"List","items":[]}' >"$runtime/dev-app-dev-workloads.json"
jq -n '{apiVersion:"v1",kind:"List",items:[{kind:"PersistentVolumeClaim",metadata:{namespace:"app-dev",name:"data",uid:"u-1"}}]}' \
  >"$runtime/dev-app-dev-pvcs.json"
jq -n '{apiVersion:"snapshot.storage.k8s.io/v1",kind:"List",items:[{kind:"VolumeSnapshot",metadata:{namespace:"app-dev",name:"data-snapshot",uid:"snapshot-u-1"},status:{boundVolumeSnapshotContentName:"data-content"}}]}' \
  >"$runtime/dev-app-dev-snapshots.json"
jq -n '{apiVersion:"snapshot.storage.k8s.io/v1",kind:"List",items:[{kind:"VolumeSnapshotContent",metadata:{name:"data-content",uid:"content-u-1"},spec:{volumeSnapshotRef:{namespace:"app-dev",name:"data-snapshot",uid:"snapshot-u-1"}}}]}' \
  >"$runtime/dev-snapshotcontents.json"
jq -n '{ARN:"arn:aws:secretsmanager:ap-northeast-2:111111111111:secret:runtime"}' >"$runtime/provider-secret.json"
jq '
  .evidenceGrade = "STATIC" |
  .resources += [
    {kind:"VolumeSnapshot",id:"app-dev/data-snapshot",environment:"dev",classification:"source-snapshot",owner:"course",managedBy:"terraform",billable:false,decision:"RETAIN",reason:"recovery evidence",followUpAction:"delete after explicit approval"},
    {kind:"VolumeSnapshotContent",id:"data-content",environment:"dev",classification:"source-snapshot-content",owner:"course",managedBy:"terraform",billable:false,decision:"RETAIN",reason:"recovery evidence",followUpAction:"delete after explicit approval"}
  ] | .resources |= sort_by(.kind,.id)
' "$fixture_root/cleanup/ownership-valid.json" >"$eks_root/evidence/cleanup/ownership-inventory.json"

symlink_parent_root="$tmp_root/symlink-parent-inventory-root"
mkdir -p "$symlink_parent_root/evidence"
ln -s "$eks_root/evidence/cleanup" "$symlink_parent_root/evidence/cleanup"
if COURSE_CHECK_BIN_DIR="$fake_bin" FAKE_CLEANUP_DIR="$runtime" \
  bash "$repository_root/scripts/capture-cleanup-evidence.sh" removal --eks-repo-root "$symlink_parent_root" \
    --dev-context dev-context --prod-context prod-context --freeze-evidence "$fixture_root/cleanup/freeze-valid.json" \
    --output "$tmp_root/symlink-parent-removal.json" >/dev/null 2>&1; then
  fail 'static removal execution accepted an ownership inventory through a symlinked parent directory'
fi

static_freeze="$tmp_root/static-freeze.json"
freeze_log=$(COURSE_CHECK_BIN_DIR="$fake_bin" FAKE_CLEANUP_DIR="$runtime" AWS_REGION=ap-northeast-2 \
  DEV_CLUSTER_NAME=course-dev PROD_CLUSTER_NAME=course-prod \
  bash "$repository_root/scripts/capture-cleanup-evidence.sh" freeze --dev-context dev-context \
    --prod-context prod-context --output "$static_freeze") || fail 'valid static freeze execution was rejected'
grep -Fq '[STATIC]' <<<"$freeze_log" || fail 'fake freeze execution was not labelled STATIC'
jq -e '.evidenceGrade=="STATIC" and .writers=={loadGenerators:0,chaosResources:0,recoveryJobs:0,migrationJobs:0}' \
  "$static_freeze" >/dev/null || fail 'fake freeze output did not preserve live zero-writer evidence'
[[ "$before_freeze" == "$(fingerprint "$freeze_output")" ]] || fail 'fake freeze execution changed canonical evidence'

active_runtime="$tmp_root/cleanup-runtime-active"
cp -R "$runtime" "$active_runtime"
jq -n '{items:[{metadata:{labels:{"course.writer":"load-generator"}},status:{active:1}}]}' >"$active_runtime/dev-jobs.json"
if COURSE_CHECK_BIN_DIR="$fake_bin" FAKE_CLEANUP_DIR="$active_runtime" AWS_REGION=ap-northeast-2 \
  DEV_CLUSTER_NAME=course-dev PROD_CLUSTER_NAME=course-prod \
  bash "$repository_root/scripts/capture-cleanup-evidence.sh" freeze --dev-context dev-context \
    --prod-context prod-context --output "$tmp_root/active-freeze.json" >/dev/null 2>&1; then
  fail 'static freeze execution accepted an active writer'
fi

drift_runtime="$tmp_root/cleanup-runtime-drift"
cp -R "$runtime" "$drift_runtime"
jq '.clusters[0].cluster.server="https://foreign.eks.example"' "$drift_runtime/dev-kubeconfig.json" >"$drift_runtime/mutated"
mv "$drift_runtime/mutated" "$drift_runtime/dev-kubeconfig.json"
if COURSE_CHECK_BIN_DIR="$fake_bin" FAKE_CLEANUP_DIR="$drift_runtime" AWS_REGION=ap-northeast-2 \
  DEV_CLUSTER_NAME=course-dev PROD_CLUSTER_NAME=course-prod \
  bash "$repository_root/scripts/capture-cleanup-evidence.sh" freeze --dev-context dev-context \
    --prod-context prod-context --output "$tmp_root/drift-freeze.json" >/dev/null 2>&1; then
  fail 'static freeze execution accepted a context and EKS endpoint mismatch'
fi

arn_drift_runtime="$tmp_root/cleanup-runtime-arn-drift"
cp -R "$runtime" "$arn_drift_runtime"
jq '.cluster.arn="arn:aws:eks:ap-northeast-2:111111111111:cluster/other-dev"' \
  "$arn_drift_runtime/dev-cluster.json" >"$arn_drift_runtime/mutated"
mv "$arn_drift_runtime/mutated" "$arn_drift_runtime/dev-cluster.json"
if COURSE_CHECK_BIN_DIR="$fake_bin" FAKE_CLEANUP_DIR="$arn_drift_runtime" AWS_REGION=ap-northeast-2 \
  DEV_CLUSTER_NAME=course-dev PROD_CLUSTER_NAME=course-prod \
  bash "$repository_root/scripts/capture-cleanup-evidence.sh" freeze --dev-context dev-context \
    --prod-context prod-context --output "$tmp_root/arn-drift-freeze.json" >/dev/null 2>&1; then
  fail 'static freeze execution accepted an EKS ARN whose cluster name differs from the requested cluster'
fi

malformed_arn_runtime="$tmp_root/cleanup-runtime-malformed-arn"
cp -R "$runtime" "$malformed_arn_runtime"
jq '.cluster.arn="arn:aws:eks:ap-northeast-2:111111111111:cluster/forged:cluster/course-dev"' \
  "$malformed_arn_runtime/dev-cluster.json" >"$malformed_arn_runtime/mutated"
mv "$malformed_arn_runtime/mutated" "$malformed_arn_runtime/dev-cluster.json"
if COURSE_CHECK_BIN_DIR="$fake_bin" FAKE_CLEANUP_DIR="$malformed_arn_runtime" AWS_REGION=ap-northeast-2 \
  DEV_CLUSTER_NAME=course-dev PROD_CLUSTER_NAME=course-prod \
  bash "$repository_root/scripts/capture-cleanup-evidence.sh" freeze --dev-context dev-context \
    --prod-context prod-context --output "$tmp_root/malformed-arn-freeze.json" >/dev/null 2>&1; then
  fail 'static freeze execution accepted a malformed EKS cluster ARN'
fi

static_removal="$tmp_root/static-removal.json"
removal_log=$(COURSE_CHECK_BIN_DIR="$fake_bin" FAKE_CLEANUP_DIR="$runtime" \
  bash "$repository_root/scripts/capture-cleanup-evidence.sh" removal --eks-repo-root "$eks_root" \
    --dev-context dev-context --prod-context prod-context \
    --freeze-evidence "$static_freeze" --output "$static_removal") ||
  fail 'valid static removal execution was rejected'
grep -Fq '[STATIC]' <<<"$removal_log" || fail 'fake removal execution was not labelled STATIC'
jq -e '
  .evidenceGrade=="STATIC" and .status=="REMOVED" and
  [.retained[].kind] == ["Namespace","VolumeSnapshotContent","PersistentVolumeClaim","VolumeSnapshot"] and
  ([.remaining[]] | all(.==0))
' "$static_removal" >/dev/null || fail 'fake removal output omitted exhaustive retained-object evidence'
[[ "$before_removal" == "$(fingerprint "$removal_output")" ]] || fail 'fake removal execution changed canonical evidence'

for label in ascii-space bom; do
  value=' '
  [[ "$label" == bom ]] && value=$(printf '\357\273\277')
  invalid_inventory_root="$tmp_root/EKS-infra-$label-course-id"
  mkdir -p "$invalid_inventory_root/evidence/cleanup"
  jq --arg value "$value" '.courseId=$value' \
    "$eks_root/evidence/cleanup/ownership-inventory.json" \
    >"$invalid_inventory_root/evidence/cleanup/ownership-inventory.json"
  if COURSE_CHECK_BIN_DIR="$fake_bin" FAKE_CLEANUP_DIR="$runtime" \
    bash "$repository_root/scripts/capture-cleanup-evidence.sh" removal \
      --eks-repo-root "$invalid_inventory_root" --dev-context dev-context --prod-context prod-context \
      --freeze-evidence "$static_freeze" --output "$tmp_root/$label-course-id-removal.json" >/dev/null 2>&1; then
    fail "static removal execution accepted $label-only ownership courseId"
  fi
  invalid_inventory_root="$tmp_root/EKS-infra-$label-reason"
  mkdir -p "$invalid_inventory_root/evidence/cleanup"
  jq --arg value "$value" \
    '.resources |= map(if .kind=="PersistentVolumeClaim" then .reason=$value else . end)' \
    "$eks_root/evidence/cleanup/ownership-inventory.json" \
    >"$invalid_inventory_root/evidence/cleanup/ownership-inventory.json"
  if COURSE_CHECK_BIN_DIR="$fake_bin" FAKE_CLEANUP_DIR="$runtime" \
    bash "$repository_root/scripts/capture-cleanup-evidence.sh" removal \
      --eks-repo-root "$invalid_inventory_root" --dev-context dev-context --prod-context prod-context \
      --freeze-evidence "$static_freeze" --output "$tmp_root/$label-reason-removal.json" >/dev/null 2>&1; then
    fail "static removal execution accepted $label-only retained rationale"
  fi
done

existing_runtime="$tmp_root/cleanup-runtime-existing-app"
cp -R "$runtime" "$existing_runtime"
printf '%s\n' 'application.argoproj.io/sample-app-dev' >"$existing_runtime/dev-application-name.txt"
if COURSE_CHECK_BIN_DIR="$fake_bin" FAKE_CLEANUP_DIR="$existing_runtime" \
  bash "$repository_root/scripts/capture-cleanup-evidence.sh" removal --eks-repo-root "$eks_root" \
    --dev-context dev-context --prod-context prod-context --freeze-evidence "$static_freeze" \
    --output "$tmp_root/existing-app-removal.json" >/dev/null 2>&1; then
  fail 'static removal execution accepted a remaining Argo CD Application'
fi

workload_runtime="$tmp_root/cleanup-runtime-existing-workload"
cp -R "$runtime" "$workload_runtime"
jq -n '{items:[{kind:"Deployment",metadata:{namespace:"app-dev",name:"sample-app"}}]}' \
  >"$workload_runtime/dev-app-dev-workloads.json"
if COURSE_CHECK_BIN_DIR="$fake_bin" FAKE_CLEANUP_DIR="$workload_runtime" \
  bash "$repository_root/scripts/capture-cleanup-evidence.sh" removal --eks-repo-root "$eks_root" \
    --dev-context dev-context --prod-context prod-context --freeze-evidence "$static_freeze" \
    --output "$tmp_root/existing-workload-removal.json" >/dev/null 2>&1; then
  fail 'static removal execution accepted a remaining workload'
fi

collision_root="$tmp_root/EKS-infra-collision"
mkdir -p "$collision_root/evidence/cleanup"
jq '.resources |= map(if .kind=="PersistentVolumeClaim" then .id="app-dev/data-u-1" else . end) | .resources |= sort_by(.kind,.id)' \
  "$eks_root/evidence/cleanup/ownership-inventory.json" >"$collision_root/evidence/cleanup/ownership-inventory.json"
if COURSE_CHECK_BIN_DIR="$fake_bin" FAKE_CLEANUP_DIR="$runtime" \
  bash "$repository_root/scripts/capture-cleanup-evidence.sh" removal --eks-repo-root "$collision_root" \
    --dev-context dev-context --prod-context prod-context --freeze-evidence "$static_freeze" \
    --output "$tmp_root/collision-removal.json" >/dev/null 2>&1; then
  fail 'static removal execution accepted a retained-object ID suffix collision'
fi

delete_provider_root="$tmp_root/EKS-infra-delete-provider"
mkdir -p "$delete_provider_root/evidence/cleanup"
jq '.resources |= map(if .kind=="SecretsManagerSecret" then .decision="DELETE" | .owner="course" else . end)' \
  "$eks_root/evidence/cleanup/ownership-inventory.json" >"$delete_provider_root/evidence/cleanup/ownership-inventory.json"
if COURSE_CHECK_BIN_DIR="$fake_bin" FAKE_CLEANUP_DIR="$runtime" \
  bash "$repository_root/scripts/capture-cleanup-evidence.sh" removal --eks-repo-root "$delete_provider_root" \
    --dev-context dev-context --prod-context prod-context --freeze-evidence "$static_freeze" \
    --output "$tmp_root/delete-provider-removal.json" >/dev/null 2>&1; then
  fail 'static removal execution treated a delete-planned provider Secret as retained'
fi

provider_runtime="$tmp_root/cleanup-runtime-provider-unobservable"
cp -R "$runtime" "$provider_runtime"
rm -f -- "$provider_runtime/provider-secret.json"
if COURSE_CHECK_BIN_DIR="$fake_bin" FAKE_CLEANUP_DIR="$provider_runtime" \
  bash "$repository_root/scripts/capture-cleanup-evidence.sh" removal --eks-repo-root "$eks_root" \
    --dev-context dev-context --prod-context prod-context --freeze-evidence "$static_freeze" \
    --output "$tmp_root/provider-removal.json" >/dev/null 2>&1; then
  fail 'static removal execution accepted an unobservable provider Secret'
fi

if COURSE_CHECK_BIN_DIR="$fake_bin" FAKE_CLEANUP_DIR="$runtime" \
  bash "$repository_root/scripts/capture-cleanup-evidence.sh" removal --eks-repo-root "$eks_root" \
    --dev-context dev-context --prod-context prod-context --freeze-evidence "$static_freeze" \
    --output "$removal_output" >/dev/null 2>&1; then
  fail 'static cleanup adapter wrote to the canonical runtime evidence path'
fi

echo '[STATIC] PASS: runtime producer source contracts and non-writing fixture adapters are valid; live cloud capture was not run.'
