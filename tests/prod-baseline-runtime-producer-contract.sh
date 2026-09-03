#!/usr/bin/env bash
set -Eeuo pipefail

test_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
repository_root=$(cd -- "$test_root/.." && pwd -P)
fixture_root="$test_root/fixtures/evidence"
script="$repository_root/scripts/capture-prod-baseline-evidence.sh"
canonical="$repository_root/evidence/prod/baseline.json"
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
fixture_log=$(bash "$script" --fixture "$fixture_root/baseline-valid.json")
grep -Fq '[STATIC]' <<<"$fixture_log" || fail 'baseline fixture validator was not labelled STATIC'
[[ "$before" == "$(fingerprint)" ]] || fail 'baseline fixture validator changed canonical runtime evidence'

for label in ecr-double-slash ecr-invalid-segment ecr-trailing-space ecr-name-too-short ecr-name-too-long ecr-region-mismatch ecr-account-mismatch; do
  invalid_fixture="$tmp_root/fixture-$label.json"
  case "$label" in
    ecr-double-slash)
      jq '.image.repository="123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/course//sample-app"' "$fixture_root/baseline-valid.json" >"$invalid_fixture" ;;
    ecr-invalid-segment)
      jq '.image.repository="123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/course/-sample-app"' "$fixture_root/baseline-valid.json" >"$invalid_fixture" ;;
    ecr-trailing-space)
      jq '.image.repository="123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/course/sample-app "' "$fixture_root/baseline-valid.json" >"$invalid_fixture" ;;
    ecr-name-too-short)
      jq '.image.repository="123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/a"' "$fixture_root/baseline-valid.json" >"$invalid_fixture" ;;
    ecr-name-too-long)
      jq '.image.repository="123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/" + ("a" * 257)' "$fixture_root/baseline-valid.json" >"$invalid_fixture" ;;
    ecr-region-mismatch)
      jq '.image.repository="123456789012.dkr.ecr.us-east-1.amazonaws.com/course/sample-app"' "$fixture_root/baseline-valid.json" >"$invalid_fixture" ;;
    ecr-account-mismatch)
      jq '.image.repository="999999999999.dkr.ecr.ap-northeast-2.amazonaws.com/course/sample-app"' "$fixture_root/baseline-valid.json" >"$invalid_fixture" ;;
  esac
  if bash "$script" --fixture "$invalid_fixture" >/dev/null 2>&1; then
    fail "baseline fixture validator accepted $label"
  fi
done
two_character_fixture="$tmp_root/fixture-ecr-two-character.json"
jq '.image.repository="123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/ab"' \
  "$fixture_root/baseline-valid.json" >"$two_character_fixture"
bash "$script" --fixture "$two_character_fixture" >/dev/null ||
  fail 'baseline fixture validator rejected a two-character ECR repository name'

for option in --output --now; do
  if AWS_REGION=ap-northeast-2 EKS_CLUSTER_NAME=course-prod \
    bash "$script" "$option" "$tmp_root/override" >/dev/null 2>&1; then
    fail "live baseline producer accepted runtime path or clock override: $option"
  fi
done

fake_bin="$tmp_root/bin"
runtime="$tmp_root/runtime"
mkdir -p "$fake_bin" "$runtime"
for command in argocd aws git kubectl; do
  ln -s "$test_root/helpers/fake-prod-slo-cli.sh" "$fake_bin/$command"
done
printf '%s\n' 1111111111111111111111111111111111111111 >"$runtime/git-revision.txt"
: >"$runtime/git-status.txt"
jq -n '{metadata:{name:"sample-app-prod"},spec:{source:{repoURL:"https://github.com/OWNER/argocd-gitops.git"}},status:{sync:{status:"Synced",revision:"1111111111111111111111111111111111111111"},health:{status:"Healthy"}}}' >"$runtime/application.json"
jq -n '{cluster:{name:"course-prod",arn:"arn:aws:eks:ap-northeast-2:123456789012:cluster/course-prod",status:"ACTIVE",endpoint:"https://prod.eks.example"}}' >"$runtime/cluster.json"
jq -n '{clusters:[{cluster:{server:"https://prod.eks.example"}}]}' >"$runtime/kubeconfig.json"
jq -n --arg image '123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/course/sample-app@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' '
  {metadata:{name:"sample-app",namespace:"app-prod",uid:"22222222-2222-2222-2222-222222222222"},
   spec:{template:{spec:{containers:[{name:"sample-app",image:$image}]}}},
   status:{phase:"Healthy",stableRS:"stable-v1",currentPodHash:"stable-v1",replicas:3,readyReplicas:3,availableReplicas:3,pauseConditions:[]}}
