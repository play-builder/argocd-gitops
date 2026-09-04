#!/usr/bin/env bash
set -Eeuo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
repository_root=$(cd -- "$script_dir/.." && pwd -P)
source_record="$repository_root/envs/prod/rollback-compatibility.yaml"
output="$repository_root/evidence/prod/rollback-candidates.json"
mode=capture
if [[ ${1:-} == cleanup ]]; then
  mode=cleanup
  shift
fi
fixture=
publish_fixture=
now_override=
runtime_override=false
adapter_dir=${COURSE_CHECK_BIN_DIR:-}
configmap_name=sample-app-rollback-candidates
namespace=app-prod

fail() { echo "FAIL: $*" >&2; exit 1; }
usage() {
  echo "Usage: $0 [--fixture file | --publish-fixture file | --source file --output file --now UTC] | cleanup [--fixture file --now UTC]" >&2
  exit 2
}
require_regular_file() { [[ -f "$1" && ! -L "$1" ]] || fail "$2 must be a regular non-symlink file"; }
physical_file() {
  local parent
  parent=$(cd -- "$(dirname -- "$1")" && pwd -P) || return 1
  echo "$parent/$(basename -- "$1")"
}

while (($#)); do
  case "$1" in
    --fixture) fixture=${2:?missing fixture}; shift 2 ;;
    --publish-fixture) publish_fixture=${2:?missing publication fixture}; shift 2 ;;
    --source) source_record=${2:?missing source}; runtime_override=true; shift 2 ;;
    --output) output=${2:?missing output}; runtime_override=true; shift 2 ;;
    --now) now_override=${2:?missing clock}; runtime_override=true; shift 2 ;;
    *) usage ;;
  esac
done
[[ -z "$fixture" || -z "$publish_fixture" ]] || usage

