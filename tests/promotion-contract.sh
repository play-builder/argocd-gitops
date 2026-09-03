#!/usr/bin/env bash
set -Eeuo pipefail

test_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repository_root=$(cd -- "$test_root/.." && pwd)
fixture_root="$test_root/fixtures"
render_root=$(mktemp -d "${TMPDIR:-/tmp}/gitops-promotion-contract.XXXXXX")
trap 'rm -rf -- "$render_root"' EXIT
source "$test_root/lib/render.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }

validate_ready() {
  local evidence=$1 now=$2
  local required='["schemaVersion","environment","region","sourceSha","workflow","image","attestation","gitops","cluster","slo","issuedAt","expiresAt"]'
  local json
  json=$(yq -o=json '.' "$evidence") || fail "DEV_READY is not valid YAML"
  REQUIRED="$required" jq -e 'keys | sort == (env.REQUIRED | fromjson | sort)' <<<"$json" >/dev/null || fail "DEV_READY does not match the canonical root schema"
  jq -e --arg now "$now" '
    .schemaVersion == "course.dev-ready/v1" and .environment == "dev" and
    (.region | IN("ap-northeast-2","us-east-1")) and
    (.sourceSha | test("^[0-9a-f]{40}$")) and
    (.workflow | keys | sort) == ["event","name","runAttempt","runId","runUrl"] and
    (.image.platforms == ["linux/amd64","linux/arm64"] and (.image.indexDigest | test("^sha256:[0-9a-f]{64}$"))) and
    (.attestation | keys | sort) == ["githubId","githubUrl","ociProvenanceDigest","ociSbomDigest"] and
    (.gitops.devRevision | test("^[0-9a-f]{40}$")) and
    (.region as $region | .cluster.arn | startswith("arn:aws:eks:" + $region + ":")) and
    (.slo.evidenceId | length > 0) and
    ((.issuedAt | fromdateiso8601) <= ($now | fromdateiso8601) and ($now | fromdateiso8601) < (.expiresAt | fromdateiso8601))
  ' <<<"$json" >/dev/null || {
    if jq -e --arg now "$now" '($now | fromdateiso8601) >= (.expiresAt | fromdateiso8601)' <<<"$json" >/dev/null; then fail "DEV_READY evidence is expired"; fi
    fail "DEV_READY evidence has invalid schema or identity"
  }
}

