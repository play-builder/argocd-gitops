#!/usr/bin/env bash
set -Eeuo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
repository_root=$(cd -- "$script_dir/.." && pwd -P)
output="$repository_root/evidence/prod/baseline.json"
fixture=''
runtime_override=false
now_override=''
adapter_dir=${COURSE_CHECK_BIN_DIR:-}

fail() { echo "FAIL: $*" >&2; exit 1; }
usage() { echo "Usage: $0 [--fixture path] [--output path --now RFC3339]" >&2; exit 2; }

while (($#)); do
  case "$1" in
    --fixture) fixture=${2:?missing fixture path}; shift 2 ;;
    --output) output=${2:?missing output path}; runtime_override=true; shift 2 ;;
    --now) now_override=${2:?missing static clock}; runtime_override=true; shift 2 ;;
    *) usage ;;
  esac
done

validate_record() {
  local file=$1 expected_grade=${2:-CLOUD_RUNTIME} observed_limit=${3:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}
  jq -e --arg grade "$expected_grade" --arg observedLimit "$observed_limit" '
    (keys | sort) == ["clusterArn","evidenceGrade","gitopsRevision","image","observedAt","region","rollout","schemaVersion"] and
    .schemaVersion == "course.prod-baseline/v1" and .evidenceGrade == $grade and
    (.image | (keys | sort) == ["indexDigest","repository"]) and
    (.image.repository | test("^[0-9]{12}\\.dkr\\.ecr\\.(ap-northeast-2|us-east-1)\\.amazonaws\\.com/.+")) and
    (.image.indexDigest | test("^sha256:[0-9a-f]{64}$")) and
    (.gitopsRevision | test("^[0-9a-f]{40}$")) and
    (.rollout | (keys | sort) == ["revision","stableHash","trafficWeight"]) and
    (.rollout.stableHash | type == "string" and length > 0) and
    .rollout.revision == 1 and .rollout.trafficWeight == 100 and
    .region as $region |
    (.clusterArn | test("^arn:aws:eks:" + $region + ":[0-9]{12}:cluster/.+")) and
    ($region | IN("ap-northeast-2","us-east-1")) and
    (.observedAt | fromdateiso8601) <= ($observedLimit | fromdateiso8601)
  ' "$file" >/dev/null || fail 'Prod baseline does not satisfy course.prod-baseline/v1'

  local cluster_account image_account cluster_region image_region
  cluster_account=$(jq -r '.clusterArn | split(":")[4]' "$file")
  cluster_region=$(jq -r '.clusterArn | split(":")[3]' "$file")
  image_account=$(jq -r '.image.repository | capture("^(?<account>[0-9]{12})\\.").account' "$file")
  image_region=$(jq -r '.image.repository | capture("^[0-9]{12}\\.dkr\\.ecr\\.(?<region>[^.]+)\\.").region' "$file")
  [[ "$cluster_account" == "$image_account" && "$cluster_region" == "$image_region" ]] ||
    fail 'Prod baseline EKS and ECR account/Region identity mismatch'
}

if [[ -n "$fixture" ]]; then
  [[ -z "$adapter_dir" && "$runtime_override" == false ]] ||
    fail 'fixture validation cannot be combined with runtime adapter options'
  [[ -f "$fixture" && ! -L "$fixture" ]] || fail 'fixture must be a regular non-symlink file'
  validate_record "$fixture"
  echo '[STATIC] validated Prod baseline fixture; no runtime evidence was written.'
  exit 0
fi

evidence_grade=CLOUD_RUNTIME
clock_now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
if [[ -n "$adapter_dir" ]]; then
  [[ -d "$adapter_dir" && "$runtime_override" == true && -n "$now_override" ]] ||
    fail 'static runtime adapter requires explicit noncanonical output and clock'
  [[ "$output" != "$repository_root/evidence/"* && "$output" != *'/tests/fixtures/'* ]] ||
    fail 'static runtime adapter cannot write repository evidence or fixture paths'
  PATH="$adapter_dir:$PATH"
  evidence_grade=STATIC
  clock_now=$now_override
else
  [[ "$runtime_override" == false ]] || fail 'runtime baseline output and clock are fixed'
  [[ "$output" == "$repository_root/evidence/prod/baseline.json" ]] ||
    fail 'runtime baseline output is fixed to evidence/prod/baseline.json'
fi
jq -en --arg now "$clock_now" '($now | fromdateiso8601) != null' >/dev/null ||
  fail 'capture clock must be RFC3339 UTC'

for required in kubectl argocd aws git jq mktemp; do
  command -v "$required" >/dev/null || fail "$required is required for live Prod baseline capture"
