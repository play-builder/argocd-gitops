# Argo CD 복구

## 백업

핵심 요약: Git에는 원하는 배포 상태를 보관하고, Argo export는 별도 암호화된 보관소에 둔다. export에는 민감한 정보가 포함될 수 있다.

동일한 Argo CD 버전의 CLI로 export한다. 로컬 파일 권한을 제한하고 승인된 KMS/S3 보관 절차를 따른다.

```bash
umask 077
argocd admin export -n argocd > argocd-export.yaml
```

운영 Git SHA, Argo 버전, 원본 cluster, backup 시각과 checksum을 변경 기록에 남긴다. export 파일은 Git에 추가하지 않는다.

## 격리 복구

핵심 요약: 원본과 다른 cluster에서 같은 Argo 버전으로 복구하고, 대상 Secret/DB가 운영 원본을 가리키지 않도록 검토한다.

```bash
argocd admin import -n argocd argocd-export.yaml
```

실행 전 kubectl context와 destination을 확인한다. import 후 Application source revision, Secret 연결, health와 실제 서비스 요청을 검사한다. RDS 복구는 EKS의 `environments/recovery/03-database`에서 별도 plan과 SQL 검증을 수행한다.

[Argo CD 공식 DR 절차](https://argo-cd.readthedocs.io/en/stable/operator-manual/disaster_recovery/)를 기준으로 조직의 backup/restore 책임과 승인 절차를 적용한다. 별도 incident companion JSON은 요구하지 않는다.
