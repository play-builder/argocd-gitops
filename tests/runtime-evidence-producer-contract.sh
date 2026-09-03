#!/usr/bin/env bash
set -Eeuo pipefail

test_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repository_root=$(cd -- "$test_root/.." && pwd)
tmp_root=$(mktemp -d)
trap 'rm -rf -- "$tmp_root"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

runtime_repo="$tmp_root/argocd-gitops"
infra_repo="$tmp_root/EKS-infra"
fake_bin="$tmp_root/bin"
fixture_root="$tmp_root/fixtures"
mkdir -p "$runtime_repo/scripts" "$runtime_repo/evidence/prod" "$runtime_repo/evidence/cleanup" \
  "$infra_repo/evidence/cleanup" "$fake_bin" "$fixture_root"
cp "$repository_root/scripts/capture-prod-baseline-evidence.sh" "$runtime_repo/scripts/"
cp "$repository_root/scripts/capture-cleanup-evidence.sh" "$runtime_repo/scripts/"
chmod +x "$runtime_repo/scripts/"*.sh

git -C "$runtime_repo" init -q
git -C "$runtime_repo" config user.name course-test
git -C "$runtime_repo" config user.email course-test@example.invalid
git -C "$runtime_repo" add scripts
git -C "$runtime_repo" commit -qm 'test runtime evidence producer'
git_revision=$(git -C "$runtime_repo" rev-parse HEAD)

