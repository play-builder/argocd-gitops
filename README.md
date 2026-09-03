# Argo CD GitOps — dev/prod 배포 상태 저장소

이 저장소는 애플리케이션 소스가 아니라 EKS에 배포할 **원하는 상태(desired state)** 를
보관합니다. dev와 prod는 같은 Helm chart를 사용하지만, dev는 `Deployment`, prod는
`Rollout`으로 렌더링됩니다. 이미지 tag는 허용하지 않고 multi-architecture image index
digest만 사용합니다.

## 핵심 구조

```text
charts/sample-app/              공통 Helm chart
├── templates/workload.yaml     Deployment 또는 Rollout
├── templates/gateway.yaml      AWS LBC Gateway API + HTTPRoute
├── templates/analysistemplate.yaml
├── templates/database-statefulset.yaml
└── templates/migration-job.yaml

envs/dev/values.yaml            자동 배포, RollingUpdate
envs/prod/values.yaml           승인된 PR, Canary + AMP 분석
envs/*/stateful-values.yaml      Ch14 이후에만 true로 바꾸는 DB opt-in switch
envs/dev/phase-default-values.yaml  기본 lifecycle phase(모두 비활성)
envs/dev/snapshot-maintenance-values.yaml  Ch23 A1→A2에서만 선택·편집

argocd/bootstrap/dev/           dev 클러스터만 읽는 root 구성
argocd/bootstrap/prod/          prod 클러스터만 읽는 root 구성
```

이 그림에서 봐야 할 핵심은 **클러스터마다 자기 bootstrap 경로만 읽는다**는 점입니다.
dev Argo CD가 실수로 prod values를 배포하거나, prod Argo CD가 dev 자동화 정책을 상속하지
않도록 경계를 나눴습니다.

## Helm과 Kustomize의 적용 경계

현재 애플리케이션과 외부 패키지는 Argo CD의 Helm source로 직접 렌더링하고,
환경별 차이는 `valueFiles` 또는 `valuesObject`로 관리합니다. Kustomize는 Helm 렌더링
결과를 후처리하지 않으며, bootstrap의 `ApplicationSet`, `AppProject`, namespace label,
admission policy처럼 GitOps 제어 계층의 객체를 조합하고 패치하는 데 사용합니다.

외부 Chart가 제공하는 values만으로 필수 보안·운영 설정을 표현할 수 없는 경우에는 해당
Chart 하나에 한해 `helmCharts` 기반 Kustomize 렌더링 또는 격리된 Config Management
Plugin을 검토합니다. 단순 label 추가처럼 values로 해결 가능한 요구에는 이 방식을
도입하지 않습니다.

예외 방식을 도입할 때는 다음 조건을 모두 만족해야 합니다.

- upstream values로 필요한 필드를 설정할 수 없고, 그 필드가 필수 보안·운영 계약이다.
- Chart 버전과 repository를 고정하고 CI에서 Helm 및 Kustomize 최종 산출물을 검증한다.
- patch 대상이 사라지거나 이름이 바뀌면 upgrade 검증이 즉시 실패한다.
- 영향 범위를 해당 Application으로 제한한다. 전역 `--enable-helm`은 모든 Kustomize
  Application에 영향을 주므로 별도 위험 검토 없이 활성화하지 않는다.

현재 외부 Chart인 External Secrets는 `valuesObject`로 필요한 설정을 충족하므로 예외
연동을 사용하지 않습니다. 향후 Chart values에 없는 필수 설정이 생기면 첫 적용 후보로
검토하되, 그전까지는 미완성 Kustomization이나 사용되지 않는 CMP 구성을 저장소에
남기지 않습니다.

## 처음 한 번 바꿀 값

다음 placeholder는 계정과 저장소가 만들어진 뒤 실제 값으로 교체합니다. `REPLACE_ME_REGION`은
과정에서 검증한 `ap-northeast-2` 또는 `us-east-1` 중 EKS를 만든 Region과 같아야 합니다.

- `REPLACE_ME_ACCOUNT_ID`: AWS 계정 ID
- `REPLACE_ME_REGION`: `ap-northeast-2` 또는 `us-east-1`
- `REPLACE_ME_PROJECT`: Terraform의 `project_name`
- `example.com`: Route53 도메인
- `ws-REPLACE_ME`: 각 클러스터의 AMP workspace ID
- `REPLACE_ME`: GitHub owner/team과 GitOps repository URL
- `sha256:000...000`: CI가 처음 빌드한 multi-arch index digest

