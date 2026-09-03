#!/usr/bin/env bash
set -Eeuo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repository_root=$(cd -- "$script_dir/.." && pwd)
output="$repository_root/evidence/prod/slo.json"
fixture=""
promotion="$repository_root/envs/prod/promotion-evidence.yaml"
baseline="$repository_root/evidence/prod/baseline.json"

fail() { echo "FAIL: $*" >&2; exit 1; }
usage() { echo "Usage: $0 [--fixture path] [--promotion-evidence path] [--baseline path] [--output path]" >&2; exit 2; }

while (($#)); do
  case "$1" in
    --fixture) fixture=${2:?missing fixture path}; shift 2 ;;
    --promotion-evidence) promotion=${2:?missing promotion path}; shift 2 ;;
    --baseline) baseline=${2:?missing baseline path}; shift 2 ;;
    --output) output=${2:?missing output path}; shift 2 ;;
    --now) [[ -n "$fixture" ]] || fail "--now is permitted only by the static fixture adapter"; shift 2 ;;
    *) usage ;;
  esac
done

validate_record() {
  local file=$1
  jq -e '
    (keys | sort) == ["analysisRun","clusterArn","evidenceGrade","evidenceId","gitopsRevision","image","metricResults","observedAt","region","rollout","schemaVersion","source","status"] and
    .schemaVersion == "course.prod-slo/v1" and .evidenceGrade == "CLOUD_RUNTIME" and .status == "PASS" and
    (.source | (keys | sort) == ["repository","sha"]) and (.image | (keys | sort) == ["indexDigest","repository"]) and
    (.source.sha | test("^[0-9a-f]{40}$")) and (.image.indexDigest | test("^sha256:[0-9a-f]{64}$")) and
    (.gitopsRevision | test("^[0-9a-f]{40}$")) and (.clusterArn | test("^arn:aws:eks:[a-z0-9-]+:[0-9]{12}:cluster/.+")) and (.region | IN("ap-northeast-2","us-east-1")) and
    (.rollout | (keys | sort) == ["currentPodHash","name","phase","revision","stableHash","trafficWeight","uid"]) and
    .rollout.phase == "Healthy" and .rollout.trafficWeight == 100 and .rollout.stableHash == .rollout.currentPodHash and
    (.analysisRun | (keys | sort) == ["name","phase","templateName","uid"]) and .analysisRun.phase == "Successful" and
    .analysisRun.templateName == "sample-app-success-rate" and
    ([.metricResults[].name] | sort) == ["request-rate","success-rate"] and
    all(.metricResults[]; (keys | sort) == ["measurements","name","phase"] and .phase == "Successful" and ([.measurements[] | select(.phase == "Successful")] | length) > 0 and
      all(.measurements[]; (keys | sort) == ["finishedAt","phase","startedAt","value"] and (.value | type == "number" and isfinite) and (.startedAt | fromdateiso8601) < (.finishedAt | fromdateiso8601))) and
    (.observedAt | fromdateiso8601)
  ' "$file" >/dev/null || fail "Prod SLO evidence failed canonical metric or terminal-state validation"
}

if [[ -n "$fixture" ]]; then
  [[ -f "$fixture" ]] || fail "fixture does not exist"
  validate_record "$fixture"
  echo "[STATIC] fake Prod SLO adapter validated canonical request-rate and success-rate evidence; no runtime file written."
  exit 0
fi

[[ "$output" == "$repository_root/evidence/prod/slo.json" ]] || fail "runtime producer output is fixed to evidence/prod/slo.json"
[[ -f "$promotion" && -f "$baseline" ]] || fail "promotion evidence and Prod baseline are required"

promotion_json=$(yq -o=json '.' "$promotion") || fail "promotion evidence is not valid YAML"
baseline_json=$(jq '.' "$baseline") || fail "Prod baseline is not valid JSON"
jq -e '
  (keys | sort) == ["attestation","cluster","environment","expiresAt","gitops","image","issuedAt","region","schemaVersion","slo","sourceSha","workflow"] and
  .schemaVersion == "course.dev-ready/v1" and .environment == "dev" and
  (.region | IN("ap-northeast-2","us-east-1")) and
  (.sourceSha | test("^[0-9a-f]{40}$")) and (.image.indexDigest | test("^sha256:[0-9a-f]{64}$")) and
  .image.platforms == ["linux/amd64","linux/arm64"]