cat >"$fixture_root/rollout.json" <<JSON
{"apiVersion":"argoproj.io/v1alpha1","kind":"Rollout","metadata":{"name":"sample-app","namespace":"app-prod","uid":"rollout-uid","annotations":{"rollouts.argoproj.io/revision":"1"}},"spec":{"template":{"spec":{"containers":[{"name":"sample-app","image":"123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/course/sample-app@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}]}}},"status":{"phase":"Healthy","stableRS":"stable-hash","currentPodHash":"stable-hash","replicas":3,"readyReplicas":3,"availableReplicas":3}}
JSON
cat >"$fixture_root/replicasets.json" <<JSON
{"apiVersion":"v1","kind":"List","items":[{"apiVersion":"apps/v1","kind":"ReplicaSet","metadata":{"name":"sample-app-stable","uid":"rs-uid","labels":{"rollouts-pod-template-hash":"stable-hash"},"ownerReferences":[{"apiVersion":"argoproj.io/v1alpha1","kind":"Rollout","name":"sample-app","uid":"rollout-uid","controller":true}]},"spec":{"replicas":3,"template":{"spec":{"containers":[{"name":"sample-app","image":"123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/course/sample-app@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}]}}},"status":{"readyReplicas":3,"availableReplicas":3}}]}
JSON
cat >"$fixture_root/route.json" <<JSON
{"apiVersion":"gateway.networking.k8s.io/v1","kind":"HTTPRoute","metadata":{"name":"sample-app","namespace":"app-prod"},"spec":{"rules":[{"backendRefs":[{"name":"sample-app-stable","weight":100},{"name":"sample-app-canary","weight":0}]}]}}
JSON
cat >"$fixture_root/argocd-app.json" <<JSON
{"metadata":{"name":"sample-app-prod"},"spec":{"source":{"repoURL":"https://github.com/play-builder/argocd-gitops.git","targetRevision":"main"}},"status":{"sync":{"status":"Synced","revision":"$git_revision"},"health":{"status":"Healthy"},"operationState":{"syncResult":{"revision":"$git_revision"}}}}
JSON
cat >"$fixture_root/cluster.json" <<'JSON'
{"cluster":{"arn":"arn:aws:eks:ap-northeast-2:123456789012:cluster/course-prod","name":"course-prod","endpoint":"https://COURSE.gr7.ap-northeast-2.eks.amazonaws.com","status":"ACTIVE"}}
JSON
cat >"$fixture_root/kubeconfig.json" <<'JSON'
{"apiVersion":"v1","kind":"Config","clusters":[{"name":"course-prod","cluster":{"server":"https://COURSE.gr7.ap-northeast-2.eks.amazonaws.com"}}],"contexts":[{"name":"course-prod","context":{"cluster":"course-prod"}}],"current-context":"course-prod"}
JSON

cat >"$fake_bin/kubectl" <<'BASH'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ ${MOCK_SCENARIO:?} == baseline ]]; then
  case " $* " in
    *" get rollout sample-app "*) cat "$MOCK_FIXTURE_ROOT/rollout.json" ;;
    *" get replicasets "*) cat "$MOCK_FIXTURE_ROOT/replicasets.json" ;;
    *" get httproute sample-app "*) cat "$MOCK_FIXTURE_ROOT/route.json" ;;
    *" config view "*) cat "$MOCK_FIXTURE_ROOT/kubeconfig.json" ;;
    *) echo "unexpected kubectl baseline call: $*" >&2; exit 90 ;;
  esac
  exit 0
fi
if [[ " $* " == *" config view "* ]]; then
  context=course-dev; [[ " $* " == *" --context course-prod "* ]] && context=course-prod
  echo "{\"apiVersion\":\"v1\",\"kind\":\"Config\",\"clusters\":[{\"name\":\"$context\",\"cluster\":{\"server\":\"https://$context.example.invalid\"}}],\"contexts\":[{\"name\":\"$context\",\"context\":{\"cluster\":\"$context\"}}],\"current-context\":\"$context\"}"
elif [[ " $* " == *" get namespace "* ]]; then
  environment=dev; [[ " $* " == *" app-prod "* ]] && environment=prod
  echo "{\"apiVersion\":\"v1\",\"kind\":\"Namespace\",\"metadata\":{\"name\":\"app-$environment\",\"uid\":\"namespace-$environment\"}}"
elif [[ " $* " == *" get persistentvolumeclaims "* ]]; then
  if [[ " $* " == *" app-dev "* ]]; then
    echo '{"apiVersion":"v1","kind":"List","items":[{"apiVersion":"v1","kind":"PersistentVolumeClaim","metadata":{"name":"data","namespace":"app-dev","uid":"pvc-uid-1"}}]}'
  else
    echo '{"apiVersion":"v1","kind":"List","items":[]}'
  fi
elif [[ " $* " == *" get rollouts.argoproj.io,deployments.apps,statefulsets.apps,jobs.batch,externalsecrets.external-secrets.io,podchaos.chaos-mesh.org,networkchaos.chaos-mesh.org "* ]]; then
  if [[ ${MOCK_ACTIVE_WRITER:-false} == true && " $* " == *" app-dev "* ]]; then
    echo '{"apiVersion":"v1","kind":"List","items":[{"apiVersion":"batch/v1","kind":"Job","metadata":{"name":"load-generator","namespace":"app-dev"}}]}'
  else
    echo '{"apiVersion":"v1","kind":"List","items":[]}'
  fi
else
  echo "unexpected kubectl removal call: $*" >&2
  exit 91
fi
BASH

cat >"$fake_bin/argocd" <<'BASH'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ ${MOCK_SCENARIO:?} == baseline ]]; then
  [[ " $* " == " app get sample-app-prod -o json " ]] || { echo "unexpected argocd call: $*" >&2; exit 92; }
  cat "$MOCK_FIXTURE_ROOT/argocd-app.json"
else
  [[ " $* " == " app list -o json " ]] || { echo "unexpected argocd call: $*" >&2; exit 93; }
  echo '[]'
fi
BASH

cat >"$fake_bin/aws" <<'BASH'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ " $* " == *" eks describe-cluster "* ]]; then
  if [[ ${MOCK_SCENARIO:?} == baseline ]]; then
    cat "$MOCK_FIXTURE_ROOT/cluster.json"
  else
    cluster=course-dev; [[ " $* " == *" --name course-prod "* ]] && cluster=course-prod
    echo "{\"cluster\":{\"arn\":\"arn:aws:eks:ap-northeast-2:123456789012:cluster/$cluster\",\"name\":\"$cluster\",\"endpoint\":\"https://$cluster.example.invalid\",\"status\":\"ACTIVE\"}}"
  fi
elif [[ " $* " == *" secretsmanager describe-secret "* ]]; then
  [[ ${MOCK_PROVIDER_MISSING:-false} != true ]] || exit 254
  echo '{"ARN":"arn:aws:secretsmanager:ap-northeast-2:123456789012:secret:shared-provider"}'
else
  echo "unexpected aws call: $*" >&2
  exit 94
fi
BASH
chmod +x "$fake_bin/kubectl" "$fake_bin/argocd" "$fake_bin/aws"

PATH="$fake_bin:$PATH" MOCK_SCENARIO=baseline MOCK_FIXTURE_ROOT="$fixture_root" \
  AWS_REGION=ap-northeast-2 EKS_CLUSTER_NAME=course-prod \
  bash "$runtime_repo/scripts/capture-prod-baseline-evidence.sh"
baseline="$runtime_repo/evidence/prod/baseline.json"
[[ -f "$baseline" ]] || fail 'runtime baseline producer did not write the canonical path'
jq -e --arg revision "$git_revision" '
  (keys | sort) == ["clusterArn","evidenceGrade","gitopsRevision","image","observedAt","region","rollout","schemaVersion"] and
  .schemaVersion == "course.prod-baseline/v1" and .evidenceGrade == "CLOUD_RUNTIME" and
  .gitopsRevision == $revision and .region == "ap-northeast-2" and
  .clusterArn == "arn:aws:eks:ap-northeast-2:123456789012:cluster/course-prod" and
  .image.repository == "123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/course/sample-app" and
  .image.indexDigest == "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" and
  .rollout == {stableHash:"stable-hash",revision:1,trafficWeight:100} and
  (.observedAt | fromdateiso8601) <= now
' "$baseline" >/dev/null || fail 'runtime baseline has the wrong exact schema or identity'

jq '.spec.rules[0].backendRefs[0].weight=50 | .spec.rules[0].backendRefs[1].weight=50' \
  "$fixture_root/route.json" >"$fixture_root/route-invalid.json"
mv "$fixture_root/route-invalid.json" "$fixture_root/route.json"
rm -f -- "$baseline"
if PATH="$fake_bin:$PATH" MOCK_SCENARIO=baseline MOCK_FIXTURE_ROOT="$fixture_root" \
  AWS_REGION=ap-northeast-2 EKS_CLUSTER_NAME=course-prod \
  bash "$runtime_repo/scripts/capture-prod-baseline-evidence.sh" >/dev/null 2>&1; then
  fail 'baseline producer accepted a 50/50 live HTTPRoute'
fi
[[ ! -e "$baseline" ]] || fail 'failed baseline capture left a canonical runtime artifact'

cat >"$runtime_repo/evidence/cleanup/freeze.json" <<JSON
{"schemaVersion":"course.gitops-freeze/v1","evidenceGrade":"CLOUD_RUNTIME","status":"FROZEN","gitopsRevision":"$git_revision","clusters":[{"environment":"dev","clusterArn":"arn:aws:eks:ap-northeast-2:123456789012:cluster/course-dev","application":{"name":"sample-app-dev","sync":"Synced","health":"Healthy","automated":false}},{"environment":"prod","clusterArn":"arn:aws:eks:ap-northeast-2:123456789012:cluster/course-prod","application":{"name":"sample-app-prod","sync":"Synced","health":"Healthy","automated":false}}],"writers":{"loadGenerators":0,"chaosResources":0,"recoveryJobs":0,"migrationJobs":0},"observedAt":"2026-01-01T00:00:00Z"}
JSON
cat >"$infra_repo/evidence/cleanup/ownership-inventory.json" <<'JSON'
{
  "schemaVersion":"course.cleanup-ownership/v1","evidenceGrade":"CLOUD_RUNTIME","courseId":"course-2026","accountId":"123456789012","region":"ap-northeast-2",
  "resources":[
    {"kind":"PersistentVolumeClaim","id":"k8s://course-dev/app-dev/PersistentVolumeClaim/data/pvc-uid-1","environment":"dev","classification":"source-pvc","owner":"course","managedBy":"terraform","billable":true,"decision":"RETAIN","reason":"stateful recovery checkpoint","followUpAction":"delete after evidence export"},
    {"kind":"SecretsManagerSecret","id":"arn:aws:secretsmanager:ap-northeast-2:123456789012:secret:shared-provider","environment":"shared","classification":"provider-secret","owner":"external","managedBy":"terraform","billable":false,"decision":"EXTERNAL_SHARED","reason":"shared provider secret","followUpAction":"retain and review separately"}
  ],
  "observedAt":"2026-01-01T00:00:00Z"
}
JSON

PATH="$fake_bin:$PATH" MOCK_SCENARIO=removal MOCK_FIXTURE_ROOT="$fixture_root" \
  AWS_REGION=ap-northeast-2 \
  bash "$runtime_repo/scripts/capture-cleanup-evidence.sh" removal --eks-repo-root "$infra_repo" \
    --dev-context course-dev --prod-context course-prod
removal="$runtime_repo/evidence/cleanup/removal.json"
[[ -f "$removal" ]] || fail 'runtime removal producer did not write the canonical path'
freeze_sha=$(shasum -a 256 "$runtime_repo/evidence/cleanup/freeze.json" | awk '{print $1}')
provider_sha=$(jq -cS '[.resources[] | select(.kind == "SecretsManagerSecret")] | sort_by(.environment,.id)' \
  "$infra_repo/evidence/cleanup/ownership-inventory.json" | shasum -a 256 | awk '{print $1}')
jq -e --arg revision "$git_revision" --arg freeze "$freeze_sha" --arg provider "$provider_sha" '
  (keys | sort) == ["clusters","evidenceGrade","freezeEvidenceSha256","gitopsRevision","observedAt","providerSecrets","remaining","retained","schemaVersion","status"] and
  .schemaVersion == "course.gitops-removal/v1" and .evidenceGrade == "CLOUD_RUNTIME" and .status == "REMOVED" and
  .gitopsRevision == $revision and .freezeEvidenceSha256 == $freeze and
  .clusters == [{environment:"dev",clusterArn:"arn:aws:eks:ap-northeast-2:123456789012:cluster/course-dev"},{environment:"prod",clusterArn:"arn:aws:eks:ap-northeast-2:123456789012:cluster/course-prod"}] and
  .remaining == {rollouts:0,deployments:0,statefulSets:0,jobs:0,externalSecrets:0,chaosResources:0} and
  .retained == [{environment:"dev",namespace:"app-dev",kind:"PersistentVolumeClaim",name:"data",uid:"pvc-uid-1",classification:"source-pvc",requiresExplicitDeletion:true}] and
  .providerSecrets == {retained:true,inventorySha256:$provider} and
  (.observedAt | fromdateiso8601) > ("2026-01-01T00:00:00Z" | fromdateiso8601)
' "$removal" >/dev/null || fail 'runtime removal has the wrong exact schema, digest projection, or retained identity'

rm -f -- "$removal"
if PATH="$fake_bin:$PATH" MOCK_SCENARIO=removal MOCK_FIXTURE_ROOT="$fixture_root" MOCK_ACTIVE_WRITER=true \
  AWS_REGION=ap-northeast-2 \
  bash "$runtime_repo/scripts/capture-cleanup-evidence.sh" removal --eks-repo-root "$infra_repo" \
    --dev-context course-dev --prod-context course-prod >/dev/null 2>&1; then
  fail 'removal producer accepted an active writer'
fi
[[ ! -e "$removal" ]] || fail 'failed writer scan left a canonical removal artifact'

if PATH="$fake_bin:$PATH" MOCK_SCENARIO=removal MOCK_FIXTURE_ROOT="$fixture_root" MOCK_PROVIDER_MISSING=true \
  AWS_REGION=ap-northeast-2 \
  bash "$runtime_repo/scripts/capture-cleanup-evidence.sh" removal --eks-repo-root "$infra_repo" \
    --dev-context course-dev --prod-context course-prod >/dev/null 2>&1; then
  fail 'removal producer accepted an unobservable provider Secret'
fi
[[ ! -e "$removal" ]] || fail 'failed provider Secret scan left a canonical removal artifact'

echo 'PASS: baseline and GitOps removal runtime producers are fail-closed and provenance-bound.'