' >"$runtime/rollout.json"
jq -n --arg image '123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/course/sample-app@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' '
  {items:[{metadata:{name:"sample-app-stable-v1",labels:{"rollouts-pod-template-hash":"stable-v1"},annotations:{"rollout.argoproj.io/revision":"1"},ownerReferences:[{apiVersion:"argoproj.io/v1alpha1",kind:"Rollout",name:"sample-app",uid:"22222222-2222-2222-2222-222222222222",controller:true}]},
   spec:{replicas:3,template:{spec:{containers:[{name:"sample-app",image:$image}]}}},status:{readyReplicas:3,availableReplicas:3}}]}
' >"$runtime/replicasets.json"
jq -n '{metadata:{name:"sample-app",namespace:"app-prod"},spec:{rules:[{backendRefs:[{name:"sample-app-stable",port:80,weight:100},{name:"sample-app-canary",port:80,weight:0}]}]}}' >"$runtime/httproute.json"

run_static() {
  local source=$1 output=$2
  COURSE_CHECK_BIN_DIR="$fake_bin" FAKE_RUNTIME_DIR="$source" AWS_REGION=ap-northeast-2 EKS_CLUSTER_NAME=course-prod \
    bash "$script" --output "$output" --now 2026-09-03T00:30:00Z
}

set_runtime_repository() {
  local source=$1 repository=$2
  local digest='sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
  jq --arg image "$repository@$digest" '.spec.template.spec.containers[0].image=$image' \
    "$source/rollout.json" >"$source/mutated"
  mv "$source/mutated" "$source/rollout.json"
  jq --arg image "$repository@$digest" '.items[0].spec.template.spec.containers[0].image=$image' \
    "$source/replicasets.json" >"$source/mutated"
  mv "$source/mutated" "$source/replicasets.json"
}

static_output="$tmp_root/baseline.json"
static_log=$(run_static "$runtime" "$static_output") || fail 'valid static baseline runtime was rejected'
grep -Fq '[STATIC]' <<<"$static_log" || fail 'fake baseline runtime was not labelled STATIC'
jq -e '.evidenceGrade=="STATIC" and .rollout=={stableHash:"stable-v1",revision:1,trafficWeight:100} and .observedAt=="2026-09-03T00:30:00Z"' \
  "$static_output" >/dev/null || fail 'fake baseline runtime output is not canonical STATIC evidence'
[[ "$before" == "$(fingerprint)" ]] || fail 'fake baseline runtime changed canonical evidence'

two_character_runtime="$tmp_root/runtime-ecr-two-character"
cp -R "$runtime" "$two_character_runtime"
set_runtime_repository "$two_character_runtime" '123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/ab'
run_static "$two_character_runtime" "$tmp_root/ecr-two-character.json" >/dev/null ||
  fail 'static baseline runtime rejected a two-character ECR repository name'

