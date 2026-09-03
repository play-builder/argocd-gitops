#!/usr/bin/env bash
set -Eeuo pipefail

test_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repository_root=$(cd -- "$test_root/.." && pwd)
fixture_root="$test_root/fixtures/evidence"
script="$repository_root/scripts/capture-prod-slo-evidence.sh"
canonical="$repository_root/evidence/prod/slo.json"
tmp_root=$(mktemp -d)
trap 'rm -rf -- "$tmp_root"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
fingerprint() {
  if [[ -f "$canonical" ]]; then shasum -a 256 "$canonical" | awk '{print "file:" $1}'
  elif [[ -e "$canonical" ]]; then echo other
  else echo absent
  fi
}

before=$(fingerprint)
log=$(bash "$script" --fixture "$fixture_root/prod-slo-valid.json")
grep -Fq '[STATIC]' <<<"$log" || fail 'Prod SLO fixture adapter was not labelled STATIC'
[[ "$before" == "$(fingerprint)" ]] || fail 'Prod SLO fixture adapter changed canonical runtime evidence'

while IFS='|' read -r label expression; do
  invalid="$tmp_root/$label.json"
  jq "$expression" "$fixture_root/prod-slo-valid.json" >"$invalid"
  if bash "$script" --fixture "$invalid" >/dev/null 2>&1; then
    fail "Prod SLO fixture adapter accepted invalid $label"
  fi
  [[ "$before" == "$(fingerprint)" ]] || fail "invalid $label fixture changed canonical runtime evidence"
done <<'CASES'
source-repository|.source.repository = "play-builder/other-app"
source-owner-whitespace|.source.repository = "play-builder /cicd-course-sample-app"
image-account|.image.repository = "999999999999.dkr.ecr.ap-northeast-2.amazonaws.com/course/sample-app"
image-name-too-short|.image.repository = "123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/a"
measurement-number|.metricResults[0].measurements[0].value = 12.5
measurement-nan|.metricResults[0].measurements[0].value = "NaN"
analysis-failed|.analysisRun.phase = "Failed"
traffic-weight|.rollout.trafficWeight = 50
CASES
while IFS='|' read -r label expression; do
  for whitespace in ascii-space bom; do
    value=' '
    [[ "$whitespace" == bom ]] && value=$(printf '\357\273\277')
    invalid="$tmp_root/$label-$whitespace.json"
    jq --arg value "$value" "$expression" "$fixture_root/prod-slo-valid.json" >"$invalid"
    if bash "$script" --fixture "$invalid" >/dev/null 2>&1; then
      fail "Prod SLO fixture adapter accepted $whitespace-only $label"
    fi
    [[ "$before" == "$(fingerprint)" ]] || fail "invalid $label fixture changed canonical runtime evidence"
  done
done <<'CASES'
evidenceId|.evidenceId=$value
rollout-name|.rollout.name=$value
rollout-uid|.rollout.uid=$value
rollout-hashes|.rollout.stableHash=$value | .rollout.currentPodHash=$value
analysis-name|.analysisRun.name=$value
analysis-uid|.analysisRun.uid=$value
analysis-template|.analysisRun.templateName=$value
CASES
two_character_fixture="$tmp_root/ecr-two-character.json"
jq '.image.repository="123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/ab"' \
  "$fixture_root/prod-slo-valid.json" >"$two_character_fixture"
bash "$script" --fixture "$two_character_fixture" >/dev/null ||
  fail 'Prod SLO fixture adapter rejected a two-character ECR repository name'

[[ -x "$script" ]] || fail 'Prod SLO producer is not executable'
head -1 "$script" | grep -Fqx '#!/usr/bin/env bash' || fail 'Prod SLO producer has the wrong shebang'
grep -Fq 'set -Eeuo pipefail' "$script" || fail 'Prod SLO producer is not fail-fast'
grep -Fq 'workflow.runUrl | capture' "$script" || fail 'Prod SLO producer does not derive source repository from workflow URL'
if grep -Fq 'repository:"OWNER/cicd-course-sample-app"' "$script"; then
  fail 'Prod SLO producer still hard-codes the source repository'
