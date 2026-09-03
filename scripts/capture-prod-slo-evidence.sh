#!/usr/bin/env bash
set -Eeuo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
repository_root=$(cd -- "$script_dir/.." && pwd -P)
output="$repository_root/evidence/prod/slo.json"
fixture=""
promotion="$repository_root/envs/prod/promotion-evidence.yaml"
baseline="$repository_root/evidence/prod/baseline.json"
runtime_override=false
now_override=""
adapter_dir=${COURSE_CHECK_BIN_DIR:-}

fail() { echo "FAIL: $*" >&2; exit 1; }
usage() { echo "Usage: $0 [--fixture path] [--promotion-evidence path] [--baseline path] [--output path]" >&2; exit 2; }

require_exact_regular_file() {
  local requested=$1 expected=$2 label=$3 physical_parent resolved
  [[ -f "$requested" && ! -L "$requested" ]] || fail "$label must be a regular non-symlink file"
  physical_parent=$(cd -- "$(dirname -- "$requested")" && pwd -P) || fail "cannot resolve $label parent"
  resolved="$physical_parent/$(basename -- "$requested")"
  [[ "$resolved" == "$expected" ]] || fail "$label escaped its canonical repository path"
}

while (($#)); do
  case "$1" in
    --fixture) fixture=${2:?missing fixture path}; shift 2 ;;
    --promotion-evidence) promotion=${2:?missing promotion path}; runtime_override=true; shift 2 ;;
    --baseline) baseline=${2:?missing baseline path}; runtime_override=true; shift 2 ;;
    --output) output=${2:?missing output path}; runtime_override=true; shift 2 ;;
    --now) now_override=${2:?missing static clock}; shift 2 ;;
    *) usage ;;
  esac
done

validate_record() {
  local file=$1 expected_grade=${2:-CLOUD_RUNTIME} observed_limit=${3:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}
  jq -e --arg grade "$expected_grade" --arg observedLimit "$observed_limit" '
    def canonical_utc_seconds:
      . as $value |
      type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$") and
      (try ((fromdateiso8601 | strftime("%Y-%m-%dT%H:%M:%SZ")) == $value) catch false);
    . as $root |
    (.image.repository | capture("^(?<account>[0-9]{12})\\.dkr\\.ecr\\.(?<region>ap-northeast-2|us-east-1)\\.amazonaws\\.com/(?<name>[a-z0-9]+([._/-][a-z0-9]+)*)$")) as $ecr |
    (.clusterArn | capture("^arn:aws:eks:(?<region>ap-northeast-2|us-east-1):(?<account>[0-9]{12}):cluster/[A-Za-z0-9][A-Za-z0-9_-]{0,99}$")) as $cluster |
    (keys | sort) == ["analysisRun","clusterArn","evidenceGrade","evidenceId","gitopsRevision","image","metricResults","observedAt","region","rollout","schemaVersion","source","status"] and
    .schemaVersion == "course.prod-slo/v1" and .evidenceGrade == $grade and .status == "PASS" and
    (.source | (keys | sort) == ["repository","sha"]) and (.image | (keys | sort) == ["indexDigest","repository"]) and
    (.source.repository | test("^[^/\\s]+/cicd-course-sample-app$")) and
    (.source.sha | test("^[0-9a-f]{40}$")) and (.image.indexDigest | test("^sha256:[0-9a-f]{64}$")) and
    (($ecr.name | length) >= 2 and ($ecr.name | length) <= 256) and
    (.gitopsRevision | test("^[0-9a-f]{40}$")) and (.clusterArn | test("^arn:aws:eks:(ap-northeast-2|us-east-1):[0-9]{12}:cluster/[A-Za-z0-9][A-Za-z0-9_-]{0,99}$")) and (.region | IN("ap-northeast-2","us-east-1")) and
    $ecr.region == $root.region and $cluster.region == $root.region and $ecr.account == $cluster.account and
    (.rollout | (keys | sort) == ["currentPodHash","name","phase","revision","stableHash","trafficWeight","uid"]) and
    (.rollout.revision | type == "number" and floor == . and . >= 2) and
    .rollout.phase == "Healthy" and .rollout.trafficWeight == 100 and .rollout.stableHash == .rollout.currentPodHash and
    (.analysisRun | (keys | sort) == ["name","phase","templateName","uid"]) and .analysisRun.phase == "Successful" and
    .analysisRun.templateName == "sample-app-success-rate" and
    (.metricResults | type == "array" and length == 2) and
    ([.metricResults[].name] | sort) == ["request-rate","success-rate"] and
    all(.metricResults[]; (keys | sort) == ["measurements","name","phase"] and .phase == "Successful" and ([.measurements[] | select(.phase == "Successful")] | length) > 0 and
      all(.measurements[]; (keys | sort) == ["finishedAt","phase","startedAt","value"] and
        (.phase | IN("Successful","Failed","Error")) and
        (.value | type == "string" and (try (tonumber | ((isnan or isinfinite) | not)) catch false)) and
        (.startedAt | canonical_utc_seconds) and (.finishedAt | canonical_utc_seconds) and
        (.startedAt | fromdateiso8601) <= (.finishedAt | fromdateiso8601))) and
    (.observedAt | canonical_utc_seconds) and ($observedLimit | canonical_utc_seconds) and
    (.observedAt | fromdateiso8601) <= ($observedLimit | fromdateiso8601)
  ' "$file" >/dev/null || fail "Prod SLO evidence failed canonical metric or terminal-state validation"
}

