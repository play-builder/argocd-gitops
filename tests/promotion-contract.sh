#!/usr/bin/env bash
set -Eeuo pipefail

test_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
repository_root=$(cd -- "$test_root/.." && pwd -P)
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
    . as $root |
    .workflow as $workflow |
    (.workflow.runUrl | capture("^https://github\\.com/(?<repository>[^/]+/cicd-course-sample-app)/actions/runs/(?<id>[0-9]+)$")) as $run |
    (.image.repository | capture("^(?<account>[0-9]{12})\\.dkr\\.ecr\\.(?<region>ap-northeast-2|us-east-1)\\.amazonaws\\.com/.+$")) as $ecr |
    (.cluster.arn | capture("^arn:aws:eks:(?<region>ap-northeast-2|us-east-1):(?<account>[0-9]{12}):cluster/[A-Za-z0-9][A-Za-z0-9_-]{0,99}$")) as $cluster |
    .schemaVersion == "course.dev-ready/v1" and .environment == "dev" and
    (.region | IN("ap-northeast-2","us-east-1")) and
    (.sourceSha | test("^[0-9a-f]{40}$")) and
    ($workflow | (keys | sort) == ["event","name","runAttempt","runId","runUrl"]) and
    $workflow.name == "ci" and $workflow.event == "push" and
    ($workflow.runId | type == "string" and test("^[0-9]+$")) and
    ($workflow.runAttempt | type == "number" and floor == . and . >= 1) and
    $run.id == $workflow.runId and
    (.image | (keys | sort) == ["indexDigest","platforms","repository"]) and
    .image.platforms == ["linux/amd64","linux/arm64"] and
    (.image.indexDigest | test("^sha256:[0-9a-f]{64}$")) and
    (.attestation | (keys | sort) == ["githubId","githubUrl","ociProvenanceDigest","ociSbomDigest"]) and
    (.attestation.githubId | type == "string" and length > 0) and
    .attestation.githubUrl == ("https://github.com/" + $run.repository + "/attestations/" + .attestation.githubId) and
    (.attestation.ociSbomDigest | test("^sha256:[0-9a-f]{64}$")) and
    (.attestation.ociProvenanceDigest | test("^sha256:[0-9a-f]{64}$")) and
    (.gitops | (keys | sort) == ["devRevision"]) and (.gitops.devRevision | test("^[0-9a-f]{40}$")) and
    (.cluster | (keys | sort) == ["arn"]) and (.slo | (keys | sort) == ["evidenceId"]) and
    (.slo.evidenceId | type == "string" and length > 0) and
    $ecr.region == $root.region and $cluster.region == $root.region and $ecr.account == $cluster.account and
    ((.issuedAt | fromdateiso8601) <= ($now | fromdateiso8601) and ($now | fromdateiso8601) < (.expiresAt | fromdateiso8601))
  ' <<<"$json" >/dev/null || {
    if jq -e --arg now "$now" '($now | fromdateiso8601) >= (.expiresAt | fromdateiso8601)' <<<"$json" >/dev/null; then fail "DEV_READY evidence is expired"; fi
    fail "DEV_READY evidence has invalid schema or identity"
  }
}