source_json=
source_digest=
validate_source() {
  local file=$1 digest_before digest_after
  require_regular_file "$file" 'rollback compatibility source'
  digest_before=$(shasum -a 256 "$file" | awk '{print $1}')
  source_json=$(yq -o=json -I=0 '.' "$file") || fail 'rollback compatibility source is not valid YAML'
  digest_after=$(shasum -a 256 "$file" | awk '{print $1}')
  [[ "$digest_before" == "$digest_after" ]] || fail 'rollback compatibility source changed while it was read'
  jq -e '
    def nonblank: type == "string" and test("[^[:space:]\uFEFF]");
    def canonical_utc_seconds:
      . as $value |
      type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$") and
      (try ((fromdateiso8601 | strftime("%Y-%m-%dT%H:%M:%SZ")) == $value) catch false);
    . as $root | .completedRollback as $rollback |
    ([ $rollback.replicaSetList.items[] |
       select((.metadata.annotations["rollouts.argoproj.io/experiment-name"] // "") == "") |
       {hash:.metadata.labels["rollouts-pod-template-hash"],
        revision:(.metadata.annotations["rollout.argoproj.io/revision"] | tonumber),
        observed:(.metadata.creationTimestamp | fromdateiso8601)} ]) as $eligible |
    ([ $eligible[] | select(.hash == $rollback.stableHash) ]) as $stable |
    ([ $eligible[] | select(.observed < $stable[0].observed) ] |
      sort_by(.revision) | reverse | .[0:$rollback.rollbackWindow.revisions] |
      map({hash,revision}) | sort_by(.revision)) as $expected |
    ((keys | sort) == ["completedRollback","releaseLineage"] or
     (keys | sort) == ["completedRollback","inProgressStableReapply","releaseLineage"]) and
    ($rollback | keys | sort) == ["candidates","replicaSetList","rollbackWindow","rolloutName","rolloutUid","stableHash","targetHash"] and
    ($rollback.rolloutName | nonblank) and ($rollback.rolloutUid | nonblank) and
    ($rollback.stableHash | nonblank) and ($rollback.targetHash | nonblank) and
    ($rollback.rollbackWindow | keys) == ["revisions"] and
    ($rollback.rollbackWindow.revisions | type == "number" and floor == . and . >= 1) and
    ($root.releaseLineage | keys | sort) == ["v1Compatible","v201HotfixOrderTotal","v2FaultyOrderTotal","v2PrimeContractCompatible"] and
    all($root.releaseLineage[];
      (keys | sort) == ["indexDigest","sourceSha"] and
      (.sourceSha | test("^[0-9a-f]{40}$")) and (.indexDigest | test("^sha256:[0-9a-f]{64}$"))) and
    ([$root.releaseLineage[].sourceSha] | unique | length) == 4 and
    ([$root.releaseLineage[].indexDigest] | unique | length) == 4 and
    ($rollback.replicaSetList | keys | sort) == ["apiVersion","items","kind"] and
    $rollback.replicaSetList.apiVersion == "apps/v1" and $rollback.replicaSetList.kind == "ReplicaSetList" and
    ($rollback.replicaSetList.items | type == "array" and length > 0) and
    all($rollback.replicaSetList.items[];
      (.metadata | keys | sort) == ["annotations","creationTimestamp","labels","name","ownerReferences"] and
      (.metadata.name | nonblank) and (.metadata.creationTimestamp | canonical_utc_seconds) and
      (.metadata.labels | keys) == ["rollouts-pod-template-hash"] and
      (.metadata.labels["rollouts-pod-template-hash"] | nonblank) and
      (.metadata.annotations | type == "object") and
      (if .metadata.annotations | has("rollouts.argoproj.io/experiment-name")
       then (.metadata.annotations | keys) == ["rollouts.argoproj.io/experiment-name"] and
            (.metadata.annotations["rollouts.argoproj.io/experiment-name"] | nonblank)
       else (.metadata.annotations | keys) == ["rollout.argoproj.io/revision"] and
            (.metadata.annotations["rollout.argoproj.io/revision"] | test("^[0-9]+$")) end) and
      (.metadata.ownerReferences | type == "array" and length == 1) and
      all(.metadata.ownerReferences[];
        (keys | sort) == ["apiVersion","controller","kind","name","uid"] and
        .apiVersion == "argoproj.io/v1alpha1" and .kind == "Rollout" and .controller == true and
        .name == $rollback.rolloutName and .uid == $rollback.rolloutUid)) and
    ([ $rollback.replicaSetList.items[].metadata.name ] | unique | length) == ($rollback.replicaSetList.items | length) and
    ([ $rollback.replicaSetList.items[].metadata.labels["rollouts-pod-template-hash"] ] | unique | length) == ($rollback.replicaSetList.items | length) and
    ($rollback.candidates | type == "array" and length > 0) and
    all($rollback.candidates[];
      (keys | sort) == ["gitRevertSha","imageDigest","podTemplateHash","productReadContract","rolloutRevision"] and
      .productReadContract == "v2prime" and
      (.imageDigest | test("^sha256:[0-9a-f]{64}$")) and
      (.gitRevertSha | test("^[0-9a-f]{40}$")) and
      (.podTemplateHash | nonblank) and
      (.rolloutRevision | type == "number" and floor == . and . >= 1) and
      .imageDigest == $root.releaseLineage.v2PrimeContractCompatible.indexDigest and
      .gitRevertSha == $root.releaseLineage.v2PrimeContractCompatible.sourceSha) and
    ([ $rollback.candidates[].podTemplateHash ] | unique | length) == ($rollback.candidates | length) and
    ([ $rollback.candidates[].rolloutRevision ] | unique | length) == ($rollback.candidates | length) and
    any($rollback.candidates[]; .podTemplateHash == $rollback.targetHash) and
    ($stable | length) == 1 and
    ([ $eligible[] | select(.hash == $rollback.targetHash) ] | length) == 1 and
    ([ $rollback.candidates[] | {hash:.podTemplateHash,revision:.rolloutRevision} ] | sort_by(.revision)) == $expected and
    ($root | if has("inProgressStableReapply") then
      (.inProgressStableReapply | keys | sort) == ["action","candidateDigest","requiresDesiredStateReconcile","stableDigest"] and
      .inProgressStableReapply.action == "git-reapply-stable-digest" and
      .inProgressStableReapply.requiresDesiredStateReconcile == true and
      (.inProgressStableReapply.stableDigest | test("^sha256:[0-9a-f]{64}$")) and
      (.inProgressStableReapply.candidateDigest | test("^sha256:[0-9a-f]{64}$")) and
      .inProgressStableReapply.stableDigest != .inProgressStableReapply.candidateDigest
    else true end)
  ' <<<"$source_json" >/dev/null || fail 'rollback compatibility source is not canonical or exhaustive'
  source_digest="sha256:$digest_before"
}

validate_record() {
  local file=$1 expected_grade=$2 validation_now=${3:-}
  require_regular_file "$file" 'rollback candidate evidence'
  jq -e --arg grade "$expected_grade" --arg now "$validation_now" \
    --arg digest "$source_digest" --argjson source "$source_json" '
    def nonblank: type == "string" and test("[^[:space:]\uFEFF]");
    def canonical_utc_seconds:
      . as $value |
      type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$") and
      (try ((fromdateiso8601 | strftime("%Y-%m-%dT%H:%M:%SZ")) == $value) catch false);
    . as $record |
    (keys | sort) == ["candidates","clusterArn","environment","evidenceGrade","expiresAt","gitopsRevision","observedAt","region","rolloutName","schemaVersion","sourceEvidenceDigest"] and
    .schemaVersion == "course.rollback-candidates/v1" and .evidenceGrade == $grade and
    .environment == "prod" and (.region | IN("ap-northeast-2","us-east-1")) and
    (.clusterArn | test("^arn:aws:eks:" + $record.region + ":[0-9]{12}:cluster/[A-Za-z0-9][A-Za-z0-9_-]{0,99}$")) and
    .rolloutName == "sample-app" and (.rolloutName | nonblank) and
    (.gitopsRevision | test("^[0-9a-f]{40}$")) and .sourceEvidenceDigest == $digest and
    (.observedAt | canonical_utc_seconds) and (.expiresAt | canonical_utc_seconds) and
    ((.observedAt | fromdateiso8601) < (.expiresAt | fromdateiso8601)) and
    (((.expiresAt | fromdateiso8601) - (.observedAt | fromdateiso8601)) <= 3600) and
    ($now == "" or
      (($now | canonical_utc_seconds) and
       ((.observedAt | fromdateiso8601) < ($now | fromdateiso8601)) and
       (($now | fromdateiso8601) < (.expiresAt | fromdateiso8601)))) and
    (.candidates | type == "array" and length > 0) and
    all(.candidates[];
      (keys | sort) == ["gitRevertSha","imageDigest","podTemplateHash","productReadContract","rolloutRevision"] and
      .productReadContract == "v2prime" and (.imageDigest | test("^sha256:[0-9a-f]{64}$")) and
      (.gitRevertSha | test("^[0-9a-f]{40}$")) and (.podTemplateHash | nonblank) and
      (.rolloutRevision | type == "number" and floor == . and . >= 1)) and
    ([.candidates[].podTemplateHash] | unique | length) == (.candidates | length) and
    ([.candidates[].rolloutRevision] | unique | length) == (.candidates | length) and
    .candidates == $source.completedRollback.candidates
  ' "$file" >/dev/null || fail 'rollback candidate evidence failed canonical identity, lifetime, or candidate validation'
}

validate_ecr_repository() {
  local repository=$1 region=$2 account=$3 name
  [[ "$repository" =~ ^([0-9]{12})\.dkr\.ecr\.(ap-northeast-2|us-east-1)\.amazonaws\.com/([a-z0-9]+([._/-][a-z0-9]+)*)$ ]] ||
    fail 'rollback candidate image repository is not canonical commercial ECR'
  [[ ${BASH_REMATCH[1]} == "$account" && ${BASH_REMATCH[2]} == "$region" ]] ||
    fail 'rollback candidate image repository account or Region differs from EKS'
  name=${BASH_REMATCH[3]}
  ((${#name} >= 2 && ${#name} <= 256)) || fail 'rollback candidate ECR repository name length is invalid'
  [[ "$name" == sample-app || "$name" == */sample-app ]] ||
    fail 'rollback candidate image repository is not the canonical sample-app identity'
}

publish_configmap() {
  local evidence=$1 existing payload
  validate_application_binding "$evidence"
  validate_cluster_binding "$evidence"
  [[ $(kubectl auth can-i create configmaps --namespace "$namespace") == yes ]] ||
    fail 'caller is not authorized to create the rollback candidate ConfigMap'
  payload=$(mktemp)
  write_configmap_payload "$evidence" "$payload"
  existing=$(kubectl -n "$namespace" get configmap "$configmap_name" -o json --ignore-not-found) || {
    rm -f -- "$payload"
    fail 'unable to query the rollback candidate ConfigMap'
  }
  if [[ -n "$existing" ]]; then
    jq -e --argjson expected "$(cat "$payload")" '
      {apiVersion,kind,
       metadata:{name:.metadata.name,namespace:.metadata.namespace,labels:.metadata.labels,annotations:.metadata.annotations},
       immutable,data} == $expected
    ' <<<"$existing" >/dev/null || {
      rm -f -- "$payload"
      fail 'existing immutable rollback candidate ConfigMap has different bytes or identity'
    }
  else
    kubectl -n "$namespace" create -f "$payload" >/dev/null || {
      rm -f -- "$payload"
      fail 'unable to create the immutable rollback candidate ConfigMap'
    }
  fi
  rm -f -- "$payload"
}

validate_application_binding() {
  local evidence=$1 application revision
  application=$(argocd app get sample-app-prod -o json) ||
    fail 'unable to re-query sample-app-prod before ConfigMap publication'
  revision=$(jq -er '.gitopsRevision' "$evidence") || fail 'rollback evidence GitOps revision is missing'
  jq -e --arg revision "$revision" '
    .metadata.name == "sample-app-prod" and .status.sync.status == "OutOfSync" and
    .status.sync.revision == $revision and .status.health.status == "Healthy" and
    (.spec.source.repoURL | test("/argocd-gitops(\\.git)?$")) and
    ((.spec.syncPolicy.automated // null) == null) and
    ((.status.operationState.phase // "") | IN("","Succeeded"))
  ' <<<"$application" >/dev/null ||
    fail 'fresh Argo desired revision or pre-Sync state differs from rollback evidence'
}

validate_finalize_binding() {
  local application revision
  [[ -z $(git -C "$repository_root" status --porcelain --untracked-files=all -- . ':(exclude)evidence') ]] ||
    fail 'GitOps source outside evidence/ must match the reviewed finalize commit'
  revision=$(git -C "$repository_root" rev-parse HEAD) || fail 'unable to read the finalize GitOps revision'
  [[ "$revision" =~ ^[0-9a-f]{40}$ ]] || fail 'finalize GitOps revision is not a full commit SHA'
  application=$(argocd app get sample-app-prod -o json) ||
    fail 'unable to re-query sample-app-prod before rollback evidence cleanup'
  jq -e --arg revision "$revision" '
    .metadata.name == "sample-app-prod" and
    .status.sync.status == "Synced" and .status.sync.revision == $revision and
    .status.health.status == "Healthy" and
    ((.status.operationState.phase // "") | IN("", "Succeeded")) and
    (.spec.source.repoURL | test("/argocd-gitops(\\.git)?$")) and
    ((.spec.syncPolicy.automated // null) == null) and
    .spec.source.helm.valueFiles == [
      "../../envs/prod/values.yaml",
      "../../envs/prod/stateful-values.yaml",
      "../../envs/prod/migration-finalize-values.yaml"
    ]
  ' <<<"$application" >/dev/null ||
    fail 'Prod Application is not Synced and Healthy at the reviewed finalize revision'
}

validate_cluster_binding() {
  local evidence=$1 cluster live_endpoint kubeconfig kube_server
  cluster=$(aws eks describe-cluster --name "$EKS_CLUSTER_NAME" --region "$AWS_REGION" --output json) ||
    fail 'unable to re-query the Prod EKS cluster for rollback evidence'
  live_endpoint=$(jq -er '.cluster.endpoint' <<<"$cluster") || fail 'fresh Prod EKS endpoint is missing'
  jq -e --arg arn "$(jq -r '.clusterArn' "$evidence")" --arg name "$EKS_CLUSTER_NAME" --arg region "$AWS_REGION" '
    .cluster.arn == $arn and .cluster.name == $name and .cluster.status == "ACTIVE" and
    (.cluster.arn | test("^arn:aws:eks:"+$region+":[0-9]{12}:cluster/"+$name+"$")) and
    (.cluster.endpoint | type == "string" and startswith("https://"))
  ' <<<"$cluster" >/dev/null || fail 'fresh Prod EKS identity differs from rollback candidate evidence'
  kubeconfig=$(kubectl config view --minify -o json) || fail 'unable to re-query the active context for rollback evidence'
  kube_server=$(jq -er '.clusters | if length == 1 then .[0].cluster.server else empty end' <<<"$kubeconfig") ||
    fail 'fresh active context must contain exactly one cluster server'
  [[ "$kube_server" == "$live_endpoint" ]] || fail 'fresh active context differs from the Prod EKS cluster'
}

write_configmap_payload() {
  local evidence=$1 payload=$2 evidence_sha
  evidence_sha="sha256:$(shasum -a 256 "$evidence" | awk '{print $1}')"
  jq -n --rawfile evidence "$evidence" --arg evidenceSha "$evidence_sha" --arg sourceDigest "$source_digest" \
    --arg environment "$(jq -r '.environment' "$evidence")" --arg region "$(jq -r '.region' "$evidence")" \
    --arg clusterArn "$(jq -r '.clusterArn' "$evidence")" --arg rolloutName "$(jq -r '.rolloutName' "$evidence")" \
    --arg gitopsRevision "$(jq -r '.gitopsRevision' "$evidence")" '
    {apiVersion:"v1",kind:"ConfigMap",
     metadata:{name:"sample-app-rollback-candidates",namespace:"app-prod",
       labels:{"app.kubernetes.io/name":"sample-app-rollback-candidates",
               "app.kubernetes.io/part-of":"sample-app",
               "course.playbuilder.io/cleanup-scope":"rollback-candidates"},
       annotations:{"course.playbuilder.io/content-sha256":$evidenceSha,
                    "course.playbuilder.io/source-evidence-digest":$sourceDigest}},
     immutable:true,
     data:{"rollback-candidates.json":$evidence,environment:$environment,region:$region,
           clusterArn:$clusterArn,rolloutName:$rolloutName,gitopsRevision:$gitopsRevision,
           sourceEvidenceDigest:$sourceDigest}}
  ' >"$payload" || { rm -f -- "$payload"; fail 'unable to construct immutable ConfigMap payload'; }
  chmod 600 "$payload"
}

cleanup_configmap() {
  local evidence=$1 cleanup_now=$2 existing uid job deleted payload delete_options
  validate_record "$evidence" CLOUD_RUNTIME
  validate_finalize_binding
  validate_cluster_binding "$evidence"
  [[ $(kubectl auth can-i delete configmaps --namespace "$namespace") == yes ]] ||
    fail 'caller is not authorized to delete the rollback candidate ConfigMap'
  payload=$(mktemp)
  write_configmap_payload "$evidence" "$payload"
  existing=$(kubectl -n "$namespace" get configmap "$configmap_name" -o json --ignore-not-found) || {
    rm -f -- "$payload"
    fail 'unable to query the rollback candidate ConfigMap for cleanup'
  }
  [[ -n "$existing" ]] || { rm -f -- "$payload"; fail 'rollback candidate ConfigMap is absent before explicit cleanup'; }
  jq -e --argjson expected "$(cat "$payload")" '
    def nonblank: type == "string" and test("[^[:space:]\uFEFF]");
    (.metadata.uid | nonblank) and
    {apiVersion,kind,
     metadata:{name:.metadata.name,namespace:.metadata.namespace,labels:.metadata.labels,annotations:.metadata.annotations},
     immutable,data} == $expected
  ' <<<"$existing" >/dev/null || {
    rm -f -- "$payload"
    fail 'rollback candidate ConfigMap UID, bytes, or identity differs before cleanup'
  }
  rm -f -- "$payload"
  uid=$(jq -er '.metadata.uid' <<<"$existing") || fail 'rollback candidate ConfigMap UID is missing'
  job=$(kubectl -n "$namespace" get job sample-app-migration -o json) ||
    fail 'unable to query the Contract 003 migration Job before cleanup'
  jq -e --arg now "$cleanup_now" --argjson evidence "$(cat "$evidence")" '
    def canonical_utc_seconds:
      . as $value |
      type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$") and
      (try ((fromdateiso8601 | strftime("%Y-%m-%dT%H:%M:%SZ")) == $value) catch false);
    (.spec.template.spec.containers[] | select(.name == "migrate")) as $container |
    .metadata.name == "sample-app-migration" and .metadata.namespace == "app-prod" and
    .metadata.labels["app.kubernetes.io/component"] == "migration" and
    .metadata.labels["app.kubernetes.io/part-of"] == "sample-app" and
    .status.succeeded == 1 and ((.status.failed // 0) == 0) and
    (.status.completionTime | canonical_utc_seconds) and ($now | canonical_utc_seconds) and
    ((.status.completionTime | fromdateiso8601) > ($evidence.observedAt | fromdateiso8601)) and
    ((.status.completionTime | fromdateiso8601) < ($evidence.expiresAt | fromdateiso8601)) and
    ((.status.completionTime | fromdateiso8601) <= ($now | fromdateiso8601)) and
    $container.command == ["node", "scripts/migrate.mjs"] and
    $container.args == ["--target", "003_contract_product_name"] and
    ([ $container.env[]? | select(.name | startswith("ROLLBACK_")) ] | length) == 0 and
    ([ $container.volumeMounts[]? | select(.name == "rollback-candidates") ] | length) == 0 and
    ([ .spec.template.spec.volumes[]? | select(.name == "rollback-candidates") ] | length) == 0
  ' <<<"$job" >/dev/null || fail 'finalize migration Job is not complete or still consumes rollback evidence'
  delete_options=$(mktemp)
  jq -n --arg uid "$uid" \
    '{apiVersion:"v1",kind:"DeleteOptions",propagationPolicy:"Background",preconditions:{uid:$uid}}' \
    >"$delete_options" || { rm -f -- "$delete_options"; fail 'unable to construct UID-bound DeleteOptions'; }
  chmod 600 "$delete_options"
  kubectl delete --raw="/api/v1/namespaces/$namespace/configmaps/$configmap_name" -f "$delete_options" >/dev/null || {
    rm -f -- "$delete_options"
    fail 'unable to delete the exact rollback candidate ConfigMap UID'
  }
  rm -f -- "$delete_options"
  deleted=$(kubectl -n "$namespace" get configmap "$configmap_name" -o json --ignore-not-found) ||
    fail 'unable to verify rollback candidate ConfigMap deletion'
  [[ -z "$deleted" ]] || fail 'rollback candidate ConfigMap remains after explicit cleanup'
}

for command in jq yq shasum mktemp; do command -v "$command" >/dev/null || fail "$command is required"; done
validate_source "$source_record"

if [[ "$mode" == cleanup ]]; then
  cleanup_evidence=$output
  cleanup_now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  if [[ -n "$adapter_dir" ]]; then
    [[ -n "$fixture" && -z "$publish_fixture" && -n "$now_override" ]] ||
      fail 'static cleanup simulation requires a CLOUD_RUNTIME fixture and explicit clock'
    [[ "$source_record" == "$repository_root/envs/prod/rollback-compatibility.yaml" &&
       "$output" == "$repository_root/evidence/prod/rollback-candidates.json" ]] ||
      fail 'cleanup simulation does not accept source or output overrides'
    PATH="$adapter_dir:$PATH"
    cleanup_evidence=$fixture
    cleanup_now=$now_override
  else
    [[ -z "$fixture" && -z "$publish_fixture" && "$runtime_override" == false ]] ||
      fail 'runtime cleanup uses only canonical evidence and the current clock'
    require_regular_file "$cleanup_evidence" 'canonical rollback candidate evidence'
    [[ "$(physical_file "$cleanup_evidence")" == "$repository_root/evidence/prod/rollback-candidates.json" ]] ||
      fail 'runtime cleanup evidence escaped its canonical path'
  fi
  [[ ${AWS_REGION:-} == ap-northeast-2 || ${AWS_REGION:-} == us-east-1 ]] ||
    fail 'AWS_REGION must be ap-northeast-2 or us-east-1 for rollback ConfigMap cleanup'
  [[ ${EKS_CLUSTER_NAME:-} =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,99}$ ]] ||
    fail 'EKS_CLUSTER_NAME is invalid for rollback ConfigMap cleanup'
  for command in argocd aws git kubectl; do command -v "$command" >/dev/null || fail "$command is required for rollback ConfigMap cleanup"; done
  cleanup_configmap "$cleanup_evidence" "$cleanup_now"
  if [[ -n "$adapter_dir" ]]; then
    echo '[STATIC] simulated UID-bound rollback ConfigMap cleanup; no live cluster was changed.'
  else
    echo "[CLOUD_RUNTIME] removed $namespace/$configmap_name after successful finalize migration"
  fi
  exit 0
fi

if [[ -n "$fixture" ]]; then
  [[ -z "$adapter_dir" && "$runtime_override" == false ]] ||
    fail 'fixture validation cannot be combined with adapters, clocks, or runtime overrides'
  validate_record "$fixture" CLOUD_RUNTIME
  echo '[STATIC] validated rollback candidate fixture; no runtime evidence or ConfigMap was written.'
  exit 0
fi

if [[ -n "$publish_fixture" ]]; then
  [[ -n "$adapter_dir" && "$runtime_override" == true && -n "$now_override" ]] ||
    fail 'publication fixture simulation requires a fake adapter and explicit clock'
  PATH="$adapter_dir:$PATH"
  validate_record "$publish_fixture" CLOUD_RUNTIME "$now_override"
  publish_configmap "$publish_fixture"
  echo '[STATIC] simulated exact immutable ConfigMap publication; no live cluster was changed.'
  exit 0
fi

evidence_grade=CLOUD_RUNTIME
clock_now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
if [[ -n "$adapter_dir" ]]; then
  [[ "$runtime_override" == true && -n "$now_override" ]] ||
    fail 'static runtime adapter requires explicit source, output, and clock'
  [[ "$source_record" != "$repository_root/envs/prod/rollback-compatibility.yaml" &&
     "$output" != "$repository_root/evidence/"* && "$output" != *'/tests/fixtures/'* ]] ||
    fail 'static runtime adapter requires noncanonical source and output paths'
  PATH="$adapter_dir:$PATH"
  evidence_grade=STATIC
  clock_now=$now_override
else
  [[ "$runtime_override" == false ]] || fail 'runtime producer source, output, and clock are fixed'
  [[ "$(physical_file "$source_record")" == "$repository_root/envs/prod/rollback-compatibility.yaml" ]] ||
    fail 'runtime rollback compatibility source escaped its canonical path'
fi
jq -en --arg now "$clock_now" '
  $now | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$") and
  (try ((fromdateiso8601 | strftime("%Y-%m-%dT%H:%M:%SZ")) == $now) catch false)
' >/dev/null || fail 'capture clock must be canonical UTC seconds'

for command in argocd aws git kubectl; do command -v "$command" >/dev/null || fail "$command is required for live rollback candidate capture"; done
[[ ${AWS_REGION:-} == ap-northeast-2 || ${AWS_REGION:-} == us-east-1 ]] ||
  fail 'AWS_REGION must be ap-northeast-2 or us-east-1'
[[ ${EKS_CLUSTER_NAME:-} =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,99}$ ]] || fail 'EKS_CLUSTER_NAME is invalid'
[[ -z $(git -C "$repository_root" status --porcelain --untracked-files=all -- . ':(exclude)evidence') ]] ||
  fail 'GitOps source outside evidence/ must match the checked-out commit before rollback capture'
local_revision=$(git -C "$repository_root" rev-parse HEAD)
[[ "$local_revision" =~ ^[0-9a-f]{40}$ ]] || fail 'local GitOps revision is not a full commit SHA'

application=$(argocd app get sample-app-prod -o json) || fail 'unable to query sample-app-prod from Argo CD'
desired_revision=$(jq -er '.status.sync.revision' <<<"$application") || fail 'Argo CD desired revision is missing'
jq -e '
  .metadata.name == "sample-app-prod" and .status.sync.status == "OutOfSync" and
  .status.health.status == "Healthy" and (.spec.source.repoURL | test("/argocd-gitops(\\.git)?$")) and
  ((.spec.syncPolicy.automated // null) == null) and
  ((.status.operationState.phase // "") | IN("","Succeeded"))
' <<<"$application" >/dev/null ||
  fail 'sample-app-prod must be Healthy, manually managed, idle, and OutOfSync before full Sync'
[[ "$desired_revision" == "$local_revision" ]] || fail 'Argo CD desired revision does not equal the clean reviewed HEAD'

cluster=$(aws eks describe-cluster --name "$EKS_CLUSTER_NAME" --region "$AWS_REGION" --output json) ||
  fail 'unable to describe the Prod EKS cluster'
cluster_arn=$(jq -er '.cluster.arn' <<<"$cluster") || fail 'Prod EKS cluster ARN is missing'
cluster_endpoint=$(jq -er '.cluster.endpoint' <<<"$cluster") || fail 'Prod EKS endpoint is missing'
jq -e --arg name "$EKS_CLUSTER_NAME" --arg region "$AWS_REGION" '
  .cluster.name == $name and .cluster.status == "ACTIVE" and
  (.cluster.arn | test("^arn:aws:eks:"+$region+":[0-9]{12}:cluster/"+$name+"$")) and
  (.cluster.endpoint | type == "string" and startswith("https://"))
' <<<"$cluster" >/dev/null || fail 'Prod EKS identity, Region, account, or status is invalid'
cluster_account=${cluster_arn#arn:aws:eks:$AWS_REGION:}
cluster_account=${cluster_account%%:*}
kubeconfig=$(kubectl config view --minify -o json) || fail 'unable to inspect the active Kubernetes context'
kube_server=$(jq -er '.clusters | if length == 1 then .[0].cluster.server else empty end' <<<"$kubeconfig") ||
  fail 'active context must contain exactly one cluster server'
[[ "$kube_server" == "$cluster_endpoint" ]] || fail 'active context endpoint differs from the Prod EKS cluster'

rollout=$(kubectl -n "$namespace" get rollout sample-app -o json) || fail 'unable to query the live Prod Rollout'
rollout_name=$(jq -er '.metadata.name' <<<"$rollout") || fail 'live Rollout name is missing'
rollout_uid=$(jq -er '.metadata.uid' <<<"$rollout") || fail 'live Rollout UID is missing'
stable_hash=$(jq -er '.status.stableRS' <<<"$rollout") || fail 'live stable hash is missing'
window=$(jq -er '.spec.rollbackWindow.revisions' <<<"$rollout") || fail 'live rollbackWindow is missing'
jq -e --argjson source "$source_json" '
  def nonblank: type == "string" and test("[^[:space:]\uFEFF]");
  .metadata.name == $source.completedRollback.rolloutName and .metadata.namespace == "app-prod" and
  (.metadata.name | nonblank) and .metadata.uid == $source.completedRollback.rolloutUid and (.metadata.uid | nonblank) and
  .spec.rollbackWindow.revisions == $source.completedRollback.rollbackWindow.revisions and
  .status.phase == "Healthy" and .status.stableRS == $source.completedRollback.stableHash and
  .status.currentPodHash == .status.stableRS and (.status.stableRS | nonblank) and
  (.status.replicas | type == "number" and . > 0) and
  .status.readyReplicas == .status.replicas and .status.availableReplicas == .status.replicas and
  ((.status.pauseConditions // []) | length) == 0
' <<<"$rollout" >/dev/null || fail 'live Rollout identity, stable state, or rollbackWindow differs from reviewed source'

replicasets=$(kubectl -n "$namespace" get replicasets -l app.kubernetes.io/instance=sample-app -o json) ||
  fail 'unable to query live Prod ReplicaSets'
source_projection=$(jq -cS '
  .completedRollback.replicaSetList |
  .items |= (map({metadata:{name:.metadata.name,creationTimestamp:.metadata.creationTimestamp,
    labels:{"rollouts-pod-template-hash":.metadata.labels["rollouts-pod-template-hash"]},
    annotations:(.metadata.annotations | with_entries(select(.key == "rollout.argoproj.io/revision" or .key == "rollouts.argoproj.io/experiment-name"))),
    ownerReferences:[.metadata.ownerReferences[] | {apiVersion,kind,name,uid,controller}]}}) | sort_by(.metadata.name))
' <<<"$source_json")
live_projection=$(jq -cS '
  {apiVersion,kind,items:(.items | map({metadata:{name:.metadata.name,creationTimestamp:.metadata.creationTimestamp,
    labels:{"rollouts-pod-template-hash":.metadata.labels["rollouts-pod-template-hash"]},
    annotations:(.metadata.annotations | with_entries(select(.key == "rollout.argoproj.io/revision" or .key == "rollouts.argoproj.io/experiment-name"))),
    ownerReferences:[.metadata.ownerReferences[] | {apiVersion,kind,name,uid,controller}]}}) | sort_by(.metadata.name))}
' <<<"$replicasets") || fail 'live ReplicaSet list is malformed'
[[ "$source_projection" == "$live_projection" ]] ||
  fail 'live ReplicaSet identities are missing, additional, foreign, or different from reviewed source'

candidates=$(jq -c '.completedRollback.candidates' <<<"$source_json")
first_hash=$(jq -r '.[0].podTemplateHash' <<<"$candidates")
first_image=$(jq -er --arg hash "$first_hash" '
  [.items[] | select(.metadata.labels["rollouts-pod-template-hash"] == $hash) |
    .spec.template.spec.containers[] | select(.name == "sample-app") | .image] |
  if length == 1 then .[0] else empty end
' <<<"$replicasets") || fail 'candidate ReplicaSet sample-app image is ambiguous'
[[ "$first_image" =~ ^([^@]+)@(sha256:[0-9a-f]{64})$ ]] || fail 'candidate image is not pinned by digest'
image_repository=${BASH_REMATCH[1]}
validate_ecr_repository "$image_repository" "$AWS_REGION" "$cluster_account"
jq -e --argjson candidates "$candidates" --arg repository "$image_repository" '
  . as $list |
  all($candidates[];
    . as $candidate |
    ([ $list.items[] | select(
      .metadata.labels["rollouts-pod-template-hash"] == $candidate.podTemplateHash and
      .metadata.annotations["rollout.argoproj.io/revision"] == ($candidate.rolloutRevision | tostring) and
      ((.metadata.annotations["rollouts.argoproj.io/experiment-name"] // "") == "") and
      ([.spec.template.spec.containers[] | select(.name == "sample-app") | .image] ==
        [($repository + "@" + $candidate.imageDigest)])) ] | length) == 1)
' <<<"$replicasets" >/dev/null || fail 'live candidate image, revision, hash, or Experiment exclusion is invalid'
[[ "$source_digest" == "sha256:$(shasum -a 256 "$source_record" | awk '{print $1}')" ]] ||
  fail 'rollback compatibility source changed during live capture'
[[ -z $(git -C "$repository_root" status --porcelain --untracked-files=all -- . ':(exclude)evidence') &&
   $(git -C "$repository_root" rev-parse HEAD) == "$local_revision" ]] ||
  fail 'GitOps HEAD or worktree changed during live rollback capture'

observed_at=$(jq -nr --arg now "$clock_now" '(($now | fromdateiso8601) - 1) | strftime("%Y-%m-%dT%H:%M:%SZ")')
expires_at=$(jq -nr --arg now "$clock_now" '(($now | fromdateiso8601) + 3599) | strftime("%Y-%m-%dT%H:%M:%SZ")')
mkdir -p "$(dirname -- "$output")"
output_parent=$(cd -- "$(dirname -- "$output")" && pwd -P) || fail 'unable to resolve rollback evidence output parent'
if [[ "$evidence_grade" == CLOUD_RUNTIME ]]; then
  [[ "$output_parent/$(basename -- "$output")" == "$repository_root/evidence/prod/rollback-candidates.json" ]] ||
    fail 'runtime rollback evidence output escaped its canonical path'
fi
tmp=$(mktemp "$output_parent/.rollback-candidates.XXXXXX")
trap 'rm -f -- "$tmp"' EXIT
jq -n --arg grade "$evidence_grade" --arg region "$AWS_REGION" --arg arn "$cluster_arn" \
  --arg revision "$local_revision" --arg digest "$source_digest" --arg observed "$observed_at" \
  --arg expires "$expires_at" --argjson candidates "$candidates" '
  {schemaVersion:"course.rollback-candidates/v1",evidenceGrade:$grade,environment:"prod",
   region:$region,clusterArn:$arn,rolloutName:"sample-app",gitopsRevision:$revision,
   sourceEvidenceDigest:$digest,observedAt:$observed,expiresAt:$expires,candidates:$candidates}
' >"$tmp" || fail 'unable to construct rollback candidate evidence'
chmod 600 "$tmp"
validate_record "$tmp" "$evidence_grade" "$clock_now"
if [[ -e "$output" ]]; then
  require_regular_file "$output" 'existing rollback candidate evidence'
  cmp -s "$tmp" "$output" || fail 'existing rollback candidate evidence differs from the immutable capture'
  rm -f -- "$tmp"
else
  mv "$tmp" "$output"
fi
trap - EXIT
if [[ "$evidence_grade" == CLOUD_RUNTIME ]]; then publish_configmap "$output"; fi
echo "[$evidence_grade] wrote $output"
