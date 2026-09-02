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

argocd/bootstrap/dev/           dev 클러스터만 읽는 root 구성
argocd/bootstrap/prod/          prod 클러스터만 읽는 root 구성
```

이 그림에서 봐야 할 핵심은 **클러스터마다 자기 bootstrap 경로만 읽는다**는 점입니다.
dev Argo CD가 실수로 prod values를 배포하거나, prod Argo CD가 dev 자동화 정책을 상속하지
않도록 경계를 나눴습니다.

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

## 운영 계약

- dev: application code PR merge → build/push → dev digest PR → validate → auto-merge → Argo CD auto-sync
- prod: dev에서 검증한 **동일 digest** → prod promotion PR → CODEOWNERS 승인/merge → Argo CD auto-sync → Rollouts Canary
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