for label in duplicate-replicaset wrong-owner wrong-owner-name wrong-revision nonfinal-route extra-route-backend extra-route-rule image-account image-region image-double-slash image-invalid-segment image-trailing-space image-name-too-short image-name-too-long context-drift git-mismatch dirty-source argo-repository malformed-cluster-arn; do
  candidate="$tmp_root/runtime-$label"
  cp -R "$runtime" "$candidate"
  case "$label" in
    duplicate-replicaset) jq '.items += [.items[0] | .metadata.uid="duplicate"]' "$candidate/replicasets.json" >"$candidate/mutated" && mv "$candidate/mutated" "$candidate/replicasets.json" ;;
    wrong-owner) jq '.items[0].metadata.ownerReferences[0].uid="foreign"' "$candidate/replicasets.json" >"$candidate/mutated" && mv "$candidate/mutated" "$candidate/replicasets.json" ;;
    wrong-owner-name) jq '.items[0].metadata.ownerReferences[0].name="other-rollout"' "$candidate/replicasets.json" >"$candidate/mutated" && mv "$candidate/mutated" "$candidate/replicasets.json" ;;
    wrong-revision) jq '.items[0].metadata.annotations["rollout.argoproj.io/revision"]="2"' "$candidate/replicasets.json" >"$candidate/mutated" && mv "$candidate/mutated" "$candidate/replicasets.json" ;;
    nonfinal-route) jq '.spec.rules[0].backendRefs[0].weight=50 | .spec.rules[0].backendRefs[1].weight=50' "$candidate/httproute.json" >"$candidate/mutated" && mv "$candidate/mutated" "$candidate/httproute.json" ;;
    extra-route-backend) jq '.spec.rules[0].backendRefs += [{name:"shadow",port:80,weight:0}]' "$candidate/httproute.json" >"$candidate/mutated" && mv "$candidate/mutated" "$candidate/httproute.json" ;;
    extra-route-rule) jq '.spec.rules += [.spec.rules[0]]' "$candidate/httproute.json" >"$candidate/mutated" && mv "$candidate/mutated" "$candidate/httproute.json" ;;
    image-account) set_runtime_repository "$candidate" '999999999999.dkr.ecr.ap-northeast-2.amazonaws.com/course/sample-app' ;;
    image-region) set_runtime_repository "$candidate" '123456789012.dkr.ecr.us-east-1.amazonaws.com/course/sample-app' ;;
    image-double-slash) set_runtime_repository "$candidate" '123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/course//sample-app' ;;
    image-invalid-segment) set_runtime_repository "$candidate" '123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/course/-sample-app' ;;
    image-trailing-space) set_runtime_repository "$candidate" '123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/course/sample-app ' ;;
    image-name-too-short) set_runtime_repository "$candidate" '123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/a' ;;
    image-name-too-long) set_runtime_repository "$candidate" "123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/$(printf 'a%.0s' {1..257})" ;;
    context-drift) jq '.clusters[0].cluster.server="https://foreign.eks.example"' "$candidate/kubeconfig.json" >"$candidate/mutated" && mv "$candidate/mutated" "$candidate/kubeconfig.json" ;;
    git-mismatch) printf '%s\n' aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa >"$candidate/git-revision.txt" ;;
    dirty-source) printf '%s\n' ' M envs/prod/values.yaml' >"$candidate/git-status.txt" ;;
    argo-repository) jq '.spec.source.repoURL="https://github.com/OWNER/other-repo.git"' "$candidate/application.json" >"$candidate/mutated" && mv "$candidate/mutated" "$candidate/application.json" ;;
    malformed-cluster-arn) jq '.cluster.arn="arn:aws:eks:ap-northeast-2:123456789012:cluster/forged:cluster/course-prod"' "$candidate/cluster.json" >"$candidate/mutated" && mv "$candidate/mutated" "$candidate/cluster.json" ;;
  esac
  if run_static "$candidate" "$tmp_root/$label.json" >/dev/null 2>&1; then
    fail "static baseline runtime accepted $label"
  fi
done

if COURSE_CHECK_BIN_DIR="$fake_bin" FAKE_RUNTIME_DIR="$runtime" AWS_REGION=ap-northeast-2 EKS_CLUSTER_NAME=course-prod \
  bash "$script" --output "$canonical" --now 2026-09-03T00:30:00Z >/dev/null 2>&1; then
  fail 'static baseline runtime wrote to the canonical CLOUD_RUNTIME path'
fi

immutable_before=$(shasum -a 256 "$static_output" | awk '{print $1}')
changed="$tmp_root/runtime-changed"
cp -R "$runtime" "$changed"
jq '.spec.template.spec.containers[0].image |= sub("b{64}$";"c" * 64)' "$changed/rollout.json" >"$changed/mutated"
mv "$changed/mutated" "$changed/rollout.json"
jq '.items[0].spec.template.spec.containers[0].image |= sub("b{64}$";"c" * 64)' "$changed/replicasets.json" >"$changed/mutated"
mv "$changed/mutated" "$changed/replicasets.json"
if run_static "$changed" "$static_output" >/dev/null 2>&1; then
  fail 'baseline runtime overwrote a different immutable baseline identity'
fi
[[ "$immutable_before" == "$(shasum -a 256 "$static_output" | awk '{print $1}')" ]] ||
  fail 'rejected baseline identity changed existing output bytes'

echo '[STATIC] PASS: Prod baseline runtime producer and non-writing fixture adapter are valid; live cloud capture was not run.'
