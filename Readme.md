# ArgoCD GitOps

Kubernetes manifest repository implementing the GitOps pattern with ArgoCD App of Apps, Kustomize overlays, and automated deployment pipelines.

## Gitops Flow

![Gitops Flow](./images/gitops-flow.png)

## App of Apps Pattern

Root Apps: root-apps-dev and root-apps-prod serve as the entry points for their respective environments.

Child Apps: These are the actual infrastructure components and applications managed by the root app.

Sync waves ensure correct deployment order: CRDs → Controllers → Application → Ingress routes.

## Deployment Verification

```bash
# Check all ArgoCD applications
kubectl get applications -n argocd

# Expected output:
# NAME                      SYNC STATUS   HEALTH STATUS
# root-apps-dev             Synced        Healthy
# external-secrets-dev      Synced        Healthy
# ingress-nginx             Synced        Healthy
# exchange-settlement-dev   Synced        Healthy
# argocd-ingress-dev        Synced        Healthy

# Check app pods
kubectl get pods -n app-dev

# Check deployed image tag
kubectl get pods -n app-dev -o jsonpath='{.items[0].spec.containers[0].image}'
```

## Tech Stack

| Component                 | Version       | Purpose                           |
| ------------------------- | ------------- | --------------------------------- |
| ArgoCD                    | 7.7.16 (Helm) | GitOps continuous delivery        |
| Kustomize                 | 5.4.3         | Manifest templating with overlays |
| External Secrets Operator | 0.14.2        | AWS Secrets Manager → K8s Secrets |
| Ingress-NGINX             | Latest        | Kubernetes ingress controller     |

## Related Repositories

| Repository                                                                               | Purpose                               |
| ---------------------------------------------------------------------------------------- | ------------------------------------- |
| [eks-terraform-provisioning](https://github.com/play-builder/eks-terraform-provisioning) | EKS infrastructure (Terraform)        |
| [exchange-settlement-app](https://github.com/play-builder/exchange-settlement-app)       | Node.js application + CI/CD workflows |
