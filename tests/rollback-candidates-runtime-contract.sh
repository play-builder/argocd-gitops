#!/usr/bin/env bash
set -Eeuo pipefail

test_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
repository_root=$(cd -- "$test_root/.." && pwd -P)
script="$repository_root/scripts/capture-rollback-candidates-evidence.sh"
source_record="$repository_root/envs/prod/rollback-compatibility.yaml"
canonical="$repository_root/evidence/prod/rollback-candidates.json"
sample_verifier_resolver="$test_root/lib/resolve-sample-verifier.sh"
sample_verifier=$("$sample_verifier_resolver")
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
[[ -x "$script" ]] || fail 'rollback candidate runtime producer is missing or not executable'
head -1 "$script" | grep -Fqx '#!/usr/bin/env bash' || fail 'rollback candidate producer has the wrong shebang'
grep -Fq 'set -Eeuo pipefail' "$script" || fail 'rollback candidate producer is not fail-fast'

yq -o=json '.' "$source_record" | jq -e '
  .completedRollback as $rollback |
  [$rollback.replicaSetList.items[] |
    select((.metadata.annotations["rollouts.argoproj.io/experiment-name"] // "") == "") |
    select(.metadata.labels["rollouts-pod-template-hash"] != $rollback.stableHash) |
    .metadata.annotations["rollout.argoproj.io/revision"] | tonumber] as $retained |
  ([ $rollback.candidates[].rolloutRevision ] | sort) == ($retained | sort) and
  ($rollback.candidates | length) == $rollback.rollbackWindow.revisions
' >/dev/null || fail 'canonical rollback source must enumerate every retained non-Experiment revision'

fake_bin="$tmp_root/bin"
runtime="$tmp_root/runtime-valid"
mkdir -p "$fake_bin" "$runtime"
for command in argocd aws git kubectl; do
  ln -s "$test_root/helpers/fake-rollback-candidates-cli.sh" "$fake_bin/$command"
done
cp "$source_record" "$runtime/source.yaml"
printf '%s\n' fedcba9876543210fedcba9876543210fedcba98 >"$runtime/git-revision.txt"
: >"$runtime/git-status.txt"
printf '%s\n' yes >"$runtime/configmap-create-permission.txt"
printf '%s\n' yes >"$runtime/configmap-delete-permission.txt"
: >"$runtime/existing-configmap.json"
: >"$runtime/kubectl.log"
jq -n '{metadata:{name:"sample-app-prod"},spec:{source:{repoURL:"https://github.com/OWNER/argocd-gitops.git"},syncPolicy:{}},status:{sync:{status:"OutOfSync",revision:"fedcba9876543210fedcba9876543210fedcba98"},health:{status:"Healthy"}}}' >"$runtime/application.json"
jq -n '{cluster:{name:"course-prod",arn:"arn:aws:eks:ap-northeast-2:123456789012:cluster/course-prod",status:"ACTIVE",endpoint:"https://prod.eks.example"}}' >"$runtime/cluster.json"
jq -n '{clusters:[{cluster:{server:"https://prod.eks.example"}}]}' >"$runtime/kubeconfig.json"
jq -n '
  {metadata:{name:"sample-app",namespace:"app-prod",uid:"11111111-1111-1111-1111-111111111111"},
   spec:{rollbackWindow:{revisions:2}},
   status:{phase:"Healthy",stableRS:"stable-hash",currentPodHash:"stable-hash",
     replicas:3,readyReplicas:3,availableReplicas:3,pauseConditions:[]}}
' >"$runtime/rollout.json"
yq -o=json '.' "$runtime/source.yaml" | jq '
  . as $source |
  "123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/course/sample-app" as $repository |
  $source.releaseLineage.v2PrimeContractCompatible.indexDigest as $v2prime |
  {apiVersion:"apps/v1",kind:"ReplicaSetList",items:[
    $source.completedRollback.replicaSetList.items[] |
    . as $item |
    ($item.metadata.labels["rollouts-pod-template-hash"] // "experiment-hash") as $hash |
    . + {spec:{replicas:1,template:{spec:{containers:[{name:"sample-app",image:($repository + "@" +
      (if ($hash == "target-hash" or $hash == "intermediate-hash") then $v2prime
       else "sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee" end))}]}}},
      status:{readyReplicas:1,availableReplicas:1}}
  ]}
' >"$runtime/replicasets.json"

runtime_region() { jq -r '.cluster.arn | split(":")[3]' "$1/cluster.json"; }
runtime_cluster() { jq -r '.cluster.name' "$1/cluster.json"; }
run_static() {
  local source_dir=$1 output=$2 now=${3:-2026-09-03T01:00:00Z}
  COURSE_CHECK_BIN_DIR="$fake_bin" FAKE_ROLLBACK_DIR="$source_dir" \
    AWS_REGION="$(runtime_region "$source_dir")" EKS_CLUSTER_NAME="$(runtime_cluster "$source_dir")" \
    bash "$script" --source "$source_dir/source.yaml" --output "$output" --now "$now"
}
run_publish_fixture() {
  local source_dir=$1 evidence=$2 now=${3:-2026-09-03T01:00:00Z}
  COURSE_CHECK_BIN_DIR="$fake_bin" FAKE_ROLLBACK_DIR="$source_dir" \
    AWS_REGION="$(runtime_region "$source_dir")" EKS_CLUSTER_NAME="$(runtime_cluster "$source_dir")" \
    bash "$script" --publish-fixture "$evidence" --now "$now"
}
run_cleanup_fixture() {
  local source_dir=$1 evidence=$2 now=${3:-2026-09-03T01:10:00Z}
  COURSE_CHECK_BIN_DIR="$fake_bin" FAKE_ROLLBACK_DIR="$source_dir" \
    AWS_REGION="$(runtime_region "$source_dir")" EKS_CLUSTER_NAME="$(runtime_cluster "$source_dir")" \
    bash "$script" cleanup --fixture "$evidence" --now "$now"
}

static_output="$tmp_root/rollback-candidates-static.json"
static_log=$(run_static "$runtime" "$static_output") || fail 'valid static runtime adapter was rejected'
grep -Fq '[STATIC]' <<<"$static_log" || fail 'fake runtime execution was not labelled STATIC'
source_digest="sha256:$(shasum -a 256 "$runtime/source.yaml" | awk '{print $1}')"
jq -e --arg digest "$source_digest" '
  (keys | sort) == ["candidates","clusterArn","environment","evidenceGrade","expiresAt","gitopsRevision","observedAt","region","rolloutName","schemaVersion","sourceEvidenceDigest"] and
  .schemaVersion == "course.rollback-candidates/v1" and .evidenceGrade == "STATIC" and
  .environment == "prod" and .region == "ap-northeast-2" and
  .clusterArn == "arn:aws:eks:ap-northeast-2:123456789012:cluster/course-prod" and
  .rolloutName == "sample-app" and
  .gitopsRevision == "fedcba9876543210fedcba9876543210fedcba98" and
  .sourceEvidenceDigest == $digest and
  .observedAt == "2026-09-03T00:59:59Z" and .expiresAt == "2026-09-03T01:59:59Z" and
  [.candidates[].rolloutRevision] == [3,4] and
  all(.candidates[]; .productReadContract == "v2prime")
' "$static_output" >/dev/null || fail 'static adapter output is not the canonical rollback candidate projection'
[[ "$(file_mode "$static_output")" == 600 ]] || fail 'rollback candidate output mode must be 0600'
[[ "$before" == "$(fingerprint)" ]] || fail 'static adapter changed canonical runtime evidence'
if grep -Eq 'auth can-i|configmap|create -f' "$runtime/kubectl.log"; then
  fail 'static adapter attempted to publish a ConfigMap'
fi

cloud_fixture="$tmp_root/rollback-candidates-cloud.json"
jq '.evidenceGrade="CLOUD_RUNTIME"' "$static_output" >"$cloud_fixture"
bash "$script" --fixture "$cloud_fixture" >/dev/null || fail 'runtime-shaped CLOUD_RUNTIME fixture was rejected'
[[ "$before" == "$(fingerprint)" ]] || fail 'fixture validation changed canonical runtime evidence'

if [[ -f "$sample_verifier" ]]; then
  node --input-type=module - "$sample_verifier" "$cloud_fixture" <<'NODE'
import { pathToFileURL } from 'node:url';
import fs from 'node:fs';
const verifierPath = process.argv[2];
const evidencePath = process.argv[3];
const { verifyContract003RollbackCandidates } = await import(pathToFileURL(verifierPath));
const evidence = JSON.parse(fs.readFileSync(evidencePath, 'utf8'));
const expected = Object.fromEntries([
  'environment','region','clusterArn','rolloutName','gitopsRevision','sourceEvidenceDigest',
].map((key) => [key, evidence[key]]));
verifyContract003RollbackCandidates(evidencePath, expected, new Date('2026-09-03T01:00:00Z'));
for (const key of Object.keys(expected)) {
  let rejected = false;
  try { verifyContract003RollbackCandidates(evidencePath, {...expected, [key]: `${expected[key]}-drift`}, new Date('2026-09-03T01:00:00Z')); }
  catch { rejected = true; }
  if (!rejected) throw new Error(`Sample verifier accepted expected ${key} drift`);
}
NODE
  sample_repository=$(git -C "$(dirname -- "$sample_verifier")" rev-parse --show-toplevel)
  sample_revision=$(git -C "$sample_repository" rev-parse HEAD)
  echo "[STATIC] verified Sample Contract 003 with $sample_repository at $sample_revision"
else
  echo '[STATIC] Sample Contract 003 verification skipped by explicit SAMPLE_APP_VERIFIER_OPTIONAL=1.'
fi

for label in dirty-git git-mismatch already-synced automated-sync running-operation cluster-account cluster-region cluster-name kube-endpoint rollout-name rollout-uid rollout-window rollout-unhealthy foreign-owner non-controller missing-candidate-rs extra-candidate-rs experiment-candidate wrong-candidate-image source-missing-candidate source-extra-candidate source-duplicate-candidate source-wrong-lineage source-wrong-revert source-window; do
  invalid="$tmp_root/runtime-$label"
  cp -R "$runtime" "$invalid"
  case "$label" in
    dirty-git) printf '%s\n' ' M envs/prod/values.yaml' >"$invalid/git-status.txt" ;;
    git-mismatch) jq '.status.sync.revision="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' "$invalid/application.json" >"$invalid/mutated" && mv "$invalid/mutated" "$invalid/application.json" ;;
    already-synced) jq '.status.sync.status="Synced"' "$invalid/application.json" >"$invalid/mutated" && mv "$invalid/mutated" "$invalid/application.json" ;;
    automated-sync) jq '.spec.syncPolicy.automated={prune:true}' "$invalid/application.json" >"$invalid/mutated" && mv "$invalid/mutated" "$invalid/application.json" ;;
    running-operation) jq '.status.operationState.phase="Running"' "$invalid/application.json" >"$invalid/mutated" && mv "$invalid/mutated" "$invalid/application.json" ;;
    cluster-account) jq '.cluster.arn="arn:aws:eks:ap-northeast-2:999999999999:cluster/course-prod"' "$invalid/cluster.json" >"$invalid/mutated" && mv "$invalid/mutated" "$invalid/cluster.json" ;;
    cluster-region) jq '.cluster.arn="arn:aws:eks:us-east-1:123456789012:cluster/course-prod"' "$invalid/cluster.json" >"$invalid/mutated" && mv "$invalid/mutated" "$invalid/cluster.json" ;;
    cluster-name) jq '.cluster.arn="arn:aws:eks:ap-northeast-2:123456789012:cluster/other-prod"' "$invalid/cluster.json" >"$invalid/mutated" && mv "$invalid/mutated" "$invalid/cluster.json" ;;
    kube-endpoint) jq '.clusters[0].cluster.server="https://foreign.eks.example"' "$invalid/kubeconfig.json" >"$invalid/mutated" && mv "$invalid/mutated" "$invalid/kubeconfig.json" ;;
    rollout-name) jq '.metadata.name="other-app"' "$invalid/rollout.json" >"$invalid/mutated" && mv "$invalid/mutated" "$invalid/rollout.json" ;;
    rollout-uid) jq '.metadata.uid="foreign-uid"' "$invalid/rollout.json" >"$invalid/mutated" && mv "$invalid/mutated" "$invalid/rollout.json" ;;
    rollout-window) jq '.spec.rollbackWindow.revisions=3' "$invalid/rollout.json" >"$invalid/mutated" && mv "$invalid/mutated" "$invalid/rollout.json" ;;
    rollout-unhealthy) jq '.status.phase="Progressing"' "$invalid/rollout.json" >"$invalid/mutated" && mv "$invalid/mutated" "$invalid/rollout.json" ;;
    foreign-owner) jq '.items[0].metadata.ownerReferences[0].uid="foreign-uid"' "$invalid/replicasets.json" >"$invalid/mutated" && mv "$invalid/mutated" "$invalid/replicasets.json" ;;
    non-controller) jq '.items[0].metadata.ownerReferences[0].controller=false' "$invalid/replicasets.json" >"$invalid/mutated" && mv "$invalid/mutated" "$invalid/replicasets.json" ;;
    missing-candidate-rs) jq '.items |= map(select(.metadata.name != "sample-app-intermediate"))' "$invalid/replicasets.json" >"$invalid/mutated" && mv "$invalid/mutated" "$invalid/replicasets.json" ;;
    extra-candidate-rs) jq '.items += [.items[1] | .metadata.name="sample-app-extra" | .metadata.labels["rollouts-pod-template-hash"]="extra-hash" | .metadata.annotations["rollout.argoproj.io/revision"]="2"]' "$invalid/replicasets.json" >"$invalid/mutated" && mv "$invalid/mutated" "$invalid/replicasets.json" ;;
    experiment-candidate) jq '.items[] |= if .metadata.name=="sample-app-intermediate" then .metadata.annotations["rollouts.argoproj.io/experiment-name"]="analysis" else . end' "$invalid/replicasets.json" >"$invalid/mutated" && mv "$invalid/mutated" "$invalid/replicasets.json" ;;
    wrong-candidate-image) jq '.items[] |= if .metadata.name=="sample-app-target" then .spec.template.spec.containers[0].image |= sub("4{64}$";"3" * 64) else . end' "$invalid/replicasets.json" >"$invalid/mutated" && mv "$invalid/mutated" "$invalid/replicasets.json" ;;
    source-missing-candidate) yq -i 'del(.completedRollback.candidates[1])' "$invalid/source.yaml" ;;
    source-extra-candidate) yq -i '.completedRollback.candidates += [.completedRollback.candidates[0] | .rolloutRevision=2 | .podTemplateHash="extra-hash"]' "$invalid/source.yaml" ;;
    source-duplicate-candidate) yq -i '.completedRollback.candidates[1]=.completedRollback.candidates[0]' "$invalid/source.yaml" ;;
    source-wrong-lineage) yq -i '.completedRollback.candidates[0].imageDigest="sha256:3333333333333333333333333333333333333333333333333333333333333333"' "$invalid/source.yaml" ;;
    source-wrong-revert) yq -i '.completedRollback.candidates[0].gitRevertSha="3333333333333333333333333333333333333333"' "$invalid/source.yaml" ;;
    source-window) yq -i '.completedRollback.rollbackWindow.revisions=1' "$invalid/source.yaml" ;;
  esac
  if run_static "$invalid" "$tmp_root/$label-output.json" >/dev/null 2>&1; then
    fail "static rollback adapter accepted $label"
  fi