검색 명령:

```bash
rg -n 'REPLACE_ME|example\.com|sha256:0{64}' .
```

## 로컬 검증

```bash
helm lint charts/sample-app -f envs/dev/values.yaml
helm lint charts/sample-app -f envs/prod/values.yaml

helm template sample-app charts/sample-app -f envs/dev/values.yaml > /tmp/dev.yaml
helm template sample-app charts/sample-app -f envs/prod/values.yaml > /tmp/prod.yaml

kubectl kustomize argocd/bootstrap/dev > /tmp/bootstrap-dev.yaml
kubectl kustomize argocd/bootstrap/prod > /tmp/bootstrap-prod.yaml
```

정상 결과는 dev 렌더에 `Deployment`만, prod 렌더에 `Rollout`과 native `sigv4`가
나오는 것입니다.

Stateful 렌더 계약은 별도 테스트로 확인합니다.

```bash
bash tests/stateful-contract.sh
```

## Ch14 이후 Stateful Mini Commerce 활성화

두 `stateful-values.yaml`은 ApplicationSet에 연결되어 있지만 초기값은 `false`입니다. 따라서 기존
Ch01~Ch14는 PostgreSQL, PVC, migration Job 없이 Stateless로 진행됩니다. Stateful 보충 실습의
Dev PR에서만 다음 값을 바꿉니다.

```yaml
database:
  enabled: true
```

활성화 후 Argo CD는 다음 순서로 동기화합니다.

```text
wave -3  ExternalSecret
wave -2  PostgreSQL Service + StatefulSet + course-gp3 PVC
wave -1  node-pg-migrate Sync hook Job
wave  0  Mini Commerce Deployment 또는 Rollout
```

PostgreSQL은 실습 비용과 schema migration 관찰을 위한 단일 replica 구성입니다. Multi-AZ,
backup/PITR, failover를 제공하는 운영 DB 설계가 아니며 RDS/Aurora의 대체안으로 사용하지 않습니다.

Application과 migration Job은 같은 ECR image를 사용할 수 있지만 desired state에는 digest를
별도로 저장합니다. 정상 전진 배포와 Dev→Prod 승격은 두 digest를 함께 변경하고, schema migration
후 긴급 Fix-Backward는 application digest만 되돌립니다. 이미 적용된 backward-compatible schema는
내리지 않습니다.

StatefulSet을 삭제해도 `volumeClaimTemplates`가 만든 PVC가 자동으로 정리된다고 가정하지 않습니다.
최종 정리에서는 대상 namespace와 label을 확인한 뒤 PVC를 명시적으로 삭제하고 PV와 EBS volume
삭제 완료까지 확인해야 합니다.

## Ch23 snapshot quiesce A1/A2/A3

Dev ApplicationSet은 기본적으로 `phaseValuesFile=envs/dev/phase-default-values.yaml` 하나만
선택합니다. 이 safe-default 파일은 recovery와 Chaos를 모두 비활성화하므로 Ch01~Ch14의 기본
render가 PostgreSQL, recovery object, Chaos object를 만들지 않습니다. Stateful, Chaos, snapshot,
recovery lifecycle은 각각 검토한 Git commit에서만 phase selector를 해당 파일로 바꿉니다.

A1에서는 `argocd/bootstrap/dev/sample-app.yaml`의 `phaseValuesFile`을
`envs/dev/snapshot-maintenance-values.yaml`로 바꿔 commit하고 Sync합니다. 이 파일은 application
replica와 HPA, migration Job을 모두 끄되 PostgreSQL은 `replicaCount: 1`로 유지합니다. 다음 producer는
clean `HEAD == Argo desired revision`, 현재 EKS/context, DB Pod→PVC UID→PV→VolumeAttachment identity를
fresh query하고, DB 안에서 FK·idempotency·inventory invariant와 정렬된 네 테이블 row set을 조회합니다.
raw row set은 저장하지 않고 canonical JSON의 SHA-256만 `0600` A1 handoff에 기록합니다.

```bash
AWS_REGION="$AWS_REGION" EKS_CLUSTER_NAME="$DEV_CLUSTER_NAME" \
  bash scripts/capture-snapshot-evidence.sh prepare
```