classify_rollback() {
  local file=$1 target_hash=$2 target_revision=$3
  yq -o=json '.' "$file" | jq -er --arg targetHash "$target_hash" --argjson targetRevision "$target_revision" '
    .completedRollback as $r |
    def owned: any(.metadata.ownerReferences[]?;
      .apiVersion == "argoproj.io/v1alpha1" and .kind == "Rollout" and
      .name == $r.rolloutName and .uid == $r.rolloutUid and .controller == true);
    if (($r.stableHash|type)!="string" or ($targetHash|type)!="string" or $r.stableHash == $targetHash) then error("ROLLBACK_ENDPOINT_HASH_INVALID") else . end |
    [$r.replicaSetList.items[] | select(owned)] as $owned |
    if any($owned[]; ((.metadata.labels["rollouts-pod-template-hash"] // "")|length)==0 or ((try (.metadata.creationTimestamp|fromdateiso8601) catch null)==null)) then error("ROLLBACK_OWNED_REPLICASET_INVALID") else . end |
    [$owned[] | select((.metadata.annotations // {}) | has("rollouts.argoproj.io/experiment-name") | not)] as $eligible |
    [$eligible[] | select(.metadata.labels["rollouts-pod-template-hash"] == $targetHash)] as $target |
    [$eligible[] | select(.metadata.labels["rollouts-pod-template-hash"] == $r.stableHash)] as $stable |
    if ($target|length)!=1 then error("ROLLBACK_TARGET_REPLICASET_NOT_UNIQUE") else . end |
    if ($stable|length)!=1 then error("ROLLBACK_STABLE_REPLICASET_NOT_UNIQUE") else . end |
    ($target[0].metadata.annotations["rollout.argoproj.io/revision"] // "") as $targetAuditText |
    ($stable[0].metadata.annotations["rollout.argoproj.io/revision"] // "") as $stableAuditText |
    (if ($targetAuditText | type == "string" and test("^[0-9]+$")) then ($targetAuditText | tonumber) else null end) as $targetAuditRevision |
    (if ($stableAuditText | type == "string" and test("^[0-9]+$")) then ($stableAuditText | tonumber) else null end) as $stableAuditRevision |
    if $targetAuditRevision != $targetRevision then error("ROLLBACK_TARGET_REVISION_MISMATCH") else . end |
    if ($stableAuditRevision == null or $stableAuditRevision <= $targetRevision) then error("ROLLBACK_STABLE_REVISION_INVALID") else . end |
    ($target[0].metadata.creationTimestamp|fromdateiso8601) as $targetTime |
    ($stable[0].metadata.creationTimestamp|fromdateiso8601) as $stableTime |
    if $targetTime >= $stableTime then error("ROLLBACK_TARGET_NOT_OLDER_THAN_STABLE") else . end |
    [$eligible[] | (.metadata.creationTimestamp|fromdateiso8601) | select(. > $targetTime and . < $stableTime)] | length
  '
}

validate_candidate_set() {
  local file=$1 rollback_json window hash revision count
  rollback_json=$(yq -o=json '.' "$file") || return 1
  jq -e '
    . as $root |
    .completedRollback as $r |
    ((keys | sort) == ["completedRollback","releaseLineage"] or
      (keys | sort) == ["completedRollback","inProgressStableReapply","releaseLineage"]) and
    ($r | keys | sort) == ["candidates","replicaSetList","rollbackWindow","rolloutName","rolloutUid","stableHash","targetHash"] and
    ($r.rollbackWindow | keys) == ["revisions"] and
    ($r.replicaSetList | keys | sort) == ["apiVersion","items","kind"] and
    $r.replicaSetList.apiVersion == "apps/v1" and $r.replicaSetList.kind == "ReplicaSetList" and
    ($r.rolloutName | type == "string" and length > 0) and
    ($r.rolloutUid | type == "string" and length > 0) and
    ($r.stableHash | type == "string" and length > 0) and
    ($root.releaseLineage | keys | sort) == ["v1Compatible","v201HotfixOrderTotal","v2FaultyOrderTotal","v2PrimeContractCompatible"] and
    all($root.releaseLineage[];
      (keys | sort) == ["indexDigest","sourceSha"] and
      (.sourceSha | type == "string" and test("^[0-9a-f]{40}$")) and
      (.indexDigest | type == "string" and test("^sha256:[0-9a-f]{64}$"))) and
    ([$root.releaseLineage[].sourceSha] | unique | length) == 4 and
    ([$root.releaseLineage[].indexDigest] | unique | length) == 4 and
    ($r.candidates | type == "array" and length > 0) and
    ($r.targetHash | type == "string" and length > 0) and
    any($r.candidates[]; .podTemplateHash == $r.targetHash) and
    ([ $r.candidates[].podTemplateHash ] | unique | length) == ($r.candidates | length) and
    ([ $r.candidates[].rolloutRevision ] | unique | length) == ($r.candidates | length) and
    all($r.candidates[];
      (keys | sort) == ["gitRevertSha","imageDigest","podTemplateHash","productReadContract","rolloutRevision"] and
      (.imageDigest | test("^sha256:[0-9a-f]{64}$")) and
      .productReadContract == "v2prime" and
      (.rolloutRevision | type == "number" and floor == . and . >= 1) and
      (.gitRevertSha | test("^[0-9a-f]{40}$")) and
      (.podTemplateHash | type == "string" and length > 0) and
      .imageDigest == $root.releaseLineage.v2PrimeContractCompatible.indexDigest and
      .gitRevertSha == $root.releaseLineage.v2PrimeContractCompatible.sourceSha)
  ' <<<"$rollback_json" >/dev/null || return 1
  window=$(jq -r '.completedRollback.rollbackWindow.revisions' <<<"$rollback_json")
  [[ "$window" =~ ^[0-9]+$ ]] && ((window >= 1)) || return 1
  while IFS=$'\t' read -r hash revision; do
    count=$(classify_rollback "$file" "$hash" "$revision") || return 1
    ((count < window)) || return 1
  done < <(jq -r '.completedRollback.candidates[] | [.podTemplateHash, (.rolloutRevision | tostring)] | @tsv' <<<"$rollback_json")
}

case_promotion() {
  local evidence=${EVIDENCE:-$fixture_root/promotion/valid-ap-northeast-2.yaml}
  local rollback=${ROLLBACK:-$repository_root/envs/prod/rollback-compatibility.yaml}
  local baseline_file
  if [[ -n ${BASELINE:-} ]]; then
    baseline_file=$BASELINE
  elif [[ "$evidence" == "$fixture_root/"* ]]; then
    baseline_file="$fixture_root/evidence/baseline-valid.json"
  else
    baseline_file="$repository_root/evidence/prod/baseline.json"
  fi
  local now=${NOW:-2026-09-03T01:00:00Z}
  [[ -f "$evidence" && -f "$rollback" && -f "$baseline_file" ]] ||
    fail "promotion evidence, rollback evidence, and Prod baseline are required"
  validate_ready "$evidence" "$now"
  local candidate baseline candidate_repository baseline_repository candidate_region baseline_region
  candidate=$(yq -r '.image.indexDigest' "$evidence")
  baseline=$(jq -r '.image.indexDigest' "$baseline_file")
  [[ "$candidate" != "$baseline" ]] || fail "prod candidate digest differs from DEV_READY image.indexDigest"
  jq -e '
    . as $root |
    (.image.repository | capture("^(?<account>[0-9]{12})\\.dkr\\.ecr\\.(?<region>ap-northeast-2|us-east-1)\\.amazonaws\\.com/.+$")) as $ecr |
    (.clusterArn | capture("^arn:aws:eks:(?<region>ap-northeast-2|us-east-1):(?<account>[0-9]{12}):cluster/[A-Za-z0-9][A-Za-z0-9_-]{0,99}$")) as $cluster |
    (keys | sort) == ["clusterArn","evidenceGrade","gitopsRevision","image","observedAt","region","rollout","schemaVersion"] and
    .schemaVersion == "course.prod-baseline/v1" and .evidenceGrade == "CLOUD_RUNTIME" and
    (.image | (keys | sort) == ["indexDigest","repository"]) and
    (.image.repository | type == "string" and length > 0) and
    (.gitopsRevision | test("^[0-9a-f]{40}$")) and
    (.rollout | (keys | sort) == ["revision","stableHash","trafficWeight"]) and
    (.rollout.stableHash | type == "string" and length > 0) and
    .rollout.revision == 1 and .rollout.trafficWeight == 100 and
    (.image.indexDigest | test("^sha256:[0-9a-f]{64}$")) and
    (.region | IN("ap-northeast-2","us-east-1")) and
    $ecr.region == $root.region and $cluster.region == $root.region and $ecr.account == $cluster.account and
    (.observedAt | fromdateiso8601) <= now
  ' "$baseline_file" >/dev/null || fail "Prod baseline must prove stable ReplicaSet revision 1 at 100 percent"
  candidate_repository=$(yq -r '.image.repository' "$evidence")
  baseline_repository=$(jq -r '.image.repository' "$baseline_file")
  candidate_region=$(yq -r '.region' "$evidence")
  baseline_region=$(jq -r '.region' "$baseline_file")
  [[ "$candidate_repository" == "$baseline_repository" && "$candidate_region" == "$baseline_region" ]] ||
    fail "DEV_READY candidate and Prod baseline repository/Region identity mismatch"
  rollback_json=$(yq -o=json '.' "$rollback")
  validate_candidate_set "$rollback" ||
    fail "every rollback candidate must map uniquely to an eligible v2Prime ReplicaSet inside rollbackWindow"
  jq -e '.releaseLineage.v2PrimeContractCompatible.sourceSha and .releaseLineage.v2PrimeContractCompatible.indexDigest' <<<"$rollback_json" >/dev/null || fail "rollback compatibility lacks the v2Prime release lineage"
  echo "PASS: promotion evidence, manual boundary, and completed rollback candidate are valid."
}

case_real_path() {
  local evidence="$repository_root/envs/prod/promotion-evidence.yaml"
  local baseline="$repository_root/evidence/prod/baseline.json"
  local physical_parent
  [[ -z ${PROMOTION_REAL_PATH:-} && -z ${BASELINE_REAL_PATH:-} && -z ${NOW:-} ]] ||
    fail "canonical promotion gate does not accept caller-supplied paths or clocks"
  if [[ ! -e "$evidence" ]]; then
    echo "PASS: canonical promotion evidence is absent; no promotion PR is pending."
    return 0
  fi
  [[ -f "$evidence" && ! -L "$evidence" && -f "$baseline" && ! -L "$baseline" ]] ||
    fail "canonical promotion evidence and Prod baseline must be regular non-symlink files"
  physical_parent=$(cd -- "$(dirname -- "$evidence")" && pwd -P) || fail "cannot resolve canonical promotion parent"
  [[ "$physical_parent/$(basename -- "$evidence")" == "$evidence" ]] ||
    fail "canonical promotion evidence escaped its repository path"
  physical_parent=$(cd -- "$(dirname -- "$baseline")" && pwd -P) || fail "cannot resolve canonical baseline parent"
  [[ "$physical_parent/$(basename -- "$baseline")" == "$baseline" ]] ||
    fail "canonical Prod baseline escaped its repository path"
  local current_time
  current_time=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  EVIDENCE="$evidence" BASELINE="$baseline" NOW="$current_time" case_promotion
  echo "PASS: canonical promotion path is schema, baseline, and rollback bound."
}

case_rollback_edges() {
  local inside="$fixture_root/rollback/inside-window.json"
  local multi="$fixture_root/rollback/multi-candidate.json"
  local outside="$fixture_root/rollback/outside-window.json"
  local fixture invalid

  validate_candidate_set "$inside" || fail "inside-window rollback fixture must remain within rollbackWindow"
  validate_candidate_set "$multi" || fail "all multi-candidate rollback entries must be independently eligible"

  validate_candidate_set "$outside" >/dev/null 2>&1 && fail "outside-window rollback fixture was accepted"

  for fixture in "$fixture_root"/rollback/{experiment-excluded,foreign-owner,foreign-uid,non-controller-owner,revision-gap}.json; do
    validate_candidate_set "$fixture" ||
      fail "valid timestamp/ownership rollback fixture was rejected: $(basename "$fixture")"
  done

  invalid="$render_root/rollback-duplicate-candidate.json"
  jq '.completedRollback.candidates[1].podTemplateHash = .completedRollback.candidates[0].podTemplateHash' "$multi" >"$invalid"
  validate_candidate_set "$invalid" >/dev/null 2>&1 && fail "duplicate rollback candidate hash was accepted"
  invalid="$render_root/rollback-experiment-candidate.json"
  jq '.completedRollback.candidates[1].podTemplateHash = "experiment-hash"' "$multi" >"$invalid"
  validate_candidate_set "$invalid" >/dev/null 2>&1 && fail "Experiment ReplicaSet was accepted as a rollback candidate"
  invalid="$render_root/rollback-candidate-revision-mismatch.json"
  jq '.completedRollback.candidates[0].rolloutRevision += 10' "$multi" >"$invalid"
  validate_candidate_set "$invalid" >/dev/null 2>&1 && fail "candidate rolloutRevision was not bound to its ReplicaSet audit revision"
  invalid="$render_root/rollback-stable-revision-not-newer.json"
  jq '.completedRollback.replicaSetList.items[] |=
    if .metadata.labels["rollouts-pod-template-hash"] == "stable-hash"
    then .metadata.annotations["rollout.argoproj.io/revision"] = "3" else . end' "$inside" >"$invalid"
  validate_candidate_set "$invalid" >/dev/null 2>&1 && fail "stable ReplicaSet revision was not newer than the rollback candidate"
  invalid="$render_root/rollback-noncanonical-revision.json"
  jq '.completedRollback.replicaSetList.items[0].metadata.annotations["rollout.argoproj.io/revision"] = "3.0"' "$inside" >"$invalid"
  validate_candidate_set "$invalid" >/dev/null 2>&1 && fail "noncanonical ReplicaSet revision annotation was accepted"

  for fixture in "$fixture_root"/rollback/{malformed-owned-replicaset,missing-stable,missing-target,target-newer-than-stable}.json; do
    if validate_candidate_set "$fixture" >/dev/null 2>&1; then
      fail "invalid rollback fixture was accepted: $(basename "$fixture")"
    fi
  done
  echo "PASS: rollback candidates, ownership, and rollback-window edge cases fail closed."
}

case_lineage() {
  yq -o=json '.' "$repository_root/envs/prod/rollback-compatibility.yaml" | jq -e '
    .releaseLineage as $lineage |
    ($lineage | keys | sort) == ["v1Compatible","v201HotfixOrderTotal","v2FaultyOrderTotal","v2PrimeContractCompatible"] and
    all($lineage[];
      (keys | sort) == ["indexDigest","sourceSha"] and
      (.sourceSha | type == "string" and test("^[0-9a-f]{40}$")) and
      (.indexDigest | type == "string" and test("^sha256:[0-9a-f]{64}$"))) and
    ([$lineage[].sourceSha] | unique | length) == 4 and
    ([$lineage[].indexDigest] | unique | length) == 4
  ' >/dev/null || fail "release lineage identifiers are not four exact distinct immutable identities"
  echo "PASS: release lineage identities are exact and distinct."
}

case_ready_edges() {
  local valid="$fixture_root/promotion/valid-ap-northeast-2.yaml"
  local now=2026-09-03T01:00:00Z candidate label expression
  validate_ready "$valid" "$now"
  while IFS='|' read -r label expression; do
    candidate="$render_root/dev-ready-$label.yaml"
    yq "$expression" "$valid" >"$candidate"
    if (validate_ready "$candidate" "$now") >/dev/null 2>&1; then
      fail "DEV_READY accepted invalid $label"
    fi
  done <<'CASES'
workflow-name|.workflow.name = "promote"
workflow-event|.workflow.event = "workflow_dispatch"
workflow-runid-type|.workflow.runId = 1001
workflow-runattempt|.workflow.runAttempt = 0
workflow-runurl-id|.workflow.runUrl = "https://github.com/OWNER/cicd-course-sample-app/actions/runs/9999"
workflow-runurl-repository|.workflow.runUrl = "https://github.com/OWNER/other-app/actions/runs/1001"
platform-order|.image.platforms = ["linux/arm64", "linux/amd64"]
CASES
  if (PROMOTION_REAL_PATH="$valid" BASELINE_REAL_PATH="$fixture_root/evidence/baseline-valid.json" NOW="$now" case_real_path) >/dev/null 2>&1; then
    fail "canonical promotion gate accepted caller-supplied fixture paths"
  fi
  if (PROMOTION_REAL_PATH="$fixture_root/promotion/digest-mismatch.yaml" \
    BASELINE_REAL_PATH="$fixture_root/evidence/baseline-valid.json" case_real_path) >/dev/null 2>&1; then
    fail "canonical promotion path accepted the recorded Prod baseline digest"
  fi
  if bash "$0" --evidence "$valid" --rollback "$fixture_root/rollback/inside-window.json" \
    --baseline "$render_root/missing-baseline.json" --now "$now" >/dev/null 2>&1; then
    fail "explicit promotion invocation ignored --baseline"
  fi
  bash "$0" --evidence "$valid" --rollback "$fixture_root/rollback/inside-window.json" \
    --baseline "$fixture_root/evidence/baseline-valid.json" --now "$now" >/dev/null ||
    fail "explicit promotion invocation did not accept and validate --baseline"
  echo "PASS: DEV_READY workflow and platform identities fail closed."
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

requested=all
explicit_evidence=false
while (($#)); do
  case "$1" in
    --case) requested=${2:?missing case}; shift 2 ;;
    --evidence) EVIDENCE=${2:?missing evidence}; explicit_evidence=true; shift 2 ;;
    --rollback) ROLLBACK=${2:?missing rollback}; shift 2 ;;
    --baseline) BASELINE=${2:?missing baseline}; shift 2 ;;
    --now) NOW=${2:?missing now}; shift 2 ;;
    --*) echo "Usage: $0 [--case case] [--evidence path --rollback path --baseline path --now RFC3339]" >&2; exit 2 ;;
    *) requested=$1; shift ;;
  esac
done
[[ "$explicit_evidence" == false ]] || requested=promotion
case "$requested" in
  digest-mismatch) EVIDENCE="$fixture_root/promotion/digest-mismatch.yaml" case_promotion ;;
  expired) NOW=2026-09-03T03:00:00Z EVIDENCE="$fixture_root/promotion/expired.yaml" case_promotion ;;
  baseline-candidate-input|render-equivalence) case_render ;;
  promotion) case_promotion ;;
  in-progress-stable-reapply) jq -e '.inProgressStableReapply.requiresDesiredStateReconcile == true and .inProgressStableReapply.stableDigest != .inProgressStableReapply.candidateDigest' "$fixture_root/rollback/in-progress-stable-reapply.json" >/dev/null || fail "in-progress stable reapply requires desired-state reconciliation"; echo "PASS: stable reapply requires GitOps reconciliation." ;;
  rollback-edges) case_rollback_edges ;;
  ready-edges) case_ready_edges ;;
  lineage) case_lineage ;;
  real-path) case_real_path ;;
  all) case_promotion; case_render; case_ready_edges; case_rollback_edges; case_lineage; case_real_path ;;
  *) case_promotion ;;
esac