done

for whitespace in ascii-space bom; do
  value=' '
  [[ "$whitespace" == bom ]] && value=$(printf '\357\273\277')
  for identity in rollout-name rollout-uid stable-hash target-candidate-hash; do
    invalid="$tmp_root/runtime-$identity-$whitespace"
    cp -R "$runtime" "$invalid"
    case "$identity" in
      rollout-name) yq -i ".completedRollback.rolloutName=\"$value\"" "$invalid/source.yaml" ;;
      rollout-uid) yq -i ".completedRollback.rolloutUid=\"$value\"" "$invalid/source.yaml" ;;
      stable-hash) yq -i ".completedRollback.stableHash=\"$value\"" "$invalid/source.yaml" ;;
      target-candidate-hash) yq -i ".completedRollback.targetHash=\"$value\" | .completedRollback.candidates[0].podTemplateHash=\"$value\"" "$invalid/source.yaml" ;;
    esac
    if run_static "$invalid" "$tmp_root/$identity-$whitespace-output.json" >/dev/null 2>&1; then
      fail "static rollback adapter accepted $whitespace-only $identity"
    fi
  done
done

for region in ap-northeast-2 us-east-1; do
  for cluster_name in a "$(printf 'a%.0s' {1..100})"; do
    boundary="$tmp_root/runtime-$region-${#cluster_name}"
    cp -R "$runtime" "$boundary"
    endpoint="https://$region-${#cluster_name}.eks.example"
    jq --arg region "$region" --arg name "$cluster_name" --arg endpoint "$endpoint" '
      .cluster.name=$name | .cluster.arn=("arn:aws:eks:"+$region+":123456789012:cluster/"+$name) | .cluster.endpoint=$endpoint
    ' "$boundary/cluster.json" >"$boundary/mutated" && mv "$boundary/mutated" "$boundary/cluster.json"
    jq --arg endpoint "$endpoint" '.clusters[0].cluster.server=$endpoint' "$boundary/kubeconfig.json" >"$boundary/mutated" && mv "$boundary/mutated" "$boundary/kubeconfig.json"
    if [[ "$region" == us-east-1 ]]; then
      jq '.items[].spec.template.spec.containers[].image |= sub("ecr.ap-northeast-2";"ecr.us-east-1")' "$boundary/replicasets.json" >"$boundary/mutated" && mv "$boundary/mutated" "$boundary/replicasets.json"
    fi
    run_static "$boundary" "$tmp_root/boundary-$region-${#cluster_name}.json" >/dev/null ||
      fail "rollback producer rejected supported $region cluster-name length ${#cluster_name}"
  done
