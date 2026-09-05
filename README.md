# Mini Commerce GitOps delivery

Mini Commerce desired state uses Dev Deployment and Prod Rollout with native Istio routing.
Local verification is STATIC_VERIFIED; it does not establish CLOUD_RUNTIME, RECOVERY_VERIFIED or RELEASE_READY.

## Ownership and entry points

- `charts/mini-commerce`: app, migration, public3000 Service, management3001 probes, native VirtualService and analysis.
- `charts/mini-commerce-db-dev`: manual Dev PostgreSQL; retained PVC identity.
- `charts/mini-commerce-recovery`: manual Dev snapshot inspection, not RDS PITR or SQL recovery proof.
- `experiments/chaos/dev`: manual five-minute bounded chaos.
- `argocd/bootstrap/{dev,prod}`: scoped AppProjects and Applications, legacy ownership retained until reviewed cutover.
- `platform/istio`: stable/candidate mesh, collector-only management paths and ALB GatewayAPI edge.
- `platform/security/{dev,prod}`: restricted PSA, VAP, quota and LimitRange. Governance Application is manual until namespace ownership handoff.
- EKS owns RDS, secret shells/readers, ADOT/AMP, Argo CD/Rollouts controllers and encrypted Argo DR payload producers.

## Environment injection and cutover

Use `scripts/render-application-secrets.rb OUTPUT_JSON prod` with the actual EKS `mini_commerce_secrets` output.
The result contains SecretStore/reader manifests and Helm reference values only. Review and apply these to
`application-secret-stores.yaml` and the environment values; plaintext secret values never enter Git.
Runtime DML uses `mini-commerce-database`; migration DDL uses `mini-commerce-migration`.

Before enabling production database clients, inject the private RDS endpoint through Secrets Manager,
review `database.allowedCidrs`, bootstrap users/schema, and verify the trusted CA. Empty CIDRs intentionally grant no RDS egress.
The vendored public AWS CA is mounted with NODE_EXTRA_CA_CERTS; DB_SSL enables hostname and chain validation.
Follow [data and telemetry cutover](docs/runbooks/data-and-telemetry-cutover.md).

The new runtime keeps repository ID `1352247019`. Old/new workflow names remain migration-aware until
fresh `course.rename-cutover/v1` evidence. Remote rename and push are user actions.
Preserve legacy Applications, PVCs, PVs and snapshots until the documented non-cascading ownership handoff.

## Local verification

Use Helm4.2.4, kubectl1.36.0, yq4.53.6, kubeconform0.7.0, CUE0.12.1, istioctl1.31.0 and promtool3.14.0.

```bash
bash tests/test-all.sh
```

This runs rendered routing/security/tenancy, real PromQL evaluation, strict upstream schemas, image/source
integrity and local evidence parser/CLI-double contracts. It never applies cloud or Kubernetes resources.
Optional `EKS_REPO_ROOT` and `APPLICATION_REPO_ROOT` enable read-only producer interface inspection.

```bash
bash scripts/package-chart.sh /tmp/mini-commerce-package
```

The package includes its SHA-256 sidecar. CI runs the same complete local suite after installing pinned tools.

## Evidence and operational procedures

- [Production sync and canary abort](docs/runbooks/prod-sync-canary-abort.md)
- [Argo disaster recovery](docs/runbooks/argocd-disaster-recovery.md)
- [Drift and orphan response](docs/runbooks/drift-and-orphan.md)
- [Source integrity failure](docs/runbooks/source-integrity-failure.md)
- [Istio revision upgrade](docs/runbooks/istio-revision-upgrade.md)
- [Break-glass SSO](docs/runbooks/break-glass-sso.md)

`capture-incident-binding.rb DR_METADATA_JSON REVIEWED_NOTIFICATION_EVENT_ID` performs read-only live
identity capture and prints a secret-free binding for review. Notification event ID must come from the
actual provider delivery/audit record; this helper does not prove notification delivery.
Set `PLATFORM_INCIDENT_EVIDENCE` and `PLATFORM_DR_METADATA` to the reviewed files before live baseline,
SLO or rollback capture. Each capture validates source/image/cluster/revision and emits a
`.platform.json` companion binding the source file hash to the incident and encrypted DR object.
Metadata alone is not a recoverable Argo export.

## Runtime gates

CNI readiness and restricted injection, private image admission, SSO/HA, actual destination telemetry labels,
canary abort/promote, firing/resolved notification delivery, initialized RDS TLS/DML/DDL, encrypted export,
isolated Argo restore and RDS PITR remain LIVE_NOT_VERIFIED until observed on real infrastructure.
Static snapshot inspection does not establish SQL recovery, RPO/RTO or release readiness.