done
[[ ${AWS_REGION:-} == ap-northeast-2 || ${AWS_REGION:-} == us-east-1 ]] ||
  fail 'AWS_REGION must be ap-northeast-2 or us-east-1'
[[ -n ${EKS_CLUSTER_NAME:-} ]] || fail 'EKS_CLUSTER_NAME is required'
[[ -z $(git -C "$repository_root" status --porcelain --untracked-files=all -- . ':(exclude)evidence') ]] ||
  fail 'GitOps source outside evidence/ must match the checked-out commit before baseline capture'

git_revision=$(git -C "$repository_root" rev-parse HEAD)
[[ "$git_revision" =~ ^[0-9a-f]{40}$ ]] || fail 'local GitOps revision is not a full commit SHA'

app_json=$(argocd app get sample-app-prod -o json) || fail 'unable to read sample-app-prod from Argo CD'
live_revision=$(jq -er '.status.operationState.syncResult.revision // .status.sync.revision' <<<"$app_json") ||
  fail 'Argo CD did not report a GitOps revision'
jq -e '
  .metadata.name == "sample-app-prod" and .status.sync.status == "Synced" and
  .status.health.status == "Healthy" and (.spec.source.repoURL | test("/argocd-gitops(\\.git)?$"))
' <<<"$app_json" >/dev/null || fail 'sample-app-prod must be Synced and Healthy'
[[ "$live_revision" =~ ^[0-9a-f]{40}$ && "$live_revision" == "$git_revision" ]] ||
  fail 'live Argo CD revision does not match the checked-out GitOps commit'

cluster_json=$(aws eks describe-cluster --name "$EKS_CLUSTER_NAME" --region "$AWS_REGION" --output json) ||
  fail 'unable to describe the Prod EKS cluster'
cluster_arn=$(jq -er '.cluster.arn' <<<"$cluster_json") || fail 'EKS cluster ARN is missing'
cluster_endpoint=$(jq -er '.cluster.endpoint' <<<"$cluster_json") || fail 'EKS cluster endpoint is missing'
jq -e --arg name "$EKS_CLUSTER_NAME" --arg region "$AWS_REGION" '
  .cluster.name == $name and .cluster.status == "ACTIVE" and
  (.cluster.arn | test("^arn:aws:eks:" + $region + ":[0-9]{12}:cluster/")) and
  (.cluster.arn | endswith(":cluster/" + $name)) and
  (.cluster.endpoint | type == "string" and startswith("https://"))
' <<<"$cluster_json" >/dev/null || fail 'Prod EKS identity or status is invalid'

kubeconfig_json=$(kubectl config view --minify -o json) || fail 'unable to inspect the active kube context'
kube_server=$(jq -er '.clusters | if length == 1 then .[0].cluster.server else empty end' <<<"$kubeconfig_json") ||
  fail 'active kube context does not identify exactly one cluster server'
[[ "$kube_server" == "$cluster_endpoint" ]] ||
  fail 'active kube context endpoint does not match EKS_CLUSTER_NAME'

rollout_json=$(kubectl -n app-prod get rollout sample-app -o json) || fail 'unable to read the Prod Rollout'
rollout_uid=$(jq -er '.metadata.uid' <<<"$rollout_json") || fail 'Prod Rollout UID is missing'
stable_hash=$(jq -er '.status.stableRS' <<<"$rollout_json") || fail 'Prod stable ReplicaSet hash is missing'
image=$(jq -er '[.spec.template.spec.containers[] | select(.name == "sample-app") | .image] | if length == 1 then .[0] else empty end' <<<"$rollout_json") ||
  fail 'Prod Rollout must contain exactly one sample-app image'