done

for option in --source --output --now; do
  if AWS_REGION=ap-northeast-2 EKS_CLUSTER_NAME=course-prod bash "$script" "$option" "$tmp_root/override" >/dev/null 2>&1; then
    fail "runtime producer accepted arbitrary $option override"
  fi
done
if COURSE_CHECK_BIN_DIR="$fake_bin" FAKE_ROLLBACK_DIR="$runtime" AWS_REGION=ap-northeast-2 EKS_CLUSTER_NAME=course-prod \
  bash "$script" --source "$runtime/source.yaml" --output "$canonical" --now 2026-09-03T01:00:00Z >/dev/null 2>&1; then
  fail 'static runtime adapter wrote the canonical runtime evidence path'
fi

publish_runtime="$tmp_root/runtime-publish"
cp -R "$runtime" "$publish_runtime"
publish_log=$(run_publish_fixture "$publish_runtime" "$cloud_fixture") || fail 'valid ConfigMap publication simulation was rejected'
grep -Fq '[STATIC]' <<<"$publish_log" || fail 'ConfigMap publication simulation was not labelled STATIC'
created="$publish_runtime/created-configmap.json"
[[ -f "$created" ]] || fail 'ConfigMap publication did not issue the create request'
evidence_sha="sha256:$(shasum -a 256 "$cloud_fixture" | awk '{print $1}')"
jq -e --rawfile evidence "$cloud_fixture" --arg evidenceSha "$evidence_sha" --arg sourceDigest "$source_digest" '
  .apiVersion == "v1" and .kind == "ConfigMap" and
  .metadata.name == "sample-app-rollback-candidates" and .metadata.namespace == "app-prod" and
  .metadata.labels == {
    "app.kubernetes.io/name":"sample-app-rollback-candidates",
    "app.kubernetes.io/part-of":"sample-app",
    "course.playbuilder.io/cleanup-scope":"rollback-candidates"
  } and
  .metadata.annotations == {
    "course.playbuilder.io/content-sha256":$evidenceSha,
    "course.playbuilder.io/source-evidence-digest":$sourceDigest
  } and .immutable == true and
  (.data | keys | sort) == ["clusterArn","environment","gitopsRevision","region","rollback-candidates.json","rolloutName","sourceEvidenceDigest"] and
  .data["rollback-candidates.json"] == $evidence and
  .data.environment == "prod" and .data.region == "ap-northeast-2" and
  .data.clusterArn == "arn:aws:eks:ap-northeast-2:123456789012:cluster/course-prod" and
  .data.rolloutName == "sample-app" and
  .data.gitopsRevision == "fedcba9876543210fedcba9876543210fedcba98" and
  .data.sourceEvidenceDigest == $sourceDigest and
  (has("binaryData") | not)