classify_rollback() {
  local file=$1
  yq -o=json '.' "$file" | jq -er '
    .completedRollback as $r |
    def owned: any(.metadata.ownerReferences[]?;
      .apiVersion == "argoproj.io/v1alpha1" and .kind == "Rollout" and
      .name == $r.rolloutName and .uid == $r.rolloutUid and .controller == true);
    if (($r.stableHash|type)!="string" or ($r.targetHash|type)!="string" or $r.stableHash == $r.targetHash) then error("ROLLBACK_ENDPOINT_HASH_INVALID") else . end |
    [$r.replicaSetList.items[] | select(owned)] as $owned |
    if any($owned[]; ((.metadata.labels["rollouts-pod-template-hash"] // "")|length)==0 or ((try (.metadata.creationTimestamp|fromdateiso8601) catch null)==null)) then error("ROLLBACK_OWNED_REPLICASET_INVALID") else . end |
    [$owned[] | select(.metadata.labels["rollouts-pod-template-hash"] == $r.targetHash)] as $target |
    [$owned[] | select(.metadata.labels["rollouts-pod-template-hash"] == $r.stableHash)] as $stable |
    if ($target|length)!=1 then error("ROLLBACK_TARGET_REPLICASET_NOT_UNIQUE") else . end |
    if ($stable|length)!=1 then error("ROLLBACK_STABLE_REPLICASET_NOT_UNIQUE") else . end |
    ($target[0].metadata.creationTimestamp|fromdateiso8601) as $targetTime |
    ($stable[0].metadata.creationTimestamp|fromdateiso8601) as $stableTime |
    if $targetTime >= $stableTime then error("ROLLBACK_TARGET_NOT_OLDER_THAN_STABLE") else . end |
    [$owned[] | select((.metadata.annotations // {}) | has("rollouts.argoproj.io/experiment-name") | not) | (.metadata.creationTimestamp|fromdateiso8601) | select(. > $targetTime and . < $stableTime)] | length
  '
}

case_promotion() {
  local evidence=${EVIDENCE:-$fixture_root/promotion/valid-ap-northeast-2.yaml}
  local rollback=${ROLLBACK:-$repository_root/envs/prod/rollback-compatibility.yaml}
  local now=${NOW:-2026-09-03T01:00:00Z}
  validate_ready "$evidence" "$now"
  local candidate baseline
  candidate=$(yq -r '.image.indexDigest' "$evidence")
  baseline="sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  [[ "$candidate" != "$baseline" ]] || fail "prod candidate digest differs from DEV_READY image.indexDigest"
  local baseline_file="$fixture_root/evidence/baseline-valid.json"
  jq -e '
    (keys | sort) == ["clusterArn","evidenceGrade","gitopsRevision","image","observedAt","region","rollout","schemaVersion"] and
    .schemaVersion == "course.prod-baseline/v1" and .evidenceGrade == "CLOUD_RUNTIME" and
    .rollout.revision == 1 and .rollout.trafficWeight == 100 and
    (.image.indexDigest | test("^sha256:[0-9a-f]{64}$"))
  ' "$baseline_file" >/dev/null || fail "Prod baseline must prove stable ReplicaSet revision 1 at 100 percent"
  local count
  count=$(classify_rollback "$rollback") || fail "completed rollback ReplicaSet topology is invalid"
  rollback_json=$(yq -o=json '.' "$rollback")
  jq -e '
    . as $root |
    $root.completedRollback as $r |
    ($r.candidates | type == "array" and length > 0) and
    all($r.candidates[];
      (keys | sort) == ["gitRevertSha","imageDigest","podTemplateHash","productReadContract","rolloutRevision"] and
      (.imageDigest | test("^sha256:[0-9a-f]{64}$")) and
      .productReadContract == "v2prime" and
      (.rolloutRevision | type == "number" and . >= 1) and
      (.gitRevertSha | test("^[0-9a-f]{40}$")) and
      .podTemplateHash == $r.targetHash and
      .imageDigest == $root.releaseLineage.v2PrimeContractCompatible.indexDigest and
      .gitRevertSha == $root.releaseLineage.v2PrimeContractCompatible.sourceSha
    )
  ' <<<"$rollback_json" >/dev/null || fail "rollback candidate must bind the target hash and v2Prime release lineage"
  (( count < $(jq -r '.completedRollback.rollbackWindow.revisions' <<<"$rollback_json") )) || fail "completed rollback target is outside rollbackWindow"
  jq -e '.releaseLineage.v2PrimeContractCompatible.sourceSha and .releaseLineage.v2PrimeContractCompatible.indexDigest' <<<"$rollback_json" >/dev/null || fail "rollback compatibility lacks the v2Prime release lineage"
  echo "PASS: promotion evidence, manual boundary, and completed rollback candidate are valid."
}

case_rollback_edges() {
  local inside="$fixture_root/rollback/inside-window.json"
  local outside="$fixture_root/rollback/outside-window.json"
  local count window fixture

  count=$(classify_rollback "$inside")
  window=$(jq -r '.completedRollback.rollbackWindow.revisions' "$inside")
  (( count < window )) || fail "inside-window rollback fixture must remain within rollbackWindow"

  if count=$(classify_rollback "$outside"); then
    window=$(jq -r '.completedRollback.rollbackWindow.revisions' "$outside")
    (( count < window )) && fail "outside-window rollback fixture was accepted"
  fi

  for fixture in "$fixture_root"/rollback/{experiment-excluded,foreign-owner,foreign-uid,malformed-owned-replicaset,missing-stable,missing-target,non-controller-owner,revision-gap,target-newer-than-stable}.json; do
    if classify_rollback "$fixture" >/dev/null 2>&1; then
      fail "invalid rollback fixture was accepted: $(basename "$fixture")"
    fi
  done
  echo "PASS: rollback candidates, ownership, and rollback-window edge cases fail closed."
}

case_render() {
  local baseline="$render_root/prod-baseline.yaml" candidate="$render_root/prod-candidate.yaml"
  helm template sample-app "$repository_root/charts/sample-app" \
    --values "$repository_root/envs/prod/values.yaml" \
    --values "$fixture_root/values/prod-baseline.yaml" >"$baseline"
  helm template sample-app "$repository_root/charts/sample-app" \
    --values "$repository_root/envs/prod/values.yaml" \
    --values "$fixture_root/values/prod-candidate.yaml" >"$candidate"
  normalize() { yq eval-all -o=json -I=0 '[.]' "$1" | jq -cS 'sort_by(.kind, (.metadata.namespace // ""), .metadata.name) | map(if .kind == "Rollout" then del(.spec.template.spec.containers[].image) elif .kind == "Job" and .metadata.name == "sample-app-migration" then del(.spec.template.spec.containers[].image) else . end)'; }
  [[ "$(normalize "$baseline")" == "$(normalize "$candidate")" ]] || fail "normalized prod baseline and candidate manifests differ beyond approved images"
  local b c
  b=$(yq -r 'select(.kind == "Rollout") | .spec.template.spec.containers[0].image' "$baseline")
  c=$(yq -r 'select(.kind == "Rollout") | .spec.template.spec.containers[0].image' "$candidate")
  [[ "$b" != "$c" ]] || fail "prod candidate digest must differ from baseline"
  yq eval-all -e 'select(.kind == "AnalysisTemplate") | .spec.metrics[0].name == "request-rate" and .spec.metrics[1].name == "success-rate"' "$candidate" >/dev/null || fail "AnalysisTemplate metrics must use canonical request-rate and success-rate names"
  yq eval-all -o=json 'select(.kind == "Rollout") | .spec.strategy.canary.steps' "$candidate" | jq -e '(to_entries | map(select(.value.pause == {})) | last.key) as $p | (to_entries | map(select(.value.setWeight == 100)) | last.key) as $w | $p == ($w - 1)' >/dev/null || fail "manual pause must immediately precede final 100 percent"
  yq -e '.spec.template.spec.syncPolicy.automated == null' "$repository_root/argocd/bootstrap/prod/sample-app.yaml" >/dev/null || fail "Prod ApplicationSet must remain manually synced"
  yq -o=json '.' "$repository_root/argocd/bootstrap/prod/sample-app.yaml" | jq -e '.spec.template.spec.syncPolicy.syncOptions | index("CreateNamespace=true") != null' >/dev/null || fail "Prod ApplicationSet must retain explicit namespace creation"
  echo "PASS: Prod baseline/candidate desired state is equivalent except approved images."
}

requested=${1:-all}
if [[ "$requested" == "--evidence" ]]; then
  EVIDENCE=${2:?missing evidence}; shift 2
  [[ "${1:-}" == "--rollback" ]] && ROLLBACK=${2:?missing rollback} && shift 2
  [[ "${1:-}" == "--now" ]] && NOW=${2:?missing now} && shift 2
  requested=promotion
elif [[ "$requested" == "--case" ]]; then requested=${2:-all}; fi
case "$requested" in
  digest-mismatch) EVIDENCE="$fixture_root/promotion/digest-mismatch.yaml" case_promotion ;;
  expired) NOW=2026-09-03T03:00:00Z EVIDENCE="$fixture_root/promotion/expired.yaml" case_promotion ;;
  baseline-candidate-input|render-equivalence) case_render ;;
  promotion) case_promotion ;;
  in-progress-stable-reapply) jq -e '.inProgressStableReapply.requiresDesiredStateReconcile == true and .inProgressStableReapply.stableDigest != .inProgressStableReapply.candidateDigest' "$fixture_root/rollback/in-progress-stable-reapply.json" >/dev/null || fail "in-progress stable reapply requires desired-state reconciliation"; echo "PASS: stable reapply requires GitOps reconciliation." ;;
  rollback-edges) case_rollback_edges ;;
  all) case_promotion; case_render; case_rollback_edges ;;
  *) case_promotion ;;
esac