fi
grep -Fq 'rollout.argoproj.io/revision' "$script" || fail 'Prod SLO producer does not use stable ReplicaSet revision identity'
if grep -Fq 'rollouts.argoproj.io/revision' "$script"; then
  fail 'Prod SLO producer still uses the non-canonical plural revision annotation'
fi
if grep -Fq '.status.rolloutRevision' "$script"; then
  fail 'Prod SLO producer selects AnalysisRuns through a field absent from AnalysisRunStatus'
fi
grep -Fq '.metadata.annotations["rollout.argoproj.io/revision"]' "$script" ||
  fail 'Prod SLO producer does not bind AnalysisRuns to the controller revision annotation'
grep -Fq 'get httproute sample-app' "$script" || fail 'Prod SLO producer does not inspect live 100/0 routing'
grep -Fq 'config view --minify -o json' "$script" || fail 'Prod SLO producer does not bind active context endpoint'
grep -Fq 'existing canonical Prod SLO evidence belongs to a different immutable release identity' "$script" ||
  fail 'Prod SLO producer does not preserve existing immutable release identity'
grep -Fq 'status --porcelain --untracked-files=all' "$script" || fail 'Prod SLO producer does not enforce a clean source tree'

for option in --promotion-evidence --baseline --output; do
  if AWS_REGION=ap-northeast-2 EKS_CLUSTER_NAME=course-prod \
    bash "$script" "$option" "$tmp_root/override" >/dev/null 2>&1; then
    fail "runtime producer accepted arbitrary $option override"
  fi
done

fake_bin="$tmp_root/bin"
fake_runtime="$tmp_root/runtime-valid"
mkdir -p "$fake_bin" "$fake_runtime"
for command in argocd aws git kubectl; do
  ln -s "$test_root/helpers/fake-prod-slo-cli.sh" "$fake_bin/$command"
done
printf '%s\n' fedcba9876543210fedcba9876543210fedcba98 >"$fake_runtime/git-revision.txt"
: >"$fake_runtime/git-status.txt"
cp "$test_root/fixtures/promotion/valid-ap-northeast-2.yaml" "$fake_runtime/promotion.yaml"
cp "$fixture_root/baseline-valid.json" "$fake_runtime/baseline.json"
jq -n '{metadata:{name:"sample-app-prod"},spec:{source:{repoURL:"https://github.com/OWNER/argocd-gitops.git"}},status:{sync:{status:"Synced",revision:"fedcba9876543210fedcba9876543210fedcba98"},health:{status:"Healthy"}}}' >"$fake_runtime/application.json"
jq -n '{cluster:{name:"course-prod",arn:"arn:aws:eks:ap-northeast-2:123456789012:cluster/course-prod",status:"ACTIVE",endpoint:"https://prod.eks.example"}}' >"$fake_runtime/cluster.json"
jq -n '{clusters:[{cluster:{server:"https://prod.eks.example"}}]}' >"$fake_runtime/kubeconfig.json"
jq -n --arg image '123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/course/sample-app@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc' '
  {metadata:{name:"sample-app",namespace:"app-prod",uid:"22222222-2222-2222-2222-222222222222"},
   spec:{template:{spec:{containers:[{name:"sample-app",image:$image}]}},strategy:{canary:{analysis:{templates:[{templateName:"sample-app-success-rate"}]}}}},
   status:{phase:"Healthy",stableRS:"stable-v2",currentPodHash:"stable-v2",replicas:3,readyReplicas:3,availableReplicas:3,pauseConditions:[]}}
' >"$fake_runtime/rollout.json"
jq -n --arg image '123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/course/sample-app@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc' '
  {items:[{metadata:{name:"sample-app-stable-v2",labels:{"rollouts-pod-template-hash":"stable-v2"},annotations:{"rollout.argoproj.io/revision":"2"},ownerReferences:[{apiVersion:"argoproj.io/v1alpha1",kind:"Rollout",name:"sample-app",uid:"22222222-2222-2222-2222-222222222222",controller:true}]},
   spec:{replicas:3,template:{spec:{containers:[{name:"sample-app",image:$image}]}}},status:{readyReplicas:3,availableReplicas:3}}]}