' "$created" >/dev/null || fail 'immutable ConfigMap payload is not exact or byte-bound'

cp "$created" "$publish_runtime/existing-configmap.json"
: >"$publish_runtime/kubectl.log"
run_publish_fixture "$publish_runtime" "$cloud_fixture" >/dev/null || fail 'identical existing ConfigMap was not idempotent'
if grep -Fq 'create -f' "$publish_runtime/kubectl.log"; then
  fail 'idempotent publication attempted to recreate the immutable ConfigMap'
fi
jq '.data.region="us-east-1"' "$created" >"$publish_runtime/existing-configmap.json"
if run_publish_fixture "$publish_runtime" "$cloud_fixture" >/dev/null 2>&1; then
  fail 'publication accepted an existing ConfigMap with different bound data'
fi
printf '%s\n' no >"$publish_runtime/configmap-create-permission.txt"
: >"$publish_runtime/existing-configmap.json"
if run_publish_fixture "$publish_runtime" "$cloud_fixture" >/dev/null 2>&1; then
  fail 'publication proceeded without ConfigMap create authorization'
fi

for label in grade environment cluster-arn rollout-name observed-fraction observed-offset observed-calendar future expired excessive-ttl candidate-digest candidate-contract candidate-revision candidate-revert candidate-hash extra-root; do
  invalid_evidence="$tmp_root/evidence-$label.json"
  case "$label" in
    grade) expression='.evidenceGrade="STATIC"' ;;
    environment) expression='.environment="dev"' ;;
    cluster-arn) expression='.clusterArn="arn:aws:eks:ap-northeast-2:999999999999:cluster/course-prod"' ;;
    rollout-name) expression='.rolloutName=" "' ;;
    observed-fraction) expression='.observedAt="2026-09-03T00:59:59.000Z"' ;;
    observed-offset) expression='.observedAt="2026-09-03T09:59:59+09:00"' ;;
    observed-calendar) expression='.observedAt="2026-02-31T00:59:59Z"' ;;
    future) expression='.observedAt="2026-09-03T01:00:01Z" | .expiresAt="2026-09-03T01:59:59Z"' ;;
    expired) expression='.expiresAt="2026-09-03T01:00:00Z"' ;;
    excessive-ttl) expression='.expiresAt="2026-09-03T02:00:00Z"' ;;
    candidate-digest) expression='.candidates[0].imageDigest="sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' ;;
    candidate-contract) expression='.candidates[0].productReadContract="v2"' ;;
    candidate-revision) expression='.candidates[0].rolloutRevision=0' ;;
    candidate-revert) expression='.candidates[0].gitRevertSha="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' ;;
    candidate-hash) expression='.candidates[0].podTemplateHash="\uFEFF"' ;;
    extra-root) expression='.extra=true' ;;
  esac
  jq "$expression" "$cloud_fixture" >"$invalid_evidence"
  if run_publish_fixture "$runtime" "$invalid_evidence" >/dev/null 2>&1; then
    fail "ConfigMap publisher accepted invalid $label evidence"
  fi