if [[ -n "$fixture" ]]; then
  [[ -z "$adapter_dir" && "$runtime_override" == false && -z "$now_override" ]] ||
    fail "fixture validation cannot be combined with runtime adapter options"
  [[ -f "$fixture" ]] || fail "fixture does not exist"
  validate_record "$fixture"
  echo "[STATIC] fake Prod SLO adapter validated canonical request-rate and success-rate evidence; no runtime file written."
  exit 0
fi

evidence_grade=CLOUD_RUNTIME
clock_now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
if [[ -n "$adapter_dir" ]]; then
  [[ -d "$adapter_dir" ]] || fail "COURSE_CHECK_BIN_DIR is not a directory"
  [[ "$runtime_override" == true && -n "$now_override" ]] ||
    fail "static runtime adapter requires explicit noncanonical inputs, output, and clock"
  [[ "$output" != "$repository_root/evidence/"* && "$output" != *'/tests/fixtures/'* ]] ||
    fail "static runtime adapter cannot write repository evidence or fixture paths"
  PATH="$adapter_dir:$PATH"
  evidence_grade=STATIC
  clock_now=$now_override
else
  [[ "$runtime_override" == false && -z "$now_override" ]] ||
    fail "runtime producer inputs and output are fixed to canonical repository paths"
  [[ "$output" == "$repository_root/evidence/prod/slo.json" ]] || fail "runtime producer output is fixed to evidence/prod/slo.json"
  require_exact_regular_file "$promotion" "$repository_root/envs/prod/promotion-evidence.yaml" "promotion evidence"
  require_exact_regular_file "$baseline" "$repository_root/evidence/prod/baseline.json" "Prod baseline"
fi
jq -en --arg now "$clock_now" '
  def canonical_utc_seconds:
    . as $value |
    type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$") and
    (try ((fromdateiso8601 | strftime("%Y-%m-%dT%H:%M:%SZ")) == $value) catch false);
  $now | canonical_utc_seconds
' >/dev/null ||
  fail "capture clock must be RFC3339 UTC"
[[ -f "$promotion" && -f "$baseline" ]] || fail "promotion evidence and Prod baseline are required"
for required in kubectl argocd aws git jq yq mktemp; do
  command -v "$required" >/dev/null || fail "$required is required for live Prod SLO capture"
done
[[ ${AWS_REGION:-} == ap-northeast-2 || ${AWS_REGION:-} == us-east-1 ]] ||
  fail "AWS_REGION must be ap-northeast-2 or us-east-1"
[[ -n ${EKS_CLUSTER_NAME:-} ]] || fail "EKS_CLUSTER_NAME is required"
[[ -z $(git -C "$repository_root" status --porcelain --untracked-files=all -- . ':(exclude)evidence') ]] ||
  fail "GitOps source outside evidence/ must match the checked-out commit before Prod SLO capture"
local_git_revision=$(git -C "$repository_root" rev-parse HEAD)
[[ "$local_git_revision" =~ ^[0-9a-f]{40}$ ]] || fail "local GitOps revision is not a full commit SHA"

