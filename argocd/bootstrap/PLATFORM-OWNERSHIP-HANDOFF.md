# External Secrets Phase A → Phase B 전환

현재 bootstrap은 기존 cluster에 안전하게 적용할 수 있는 **Phase A**입니다. `external-secrets-dev`와
`external-secrets-prod` Application은 남아 있지만 Auto-Sync와 resources finalizer가 제거되어
Terraform import 중 재조정 또는 cascade deletion을 일으키지 않습니다. Helm Namespace에는
`Prune=false`가 있어 ApplicationSet metadata의 server-side ownership 이관 전에 삭제되지 않습니다.

Phase B는 repository 정적 검증만으로 진행할 수 없습니다. 환경마다 EKS-infra의 live handoff와
no-op import/adoption 증거를 받은 뒤 다음 gate를 실행합니다.

```bash
export PHASE_A_GITOPS_SHA="$(git rev-parse HEAD)"
bash scripts/verify-platform-owner-phase-b.sh \
  --environment dev \
  --handoff "$DEV_EXTERNAL_SECRETS_HANDOFF" \
  --adoption "$DEV_EXTERNAL_SECRETS_ADOPTION" \
  --expected-gitops-revision "$PHASE_A_GITOPS_SHA"
```

```bash
bash scripts/verify-platform-owner-phase-b.sh \
  --environment prod \
  --handoff "$PROD_EXTERNAL_SECRETS_HANDOFF" \
  --adoption "$PROD_EXTERNAL_SECRETS_ADOPTION" \
  --expected-gitops-revision "$PHASE_A_GITOPS_SHA"
```

두 실행이 모두 `[CLOUD_RUNTIME] PASS`일 때만 별도 Phase B commit에서 다음 변경을 수행합니다.

1. `charts/sample-app/templates/namespace.yaml`을 제거합니다.
2. 두 Kustomization에서 `external-secrets.yaml` resource를 제거합니다.
3. `argocd/bootstrap/{dev,prod}/external-secrets.yaml`을 제거합니다.
4. Helm render에 Namespace가 없고 bootstrap에 External Secrets Application이 없는지 검증합니다.
5. live Application 삭제 뒤 Helm storage object, controller Deployment와 CRD UID가 adoption 증거와
   동일한지 다시 확인합니다.

gate가 실패하면 Phase B 파일을 수정하거나 삭제하지 않습니다. 현재 Phase A Application을 다시
활성화할지, 이미 import된 Terraform owner를 유지할지는 실제 import 진행 여부를 기준으로 결정합니다.