done

cleanup_runtime="$tmp_root/runtime-cleanup"
cp -R "$runtime" "$cleanup_runtime"
jq '.metadata.uid="88888888-8888-8888-8888-888888888888"' "$created" >"$cleanup_runtime/existing-configmap.json"
printf '%s\n' aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa >"$cleanup_runtime/git-revision.txt"
jq -n '{
  metadata:{name:"sample-app-prod"},
  spec:{
    source:{
      repoURL:"https://github.com/OWNER/argocd-gitops.git",
      helm:{valueFiles:[
        "../../envs/prod/values.yaml",
        "../../envs/prod/stateful-values.yaml",
        "../../envs/prod/migration-finalize-values.yaml"
      ]}
    },
    syncPolicy:{}
  },
  status:{
    sync:{status:"Synced",revision:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},
    health:{status:"Healthy"},
    operationState:{phase:"Succeeded"}
  }
}' >"$cleanup_runtime/application.json"
helm template sample-app "$repository_root/charts/sample-app" \
  --values "$repository_root/envs/prod/values.yaml" \
  --values "$repository_root/envs/prod/stateful-values.yaml" \
  --values "$test_root/fixtures/values/stateful-policy-on.yaml" \
  --values "$repository_root/envs/prod/migration-finalize-values.yaml" \
  --set-string image.repository=example.invalid/sample-app \
  --set-string image.digest=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  --set-string database.migrationImage.repository=example.invalid/sample-app \
  --set-string database.migrationImage.digest=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa |
  yq eval-all -o=json 'select(.kind == "Job" and .metadata.name == "sample-app-migration")' - |
  jq '.spec.template.spec.volumes[] |= if .name=="rollback-candidates" then .configMap.defaultMode=292 else . end |
      .status={succeeded:1,failed:0,completionTime:"2026-09-03T01:05:00Z"}' \
    >"$cleanup_runtime/migration-job.json"