promotion_json=$(yq -o=json -I=0 '.' "$promotion") || fail "promotion evidence is not valid YAML"
baseline_json=$(jq -c '.' "$baseline") || fail "Prod baseline is not valid JSON"
jq -e --arg now "$clock_now" '
  def canonical_utc_seconds:
    . as $value |
    type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$") and
    (try ((fromdateiso8601 | strftime("%Y-%m-%dT%H:%M:%SZ")) == $value) catch false);
  . as $root |
  .workflow as $workflow |
  (.workflow.runUrl | capture("^https://github\\.com/(?<repository>[^/\\s]+/cicd-course-sample-app)/actions/runs/(?<id>[0-9]+)$")) as $run |
  (.image.repository | capture("^(?<account>[0-9]{12})\\.dkr\\.ecr\\.(?<region>ap-northeast-2|us-east-1)\\.amazonaws\\.com/(?<name>[a-z0-9]+([._/-][a-z0-9]+)*)$")) as $ecr |
  (.cluster.arn | capture("^arn:aws:eks:(?<region>ap-northeast-2|us-east-1):(?<account>[0-9]{12}):cluster/[A-Za-z0-9][A-Za-z0-9_-]{0,99}$")) as $cluster |
  (keys | sort) == ["attestation","cluster","environment","expiresAt","gitops","image","issuedAt","region","schemaVersion","slo","sourceSha","workflow"] and
  .schemaVersion == "course.dev-ready/v1" and .environment == "dev" and
  (.region | IN("ap-northeast-2","us-east-1")) and
  (.sourceSha | test("^[0-9a-f]{40}$")) and
  ($workflow | (keys | sort) == ["event","name","runAttempt","runId","runUrl"]) and
  $workflow.name == "ci" and $workflow.event == "push" and
  ($workflow.runId | type == "string" and test("^[0-9]+$")) and
  ($workflow.runAttempt | type == "number" and floor == . and . >= 1) and
  $run.id == $workflow.runId and
  (.image | (keys | sort) == ["indexDigest","platforms","repository"]) and
  (.image.indexDigest | test("^sha256:[0-9a-f]{64}$")) and
  (($ecr.name | length) >= 2 and ($ecr.name | length) <= 256) and
  .image.platforms == ["linux/amd64","linux/arm64"] and
  (.attestation | (keys | sort) == ["githubId","githubUrl","ociProvenanceDigest","ociSbomDigest"]) and
  (.attestation.githubId | type == "string" and test("^[0-9]+$")) and
  .attestation.githubUrl == ("https://github.com/" + $run.repository + "/attestations/" + .attestation.githubId) and
  (.attestation.ociSbomDigest | test("^sha256:[0-9a-f]{64}$")) and
  (.attestation.ociProvenanceDigest | test("^sha256:[0-9a-f]{64}$")) and
  (.gitops | (keys | sort) == ["devRevision"]) and (.gitops.devRevision | test("^[0-9a-f]{40}$")) and
  (.cluster | (keys | sort) == ["arn"]) and
  (.slo | (keys | sort) == ["evidenceId"]) and (.slo.evidenceId | type == "string" and test("[^[:space:]\uFEFF]")) and
  $ecr.region == $root.region and $cluster.region == $root.region and $ecr.account == $cluster.account and
  (.issuedAt | canonical_utc_seconds) and (.expiresAt | canonical_utc_seconds) and
  ($now | canonical_utc_seconds) and
  (.issuedAt | fromdateiso8601) <= ($now | fromdateiso8601) and
  ($now | fromdateiso8601) < (.expiresAt | fromdateiso8601)
' <<<"$promotion_json" >/dev/null || fail "promotion evidence is not canonical DEV_READY"
jq -e --arg now "$clock_now" '
  def canonical_utc_seconds:
    . as $value |
    type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$") and
    (try ((fromdateiso8601 | strftime("%Y-%m-%dT%H:%M:%SZ")) == $value) catch false);
  . as $root |
  (.image.repository | capture("^(?<account>[0-9]{12})\\.dkr\\.ecr\\.(?<region>ap-northeast-2|us-east-1)\\.amazonaws\\.com/(?<name>[a-z0-9]+([._/-][a-z0-9]+)*)$")) as $ecr |
  (.clusterArn | capture("^arn:aws:eks:(?<region>ap-northeast-2|us-east-1):(?<account>[0-9]{12}):cluster/[A-Za-z0-9][A-Za-z0-9_-]{0,99}$")) as $cluster |
  (keys | sort) == ["clusterArn","evidenceGrade","gitopsRevision","image","observedAt","region","rollout","schemaVersion"] and
  .schemaVersion == "course.prod-baseline/v1" and .evidenceGrade == "CLOUD_RUNTIME" and
  (.image | (keys | sort) == ["indexDigest","repository"]) and
  (.image.indexDigest | test("^sha256:[0-9a-f]{64}$")) and
  (($ecr.name | length) >= 2 and ($ecr.name | length) <= 256) and
  (.gitopsRevision | test("^[0-9a-f]{40}$")) and
  (.rollout | (keys | sort) == ["revision","stableHash","trafficWeight"]) and
  (.rollout.stableHash | type == "string" and length > 0) and
  .rollout.revision == 1 and .rollout.trafficWeight == 100 and
  (.region | IN("ap-northeast-2","us-east-1")) and
  $ecr.region == $root.region and $cluster.region == $root.region and $ecr.account == $cluster.account and
  (.observedAt | canonical_utc_seconds) and ($now | canonical_utc_seconds) and
  (.observedAt | fromdateiso8601) <= ($now | fromdateiso8601)