jq -e '
  .metadata.name == "sample-app" and .metadata.namespace == "app-prod" and
  .metadata.uid != null and
  .status.phase == "Healthy" and .status.stableRS == .status.currentPodHash and
  (.status.replicas | type == "number" and . > 0) and
  .status.readyReplicas == .status.replicas and .status.availableReplicas == .status.replicas and
  ((.status.pauseConditions // []) | length) == 0
' <<<"$rollout_json" >/dev/null || fail 'Prod Rollout is not a completed healthy revision 1 baseline'
[[ "$image" =~ ^([^@]+)@(sha256:[0-9a-f]{64})$ ]] ||
  fail 'Prod Rollout image must be pinned by an immutable sha256 digest'
image_repository=${BASH_REMATCH[1]}
image_digest=${BASH_REMATCH[2]}

replicasets_json=$(kubectl -n app-prod get replicasets -l "rollouts-pod-template-hash=$stable_hash" -o json) ||
  fail 'unable to read the stable ReplicaSet'
stable_rs=$(jq -cer --arg uid "$rollout_uid" --arg hash "$stable_hash" --arg image "$image" '
  [.items[] | select(
    .metadata.labels["rollouts-pod-template-hash"] == $hash and
    .metadata.annotations["rollout.argoproj.io/revision"] == "1" and
    any(.metadata.ownerReferences[]?;
      .apiVersion == "argoproj.io/v1alpha1" and .kind == "Rollout" and
      .name == "sample-app" and .uid == $uid and .controller == true) and
    ([.spec.template.spec.containers[] | select(.name == "sample-app") | .image] == [$image]) and
    (.spec.replicas | type == "number" and . > 0) and
    .status.readyReplicas == .spec.replicas and .status.availableReplicas == .spec.replicas
  )] | if length == 1 then .[0] else empty end
' <<<"$replicasets_json") || fail 'stable ReplicaSet identity, image, revision, or readiness is ambiguous'
[[ -n "$stable_rs" ]] || fail 'stable ReplicaSet identity, image, revision, or readiness is ambiguous'
rollout_revision=$(jq -er '.metadata.annotations["rollout.argoproj.io/revision"] | tonumber' <<<"$stable_rs") ||
  fail 'stable ReplicaSet revision is invalid'
[[ "$rollout_revision" -eq 1 ]] || fail 'Prod baseline stable ReplicaSet must be revision 1'

route_json=$(kubectl -n app-prod get httproute sample-app -o json) || fail 'unable to read the Prod HTTPRoute'
jq -e '
  .metadata.name == "sample-app" and .metadata.namespace == "app-prod" and
  (.spec.rules | length) == 1 and (.spec.rules[0].backendRefs | length) == 2 and
  ([.spec.rules[0].backendRefs[] | {name,port,weight}] | sort_by(.name)) ==
    [{name:"sample-app-canary",port:80,weight:0},{name:"sample-app-stable",port:80,weight:100}] and
  ([.spec.rules[0].backendRefs[].weight] | add) == 100
' <<<"$route_json" >/dev/null || fail 'Prod HTTPRoute is not routing 100 percent to the stable service'

cluster_account=${cluster_arn#arn:aws:eks:$AWS_REGION:}
cluster_account=${cluster_account%%:*}
[[ "$image_repository" =~ ^([0-9]{12})\.dkr\.ecr\.([a-z0-9-]+)\.amazonaws\.com/.+ ]] ||
  fail 'Prod image repository is not an ECR repository'
[[ ${BASH_REMATCH[1]} == "$cluster_account" && ${BASH_REMATCH[2]} == "$AWS_REGION" ]] ||
  fail 'Prod image and EKS cluster do not share the same account and Region'

mkdir -p "$(dirname -- "$output")"
if [[ "$evidence_grade" == CLOUD_RUNTIME ]]; then
  output_parent=$(cd -- "$(dirname -- "$output")" && pwd -P) || fail 'cannot resolve canonical baseline output directory'
  [[ "$output_parent/$(basename -- "$output")" == "$repository_root/evidence/prod/baseline.json" ]] ||
    fail 'canonical Prod baseline output escaped the repository evidence directory'
fi
tmp=$(mktemp "$(dirname -- "$output")/.baseline.XXXXXX")
trap 'rm -f -- "$tmp"' EXIT
jq -n --arg repository "$image_repository" --arg digest "$image_digest" \
  --arg revision "$git_revision" --arg stable "$stable_hash" --arg arn "$cluster_arn" \
  --arg region "$AWS_REGION" --arg grade "$evidence_grade" --arg observed "$clock_now" \
  --argjson rolloutRevision "$rollout_revision" '
  {
    schemaVersion:"course.prod-baseline/v1", evidenceGrade:$grade,
    image:{repository:$repository,indexDigest:$digest}, gitopsRevision:$revision,
    rollout:{stableHash:$stable,revision:$rolloutRevision,trafficWeight:100},
    clusterArn:$arn, region:$region, observedAt:$observed
  }
' >"$tmp" || fail 'failed to construct Prod baseline evidence'
validate_record "$tmp" "$evidence_grade" "$clock_now"
if [[ -e "$output" ]]; then
  [[ -f "$output" && ! -L "$output" ]] || fail 'Prod baseline output is not a regular non-symlink file'
  validate_record "$output" "$evidence_grade" "$clock_now"
  existing_identity=$(jq -cS 'del(.observedAt)' "$output")
  candidate_identity=$(jq -cS 'del(.observedAt)' "$tmp")
  [[ "$existing_identity" == "$candidate_identity" ]] ||
    fail 'existing canonical Prod baseline belongs to a different immutable release identity'
fi
chmod 600 "$tmp"
mv "$tmp" "$output"
trap - EXIT
echo "[$evidence_grade] wrote $output"
