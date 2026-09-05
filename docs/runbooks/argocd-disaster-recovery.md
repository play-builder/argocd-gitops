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

RDS PITR은 별도 recovery Terraform root/state에서 새 private RDS를 생성하고 실제 CA/retention/pending modification convergence 후 SQL 검증한다.
Dev snapshot inspection Job은 PG_VERSION 파일 확인만 수행하므로 SQL/PITR/Argo 복구 성공 증거가 아니다.

공식 근거: [Argo CD DR](https://argo-cd.readthedocs.io/en/stable/operator-manual/disaster_recovery/).