' >"$fake_runtime/replicasets.json"
jq -n '{metadata:{name:"sample-app",namespace:"app-prod"},spec:{rules:[{backendRefs:[{name:"sample-app-stable",port:80,weight:100},{name:"sample-app-canary",port:80,weight:0}]}]}}' >"$fake_runtime/httproute.json"
jq -n --argjson metrics "$(jq -c '.metricResults' "$fixture_root/prod-slo-valid.json")" '
  {items:[{metadata:{name:"sample-app-2",uid:"33333333-3333-3333-3333-333333333333",annotations:{"rollout.argoproj.io/revision":"2"},ownerReferences:[{apiVersion:"argoproj.io/v1alpha1",kind:"Rollout",name:"sample-app",uid:"22222222-2222-2222-2222-222222222222",controller:true}]},
   spec:{metrics:[{name:"request-rate"},{name:"success-rate"}]},status:{phase:"Successful",metricResults:$metrics}}]}
' >"$fake_runtime/analysisruns.json"

run_static() {
  local runtime=$1 output=$2
  COURSE_CHECK_BIN_DIR="$fake_bin" FAKE_RUNTIME_DIR="$runtime" AWS_REGION=ap-northeast-2 EKS_CLUSTER_NAME=course-prod \
    bash "$script" --promotion-evidence "$runtime/promotion.yaml" --baseline "$runtime/baseline.json" \
      --output "$output" --now 2026-09-03T01:22:00Z
}

set_release_repository() {
  local runtime=$1 repository=$2
  local candidate_digest='sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc'
  yq -i ".image.repository=\"$repository\"" "$runtime/promotion.yaml"
  jq --arg repository "$repository" '.image.repository=$repository' \
    "$runtime/baseline.json" >"$runtime/mutated" && mv "$runtime/mutated" "$runtime/baseline.json"
  jq --arg image "$repository@$candidate_digest" '.spec.template.spec.containers[0].image=$image' \
    "$runtime/rollout.json" >"$runtime/mutated" && mv "$runtime/mutated" "$runtime/rollout.json"
  jq --arg image "$repository@$candidate_digest" '.items[0].spec.template.spec.containers[0].image=$image' \
    "$runtime/replicasets.json" >"$runtime/mutated" && mv "$runtime/mutated" "$runtime/replicasets.json"
}

static_output="$tmp_root/static-output.json"
static_log=$(run_static "$fake_runtime" "$static_output") || fail 'valid static runtime adapter was rejected'
grep -Fq '[STATIC]' <<<"$static_log" || fail 'fake runtime execution was not labelled STATIC'
jq -e '
  .evidenceGrade == "STATIC" and .status == "PASS" and
  .source.repository == "OWNER/cicd-course-sample-app" and
  .rollout.revision == 2 and .rollout.trafficWeight == 100 and
  .metricResults[0].measurements[0].value == "12.5" and
  .metricResults[0].measurements[0].phase == "Failed" and
  .metricResults[0].measurements[1].phase == "Successful"
' "$static_output" >/dev/null || fail 'static runtime adapter did not preserve canonical live-selection output'
[[ "$before" == "$(fingerprint)" ]] || fail 'static runtime adapter changed canonical runtime evidence'

two_character_runtime="$tmp_root/runtime-ecr-two-character"
cp -R "$fake_runtime" "$two_character_runtime"
set_release_repository "$two_character_runtime" '123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/ab'
run_static "$two_character_runtime" "$tmp_root/ecr-two-character-output.json" >/dev/null ||
  fail 'Prod SLO runtime rejected a two-character ECR repository name'

