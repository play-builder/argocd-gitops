# Namespace bootstrap and ownership cutover

The root bootstrap is the sole owner of app-dev/app-prod Namespace. It applies the reviewed
restricted PSA, stable Istio revision and Sigstore include labels at wave -36, before root
reader ServiceAccounts/SecretStores at -15. Governance owns only quota, limits and admission
policy resources, not Namespace. App charts and retained legacy Applications do not create it.

The actual root producer is EKS-infra
`environments/{dev,prod}/04-workloads/argocd/main.tf` `kubectl_manifest.bootstrap`.
With approved enable_bootstrap=true it creates course-{env}-bootstrap in AppProject
`default` (Dev auto-syncs; Prod is manual). platform-bootstrap-{env} is the bounded
child project, not the root project: do not reassign root to it, since it does not grant
the direct ServiceAccount/SecretStore/ExternalSecret resource permissions. This change
does not redesign root AppProject authorization.

## Fresh cluster prerequisites

A full-root-sync is forbidden until the following staged platform prerequisites succeed.
Child Application waves do not prove readiness of manual child resources.

1. Provision the EKS-owned Policy Controller and ESO under the separate approved platform
   procedure. The policy-controller-webhook Deployment and webhook service must be ready.
2. Inject and review the real policy repository, certificate and trust-root identities in Git.
   Before enabling the root, create only the reviewed platform-bootstrap-{env} AppProject
   and supply-chain-policy Application from bootstrap manifests under platform operator
   authority (selective resources, not the entire root). Manually sync that policy Application.
   Its cosign-system destination does not depend on app-dev/app-prod. Wait for all three
   ClusterImagePolicy objects to reconcile. This is a non-circular prerequisite: no application
   Namespace is needed to install policy resources.
3. Run the read-only gate against the explicit approved context:

```bash
ruby scripts/namespace-enforcement-preflight.rb prod EXPECTED_KUBE_CONTEXT
```

The gate checks current Deployment generation/replicas, ready webhook endpoints, four
fail-closed webhook configurations with CA/rules, and exact Git policy specs plus current
Ready status. It does not prove signature acceptance, admission success or cloud completion.
Do not switch the include label off or failurePolicy to Ignore to bypass a failed gate.
4. Complete CNI/istiod, ESO and secret handoff readiness per their runbooks. Then approve
   enable_bootstrap and full-root-sync. Namespace precedes the direct readers/stores without depending on a manual
   governance child. Sync governance before application workloads; verify actual admission,
   quota and signed/private image acceptance using approved runtime tests.

## Existing cluster handoff

Before any root sync, freeze legacy/current application changes and save Namespace UID,
labels, Argo tracking metadata and workload/PVC identities. Preserve resources and use the
approved non-cascading handoff: remove legacy/governance ownership of Namespace without
deleting it or enabling prune. Legacy Helm namespace.create=false and removal of
CreateNamespace/managedNamespaceMetadata are part of this desired-state transition.
Render both Applications and confirm Namespace is absent; confirm their tracked ownership
has been relinquished before adopting it into root. Never blindly replace tracking metadata
or delete Namespace/PVC. Previously deployed old governance children require the same handoff.
For an existing Dev root, suspend its automated synchronization under approved operator
control before exposing this Git revision and prevent an EKS reconciliation from re-enabling
it during handoff. Do not use enable_bootstrap=false to pause an existing root: Terraform
would remove the root resource, whose finalizer can cascade. Resume only after the gate and
ownership evidence are approved.

Audit retained Pods for restricted PSA/CNI compatibility before changing labels, verify the
controller/policy gate, and obtain explicit enforcement/cutover approval. This repository is
the final enterprise bootstrap, not a safe in-place Phase-A label migration by itself.
If preflight or handoff fails, leave the existing Namespace and applications unchanged.
Rollback must be a reviewed ownership transfer; deleting the root Namespace is forbidden
(Prune=false). No runtime handoff or admission test has been performed by local contracts.