for label in configmap-drift missing-uid app-outofsync app-wrong-revision app-wrong-phase \
  failed-job early-job wrong-target stale-evidence delete-denied; do
  invalid_cleanup="$tmp_root/cleanup-$label"
  cp -R "$cleanup_runtime" "$invalid_cleanup"
  case "$label" in
    configmap-drift) jq '.data.region="us-east-1"' "$invalid_cleanup/existing-configmap.json" >"$invalid_cleanup/mutated" && mv "$invalid_cleanup/mutated" "$invalid_cleanup/existing-configmap.json" ;;
    missing-uid) jq '.metadata.uid="\uFEFF"' "$invalid_cleanup/existing-configmap.json" >"$invalid_cleanup/mutated" && mv "$invalid_cleanup/mutated" "$invalid_cleanup/existing-configmap.json" ;;
    app-outofsync) jq '.status.sync.status="OutOfSync"' "$invalid_cleanup/application.json" >"$invalid_cleanup/mutated" && mv "$invalid_cleanup/mutated" "$invalid_cleanup/application.json" ;;
    app-wrong-revision) jq '.status.sync.revision="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"' "$invalid_cleanup/application.json" >"$invalid_cleanup/mutated" && mv "$invalid_cleanup/mutated" "$invalid_cleanup/application.json" ;;
    app-wrong-phase) jq '.spec.source.helm.valueFiles[2]="../../envs/prod/migration-contract-values.yaml"' "$invalid_cleanup/application.json" >"$invalid_cleanup/mutated" && mv "$invalid_cleanup/mutated" "$invalid_cleanup/application.json" ;;
    failed-job) jq '.status.succeeded=0 | .status.failed=1' "$invalid_cleanup/migration-job.json" >"$invalid_cleanup/mutated" && mv "$invalid_cleanup/mutated" "$invalid_cleanup/migration-job.json" ;;
    early-job) jq '.status.completionTime="2026-09-03T00:59:58Z"' "$invalid_cleanup/migration-job.json" >"$invalid_cleanup/mutated" && mv "$invalid_cleanup/mutated" "$invalid_cleanup/migration-job.json" ;;
    wrong-target) jq '.spec.template.spec.containers[0].args[1]="002_expand_product_display_name"' "$invalid_cleanup/migration-job.json" >"$invalid_cleanup/mutated" && mv "$invalid_cleanup/mutated" "$invalid_cleanup/migration-job.json" ;;
    stale-evidence) jq '.spec.template.spec.containers[0].env += [{name:"ROLLBACK_CANDIDATES_FILE",value:"/var/run/course-evidence/rollback-candidates.json"}]' "$invalid_cleanup/migration-job.json" >"$invalid_cleanup/mutated" && mv "$invalid_cleanup/mutated" "$invalid_cleanup/migration-job.json" ;;
    delete-denied) printf '%s\n' no >"$invalid_cleanup/configmap-delete-permission.txt" ;;
  esac
  if run_cleanup_fixture "$invalid_cleanup" "$cloud_fixture" >/dev/null 2>&1; then
    fail "rollback ConfigMap cleanup accepted $label"
  fi
done

cleanup_log=$(run_cleanup_fixture "$cleanup_runtime" "$cloud_fixture") ||
  fail 'valid UID-bound rollback ConfigMap cleanup simulation was rejected'
grep -Fq '[STATIC]' <<<"$cleanup_log" || fail 'rollback ConfigMap cleanup simulation was not labelled STATIC'
jq -e '
  .apiVersion == "v1" and .kind == "DeleteOptions" and .propagationPolicy == "Background" and
  .preconditions == {uid:"88888888-8888-8888-8888-888888888888"}
' "$cleanup_runtime/delete-options.json" >/dev/null ||
  fail 'rollback ConfigMap deletion was not bound to the observed immutable UID'
[[ ! -s "$cleanup_runtime/existing-configmap.json" ]] ||
  fail 'rollback ConfigMap cleanup did not re-query absence'

echo '[STATIC] PASS: rollback candidate runtime handoff is canonical; live cloud capture was not run.'