' <<<"$baseline_json" >/dev/null || fail "Prod baseline is not a valid initial stable release"

source_sha=$(jq -r '.sourceSha' <<<"$promotion_json")
source_repository=$(jq -r '.workflow.runUrl | capture("^https://github\\.com/(?<repository>[^/\\s]+/cicd-course-sample-app)/actions/runs/[0-9]+$").repository' <<<"$promotion_json")
expected_repository=$(jq -r '.image.repository' <<<"$promotion_json")
expected_digest=$(jq -r '.image.indexDigest' <<<"$promotion_json")
dev_cluster_arn=$(jq -r '.cluster.arn' <<<"$promotion_json")
baseline_repository=$(jq -r '.image.repository' <<<"$baseline_json")
baseline_digest=$(jq -r '.image.indexDigest' <<<"$baseline_json")
baseline_cluster_arn=$(jq -r '.clusterArn' <<<"$baseline_json")
expected_region=$(jq -r '.region' <<<"$promotion_json")
baseline_region=$(jq -r '.region' <<<"$baseline_json")
[[ "$expected_region" == "$AWS_REGION" && "$baseline_region" == "$AWS_REGION" ]] ||
  fail "DEV_READY, baseline, and live Prod Region must match"
[[ "$expected_repository" == "$baseline_repository" ]] ||
  fail "DEV_READY and baseline image repositories must match"
[[ "$expected_digest" != "$baseline_digest" ]] || fail "Prod candidate reuses the baseline digest"
[[ "$dev_cluster_arn" != "$baseline_cluster_arn" ]] || fail "DEV_READY and baseline must bind distinct clusters"

app_json=$(argocd app get sample-app-prod -o json) || fail "unable to read sample-app-prod from Argo CD"
gitops_revision=$(jq -er '.status.operationState.syncResult.revision // .status.sync.revision' <<<"$app_json") ||
  fail "Argo CD did not report a GitOps revision"
jq -e '
  .metadata.name == "sample-app-prod" and .status.sync.status == "Synced" and
  .status.health.status == "Healthy" and (.spec.source.repoURL | test("/argocd-gitops(\\.git)?$"))
' <<<"$app_json" >/dev/null || fail "sample-app-prod must be Synced, Healthy, and GitOps-backed"
[[ "$gitops_revision" == "$local_git_revision" ]] ||
  fail "live Argo CD revision does not match the checked-out GitOps commit"

cluster_json=$(aws eks describe-cluster --name "$EKS_CLUSTER_NAME" --region "$AWS_REGION" --output json) ||
  fail "unable to describe the Prod EKS cluster"
cluster_arn=$(jq -er '.cluster.arn' <<<"$cluster_json") || fail "Prod EKS cluster ARN is missing"
cluster_endpoint=$(jq -er '.cluster.endpoint' <<<"$cluster_json") || fail "Prod EKS endpoint is missing"
jq -e --arg name "$EKS_CLUSTER_NAME" --arg arn "$baseline_cluster_arn" '
  .cluster.name == $name and .cluster.arn == $arn and .cluster.status == "ACTIVE" and
  (.cluster.endpoint | type == "string" and startswith("https://"))
' <<<"$cluster_json" >/dev/null || fail "live Prod EKS identity does not match the canonical baseline"
kubeconfig_json=$(kubectl config view --minify -o json) || fail "unable to inspect the active kube context"
kube_server=$(jq -er '.clusters | if length == 1 then .[0].cluster.server else empty end' <<<"$kubeconfig_json") ||
  fail "active kube context does not contain exactly one cluster server"