A2 commit은 같은 `envs/dev/snapshot-maintenance-values.yaml`의 `database.replicaCount`만 `1`에서
`0`으로 바꿉니다. 다른 파일을 함께 변경하면 producer가 `git diff A1..HEAD`에서 차단합니다. 원격에
commit이 반영된 직후, Argo Auto-Sync가 StatefulSet을 내리는 동안 다음 명령을 시작합니다. producer는
A1 Pod UID에 log watcher를 먼저 결속하고 PostgreSQL의 `received fast shutdown request` 다음
`database system is shut down`을 순서대로 관찰합니다. 이 chart는 별도 `preStop` signal을 보내지 않고
PostgreSQL official image의 `STOPSIGNAL SIGINT`를 사용하며 DB 전용 grace를 120초로 둡니다. Kubernetes는
image `STOPSIGNAL`을 존중할 수 있고, official PostgreSQL image는 SIGINT를 clean Fast Shutdown으로
정의합니다([Kubernetes Pod termination](https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/#termination-of-pods),
[docker-library/postgres Dockerfile](https://github.com/docker-library/postgres/blob/master/Dockerfile-debian.template)).
따라서 evidence도 실제 신호인 `SIGINT`를 기록하며 shutdown log 원문 대신 exact bytes
SHA-256만 보존합니다.

```bash
AWS_REGION="$AWS_REGION" EKS_CLUSTER_NAME="$DEV_CLUSTER_NAME" \
  bash scripts/capture-snapshot-evidence.sh capture
```

Capture는 StatefulSet desired/ready 0, application/migration writer 0, PVC UID/PV 불변, PVC mount Pod 0,
해당 PV의 `VolumeAttachment` 0, 기존 `VolumeSnapshot` 0을 확인한 뒤
`evidence/recovery/snapshot-quiesce.json`을 원자적 `0600`으로 기록합니다. 기록 직전에 동일 항목을
즉시 다시 조회합니다. watcher를 놓쳤거나 clean shutdown line이 없으면 증거를 합성하지 않고 실패하므로
A1 상태로 되돌려 새 두 commit을 수행해야 합니다. `kubectl scale`이나 force delete로 Git desired state를
우회하지 않습니다.

A3에서만 같은 phase file의 `snapshot.captureEnabled`를 `true`로 바꾸는 별도 commit을 Sync합니다.
그 전에 canonical evidence와 live state를 다시 확인할 수 있습니다.

```bash
AWS_REGION="$AWS_REGION" EKS_CLUSTER_NAME="$DEV_CLUSTER_NAME" \
  bash scripts/capture-snapshot-evidence.sh preflight
```

Fixture 검증과 fake CLI 테스트는 `[STATIC]`이고 canonical runtime 파일을 만들지 않습니다. 이 절차는
application-consistent volume snapshot gate이며 PostgreSQL PITR/managed backup을 대신하지 않습니다.

## 운영 계약

- dev: application code PR merge → build/push → dev digest PR → validate → auto-merge → Argo CD auto-sync
- prod: dev에서 검증한 **동일 digest** → prod promotion PR → CODEOWNERS 승인/merge → 운영자 Argo CD Sync → Rollouts Canary
- HPA 활성화 시 workload의 `spec.replicas`를 렌더하지 않습니다.
- 카나리 중 `HTTPRoute.spec.rules`는 Rollouts plugin이 변경합니다. 해당 라벨이 있는 동안만 Argo CD가 차이를 무시합니다.
- AMP 조회는 Rollouts native SigV4를 사용합니다. `aws-sigv4-proxy`는 설치하지 않습니다.
- 분석은 Rollouts의 `podTemplateHashValue: Latest`를 받아 최신 ReplicaSet 지표만 조회합니다.
- 카나리 request rate가 `minimumRequestRate`보다 작으면 성공률이 높더라도 승격하지 않습니다.
- Prod 단계의 무기한 `pause: {}`는 `setWeight: 100` 앞에 있으므로 사람이 승인하기 전에 전체
  traffic이 새 version으로 전환되지 않습니다.

## GitHub 보호 규칙

`.github/CODEOWNERS`와 `docs/github-ruleset.example.json`을 실제 owner/team으로 바꾼 뒤 main
branch에 적용합니다. dev digest PR은 validation 성공 뒤 자동 merge할 수 있지만 prod 경로는
CODEOWNERS 승인을 요구합니다. GitHub App push가 validation을 한 번 실행하는 것은 정상이며,
`envs/dev/**`를 `paths-ignore`하거나 `[skip ci]`로 검증을 건너뛰지 않습니다.

실제 클러스터 검증 전에는 이 저장소를 배포 완료로 간주하지 않습니다. `Gateway`의
`Programmed=True`, `ExternalSecret Ready=True`, `AnalysisRun Successful`을 각각 확인해야 합니다.

## Prod 승격과 SLO 증거

Dev에서 생성되는 `evidence/dev/deployment.json`과 `evidence/dev/slo.json`은
`CLOUD_RUNTIME` 등급의 만료 가능한 입력입니다. 두 파일의 source, image, GitOps revision,
cluster ARN, Region이 일치해야 CI가 `course.dev-ready/v1` 승격 증거를 수락합니다.
Prod 초기화는 승인된 PR을 수동 Sync한 뒤 stable revision `1`/traffic `100`을 확인하여
`scripts/capture-prod-baseline-evidence.sh`로 `evidence/prod/baseline.json`을 만드는 별도 단계입니다.
이 producer는 Argo CD revision, Rollout/ReplicaSet 소유권·readiness, HTTPRoute 100/0 weight,
현재 kube-context와 EKS endpoint, ECR digest의 account/Region을 모두 교차 확인하고 원자적으로
기록합니다. 이후 후보 digest가 baseline과 다르고
동일한 Canary/AnalysisTemplate을 유지할 때만 promotion PR을 진행합니다. Prod ApplicationSet은
자동 Sync를 사용하지 않으며, 최종 `setWeight: 100` 직전에는 무기한 `pause: {}`가 있습니다.

승격은 DEV_READY evidence 게시 PR과 Prod values 후보 PR을 분리합니다. 후보 PR에서
`envs/prod/values.yaml`의 application 또는 migration image repository·digest가 바뀌면
`scripts/verify-prod-promotion-binding.sh`가 네 image identity를 현재 canonical evidence와
비교합니다. image identity가 그대로인 bootstrap·운영 설정 변경에는 DEV_READY를 요구하지 않습니다. main Ruleset은
strict required status check를 사용하므로 새로운 evidence가 먼저 merge되면 기존 후보는 base를
갱신하고 이 검증을 다시 통과해야 합니다. PR merge만으로 배포되지는 않으며, 승인된 운영자가
Prod Application을 Sync한 시점에 Canary가 시작됩니다.

### Contract 003 rollback candidate handoff

Stateful Prod에서 `003_contract_product_name.js`를 적용하는 promotion은 merge된 desired
revision과 아직 Sync하지 않은 live rollback window를 함께 묶어야 합니다. Promotion PR을
merge한 뒤 전체 Sync를 시작하기 전에 checkout을 그 merge commit에 맞추고 다음 producer를
한 번 실행합니다.

```bash
AWS_REGION="$AWS_REGION" EKS_CLUSTER_NAME="$PROD_CLUSTER_NAME" \
  bash scripts/capture-rollback-candidates-evidence.sh
```

Producer는 clean `HEAD == Argo desired revision`, manual/OutOfSync Application, 현재 EKS
context, Rollout UID/stable hash, controller-owned non-Experiment ReplicaSet 전체를 fresh query한
뒤 `envs/prod/rollback-compatibility.yaml`의 exact bytes SHA-256과 결속합니다. 그 결과는
`course.rollback-candidates/v1`/`CLOUD_RUNTIME`으로 원자적 `0600` 파일에 기록되고,
`app-prod/sample-app-rollback-candidates` immutable ConfigMap에도 exact bytes와 여섯 identity
scalar로 저장됩니다. 이 ConfigMap은 Argo가 렌더하거나 prune하는 리소스가 아니며 Secret,
token, password를 포함하지 않습니다. 기존 ConfigMap이 byte-for-byte 동일하면 재실행은
idempotent하고, bytes/identity가 다르면 자동 overwrite/delete 없이 실패합니다.

그 뒤에만 selective resource Sync가 아닌 `sample-app-prod` 전체 Sync를 실행합니다. Sync wave는
PostgreSQL `-2`, migration hook Job `-1`, application Rollout `0`이며, migration Pod는 ConfigMap
파일을 `0444`/read-only로 mount하고 여섯 expected identity를 같은 ConfigMap key에서 읽습니다.
Job 성공은 Contract 003 gate가 DB에 기록되었다는 경계입니다. 성공한 Job의 completion time,
exact mount/env, ConfigMap UID와 content SHA를 재확인한 뒤에만 다음 explicit cleanup을 실행합니다.

```bash
AWS_REGION="$AWS_REGION" EKS_CLUSTER_NAME="$PROD_CLUSTER_NAME" \
  bash scripts/capture-rollback-candidates-evidence.sh cleanup
```

Cleanup은 관찰한 UID를 delete precondition으로 사용하고 삭제 후 부재를 다시 조회합니다. Ch26
`capture-cleanup-evidence.sh removal`도 이 ConfigMap이 남아 있으면 `REMOVED` 증거를 발급하지
않습니다. Fixture와 fake adapter 실행은 `[STATIC]`이며 canonical evidence나 live ConfigMap을
생성·삭제하지 않습니다.

Canonical AnalysisTemplate metric 이름은 `request-rate`와 `success-rate`입니다. Ch19의
`scripts/capture-prod-slo-evidence.sh`는 실제 Rollout/AnalysisRun/Argo/AWS 조회를 다시 묶어
성공한 두 metric과 모든 종료 measurement(이전 `Failed`/`Error` 포함)를 보존한 뒤
`evidence/prod/slo.json`을 원자적으로 기록합니다. fixture 검증은 `[STATIC]`이며 runtime 증거를
생성하지 않습니다.

정적 승격 계약은 다음처럼 실행합니다.

```bash
bash tests/evidence-contract.sh --case all
bash tests/promotion-contract.sh --case all
bash scripts/capture-prod-slo-evidence.sh --fixture tests/fixtures/evidence/prod-slo-valid.json
```

이 명령들은 EKS admission, Argo Sync/Health, AMP query, 실제 rollback 또는 CNI 동작을 증명하지
않습니다. 해당 항목은 cloud run에서 별도 `[CLOUD_RUNTIME]` 기록으로 수집해야 합니다.

## Ch25/Ch26 Chaos와 정적 검증 경계

Chaos 리소스는 `envs/dev/chaos-values.yaml`을 명시적으로 추가한 Dev 실습 단계에서만
렌더됩니다. `PodChaos`와 `NetworkChaos`는 `app-dev`의 명시적 application label을
선택하고 최대 5분 동안만 실행됩니다. Prod ApplicationSet은 Chaos values를 참조하지
않으며, Game Day 전후 Namespace annotation 변경은 별도 Git 커밋과 cloud 관찰 증거로
확인합니다.

다음 명령은 구조·스키마 계약을 검사하는 `[STATIC]` 검증입니다.

```bash
bash tests/test-all.sh
bash scripts/build-incident-index.sh --fixture tests/fixtures/incident-index/static-structure.json
bash tests/cleanup-contract.sh --all
scripts/package-chart.sh /tmp/argocd-gitops-chart-package
```

정적 fixture PASS는 실제 Chaos 복구, Argo 동기화, PSS admission, Snapshot restore,
External Secrets refresh, 또는 cleanup 실행을 증명하지 않습니다. 실제 incident index는
검토된 non-fixture lifecycle artifact를 재해시한 `evidence/incidents/index.json`만
생성하며, Ch26 freeze/removal 기록도 live read-only capture에서만
`evidenceGrade: CLOUD_RUNTIME`으로 기록합니다. Provider Secret은 GitOps가 삭제하지
않고 canonical ownership inventory에서 보존·분류합니다. Removal capture는 두 EKS context와
EKS-infra repository를 명시하여 Argo Application 부재, namespace별 workload/writer 0건,
승인된 retained PVC, 실제 provider Secret 존재를 확인합니다.

```bash
AWS_REGION="$AWS_REGION" EKS_CLUSTER_NAME="$PROD_CLUSTER_NAME" \
  bash scripts/capture-prod-baseline-evidence.sh
AWS_REGION="$AWS_REGION" EKS_CLUSTER_NAME="$PROD_CLUSTER_NAME" \
  bash scripts/capture-prod-slo-evidence.sh
AWS_REGION="$AWS_REGION" DEV_CLUSTER_NAME="$DEV_CLUSTER_NAME" PROD_CLUSTER_NAME="$PROD_CLUSTER_NAME" \
  bash scripts/capture-cleanup-evidence.sh freeze \
    --dev-context "$DEV_KUBE_CONTEXT" --prod-context "$PROD_KUBE_CONTEXT"
bash scripts/capture-cleanup-evidence.sh removal --eks-repo-root "$LAB_EKS_REPO" \
  --dev-context "$DEV_KUBE_CONTEXT" --prod-context "$PROD_KUBE_CONTEXT"
```