for label in ambiguous-analysis failed-sibling wrong-owner wrong-owner-name wrong-revision unfinished-measurement metric-failed no-successful-measurement nonfinite reversed-time nonfinal-route extra-route-backend extra-route-rule image-mismatch git-mismatch baseline-reuse baseline-stable-whitespace baseline-stable-bom malformed-cluster-arn promotion-ecr-double-slash promotion-ecr-name-too-short promotion-attestation-alpha promotion-owner-whitespace promotion-slo-evidence-id-whitespace promotion-slo-evidence-id-bom promotion-calendar-invalid; do
  runtime="$tmp_root/runtime-$label"
  cp -R "$fake_runtime" "$runtime"
  case "$label" in
    ambiguous-analysis) jq '.items += [.items[0] | .metadata.uid="44444444-4444-4444-4444-444444444444"]' "$runtime/analysisruns.json" >"$runtime/mutated" && mv "$runtime/mutated" "$runtime/analysisruns.json" ;;
    failed-sibling) jq '.items += [.items[0] | .metadata.uid="44444444-4444-4444-4444-444444444444" | .status.phase="Failed"]' "$runtime/analysisruns.json" >"$runtime/mutated" && mv "$runtime/mutated" "$runtime/analysisruns.json" ;;
    wrong-owner) jq '.items[0].metadata.ownerReferences[0].uid="foreign-uid"' "$runtime/analysisruns.json" >"$runtime/mutated" && mv "$runtime/mutated" "$runtime/analysisruns.json" ;;
    wrong-owner-name) jq '.items[0].metadata.ownerReferences[0].name="other-rollout"' "$runtime/analysisruns.json" >"$runtime/mutated" && mv "$runtime/mutated" "$runtime/analysisruns.json" ;;
    wrong-revision) jq '.items[0].metadata.annotations["rollout.argoproj.io/revision"]="1"' "$runtime/analysisruns.json" >"$runtime/mutated" && mv "$runtime/mutated" "$runtime/analysisruns.json" ;;
    unfinished-measurement) jq '.items[0].status.metricResults[0].measurements[0].finishedAt=null' "$runtime/analysisruns.json" >"$runtime/mutated" && mv "$runtime/mutated" "$runtime/analysisruns.json" ;;
    metric-failed) jq '.items[0].status.metricResults[0].phase="Failed"' "$runtime/analysisruns.json" >"$runtime/mutated" && mv "$runtime/mutated" "$runtime/analysisruns.json" ;;
    no-successful-measurement) jq '.items[0].status.metricResults[0].measurements |= map(.phase="Failed")' "$runtime/analysisruns.json" >"$runtime/mutated" && mv "$runtime/mutated" "$runtime/analysisruns.json" ;;
    nonfinite) jq '.items[0].status.metricResults[0].measurements[1].value="NaN"' "$runtime/analysisruns.json" >"$runtime/mutated" && mv "$runtime/mutated" "$runtime/analysisruns.json" ;;
    reversed-time) jq '.items[0].status.metricResults[0].measurements[1].finishedAt="2026-09-03T01:20:00Z"' "$runtime/analysisruns.json" >"$runtime/mutated" && mv "$runtime/mutated" "$runtime/analysisruns.json" ;;
    nonfinal-route) jq '.spec.rules[0].backendRefs[0].weight=50 | .spec.rules[0].backendRefs[1].weight=50' "$runtime/httproute.json" >"$runtime/mutated" && mv "$runtime/mutated" "$runtime/httproute.json" ;;
    extra-route-backend) jq '.spec.rules[0].backendRefs += [{name:"shadow",port:80,weight:0}]' "$runtime/httproute.json" >"$runtime/mutated" && mv "$runtime/mutated" "$runtime/httproute.json" ;;
    extra-route-rule) jq '.spec.rules += [.spec.rules[0]]' "$runtime/httproute.json" >"$runtime/mutated" && mv "$runtime/mutated" "$runtime/httproute.json" ;;
    image-mismatch) jq '.spec.template.spec.containers[0].image |= sub("c{64}$";"d" * 64)' "$runtime/rollout.json" >"$runtime/mutated" && mv "$runtime/mutated" "$runtime/rollout.json" ;;
    git-mismatch) printf '%s\n' aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa >"$runtime/git-revision.txt" ;;
    baseline-reuse) yq -o=json '.' "$runtime/promotion.yaml" | jq '.image.indexDigest="sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"' | yq -P >"$runtime/mutated" && mv "$runtime/mutated" "$runtime/promotion.yaml" ;;
    baseline-stable-whitespace) jq '.rollout.stableHash=" "' "$runtime/baseline.json" >"$runtime/mutated" && mv "$runtime/mutated" "$runtime/baseline.json" ;;
    baseline-stable-bom) jq '.rollout.stableHash="\uFEFF"' "$runtime/baseline.json" >"$runtime/mutated" && mv "$runtime/mutated" "$runtime/baseline.json" ;;
    malformed-cluster-arn)
      jq '.cluster.arn="arn:aws:eks:ap-northeast-2:123456789012:cluster/forged:cluster/course-prod"' "$runtime/cluster.json" >"$runtime/mutated" && mv "$runtime/mutated" "$runtime/cluster.json"
      jq '.clusterArn="arn:aws:eks:ap-northeast-2:123456789012:cluster/forged:cluster/course-prod"' "$runtime/baseline.json" >"$runtime/mutated" && mv "$runtime/mutated" "$runtime/baseline.json"
      ;;
    promotion-ecr-double-slash) yq -i '.image.repository="123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/course//sample-app"' "$runtime/promotion.yaml" ;;
    promotion-ecr-name-too-short) set_release_repository "$runtime" '123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/a' ;;
    promotion-attestation-alpha) yq -i '.attestation.githubId="alpha" | .attestation.githubUrl="https://github.com/OWNER/cicd-course-sample-app/attestations/alpha"' "$runtime/promotion.yaml" ;;
    promotion-owner-whitespace) yq -i '.workflow.runUrl="https://github.com/OWNER /cicd-course-sample-app/actions/runs/1001" | .attestation.githubUrl="https://github.com/OWNER /cicd-course-sample-app/attestations/1001"' "$runtime/promotion.yaml" ;;
    promotion-slo-evidence-id-whitespace) yq -i '.slo.evidenceId="   "' "$runtime/promotion.yaml" ;;
    promotion-slo-evidence-id-bom)
      yq -o=json '.' "$runtime/promotion.yaml" | jq '.slo.evidenceId="\uFEFF"' | yq -P >"$runtime/mutated"
      mv "$runtime/mutated" "$runtime/promotion.yaml"
      ;;
    promotion-calendar-invalid) yq -i '.issuedAt="2026-02-31T00:00:00Z"' "$runtime/promotion.yaml" ;;
  esac
  if run_static "$runtime" "$tmp_root/$label-output.json" >/dev/null 2>&1; then
    fail "static runtime adapter accepted $label"
  fi
