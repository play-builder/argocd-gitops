# Argo CD disaster recovery
권한 주체: platform recovery operator의 단기 SSO role과 DR object 읽기 권한을 사용한다.
Git desired state: 승인된 Git SHA와 Argo CD 3.5.2를 별도 EKS cluster에 bootstrap한다.
증거: EKS `platform.argocd-dr/v1`의 payload bucket/key/versionId/sha256/KMS key와 metadata SHA-256를 함께 보존한다.
Metadata JSON만으로 복구할 수 없다. 실제 export payload는 encrypted, versioned S3에 두고 Git에 저장하지 않는다.
외부 Secret은 EKS typed shell에서 다시 투영한 후 같은 3.5.2로 import한다. 원본 cluster로 import하는 작업은 금지한다.

1. source cluster ARN, Git revision, Argo version, payload digest, S3 VersionId와 대상의 다른 cluster ARN을 검증한다.
2. EKS 소유 export/restore producer를 사용한다. source와 대상이 같거나 payload가 없거나 KMS 증거가 없으면 중단한다.
3. 격리 bootstrap에서 ExternalSecrets Ready를 확인하고 import 후 Application revisions와 health를 raw capture한다.
4. secret-free metadata만 incident evidence에 결속한다. payload, Secret 또는 production restore output은 Git에 넣지 않는다.

EKS 구현은 `scripts/lib/argocd-backup.py`와 `docs/runbooks/argocd-protected-backup.md`를 기준으로 한다.
export 결과의 CAPTURED와 pure evaluator의 LOCAL_VERIFIED는 GitOps release 증거로 거부된다.
실제 isolated import receipt와 S3/AWS/Kubernetes 관측을 검증한 verify 결과만 CLOUD_RUNTIME으로 소비한다.
격리 DB/Secret destination 설정은 backup baseline 이전 승인된 동일 Git SHA에 준비한다.
복구 Application이 Prod DB를 가리키면 sync하지 말고 중단한다.
`capture-incident-binding.rb DR_METADATA_JSON REVIEWED_NOTIFICATION_EVENT_ID`는 별도 검토한
notification provider receipt ID를 요구한다. 이 인수 자체는 notification delivery 증명이 아니며
해당 provider receipt 원문/시각/대상과 실제 수신 확인은 운영자가 별도로 보존한다.
production baseline/SLO/rollback 파일은 `.platform.json` companion의 원문 DR metadata 및 source
checksum과 함께 검증한다. companion 누락 또는 byte mismatch는 canonical evidence gate가 거부한다.

RDS PITR은 별도 recovery Terraform root/state에서 새 private RDS를 생성하고 실제 CA/retention/pending modification convergence 후 SQL 검증한다.
Dev snapshot inspection Job은 PG_VERSION 파일 확인만 수행하므로 SQL/PITR/Argo 복구 성공 증거가 아니다.

공식 근거: [Argo CD DR](https://argo-cd.readthedocs.io/en/stable/operator-manual/disaster_recovery/).
