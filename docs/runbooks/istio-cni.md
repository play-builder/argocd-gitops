# Istio CNI 선행 조건과 restricted Pod

핵심 요약: Mini Commerce namespace는 PSA restricted를 유지한다.
Istio CNI 1.31.0은 각 cluster에 하나만 설치하여 AWS VPC CNI 뒤에서 sidecar 트래픽 redirection을 설정한다.
여기서 소스·실제 chart injection 검증은 완료되어도 DaemonSet/Pod admission/mesh runtime 검증을 뜻하지 않는다.

목차: [소유권](#소유권), [배포와 준비 상태](#배포와-준비-상태), [신규 노드와 업그레이드](#신규-노드와-업그레이드), [검증과 한계](#검증과-한계).

## 소유권

핵심 요약: 애플리케이션마다 NET_ADMIN/NET_RAW를 주는 대신 node-level CNI agent에 권한을 모은다.
이 agent는 별도 infrastructure namespace와 AppProject가 소유한다.

| 대상 | 소유·조건 |
| --- | --- |
| AWS VPC CNI `aws-node` | EKS Terraform; primary interface/IP networking |
| Istio CNI `istio-cni-node` | GitOps CNI singleton; chain 모드 |
| CNI namespace | `istio-cni`; PSA privileged; injection disabled |
| CNI AppProject | `platform-cni-dev/prod`; destination은 istio-cni만 |
| istiod | 1.30.4 및 1.31.0 모두 `pilot.cni.enabled=true` |
| Mini Commerce namespace | PSA restricted 유지; 별도 governance cutover 적용 |

공식 chart 1.31.0은 agent의 `privileged: false`와 명시적 NET_ADMIN/NET_RAW/SYS_ADMIN 등
node capability 및 hostPath를 사용한다. `privileged` PSA namespace는 이러한 node agent 요구를 허용하기 위한 경계다.
application AppProject나 application image policy를 확장하지 않는다.
CNI는 upstream `docker.io/istio/install-cni@sha256:8cef43ba08ae1af846d0e474591f625cd2dd6b2c0df0efcb17faef0d978ef246`로 고정된다.
amd64/arm64 manifest가 있는 index이며 실제 이미지를 실행하거나 private registry로 복제한 증거는 아니다.

기존 proxy/proxy_init private ECR digest를 유지한다.
CNI 활성 injector는 `istio-init` 대신 `istio-validation`을 동일한 trusted proxy image로 주입한다.
validation은 non-root, drop ALL, privilege escalation false이며 iptables rule 적용을 수행하지 않는다.
[Istio CNI 공식 가이드](https://istio.io/latest/docs/setup/additional-setup/cni/).

## 배포와 준비 상태

핵심 요약: sync wave는 선언 순서다. 이 저장소의 CNI·control-plane Applications는 수동 sync이므로
운영자는 child Application과 실제 DaemonSet이 준비되었는지 확인한 뒤 다음 단계로 진행한다.

순서: AppProject(-37) → infrastructure namespaces(-36) → base(-35) →
CNI(-34) → 양 istiod(-30) → gateway(-25) → governance cutover 및 application.
wave만 보고 child가 이미 배포되었다고 가정하지 않는다.

1. 승인된 cluster context에서 AWS VPC CNI가 정상인지 확인한다. Istio CNI는 이를 대체하지 않는다.
2. `istio-cni-dev/prod` child Application을 sync하고 `istio-cni-node` DaemonSet rollout 완료를 확인한다.
3. 명시적 cluster context로 읽기 전용 readiness snapshot을 남긴다.

```bash
ruby scripts/istio-cni-readiness.rb collect \
  --context APPROVED_CLUSTER_CONTEXT --output cni-readiness.json
```

스크립트는 nodes, CNI/AWS VPC CNI DaemonSets 및 그 Pod 목록만 읽는다.
새 output 파일을 mode 0600으로 생성하며 기존 파일을 덮어쓰지 않는다.
각 Linux node에 controller UID가 일치하는 Running/Ready agent Pod 하나씩 있어야 한다.
두 DaemonSet의 observedGeneration, updated/desired/ready/available count가 모두 일치해야 한다.
CNI Pod의 image도 현재 lock의 index와 비교한다.

4. 양 revision istiod를 sync하고 injection을 확인한다. 이후 restricted governance cutover와 app rollout을 진행한다.
5. 실제 API server admission, app readiness, mTLS 및 서비스 요청을 별도로 검증한다.

별도 snapshot의 오프라인 검증:

```bash
ruby scripts/istio-cni-readiness.rb validate --input cni-readiness.json
```

기본 허용 시차는 300초다. 성공은 `CAPTURED_READY`이며 captured input은
`LIVE_NOT_VERIFIED`를 유지한다. 파일 출처 및 실제 network behavior까지 인증하는 도구가 아니다.

## 신규 노드와 업그레이드

핵심 요약: node Ready와 CNI 설치 완료 사이에 간격이 존재한다.
validation init과 node agent repair는 이 간격에 잘못된 redirection으로 앱이 시작되는 것을 방지한다.

- chart의 `repair.enabled=true`, `repair.repairPods=true`를 유지한다. pod 삭제/label 변경 repair 모드는 끈다.
- 검증 init의 `--run-validation --skip-rule-apply`를 유지한다. 새 node에서 CNI가 준비되지 않으면 init이 대기/재시도하고 agent가 pod networking을 repair한다.
- 단일 CNI DaemonSet은 Linux amd64/arm64의 모든 worker pool을 대상으로 하며 NoSchedule/NoExecute taint를 허용한다. EKS managed control plane에는 이 DaemonSet이 배치되지 않는다. Fargate는 이 운영 계약에 포함하지 않는다.
- CNI는 별도 singleton upgrade로 관리한다. chart RollingUpdate maxUnavailable=1과 Prune=confirm을 유지한다.
- CNI1.31은 control-plane1.30/1.31과 공식 ±1 minor 호환 범위에 있다. 1.32 이상 업그레이드는 별도 버전·호환성 검토가 필요하다.
- node autoscaling 후 readiness snapshot을 다시 채집한다. `restartPolicy: Never`인 Job은 CNI readiness 이전에 시작되지 않도록 운영 gate를 둔다.
- `cni.istio.io/not-ready` node taint와 istiod untaint controller를 사용할 수 있지만 현재 Terraform node taint 변경과 controller 활성화는 이 패치 범위가 아니다. 이 설정이 이미 동작한다고 주장하지 않는다.

실패 시 agent readiness/설치 로그와 CNI chain 파일 경로 `/etc/cni/net.d`, binary 경로 `/opt/cni/bin`,
AWS VPC CNI 상태를 확인한다. node agent를 제거한 채 restricted app rollout을 재개하지 않는다.
rollback은 승인된 호환 CNI version으로 복구하고 node coverage 및 실제 injection/network를 다시 확인한다.
이 패치는 CNI 제거, node drain, taint 변경 또는 workload 재시작을 자동 수행하지 않는다.

## 검증과 한계

핵심 요약: `make validate`는 잠긴 chart와 CRD로 렌더링·스키마를 검사한다. 실제 CNI 설치와 신규 node 동작은 클러스터에서 확인한다.

```bash
make validate test
```

운영에서는 위 readiness 명령과 `kubectl -n istio-system get daemonset,pods -o wide`로 node별 준비 상태를 확인한다. 정적 schema 통과는 packet path나 CNI 실행을 증명하지 않는다.