' <<<"$promotion_json" >/dev/null || fail "promotion evidence is not canonical DEV_READY"
jq -e '.schemaVersion == "course.prod-baseline/v1" and .evidenceGrade == "CLOUD_RUNTIME" and .rollout.revision == 1 and .rollout.trafficWeight == 100' <<<"$baseline_json" >/dev/null || fail "Prod baseline is not a valid initial stable release"

rollout_json=$(kubectl -n app-prod get rollout sample-app -o json)
rollout_uid=$(jq -r '.metadata.uid' <<<"$rollout_json")
rollout_revision=$(jq -r '.metadata.annotations["rollouts.argoproj.io/revision"] // ""' <<<"$rollout_json")
analysis_json=$(kubectl -n app-prod get analysisruns.argoproj.io -o json)
analysis=$(jq -e --arg uid "$rollout_uid" --arg rev "$rollout_revision" '[.items[] | select(any(.metadata.ownerReferences[]?; .kind == "Rollout" and .uid == $uid and .controller == true)) | select(((.metadata.annotations["rollouts.argoproj.io/revision"] // "") == $rev) or ((.status.rolloutRevision // "")|tostring) == $rev)]' <<<"$analysis_json") || fail "unable to select owned AnalysisRun"
[[ $(jq 'length' <<<"$analysis") == 1 ]] || fail "Prod AnalysisRun selection is ambiguous"
app_json=$(argocd app get sample-app-prod -o json)
cluster_arn=$(aws eks describe-cluster --name "${EKS_CLUSTER_NAME:?set EKS_CLUSTER_NAME}" --region "${AWS_REGION:?set AWS_REGION}" --query 'cluster.arn' --output text)
image=$(jq -r '.spec.template.spec.containers[0].image' <<<"$rollout_json")
image_repo=${image%@*}; image_digest=${image##*@}
expected_digest=$(jq -r '.image.indexDigest' <<<"$promotion_json")
baseline_digest=$(jq -r '.image.indexDigest' <<<"$baseline_json")
[[ "$image_digest" == "$expected_digest" ]] || fail "live Prod image digest does not match DEV_READY"
[[ "$image_digest" != "$baseline_digest" ]] || fail "Prod candidate reuses the baseline digest"
gitops_revision=$(jq -r '.status.operationState.syncResult.revision // .status.sync.revision' <<<"$app_json")
source_sha=$(yq -r '.sourceSha' "$promotion")
expected_region=$(jq -r '.region' <<<"$promotion_json")
[[ "$AWS_REGION" == "$expected_region" ]] || fail "live Prod Region does not match DEV_READY"
[[ "$cluster_arn" == arn:aws:eks:"$AWS_REGION":* ]] || fail "live Prod cluster ARN does not match Region"

tmp=$(mktemp "$repository_root/evidence/prod/.slo.XXXXXX")
trap 'rm -f "$tmp"' EXIT
jq -n --arg source "$source_sha" --arg repo "$image_repo" --arg digest "$image_digest" --arg git "$gitops_revision" --arg arn "$cluster_arn" --arg region "$AWS_REGION" --argjson ro "$rollout_json" --argjson ar "$(jq '.[0]' <<<"$analysis")" '
  {schemaVersion:"course.prod-slo/v1",evidenceGrade:"CLOUD_RUNTIME",status:"PASS",source:{repository:"OWNER/cicd-course-sample-app",sha:$source},image:{repository:$repo,indexDigest:$digest},gitopsRevision:$git,clusterArn:$arn,region:$region,evidenceId:("prod-slo-" + (now|floor|tostring)),
   rollout:{name:$ro.metadata.name,uid:$ro.metadata.uid,revision:($ro.metadata.annotations["rollouts.argoproj.io/revision"]|tonumber),stableHash:$ro.status.stableRS,currentPodHash:$ro.status.currentPodHash,trafficWeight:100,phase:($ro.status.phase // "")},
   analysisRun:{name:$ar.metadata.name,uid:$ar.metadata.uid,phase:$ar.status.phase,templateName:($ar.spec.templates[0].templateName // "sample-app-success-rate")},metricResults:[$ar.status.metricResults[] | {name,phase,measurements:([.measurements[] | select(.finishedAt != null) | {value,phase,startedAt,finishedAt}])}],observedAt:(now|todateiso8601)}
' >"$tmp" || fail "failed to construct Prod SLO evidence"
validate_record "$tmp"
mkdir -p "$(dirname "$output")"
chmod 600 "$tmp"
mv "$tmp" "$output"
echo "[CLOUD_RUNTIME] wrote $output"
