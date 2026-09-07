# 운영 활성화와 검증

운영 대상 계정의 Terraform output과 승인된 GitHub 설정을 GitOps 입력으로 연결하는 절차다. 아래 로컬 명령은 배포 준비를 검사하며, 실제 sync·publish·삭제는 담당 운영자가 별도로 승인하고 실행한다.

## 목차

1. [준비해야 하는 입력](#준비해야-하는-입력)
2. [검증과 활성화 순서](#검증과-활성화-순서)
3. [Prod 증빙과 복구](#prod-증빙과-복구)
4. [운영 명령의 영향 범위](#운영-명령의-영향-범위)
5. [실패 시 확인](#실패-시-확인)

## 준비해야 하는 입력

**핵심 요약:** GitHub repository URL은 실제 `play-builder/argocd-gitops`로 설정돼 있다. AWS 값과 실제 운영 소유자·도메인은 추측하지 않는다. 미설정 값이 남아 있으면 activation 검사가 실패하는 것이 정상이다.

| 입력 | 적용 위치 | 확인할 근거 |
|---|---|---|
| Network ECR repository·index digest | `envs/{dev,prod}/values.yaml`, Sigstore 정책 | `mini_commerce_ecr_repository_url`, 앱 CI attestation |
| Istio proxy mirror | `argocd/bootstrap/*/istio-platform.yaml`, 플랫폼 image policy | EKS의 publisher handoff, upstream/mirrored digest |
| RDS/runtime/migration secret ARN·reader role | environment values, `application-secret-stores.yaml` | EKS `mini_commerce_secrets` output |
| AMP URL·Region, tracing endpoint | environment values | EKS AMP/ADOT outputs, 실제 collector label |
| WAF ACL·ACM·hostname | mesh `policies.yaml`, 앱 `routing.hostname` | 같은 Region의 실제 WAF/ACM, DNS/TLS 검증 |
| Git signing key | AppProject `sourceIntegrity` 및 EKS Argo keyring | 실제 배포 commit/merge commit 검증 |
| CODEOWNERS·ruleset·SSO | `.github/CODEOWNERS`, GitHub, EKS Argo 설정 | 저장소 write 권한이 있는 담당 user/team, 실제 SSO group |

`docs/github-ruleset.example.json`은 적용 예시다. GitHub에서 `validate` required check, stale approval 해제, CODEOWNERS review, bypass 없음이 실제로 적용됐는지 별도 확인한다. Dev digest PR 자동화 때문에 global 승인 수는 0이며, 운영·보안·Prod 경로는 CODEOWNERS가 보호한다. CODEOWNERS의 placeholder를 실제 write-access user/team으로 바꾸기 전에는 이 보호를 전제할 수 없다.

비밀값은 Git에 기록하지 않는다. `scripts/render-application-secrets.rb OUTPUT_JSON prod`는 실제 Terraform output 파일에서 SecretStore·reader·Helm 참조를 생성한다. plaintext DB password/API key는 Secrets Manager에서 공급한다. DML용 `mini-commerce-database`와 DDL용 `mini-commerce-migration`을 혼용하지 않는다.

## 검증과 활성화 순서

**핵심 요약:** 먼저 인프라·controller와 소유권을 확인하고, 실제 입력을 넣은 다음 렌더링·정책 검사를 실행한다. Dev 실제 관측 후에 Prod를 승격한다. 기존 설치에는 non-cascading ownership handoff가 선행돼야 한다.

1. EKS의 계정별 기반, controller/CRD, OIDC/ECR pull, private RDS/TLS, AMP/ADOT를 준비한다. 새로운 리소스 소유자와 retained 리소스를 구분한다.
2. 실제 output으로 위 입력을 설정한다. phase/ownership valueFiles를 포함한 ApplicationSet 전체 diff를 검토한다. 변경 대상 앱 소스에는 inline Helm parameters·valuesObject 대신 명시적인 values 파일을 사용한다.
3. DB 활성화는 `envs/{dev,prod}/stateful-values.yaml`에서 수행한다. Prod는 bootstrap된 RDS DML/DDL 사용자·schema와 private `database.allowedCidrs`가 먼저 필요하다. 추적 수집은 준비된 ADOT/X-Ray 출력으로 별도 활성화한다.
4. 다음 로컬 검사를 실행한다.

```bash
bash tests/test-all.sh
ruby scripts/validate-activation.rb dev
ruby scripts/validate-activation.rb prod
```

정상 결과는 `STATIC_VERIFIED`다. `BLOCKED: 경로: unresolved deployment input`이면 해당 입력을 실제 output으로 채운다. 검사는 리소스를 apply하거나 AWS 계정을 변경하지 않는다.

5. [Namespace bootstrap](runbooks/namespace-bootstrap.md), [platform ownership handoff](../argocd/bootstrap/PLATFORM-OWNERSHIP-HANDOFF.md), [CNI readiness](runbooks/istio-cni.md)를 따른다. `mesh-enable`, `pss-enforce`, `sigstore-enable` overlay는 live prerequisite 검증과 승인 후 적용한다. Namespace 삭제·재생성이나 label 강제 변경을 인계 방법으로 사용하지 않는다.
6. Dev의 실제 image digest·source SHA·EKS endpoint·SLO·알림을 관측한다. 생성한 DEV_READY로 Prod PR을 만든다. 앱·migration digest가 같고 증빙이 유효해야 한다.
7. Prod PR 승인·merge 후 [Prod sync/canary runbook](runbooks/prod-sync-canary-abort.md)에 따라 승인된 Git SHA를 수동 sync한다. traffic floor·latest-hash·성공률·지연시간을 확인한 후 promote하거나 abort한다.

승격 검사만 로컬에서 재현하려면 실제 비교 대상의 full SHA를 넘긴다. base SHA가 없는 shallow checkout이면 해당 commit을 먼저 가져와야 한다.

```bash
bash scripts/verify-prod-promotion-binding.sh "$BASE_SHA"
```

잘못된 repo/path/generator, 미검토 inline override, expired DEV_READY, rendered image 불일치는 실패한다. 동일한 이미지의 운영 변경과 앱 cleanup에는 새 DEV_READY를 요구하지 않는다. 이 검사는 PR 리뷰·서명 검증·live admission을 대체하지 않는다.

교차 저장소 검사는 [README의 exact-SHA 명령](../README.md#로컬ci-검증)을 사용한다. checkout 전체가 해당 SHA와 일치해야 하며 미추적 파일/변경된 dependency가 있으면 실패한다. Node verifier를 실행하므로 CI에서는 실제 검토한 SHA만 입력한다.

## Prod 증빙과 복구

**핵심 요약:** 수집기는 source·cluster·Rollout·시간을 묶고, incident/DR companion을 함께 보존한다. `[STATIC]` fixture는 운영 증빙으로 승격되지 않는다. 현재 baseline은 revision 1 onboarding용이며, 반복 배포의 새 baseline을 임의로 덮어쓰지 않는다.

실제 capture 전에 다음 환경 변수를 승인된 output/보관 파일로 설정한다. 아래는 변수 목록이며 sample ARN을 실환경 값으로 사용하지 않는다.

| 변수 | 의미 |
|---|---|
| `AWS_REGION` | 현재 지원 Region `ap-northeast-2` 또는 `us-east-1` |
| `EKS_CLUSTER_NAME` | 실제 Prod 클러스터 이름 |
| `EKS_CLUSTER_ARN` | baseline·rollback capture가 허용할 정확한 Prod ARN |
| `PLATFORM_INCIDENT_EVIDENCE` | 승인된 incident binding JSON |
| `PLATFORM_DR_METADATA` | 실제 암호화된 Argo export/restore metadata |

또한 현재 kubectl context와 Argo CD 로그인 대상을 Prod로 맞춘다. baseline은 실제 Helm render의 image와 live Rollout·ReplicaSet을 대조한다. SLO는 baseline의 Prod ARN을 대조하며, Dev와 Prod의 EKS ARN이 같으면 거부한다. ECR account와 EKS account의 동일성을 요구하지 않는다.

```bash
bash scripts/capture-prod-baseline-evidence.sh
bash scripts/capture-prod-slo-evidence.sh
```

첫 명령은 최초 stable revision 1, 두 번째 명령은 DEV_READY로 승격한 후속 revision에 사용한다. 서로 다른 시점의 작업이므로 두 명령을 최초 설치 직후 일괄 실행하지 않는다. SLO는 각 metric에 30분 이내 성공 측정값이 있어야 한다. vector 값 `[99.9]`는 v1 evidence 문자열 `99.9`로 정규화하며 빈 vector·다중 series·nonfinite·미래 timestamp를 거부한다.

`evidence/prod/*.json`과 `.platform.json`을 함께 승인된 저장소에 보관한다. write-once capture가 기존 다른 identity를 발견하면 실패한다. 기존 pair를 덮어쓰거나 삭제해 우회하지 말고 원본을 archive한 후 새 release의 capture 절차를 진행한다. notification event ID는 실제 공급자 delivery/audit 기록에서 얻으며, metadata만으로 알림 전달이나 복구 성공을 주장하지 않는다.

contract migration의 rollback 후보에는 실제 retained ReplicaSet inventory가 필요하다. `envs/prod/rollback-compatibility.yaml`의 예시 lineage/UID를 운영 값으로 사용하지 않는다. exact-SHA 앱 verifier로 검증한 뒤 runbook 승인에 따라 ConfigMap handoff를 생성하고, migration 종료 후 UID/resourceVersion 조건을 확인해 정리한다.

## 운영 명령의 영향 범위

**핵심 요약:** CI/입력 검사는 외부 상태를 변경하지 않지만, 모든 `scripts/`가 읽기 전용인 것은 아니다. 파일 생성, Kubernetes evidence handoff, 승인된 cleanup의 영향을 구분한다.

| 진입점 | 영향 |
|---|---|
| `tests/test-all.sh`, `validate-activation.rb` | 로컬 렌더링/fixture 검사; chart cache 다운로드 가능 |
| `render-prod-release.rb`, `verify-prod-promotion-binding.sh` | 로컬 Git/Helm/증빙 검사 |
| `capture-prod-baseline-evidence.sh`, `capture-prod-slo-evidence.sh` | 클러스터·Argo·AWS 읽기, 로컬 evidence/companion 생성 |
| `capture-rollback-candidates-evidence.sh` | 승인된 runtime capture 후 immutable ConfigMap 생성; 명시적 cleanup에서 조건부 삭제 |
| `capture-snapshot-evidence.sh` | 실제 Dev DB/PVC/attachment 관측, DB Pod 내 checksum 읽기·로그 수집 |
| `render-recovery-values.sh` | 검증된 snapshot receipt로 tracked recovery values 파일 변경 |
| cleanup values를 sync+prune | 앱 chart 소유 리소스 제거; Namespace 및 별도 DB/PVC/snapshot chart는 유지 |
| `capture-cleanup-evidence.sh` | 기존 단일 계정 inventory의 freeze/removal 관측·검증; 인프라 전체 삭제 명령이 아님 |

Dev 자동 sync는 cleanup profile 적용 전에 수동으로 동결한다. cleanup의 `platformCleanup.workloadsDisabled=true`는 앱·migration·Service·앱 Secret 참조 등 앱 chart의 desired objects를 제거한다. 실제로 삭제하려면 승인된 prune이 필요하며, SecretStore/provider Secret/RDS/PVC 등 다른 소유자의 데이터까지 삭제하지 않는다. 별도 operations Application은 각각의 절차로 확인한다.

여러 AWS 계정 전체 teardown은 현재 단일 계정 cleanup inventory 계약의 지원 범위 밖이다. account guard를 제거하거나 한 inventory로 Dev/Prod를 묶어 승인하지 않는다. EKS 계정별 state, retained data, Secrets Manager와 비용 리소스를 따로 확인해야 한다.

## 실패 시 확인

**핵심 요약:** 먼저 오류가 source identity, 입력, data/network, controller/runtime 중 어디서 발생했는지 확인한다. 실패한 안전장치를 비활성화해 진행하지 않는다.

| 실패 | 확인할 항목 |
|---|---|
| Argo source verification | 실제 merge commit 서명, 허용 GPG key, AppProject repo URL |
| image admission/pull | Network ECR repository policy·노드 pull 권한, digest, SLSA/SPDX workflow identity |
| migration 대기/실패 | ExternalSecret Ready, DDL 사용자·TLS, private CIDR, schema phase·rollback evidence |
| canary 분석 실패 | AMP SigV4 권한, 최신 hash label, 실제 request rate·오류율·latency |
| source/cluster 불일치 | Argo sync SHA, clean checkout, EKS ARN, kubectl API endpoint |
| capture 오래된 결과 | AnalysisRun revision/latest-hash와 measurement 완료 시각; 새 관측 후 재수집 |
| Pod Pending | topology spread, zone/node capacity, HPA/PDB와 quota |
| snapshot inspection 실패 | snapshot/PVC/PV UID와 EBS handle, writer 중지·detach, recovery role |

상세 절차: [데이터·관측 인계](runbooks/data-and-telemetry-cutover.md), [Argo DR](runbooks/argocd-disaster-recovery.md), [source integrity](runbooks/source-integrity-failure.md), [Istio upgrade](runbooks/istio-revision-upgrade.md), [drift/orphan](runbooks/drift-and-orphan.md), [break-glass](runbooks/break-glass-sso.md).

## 내부 API 접근 경계

핵심 요약: Dev와 Prod ALB는 `internal`이며 `sourceRanges`에는 인증·인가를 수행하는 신뢰된 caller의 실제 private CIDR을 설정해야 합니다. 기본 placeholder 상태에서는 활성화 검사가 실패합니다.
앱에는 사용자 로그인·tenant·주문 소유권 모델이 없으므로 고객에게 직접 공개하는 서비스로 배포하지 않습니다.

`platform/istio/overlays/{dev,prod}/policies.yaml`의 `REPLACE_WITH_TRUSTED_CALLER_CIDR`를 실제 gateway/caller subnet으로 대체합니다. 전체 VPC를 편의상 허용하기보다 필요한 caller 범위를 지정합니다. NetworkPolicy와 ingress workload principal은 경로를 제한할 뿐 고객 권한을 검증하지 않습니다. 내부망의 모든 사용자가 신뢰되는 것은 아닙니다.

`ruby scripts/validate-activation.rb dev` 또는 `prod`는 internet-facing scheme, public CIDR, 빈 allowlist, security group override를 거부합니다. 고객 공개가 필요하면 별도 인증 gateway와 앱의 주문 ownership/tenant 인가를 먼저 구현하고 해당 보안 계약도 함께 변경합니다.

기존 internet-facing ALB의 scheme 변경은 로드밸런서 교체와 DNS 변경을 유발할 수 있습니다. source PR 검토 뒤 별도 변경 창에서 새 내부 endpoint의 라우팅·인증 gateway 연결·health를 검증하고 전환합니다. 이 변경에서 실제 ALB를 수정하지 않습니다.
