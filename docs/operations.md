# 배포와 운영

## 준비할 설정

핵심 요약: EKS 출력과 GitHub 전달 설정을 연결한다. placeholder는 실제 환경 출력으로 바꾸며 secret은 Git에 넣지 않는다.

| 입력 | 위치 |
| --- | --- |
| ECR repository·digest | `envs/{dev,prod}/values.yaml`, image policy |
| RDS·Secrets Manager·reader IAM role | environment values, `application-secret-stores.yaml` |
| AMP·OTLP endpoint | environment telemetry/analysis 설정 |
| WAF·ACM·hostname·private caller CIDR | Istio overlay와 앱 routing |
| Git signing key·CODEOWNERS·SSO | AppProject, GitHub ruleset, EKS Argo 설정 |

`docs/github-ruleset.example.json`을 실제 조직의 reviewer와 `validate` required check로 적용한다. GitHub App에 ruleset bypass를 주지 않는다. Prod는 승인자와 수동 sync를 유지한다.
기존 리소스 인계는 [플랫폼 소유권](../argocd/bootstrap/PLATFORM-OWNERSHIP-HANDOFF.md)을 먼저 따른다.

## 로컬 검증과 최초 배포

핵심 요약: 렌더링 검사 후 실제 입력 검사를 통과시키고, 승인된 SHA를 sync한다.

```bash
make validate test
ruby scripts/validate-activation.rb dev
ruby scripts/validate-activation.rb prod
```

초기 placeholder 상태에서 activation 실패는 정상이다. `render-application-secrets.rb`와 `render-platform-images.rb`는 승인된 Terraform output/이미지 값을 선언 파일로 투영한다. [Namespace bootstrap](runbooks/namespace-bootstrap.md)과 [Istio CNI](runbooks/istio-cni.md) 순서로 활성화한다.

## 개발자 변경에서 Dev 배포까지

핵심 요약: 앱 main의 성공한 CI가 Dev digest PR을 갱신하면 Argo CD가 자동 반영한다.

```bash
argocd app get mini-commerce-dev --refresh
argocd app wait mini-commerce-dev --sync --health --timeout 600
kubectl -n app-dev rollout status deployment/mini-commerce --timeout=300s
```

Argo의 sync revision과 GitOps merge SHA, Pod의 실제 image digest가 일치해야 한다. 신뢰된 내부 호출 경로에서 `/products`와 주문 API를 확인한다. Istio 요청률·오류율·지연, 앱 metrics, CloudWatch log와 trace 연결도 확인한다. `Synced`만으로 요청 성공을 판단하지 않는다.

## Prod 승격

핵심 요약: 새로 빌드하지 않고 Dev에서 확인한 동일 digest를 승격한다. 성공한 CI run과 운영자 승인은 서로 다른 조건이다.

1. Dev에서 사용할 CI run ID/attempt와 image digest를 확인한다.
2. 앱 저장소의 `promote-dev-digest-to-prod` workflow를 main에서 실행한다. 입력은 `ci_run_id`, `ci_run_attempt`, 선택적 `expected_digest`다.
3. `gitops-production` environment 승인자는 Dev health·실제 트래픽·지표·알림을 확인한다. CI 성공은 클러스터 성공을 증명하지 않는다.
4. workflow는 해당 run/attempt의 성공·main·source SHA·repository ID·scan/attestation artifact를 확인하고 Prod PR을 만든다.
5. GitOps `validate`는 app/migration image가 PR base의 Dev와 같고 overlay/inline override로 달라지지 않았는지 확인한다. CODEOWNERS 검토 후 merge한다.
6. 승인된 GitOps merge SHA로 Prod를 수동 sync한다.

```bash
argocd app sync mini-commerce-prod --revision "$APPROVED_GITOPS_SHA"
kubectl argo rollouts get rollout mini-commerce -n app-prod --watch
```

Rollouts의 AnalysisRun과 AMP 요청 결과를 확인한다. 실패 시 canary를 중단하고 원인을 조사한다. 진행 중 canary 중단과 완료된 배포의 Git revert는 다른 절차다. DB migration은 image rollback으로 되돌리지 않는다.

자동 Dev-SLO JSON 판정과 incident/DR receipt는 배포 조건에서 제거했다. 승인은 실제 관측 결과를 근거로 진행하며, 조직의 변경 기록에 CI/PR/Argo revision과 확인 결과를 남긴다.

## 데이터와 복구

핵심 요약: 기본 앱 배포는 기존 DB migration 경로를 유지한다. DB/PVC/snapshot은 앱과 별도 소유자다.

`migrations/001–003`은 적용 이력을 보존한다. 현재 기본 target은 expand 단계이며, `003_contract_product_name` 실행은 retained rollback image 호환성 검사가 필요하다. [데이터 변경 절차](runbooks/data-and-telemetry-cutover.md)를 따른다.

Dev snapshot과 recovery chart는 선택적 별도 작업이다. `kubectl get volumesnapshot,volumesnapshotcontent`와 AWS EBS에서 원본·상태·snapshotHandle을 확인한 뒤 recovery values를 검토한다. 원본과 다른 namespace/DB에서 검사한다. snapshot inspection Job의 성공은 SQL 데이터 전체 복구를 증명하지 않는다.

Argo 복구는 [DR 절차](runbooks/argocd-disaster-recovery.md), 데이터·인증 정보의 이전은 EKS의 별도 plan과 백업 정책을 따른다.

## 운영 도구의 책임

핵심 요약: 대부분 선언형 YAML을 변경한다. 다음 도구는 단순 CLI로 대체하기 어려운 입력·정책 경계만 담당한다.

| 파일 | 목적·영향 |
| --- | --- |
| `render-application-secrets.rb`, `render-platform-credentials.rb`, `render-platform-images.rb` | Terraform output/승인 입력을 선언 파일로 투영 |
| `validate-activation.rb`, `validate-mesh-inputs.rb` | 미설정/부적절한 입력 거부 |
| `validate-rendered-manifests.rb` | chart/CRD checksum 확인과 schema 검사 |
| `render-prod-release.rb`, `verify-prod-promotion-binding.sh` | 실제 Prod 렌더와 base Dev 이미지 비교 |
| `namespace-enforcement-preflight.rb`, `istio-cni-readiness.rb`, `verify-platform-owner-phase-b.sh`, `verify-platform-mirror-activation.rb` | 소유권·PSS·image policy 활성화 전 확인 |
| `capture-rollback-candidates-evidence.sh` | Contract 003 전 live retained ReplicaSet 확인과 immutable ConfigMap handoff; `cleanup`은 완료 후 UID에 한정한 삭제 |
| `package-chart.sh` | 세 차트 archive와 checksum 생성 |

테스트 transport·fixture publication·임의 clock override는 운영 collector에서 지원하지 않는다.
