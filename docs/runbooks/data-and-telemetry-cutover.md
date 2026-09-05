# Data and telemetry cutover

Main chart owns no PostgreSQL StatefulSet, snapshot or chaos. Dev operations Applications are manual.
Application Namespace is a root-owned prerequisite; follow
[namespace bootstrap](namespace-bootstrap.md) before any existing-cluster root sync.
Before switching ownership, capture legacy Application UID, StatefulSet/PVC/PV/snapshot identities, disable
legacy pruning, and perform a non-cascading handoff. Never delete a PVC to resolve Argo ownership conflicts.
The Dev database requires a separately bootstrapped admin Secret `mini-commerce-dev-db-admin` and distinct
DML/DDL users. Existing data must not be initialized with new credentials.

Production database remains disabled until the operator injects `mini_commerce_secrets`, private RDS subnet
CIDRs, initialized DML/DDL credentials and verified endpoint through reviewed values. Enable
`database.enabled=true`; this only adds clients, never a production StatefulSet. NetworkPolicy grants
5432 solely to injected database CIDRs. Empty CIDRs intentionally grant no RDS egress.

## Production activation review

The current V2-prime application reads display_name. Both chart defaults and the Prod
Application select expand/002_expand_product_display_name before enabling DB clients.
The migration runner applies pending 001 and 002 in order up to that target. A SELECT 1
readiness probe alone cannot prove business-query compatibility; verify catalog/order reads.
The explicit initial/001_initial_commerce overlay is for a reviewed legacy-v1-compatible
artifact or isolated migration with application clients stopped, never this current app.
Approve later migration phases in Git:
expand targets 002_expand_product_display_name;
contract and finalize target 003_contract_product_name. Every Job invokes
`node scripts/migrate.mjs --target TARGET` as UID/GID 10001. Only contract mounts
rollback-candidates evidence. Finalize removes that reference before immutable ConfigMap
cleanup; the already-applied target is a ledger-verified no-op. Never run all migration
files implicitly or restore rollback mounts during finalize.

1. Read the actual `prod/03-database` `database_contract` output and verify its accountId, region,
   ARN, resourceId, endpoint and port against a fresh `aws rds describe-db-instances` response.
   Require DBInstanceStatus=available, PubliclyAccessible=false, MultiAZ=true, StorageEncrypted=true,
   matching CACertificateIdentifier, retention >=7 days and no pending configuration modifications.
2. Run the EKS-owned bootstrap procedure with the reviewed CA only under explicit operator authority.
   Confirm runtime `commerce_runtime` has DML only and `commerce_migration` owns approved DDL.
   The bootstrap's LOCAL_VERIFIED summary is not runtime proof: retain actual SQL/TLS and role checks.
3. Feed the actual `mini_commerce_secrets` output into `render-application-secrets.rb`. Confirm
   `database_contract.applicationCredentials` ARNs equal the database/migration source ARNs, while
   masterSecretArn is absent from both reader policies. Confirm both ExternalSecrets are Ready.
4. Inject only private database subnet CIDRs into `database.allowedCidrs`, and set `database.enabled=true`
   in the production activation values (including the last `stateful-values.yaml` overlay). Render the
   full Application value-file sequence and verify DB_SSL=true, NODE_EXTRA_CA_CERTS and distinct targets.
5. Stop on any unknown identity, missing credential/TLS observation, invalid CA or role overlap. After
   human approval, sync migration and application; observe dependency readiness, orders, SLO and rollback.
   Reverting activation stops database clients but never deletes or restores the RDS instance.

The public AWS RDS root bundle was retrieved from
[AWS global trust store](https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem).
Vendored SHA-256: `e5bb2084ccf45087bda1c9bffdea0eb15ee67f0b91646106e466714f9de3c7e3`.
ConfigMap mounts this bundle and NODE_EXTRA_CA_CERTS extends Node's trust store;
DB_SSL=true uses the application's existing rejectUnauthorized=true hostname/chain verification.
Rotate the public bundle by reviewed Git change after certificate expiry and fingerprint checks.

The app and proxy explicitly request 100m/128Mi and limit 500m/256Mi each. At HPA max 10 plus a
25% surge, 13 pods request 2.6 CPU/3.25Gi and limit 13 CPU/6.5Gi; migration and retained legacy workloads
also count against the namespace quota. Recalculate before raising HPA or reducing node capacity.

ADOT scrapes app management3001 /metrics and proxy15090 /stats/prometheus independently.
Merge-metrics is false. The 3001 plaintext mTLS exception is protected by a collector namespace/pod
NetworkPolicy and exact /metrics AuthorizationPolicy; kubelet probes use Istio's rewritten15020 path.
Public ALB health checks use ingress15021, never app3001.

Istio destination metrics use the real canonical-name pod label. A SERVER Telemetry override produces
destination_rollout_hash from the Rollouts pod label. Runtime validation must show this dimension on
both istio_requests_total and istio_request_duration_milliseconds_bucket before canary promotion.
No default Istio hash label is assumed. See [Telemetry customization](https://istio.io/latest/docs/tasks/observability/metrics/telemetry-api/).

## Dev snapshot phases and isolated restore

The snapshot is owned by mini-commerce-db-dev, not the main app chart.
For each approved A1/A2/A3 commit select the same phase overlay in both owners:
the mini-commerce-dev generator phaseValuesFile and the manual DB Application
spec.source.helm.valueFiles (a single ../../envs/dev/PHASE-values.yaml entry).
Keep the main Application's ownership overlay last. A1 uses snapshot-maintenance-values.yaml
with writersStopped=true and DB replicas=1; capture the checksum. A2 changes only replicas
to 0 in that same file, then manually sync the DB owner and observe clean shutdown/detach.
A3 selects snapshot-capture-values.yaml in both owners; the DB chart creates the retained
VolumeSnapshot only with writers stopped and replicas=0. Never switch A3 before A2 proof.

`capture-snapshot-evidence.sh prepare|capture|ready` verifies both Application owners at
the same reviewed SHA and phase, then binds actual PVC/PV/content identities and EBS handle.
The ready receipt is valid for at most one hour. `render-recovery-values.sh` writes values
only for charts/mini-commerce-recovery in app-recovery; normal reader-role reuse and guessed
handles are rejected. That inspection Job has no database/secret-reader identity. Restore
does not authorize database promotion or writes to the source PVC.

## Immutable incident evidence retries

Canonical baseline/SLO/rollback source and .platform.json companion are published as a
write-once pair after incident/DR validation. Identical byte retries are idempotent; changed
captures (including a new observedAt) are rejected without altering the existing valid pair.
Archive both files together under approved evidence retention before a fresh canonical capture.
A failed first publication removes only its own partial output; a crash may leave a
.publish-lock or orphan companion. Inspect and quarantine that incomplete capture under
operator approval before retrying; never overwrite a valid source or infer runtime grade.