done

if COURSE_CHECK_BIN_DIR="$fake_bin" FAKE_RUNTIME_DIR="$fake_runtime" AWS_REGION=ap-northeast-2 EKS_CLUSTER_NAME=course-prod \
  bash "$script" --promotion-evidence "$fake_runtime/promotion.yaml" --baseline "$fake_runtime/baseline.json" \
    --output "$canonical" --now 2026-09-03T01:22:00Z >/dev/null 2>&1; then
  fail 'static runtime adapter wrote to the canonical runtime evidence path'
fi

immutable_output="$tmp_root/immutable.json"
run_static "$fake_runtime" "$immutable_output" >/dev/null
immutable_before=$(shasum -a 256 "$immutable_output" | awk '{print $1}')
immutable_runtime="$tmp_root/runtime-immutable-change"
cp -R "$fake_runtime" "$immutable_runtime"
jq '.items[0].metadata.uid="55555555-5555-5555-5555-555555555555"' "$immutable_runtime/analysisruns.json" >"$immutable_runtime/mutated"
mv "$immutable_runtime/mutated" "$immutable_runtime/analysisruns.json"
if run_static "$immutable_runtime" "$immutable_output" >/dev/null 2>&1; then
  fail 'static runtime adapter overwrote an existing different immutable identity'
fi
[[ "$immutable_before" == "$(shasum -a 256 "$immutable_output" | awk '{print $1}')" ]] ||
  fail 'rejected immutable identity changed existing output bytes'

echo '[STATIC] PASS: Prod SLO source contract and non-writing fixture adapter are valid; live cloud capture was not run.'