[[ "$kube_server" == "$cluster_endpoint" ]] || fail "active kube context endpoint does not match the Prod EKS cluster"

rollout_json=$(kubectl -n app-prod get rollout sample-app -o json) || fail "unable to read the Prod Rollout"
rollout_uid=$(jq -er '.metadata.uid' <<<"$rollout_json") || fail "Prod Rollout UID is missing"
stable_hash=$(jq -er '.status.stableRS' <<<"$rollout_json") || fail "Prod stable ReplicaSet hash is missing"
image=$(jq -er '[.spec.template.spec.containers[] | select(.name == "sample-app") | .image] | if length == 1 then .[0] else empty end' <<<"$rollout_json") ||
  fail "Prod Rollout must contain exactly one sample-app image"
jq -e '
  .metadata.name == "sample-app" and .metadata.namespace == "app-prod" and
  .status.phase == "Healthy" and .status.stableRS == .status.currentPodHash and
  (.status.replicas | type == "number" and . > 0) and
  .status.readyReplicas == .status.replicas and .status.availableReplicas == .status.replicas and
  ((.status.pauseConditions // []) | length) == 0 and
  [.spec.strategy.canary.analysis.templates[].templateName] == ["sample-app-success-rate"]
' <<<"$rollout_json" >/dev/null || fail "Prod Rollout is not a completed healthy SLO release"
[[ "$image" =~ ^([^@]+)@(sha256:[0-9a-f]{64})$ ]] || fail "Prod Rollout image must use an immutable digest"
image_repository=${BASH_REMATCH[1]}
image_digest=${BASH_REMATCH[2]}
[[ "$image_repository" == "$expected_repository" && "$image_digest" == "$expected_digest" ]] ||
  fail "live Prod image does not match DEV_READY repository and digest"

replicasets_json=$(kubectl -n app-prod get replicasets -l "rollouts-pod-template-hash=$stable_hash" -o json) ||
  fail "unable to read the stable Prod ReplicaSet"
stable_rs=$(jq -cer --arg uid "$rollout_uid" --arg hash "$stable_hash" --arg image "$image" '
  [.items[] | select(
    .metadata.labels["rollouts-pod-template-hash"] == $hash and
    (.metadata.annotations["rollout.argoproj.io/revision"] | test("^[0-9]+$")) and
    any(.metadata.ownerReferences[]?;
      .apiVersion == "argoproj.io/v1alpha1" and .kind == "Rollout" and
      .name == "sample-app" and .uid == $uid and .controller == true) and
    ([.spec.template.spec.containers[] | select(.name == "sample-app") | .image] == [$image]) and
    (.spec.replicas | type == "number" and . > 0) and
    .status.readyReplicas == .spec.replicas and .status.availableReplicas == .spec.replicas
  )] | if length == 1 then .[0] else empty end
' <<<"$replicasets_json") || fail "stable ReplicaSet ownership, revision, image, or readiness is ambiguous"
[[ -n "$stable_rs" ]] || fail "stable ReplicaSet ownership, revision, image, or readiness is ambiguous"
rollout_revision=$(jq -er '.metadata.annotations["rollout.argoproj.io/revision"] | tonumber' <<<"$stable_rs") ||
  fail "stable ReplicaSet revision is invalid"
baseline_revision=$(jq -r '.rollout.revision' <<<"$baseline_json")
((rollout_revision > baseline_revision)) || fail "Prod SLO revision did not advance beyond the baseline"

route_json=$(kubectl -n app-prod get httproute sample-app -o json) || fail "unable to read the Prod HTTPRoute"
jq -e '
  .metadata.name == "sample-app" and .metadata.namespace == "app-prod" and
  (.spec.rules | length) == 1 and (.spec.rules[0].backendRefs | length) == 2 and
  ([.spec.rules[0].backendRefs[] | {name,port,weight}] | sort_by(.name)) ==
    [{name:"sample-app-canary",port:80,weight:0},{name:"sample-app-stable",port:80,weight:100}] and
  ([.spec.rules[0].backendRefs[].weight] | add) == 100
' <<<"$route_json" >/dev/null || fail "Prod HTTPRoute is not routing 100 percent to the stable service"

analysis_json=$(kubectl -n app-prod get analysisruns.argoproj.io -o json) || fail "unable to read Prod AnalysisRuns"
analysis_matches=$(jq -ce --arg uid "$rollout_uid" --arg revision "$rollout_revision" '
  [.items[] | select(
    any(.metadata.ownerReferences[]?;
      .apiVersion == "argoproj.io/v1alpha1" and .kind == "Rollout" and
      .name == "sample-app" and .uid == $uid and .controller == true) and
    ((.metadata.annotations["rollout.argoproj.io/revision"] // "") | tostring) == $revision
  )]
' <<<"$analysis_json") || fail "unable to select owned AnalysisRuns for the stable revision"
[[ $(jq 'length' <<<"$analysis_matches") -eq 1 ]] ||
  fail "owned AnalysisRun selection for the stable revision is ambiguous"
analysis=$(jq -c '.[0]' <<<"$analysis_matches")
jq -e '
  (.metadata.name | type == "string" and length > 0) and
  (.metadata.uid | type == "string" and length > 0) and
  .status.phase == "Successful" and
  ([.spec.metrics[].name] | sort) == ["request-rate","success-rate"] and
  ([.status.metricResults[].name] | sort) == ["request-rate","success-rate"] and
  all(.status.metricResults[].measurements[]?; .finishedAt != null)
' <<<"$analysis" >/dev/null || fail "the unique owned AnalysisRun is not a successful canonical SLO analysis"

output_dir=$(dirname -- "$output")
mkdir -p "$output_dir"
if [[ "$evidence_grade" == CLOUD_RUNTIME ]]; then
  output_parent=$(cd -- "$output_dir" && pwd -P) || fail "cannot resolve canonical output directory"
  [[ "$output_parent/$(basename -- "$output")" == "$repository_root/evidence/prod/slo.json" ]] ||
    fail "canonical Prod SLO output escaped the repository evidence directory"
fi
tmp=$(mktemp "$output_dir/.slo.XXXXXX")
trap 'rm -f -- "$tmp"' EXIT
jq -n --arg source "$source_sha" --arg sourceRepository "$source_repository" \
  --arg repository "$image_repository" --arg digest "$image_digest" --arg git "$gitops_revision" \
  --arg arn "$cluster_arn" --arg region "$AWS_REGION" --arg grade "$evidence_grade" \
  --arg observed "$clock_now" --argjson revision "$rollout_revision" \
  --argjson ro "$rollout_json" --argjson ar "$analysis" '
  {schemaVersion:"course.prod-slo/v1",evidenceGrade:$grade,status:"PASS",
   source:{repository:$sourceRepository,sha:$source},image:{repository:$repository,indexDigest:$digest},
   gitopsRevision:$git,clusterArn:$arn,region:$region,
   evidenceId:("prod-slo-" + (($observed | fromdateiso8601) | floor | tostring)),
   rollout:{name:$ro.metadata.name,uid:$ro.metadata.uid,revision:$revision,stableHash:$ro.status.stableRS,
     currentPodHash:$ro.status.currentPodHash,trafficWeight:100,phase:$ro.status.phase},
   analysisRun:{name:$ar.metadata.name,uid:$ar.metadata.uid,phase:$ar.status.phase,templateName:"sample-app-success-rate"},
   metricResults:[$ar.status.metricResults[] | {name,phase,
     measurements:([.measurements[] | select(.finishedAt != null) | {value,phase,startedAt,finishedAt}])}],
   observedAt:$observed}
' >"$tmp" || fail "failed to construct Prod SLO evidence"
validate_record "$tmp" "$evidence_grade" "$clock_now"
if [[ -e "$output" ]]; then
  [[ -f "$output" && ! -L "$output" ]] || fail "Prod SLO output is not a regular non-symlink file"
  validate_record "$output" "$evidence_grade" "$clock_now"
  existing_identity=$(jq -cS '{source,image,gitopsRevision,clusterArn,region,
    rollout:{name:.rollout.name,uid:.rollout.uid,revision:.rollout.revision},
    analysisRun:{name:.analysisRun.name,uid:.analysisRun.uid}}' "$output")
  candidate_identity=$(jq -cS '{source,image,gitopsRevision,clusterArn,region,
    rollout:{name:.rollout.name,uid:.rollout.uid,revision:.rollout.revision},
    analysisRun:{name:.analysisRun.name,uid:.analysisRun.uid}}' "$tmp")
  [[ "$existing_identity" == "$candidate_identity" ]] ||
    fail "existing canonical Prod SLO evidence belongs to a different immutable release identity"
fi
chmod 600 "$tmp"
mv "$tmp" "$output"
trap - EXIT
echo "[$evidence_grade] wrote $output"
