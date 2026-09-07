# =============================================================================

# 🚀 ArgoCD GitOps Lab - 종합 셋업 가이드

# =============================================================================

#

# 이 문서는 argocd-gitops 레포지토리를 이용하여

# ArgoCD 기반 GitOps 배포 파이프라인을 구축하는 전체 과정을 안내합니다.

#

# 대상: Kubernetes, Kustomize, ArgoCD를 처음 접하는 주니어 엔지니어

# 작성일: 2026-02-14

# =============================================================================

---

## 📋 목차

1. [전체 아키텍처 이해](#1-전체-아키텍처-이해)
2. [사전 요구사항 확인](#2-사전-요구사항-확인)
3. [레포지토리 구조 이해](#3-레포지토리-구조-이해)
4. [파일 학습 순서](#4-파일-학습-순서)
5. [Lab 실행 순서](#5-lab-실행-순서)
6. [배포 검증 방법](#6-배포-검증-방법)
7. [트러블슈팅 가이드](#7-트러블슈팅-가이드)

---

## 1. 전체 아키텍처 이해

### 1-1. 3개 레포지토리의 역할

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    play-builder 조직 전체 구조                           │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  ① eks-terraform-provisioning (인프라)                                  │
│  ┌──────────────────────────────────────────┐                          │
│  │  Terraform으로 AWS 인프라를 생성/관리      │                          │
│  │  - VPC, 서브넷, NAT Gateway               │                          │
│  │  - EKS 클러스터 (dev + prod)             │                          │
│  │  - RDS PostgreSQL                         │                          │
│  │  - IAM 역할 (IRSA)                       │                          │
│  │  - ArgoCD 설치 (Helm)                    │                          │
│  └──────────────┬───────────────────────────┘                          │
│                 │ EKS 클러스터 + ArgoCD 준비 완료                       │
│                 ▼                                                       │
│  ② argocd-gitops (매니페스트) ← 지금 이 레포                          │
│  ┌──────────────────────────────────────────┐                          │
│  │  K8s 매니페스트를 Git으로 관리             │                          │
│  │  - ArgoCD Application 정의               │                          │
│  │  - Kustomize base + overlay              │                          │
│  │  - 환경별 설정 (dev/prod)                │                          │
│  │                                           │                          │
│  │  ArgoCD가 이 레포를 감시(Watch)하고        │                          │
│  │  변경이 감지되면 자동으로 K8s에 배포        │                          │
│  └──────────────┬───────────────────────────┘                          │
│                 │ Git 변경 → ArgoCD 자동 Sync                          │
│                 ▼                                                       │
│  ③ exchange-settlement-app (애플리케이션)                               │
│  ┌──────────────────────────────────────────┐                          │
│  │  Node.js 애플리케이션 소스코드             │                          │
│  │  - Express.js API 서버                   │                          │
│  │  - CI 파이프라인 (GitHub Actions)         │                          │
│  │  - Docker 빌드 → ECR 푸시               │                          │
│  │  - 빌드 후 argocd-gitops의 이미지 태그    │                          │
│  │    를 자동 업데이트 (GitOps 트리거)        │                          │
│  └──────────────────────────────────────────┘                          │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

### 1-2. GitOps 배포 흐름

```
개발자가 App 코드 Push
        │
        ▼
┌─────────────────────┐
│ GitHub Actions (CI)  │  exchange-settlement-app 레포
│ 1. 코드 테스트       │
│ 2. Docker 빌드      │
│ 3. ECR에 이미지 Push │
│ 4. argocd-gitops의   │
│    이미지 태그 업데이트│
└────────┬────────────┘
         │ kustomization.yaml의 newTag 값 변경
         ▼
┌─────────────────────┐
│ argocd-gitops 레포   │  ← 지금 이 레포
│ (Git에 변경 발생)    │
└────────┬────────────┘
         │ ArgoCD가 3분마다 폴링 (또는 Webhook)
         ▼
┌─────────────────────┐
│ ArgoCD              │  EKS 클러스터 내부
│ 1. Git 변경 감지     │
│ 2. Kustomize 빌드   │
│ 3. 현재 상태와 비교  │
│ 4. 차이점 자동 적용  │
└────────┬────────────┘
         │
         ▼
┌─────────────────────┐
│ Kubernetes 클러스터  │
│ 새 버전 Pod 배포     │
│ (Rolling Update)    │
└─────────────────────┘
```

### 1-3. App of Apps 패턴

```
이 레포가 사용하는 ArgoCD의 핵심 패턴입니다.
하나의 "부모 앱"이 여러 "자식 앱"을 관리합니다.

                    ┌──────────────────────┐
                    │   root-apps-dev      │  부모 앱 (App of Apps)
                    │   (app-of-apps-dev)  │  argocd/apps/dev/ 폴더를 감시
                    └─────────┬────────────┘
                              │
            ┌─────────────────┼──────────────────┐──────────────────┐
            ▼                 ▼                  ▼                  ▼
    ┌───────────────┐ ┌──────────────┐  ┌───────────────┐  ┌───────────────┐
    │ external-     │ │ ingress-     │  │ exchange-     │  │ argocd-       │
    │ secrets-dev   │ │ nginx-dev    │  │ settlement-   │  │ ingress-dev   │
    │               │ │              │  │ dev           │  │               │
    │ sync-wave: 1  │ │ sync-wave: 2 │  │ sync-wave: 3  │  │ sync-wave: 4  │
    └───────────────┘ └──────────────┘  └───────────────┘  └───────────────┘
    CRD + 컨트롤러     로드밸런서 +       애플리케이션         ArgoCD 자체의
    설치               Ingress 컨트롤러   (Kustomize 빌드)    웹 UI Ingress

    ※ sync-wave 숫자가 작을수록 먼저 배포됩니다 (1→2→3→4 순서)
```

---

## 2. 사전 요구사항 확인

### 2-1. 이미 완료되어 있어야 하는 것들

| 항목                | 상태                | 확인 방법                               |
| ------------------- | ------------------- | --------------------------------------- |
| EKS 클러스터 (dev)  | ✅ 프로비저닝 완료  | `kubectl get nodes --context dev`       |
| EKS 클러스터 (prod) | ✅ 프로비저닝 완료  | `kubectl get nodes --context prod`      |
| ArgoCD 설치         | ✅ 설치 완료        | `kubectl get pods -n argocd`            |
| argocd-gitops 레포  | ✅ 이미 존재        | `github.com/play-builder/argocd-gitops` |
| ECR 레포지토리      | ✅ 생성 완료        | AWS Console → ECR 확인                  |
| AWS Secrets Manager | ✅ 시크릿 등록 완료 | AWS Console → Secrets Manager 확인      |
| IRSA 역할           | ✅ 생성 완료        | `eks-terraform-provisioning`에서 생성   |

### 2-2. 로컬 환경에 필요한 도구

```bash
# 1. kubectl - Kubernetes 명령줄 도구
kubectl version --client
# 예상 출력: Client Version: v1.29.x 이상

# 2. kustomize - 매니페스트 빌드 도구
kustomize version
# 예상 출력: v5.4.3

# 3. AWS CLI - AWS 서비스 접근
aws --version
# 예상 출력: aws-cli/2.x.x

# 4. ArgoCD CLI (선택사항) - ArgoCD 명령줄 도구
argocd version --client
# 예상 출력: v2.x.x

# 5. Git
git --version
```

### 2-3. kubeconfig 설정 확인

```bash
# dev 클러스터 kubeconfig 추가
aws eks update-kubeconfig \
  --region us-east-1 \
  --name exchange-settlement-dev \
  --alias dev

# prod 클러스터 kubeconfig 추가
aws eks update-kubeconfig \
  --region us-east-1 \
  --name exchange-settlement-prod \
  --alias prod

# 클러스터 연결 확인
kubectl get nodes --context dev
kubectl get nodes --context prod

# ArgoCD 네임스페이스 확인
kubectl get pods -n argocd --context dev
```

---

## 3. 레포지토리 구조 이해

```
argocd-gitops/
│
├── .github/workflows/              ─── CI: PR 시 매니페스트 유효성 검증
│   └── validate.yaml                    Kustomize 빌드 + YAML Lint + K8s 스키마 검증
│
├── argocd/                          ─── ArgoCD 설정 파일들
│   ├── app-of-apps-dev.yaml              Dev 환경 부모 앱 (최초 1회 수동 적용)
│   ├── app-of-apps-prod.yaml             Prod 환경 부모 앱 (최초 1회 수동 적용)
│   │
│   ├── apps/                        ─── 자식 앱 정의 (부모 앱이 자동 감시)
│   │   ├── dev/
│   │   │   ├── external-secrets.yaml     [wave 1] ESO 설치
│   │   │   ├── ingress-nginx.yaml        [wave 2] Ingress Controller 설치
│   │   │   ├── dev-app.yaml              [wave 3] 애플리케이션 배포
│   │   │   └── argocd-ingress.yaml       [wave 4] ArgoCD 웹 UI 노출
│   │   └── prod/
│   │       ├── external-secrets.yaml     [wave 1] ESO 설치
│   │       ├── ingress-nginx.yaml        [wave 2] Ingress Controller 설치
│   │       ├── prod-app.yaml             [wave 3] 애플리케이션 배포
│   │       └── argocd-ingress.yaml       [wave 4] ArgoCD 웹 UI 노출
│   │
│   ├── projects/                    ─── ArgoCD AppProject (권한 경계)
│   │   ├── dev-project.yaml              Dev 프로젝트: 허용 소스/목적지 정의
│   │   └── prod-project.yaml             Prod 프로젝트: + read-only 역할
│   │
│   └── manifests/                   ─── ArgoCD 자체 Ingress 매니페스트
│       ├── dev/argocd-ingress/
│       │   └── ingress.yaml              argocd-dev.playbuilder.xyz
│       └── prod/argocd-ingress/
│           └── ingress.yaml              argocd.playbuilder.xyz (IP 제한)
│
├── kustomize/                       ─── 애플리케이션 K8s 매니페스트
│   ├── base/                        ─── 공통 설정 (환경 무관)
│   │   ├── kustomization.yaml            리소스 목록 + 공통 레이블
│   │   ├── namespace.yaml                네임스페이스 정의
│   │   ├── serviceaccount.yaml           Pod 실행 시 사용할 ServiceAccount
│   │   ├── clustersecretstore.yaml       AWS Secrets Manager 연결 설정
│   │   ├── externalsecret.yaml           시크릿 동기화 규칙 (키 목록)
│   │   ├── deployment.yaml               애플리케이션 Pod 정의
│   │   ├── service.yaml                  내부 네트워크 엔드포인트
│   │   ├── ingress.yaml                  외부 트래픽 라우팅 규칙
│   │   └── networkpolicy.yaml            네트워크 접근 제어
│   │
│   └── overlays/                    ─── 환경별 커스터마이징
│       ├── dev/
│       │   ├── kustomization.yaml        Dev 빌드 설정 (이미지 태그, 패치 목록)
│       │   └── patches/
│       │       ├── namespace.yaml        Dev 네임스페이스 레이블
│       │       ├── deployment.yaml       Dev 리소스 제한 + 환경변수
│       │       ├── ingress.yaml          Dev 도메인 + TLS 설정
│       │       ├── externalsecret.yaml   Dev Secrets Manager 경로
│       │       └── networkpolicy.yaml    Dev 네트워크 정책
│       └── prod/
│           ├── kustomization.yaml        Prod 빌드 설정
│           ├── hpa.yaml                  자동 스케일링 (Prod 전용)
│           ├── pdb.yaml                  Pod 중단 예산 (Prod 전용)
│           └── patches/
│               ├── namespace.yaml        Prod 네임스페이스 레이블
│               ├── deployment.yaml       Prod 리소스 제한 + AZ 분산
│               ├── ingress.yaml          Prod 도메인 + 보안 헤더
│               ├── externalsecret.yaml   Prod Secrets Manager 경로
│               └── networkpolicy.yaml    Prod 네트워크 정책
│
├── images/
│   └── gitops-flow.png              ─── GitOps 흐름도 이미지
│
├── Readme.md                        ─── 프로젝트 설명
└── .gitignore
```

### 핵심 값 참조표

| 항목               | 값                                                                     | 사용 위치                 |
| ------------------ | ---------------------------------------------------------------------- | ------------------------- |
| AWS Account ID     | `346135039532`                                                         | ECR 이미지 URL, IRSA ARN  |
| ECR 레포지토리     | `346135039532.dkr.ecr.us-east-1.amazonaws.com/exchange-settlement-app` | kustomization.yaml        |
| AWS 리전           | `us-east-1`                                                            | ClusterSecretStore, ECR   |
| Dev 네임스페이스   | `app-dev`                                                              | Dev overlay 전체          |
| Prod 네임스페이스  | `app-prod`                                                             | Prod overlay 전체         |
| Dev 도메인         | `dev.playbuilder.xyz`                                                  | Dev ingress               |
| Prod 도메인        | `playbuilder.xyz`                                                      | Prod ingress              |
| ArgoCD Dev 도메인  | `argocd-dev.playbuilder.xyz`                                           | ArgoCD manifests          |
| ArgoCD Prod 도메인 | `argocd.playbuilder.xyz`                                               | ArgoCD manifests          |
| Dev Secret 경로    | `exchange-settlement/dev/app`                                          | Dev externalsecret        |
| Prod Secret 경로   | `exchange-settlement/prod/app`                                         | Prod externalsecret       |
| Dev IRSA 역할      | `exchange-settlement-dev-external-secrets`                             | Dev external-secrets app  |
| Prod IRSA 역할     | `exchange-settlement-prod-external-secrets`                            | Prod external-secrets app |

---

## 4. 파일 학습 순서

아래 순서대로 파일을 학습하면, 각 개념이 자연스럽게 연결됩니다.

```
Phase 1: CI 파이프라인 (1파일)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#01  .github/workflows/validate.yaml

Phase 2: Kustomize Base - 공통 설정 (8파일)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#02  kustomize/base/kustomization.yaml      ← 먼저! 전체 구조를 정의
#03  kustomize/base/namespace.yaml
#04  kustomize/base/serviceaccount.yaml
#05  kustomize/base/clustersecretstore.yaml
#06  kustomize/base/externalsecret.yaml
#07  kustomize/base/deployment.yaml
#08  kustomize/base/service.yaml
#09  kustomize/base/ingress.yaml
#10  kustomize/base/networkpolicy.yaml

Phase 3: Kustomize Overlay - Dev (6파일)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#11  kustomize/overlays/dev/kustomization.yaml
#12  kustomize/overlays/dev/patches/namespace.yaml
#13  kustomize/overlays/dev/patches/deployment.yaml
#14  kustomize/overlays/dev/patches/ingress.yaml
#15  kustomize/overlays/dev/patches/externalsecret.yaml
#16  kustomize/overlays/dev/patches/networkpolicy.yaml

Phase 4: Kustomize Overlay - Prod (8파일)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#17  kustomize/overlays/prod/kustomization.yaml
#18  kustomize/overlays/prod/hpa.yaml          ← Prod 전용
#19  kustomize/overlays/prod/pdb.yaml          ← Prod 전용
#20  kustomize/overlays/prod/patches/namespace.yaml
#21  kustomize/overlays/prod/patches/deployment.yaml
#22  kustomize/overlays/prod/patches/ingress.yaml
#23  kustomize/overlays/prod/patches/externalsecret.yaml
#24  kustomize/overlays/prod/patches/networkpolicy.yaml

Phase 5: ArgoCD Projects (2파일)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#25  argocd/projects/dev-project.yaml
#26  argocd/projects/prod-project.yaml

Phase 6: ArgoCD App of Apps (2파일)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#27  argocd/app-of-apps-dev.yaml
#28  argocd/app-of-apps-prod.yaml

Phase 7: ArgoCD Child Apps - Dev (4파일)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#29  argocd/apps/dev/external-secrets.yaml
#30  argocd/apps/dev/ingress-nginx.yaml
#31  argocd/apps/dev/dev-app.yaml
#32  argocd/apps/dev/argocd-ingress.yaml

Phase 8: ArgoCD Child Apps - Prod (4파일)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#33  argocd/apps/prod/external-secrets.yaml
#34  argocd/apps/prod/ingress-nginx.yaml
#35  argocd/apps/prod/prod-app.yaml
#36  argocd/apps/prod/argocd-ingress.yaml

Phase 9: ArgoCD Manifests (2파일)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#37  argocd/manifests/dev/argocd-ingress/ingress.yaml
#38  argocd/manifests/prod/argocd-ingress/ingress.yaml
```

---

## 5. Lab 실행 순서

> **전체 흐름 요약:**
> 포트포워딩(임시 접속) → ArgoCD 로그인 → Git 레포 등록 →
> Project 적용 → App of Apps 적용 → 자동 배포 대기 →
> Cloudflare DNS 설정 → 도메인으로 접속 전환
>
> ⚠️ **닭과 달걀 문제:**
> ArgoCD Ingress(도메인 접속)는 NGINX Ingress Controller가 먼저 배포되어야 합니다.
> 하지만 NGINX는 App of Apps로 배포됩니다.
> → 따라서 처음에는 포트포워딩으로 접속 → 배포 완료 후 도메인으로 전환!

### Step 1: ArgoCD 초기 접속 (포트포워딩)

```bash
# ─────────────────────────────────────────────────────────────
# ArgoCD admin 비밀번호 확인
# ─────────────────────────────────────────────────────────────
# ArgoCD 설치 시 자동 생성된 초기 비밀번호를 가져옵니다.
# 이 비밀번호는 추후 변경하는 것을 권장합니다.

kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d && echo
# 출력 예: xYz123AbCdEfGh  ← 이 비밀번호를 메모!

# ─────────────────────────────────────────────────────────────
# 포트포워딩으로 ArgoCD 서버에 임시 접속
# ─────────────────────────────────────────────────────────────
# 아직 Ingress가 없으므로 포트포워딩으로 접속합니다.
# 이 터미널은 포트포워딩 중에는 열어둬야 합니다!
# (새 터미널 탭을 열어서 다음 작업 진행)
#
# ⚠️ 왜 80 포트인가?
# ArgoCD 서버가 --insecure 모드(TLS 비활성화)로 실행 중이므로
# HTTPS(443)가 아닌 HTTP(80) 포트로 접근해야 합니다.
#
# "--insecure"라는 이름이 불안하게 느껴질 수 있지만:
# ┌─────────────────────────────────────────────────────────┐
# │  외부 사용자 ──HTTPS──▶ Cloudflare ──▶ NGINX Ingress  │
# │                (암호화)              (TLS 종단)         │
# │                                                         │
# │  NGINX Ingress ──HTTP──▶ ArgoCD Server                 │
# │              (클러스터 내부 Pod↔Pod, 외부 노출 없음)   │
# └─────────────────────────────────────────────────────────┘
# → 외부 구간은 전부 HTTPS로 암호화됨!
# → HTTP는 클러스터 내부 Pod간 통신뿐 (NetworkPolicy로 보호)
# → AWS EKS + ArgoCD Helm 차트의 기본 권장 방식입니다.

kubectl port-forward svc/argocd-server -n argocd 8080:80 &

# 브라우저에서 확인:
# http://localhost:8080  (https가 아닌 http!)
# ID: admin / PW: 위에서 메모한 비밀번호
```

### Step 2: ArgoCD CLI 로그인 + Git 레포 등록

```bash
# ─────────────────────────────────────────────────────────────
# ArgoCD CLI 로그인 (필수!)
# ─────────────────────────────────────────────────────────────
# ⚠️ 이 단계를 빠뜨리면 아래 에러 발생:
#    "Argo CD server address unspecified"
#
# --plaintext: ArgoCD 서버가 --insecure(HTTP) 모드이므로
#              TLS 없이 평문(HTTP)으로 통신하겠다는 뜻
#
# 참고: CLI 옵션 정리
# ┌────────────────────────────────────────────────────────┐
# │  ArgoCD 서버 모드       │  CLI 옵션                    │
# ├────────────────────────────────────────────────────────┤
# │  --insecure (HTTP)      │  --plaintext                 │
# │  TLS 활성화 (자체서명)  │  --insecure (인증서 검증 건너뛰기) │
# │  TLS 활성화 (정식인증서)│  (옵션 불필요)               │
# └────────────────────────────────────────────────────────┘

argocd login localhost:8080 \
  --username admin \
  --password $(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d) \
  --plaintext

# 예상 출력: 'admin:login' logged in successfully

# ─────────────────────────────────────────────────────────────
# Git 레포지토리 등록
# ─────────────────────────────────────────────────────────────
# 방법 1: ArgoCD CLI (로그인 후 사용 가능!)
# Public 레포인 경우:
argocd repo add https://github.com/play-builder/argocd-gitops.git

# Private 레포인 경우 (GitHub PAT 사용):
# argocd repo add https://github.com/play-builder/argocd-gitops.git \
#   --username <github-username> \
#   --password <github-personal-access-token>

# 등록 확인
argocd repo list

# ─────────────────────────────────────────────────────────────
# 방법 2: ArgoCD UI (CLI 대신 사용 가능)
# ─────────────────────────────────────────────────────────────
# https://localhost:8080 접속 후:
# Settings (⚙️) → Repositories → + CONNECT REPO
# → Choose your connection method: VIA HTTPS
# → Repository URL: https://github.com/play-builder/argocd-gitops.git
# → (Private면 Username/Password 입력)
# → CONNECT 클릭
# → Connection Status: Successful 확인 ✅

# Helm 차트 저장소도 등록 (external-secrets, ingress-nginx 설치에 필요)
argocd repo add https://charts.external-secrets.io --type helm --name external-secrets
argocd repo add https://kubernetes.github.io/ingress-nginx --type helm --name ingress-nginx
```

### Step 3: AppProject 적용 (최초 1회)

```bash
# ─────────────────────────────────────────────────────────────
# ArgoCD AppProject (권한 경계)를 먼저 만듭니다.
# ─────────────────────────────────────────────────────────────
# App of Apps를 적용하기 전에 프로젝트가 존재해야 합니다!
# (없으면 Application이 프로젝트를 찾지 못해 에러)

# Dev 프로젝트 (#25)
kubectl apply -f argocd/projects/dev-project.yaml

# Prod 프로젝트 (#26)
kubectl apply -f argocd/projects/prod-project.yaml

# 확인
kubectl get appprojects -n argocd
# 예상 출력:
# NAME                        AGE
# default                     10d   ← 기본 프로젝트
# exchange-settlement-dev     5s    ← 방금 생성
# exchange-settlement-prod    3s    ← 방금 생성
```

### Step 4: App of Apps 적용 (최초 1회) — GitOps의 시작!

```bash
# ─────────────────────────────────────────────────────────────
# 🚀 이것이 GitOps의 시작점입니다!
# ─────────────────────────────────────────────────────────────
# 이 한 번의 apply 이후로는 모든 것이 Git push만으로 관리됩니다.
# "수동 kubectl apply"는 이것이 마지막입니다!

# Dev 환경 부모 앱 적용 (#27)
kubectl apply -f argocd/app-of-apps-dev.yaml

# 잠시 대기 (30초 정도)
sleep 30

# 자식 앱들이 자동 생성되는지 확인
kubectl get applications -n argocd
# 예상 출력:
# NAME                        SYNC STATUS   HEALTH STATUS   PROJECT
# root-apps-dev               Synced        Healthy         exchange-settlement-dev
# external-secrets-dev        Synced        Progressing     exchange-settlement-dev
# ingress-nginx-dev           OutOfSync     Missing         exchange-settlement-dev
# exchange-settlement-dev     OutOfSync     Missing         exchange-settlement-dev
# argocd-ingress-dev          OutOfSync     Missing         exchange-settlement-dev

# Prod 환경도 적용 (#28)
kubectl apply -f argocd/app-of-apps-prod.yaml
```

### Step 5: Sync Wave 배포 순서 확인

```bash
# ─────────────────────────────────────────────────────────────
# ArgoCD가 sync-wave 순서대로 자동 배포합니다 (Dev 기준):
# ─────────────────────────────────────────────────────────────
#
#  Wave 1: external-secrets-dev   (ESO 설치 → CRD 등록)
#       ↓ 완료 후
#  Wave 2: ingress-nginx-dev      (NGINX Ingress Controller + NLB 생성)
#       ↓ 완료 후
#  Wave 3: exchange-settlement-dev (우리 앱 배포)
#       ↓ 완료 후
#  Wave 4: argocd-ingress-dev     (ArgoCD UI Ingress 생성)

# 실시간 상태 감시 (-w: watch 모드)
kubectl get applications -n argocd -w

# 각 컴포넌트 Pod 상태 확인
kubectl get pods -n external-secrets   # ESO 컨트롤러
kubectl get pods -n ingress-nginx      # Ingress Controller
kubectl get pods -n app-dev            # 우리 앱

# ⏱️ 전체 배포 완료까지 약 5~10분 소요
# NLB 생성이 가장 오래 걸림 (2~3분)
```

### Step 6: NLB DNS 확인 + Cloudflare DNS 설정

```bash
# ─────────────────────────────────────────────────────────────
# NGINX Ingress Controller가 생성한 NLB 주소 확인
# ─────────────────────────────────────────────────────────────
# Wave 2 완료 후 NLB가 자동으로 생성됩니다.
# 이 NLB 주소를 Cloudflare DNS에 등록해야 도메인 접속이 가능합니다.

# NLB 주소 확인 (EXTERNAL-IP 컬럼)
kubectl get svc -n ingress-nginx
# 예상 출력:
# NAME                       TYPE           EXTERNAL-IP
# ingress-nginx-controller   LoadBalancer   k8s-ingressn-xxx.elb.us-east-1.amazonaws.com

# NLB DNS 이름만 추출
export NLB_DNS=$(kubectl get svc -n ingress-nginx ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo "NLB DNS: $NLB_DNS"

# ─────────────────────────────────────────────────────────────
# Cloudflare에서 DNS 레코드 설정
# ─────────────────────────────────────────────────────────────
# Cloudflare 대시보드 → playbuilder.xyz → DNS 탭
#
# 다음 CNAME 레코드를 추가합니다:
#
# ┌──────────────────────────────────────────────────────────────┐
# │  타입    │ 이름              │ 대상(값)          │ Proxy     │
# ├──────────────────────────────────────────────────────────────┤
# │  CNAME  │ dev               │ {NLB_DNS}         │ Proxied   │
# │  CNAME  │ custody-dev       │ {NLB_DNS}         │ Proxied   │
# │  CNAME  │ datalab-dev       │ {NLB_DNS}         │ Proxied   │
# │  CNAME  │ argocd-dev        │ {NLB_DNS}         │ Proxied   │
# └──────────────────────────────────────────────────────────────┘
#
# ⚠️ Prod 클러스터는 별도 NLB가 생성되므로 Prod NLB DNS를 확인하여:
# ┌──────────────────────────────────────────────────────────────┐
# │  CNAME  │ @(루트)           │ {Prod NLB_DNS}    │ Proxied   │
# │  CNAME  │ custody           │ {Prod NLB_DNS}    │ Proxied   │
# │  CNAME  │ datalab           │ {Prod NLB_DNS}    │ Proxied   │
# │  CNAME  │ argocd            │ {Prod NLB_DNS}    │ Proxied   │
# └──────────────────────────────────────────────────────────────┘
#
# 💡 Cloudflare Proxy(주황색 구름) 활성화 시:
#   - Cloudflare가 TLS 인증서를 자동으로 발급/관리
#   - DDoS 방어 + CDN 캐싱 + WAF 적용
#   - SSL/TLS 모드: "Full" 또는 "Full (Strict)" 권장
```

### Step 7: 도메인으로 ArgoCD 접속 (포트포워딩 대체!)

```bash
# ─────────────────────────────────────────────────────────────
# Wave 4 완료 후 ArgoCD Ingress가 생성됨
# → 이제 도메인으로 ArgoCD에 접속 가능!
# ─────────────────────────────────────────────────────────────

# Dev ArgoCD 접속 확인
curl -I https://argocd-dev.playbuilder.xyz
# 200 OK가 나오면 성공!

# 브라우저에서 접속:
# https://argocd-dev.playbuilder.xyz
# ID: admin / PW: Step 1에서 확인한 비밀번호

# ─────────────────────────────────────────────────────────────
# 이제 포트포워딩을 종료해도 됩니다!
# ─────────────────────────────────────────────────────────────
# 포트포워딩 프로세스 종료
kill %1  # 또는 포트포워딩 터미널에서 Ctrl+C

# ArgoCD CLI도 도메인으로 재로그인
argocd login argocd-dev.playbuilder.xyz \
  --username admin \
  --password $(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d) \
  --grpc-web

# ─────────────────────────────────────────────────────────────
# Prod ArgoCD (IP 화이트리스트 적용됨!)
# ─────────────────────────────────────────────────────────────
# Prod는 argocd/manifests/prod/argocd-ingress/ingress.yaml (#38)에서
# whitelist-source-range가 설정되어 있으므로
# 허용된 IP(사무실 네트워크)에서만 접속 가능합니다.
#
# https://argocd.playbuilder.xyz
# → 허용된 IP에서: 정상 접속
# → 비허용 IP에서: 403 Forbidden

# 접속 구조:
# ┌─────────────────────────────────────────────────────────┐
# │  브라우저                                                │
# │  https://argocd-dev.playbuilder.xyz                     │
# │     │                                                    │
# │     ▼                                                    │
# │  [Cloudflare] → DNS 해석 + Proxy                       │
# │     │                                                    │
# │     ▼                                                    │
# │  [AWS NLB] ← ingress-nginx가 생성 (Step 5 Wave 2)     │
# │     │                                                    │
# │     ▼                                                    │
# │  [NGINX Ingress Controller]                              │
# │     │ argocd-server-ingress (#37) 규칙 적용             │
# │     ▼                                                    │
# │  [argocd-server:80] → ArgoCD UI 화면                   │
# └─────────────────────────────────────────────────────────┘
```

### Step 8: 최종 확인

```bash
# ─────────────────────────────────────────────────────────────
# 전체 Application 상태 확인
# ─────────────────────────────────────────────────────────────
kubectl get applications -n argocd

# 모든 앱이 Synced + Healthy이면 성공! 🎉
# NAME                        SYNC STATUS   HEALTH STATUS
# root-apps-dev               Synced        Healthy
# external-secrets-dev        Synced        Healthy
# ingress-nginx-dev           Synced        Healthy
# exchange-settlement-dev     Synced        Healthy
# argocd-ingress-dev          Synced        Healthy
# root-apps-prod              Synced        Healthy
# ...

# ─────────────────────────────────────────────────────────────
# 앱 도메인 접속 테스트
# ─────────────────────────────────────────────────────────────
curl -I https://dev.playbuilder.xyz/api/v1/health
# HTTP/2 200 이면 성공!

# ─────────────────────────────────────────────────────────────
# (선택) ArgoCD admin 비밀번호 변경
# ─────────────────────────────────────────────────────────────
argocd account update-password \
  --current-password $(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d) \
  --new-password <새로운안전한비밀번호>

# 변경 후 초기 시크릿 삭제 (보안)
kubectl -n argocd delete secret argocd-initial-admin-secret
```

---

## 6. 배포 검증 방법

### 6-1. ArgoCD Application 상태

```bash
# 모든 앱이 Synced + Healthy여야 정상
kubectl get applications -n argocd

# 예상 출력 (Dev):
# NAME                      SYNC STATUS   HEALTH STATUS
# root-apps-dev             Synced        Healthy
# external-secrets-dev      Synced        Healthy
# ingress-nginx-dev         Synced        Healthy
# exchange-settlement-dev   Synced        Healthy
# argocd-ingress-dev        Synced        Healthy
```

### 6-2. 애플리케이션 Pod 확인

```bash
# Pod 상태 확인
kubectl get pods -n app-dev -o wide

# 로그 확인
kubectl logs -n app-dev -l app.kubernetes.io/name=app --tail=50

# 배포된 이미지 태그 확인
kubectl get pods -n app-dev -o jsonpath='{.items[0].spec.containers[0].image}'
```

### 6-3. Ingress 확인

```bash
# Ingress 리소스 확인
kubectl get ingress -n app-dev

# 로드밸런서 DNS 확인
kubectl get svc -n ingress-nginx

# 실제 접속 테스트 (Cloudflare DNS 설정 후)
curl -I https://dev.playbuilder.xyz/api/v1/health
```

### 6-4. Secret 동기화 확인

```bash
# ExternalSecret 상태 확인
kubectl get externalsecret -n app-dev
# 예상: STATUS = SecretSynced

# 생성된 K8s Secret 확인
kubectl get secret app-secrets -n app-dev

# Secret 키 목록 확인
kubectl get secret app-secrets -n app-dev -o jsonpath='{.data}' | jq 'keys'
```

---

## 7. 트러블슈팅 가이드

### 문제 1: Application이 OutOfSync 상태

```bash
# 원인 확인
argocd app get <app-name> --show-operation

# 해결: 수동 Sync
argocd app sync <app-name>
```

### 문제 2: ExternalSecret이 SecretSyncedError

```bash
# 원인: IRSA 역할 ARN이 잘못되었거나, Secret 경로가 틀림

# 1. IRSA 역할 확인
kubectl get sa external-secrets -n external-secrets -o yaml

# 2. ESO 컨트롤러 로그 확인
kubectl logs -n external-secrets -l app.kubernetes.io/name=external-secrets --tail=100
```

### 문제 3: Pod가 CrashLoopBackOff

```bash
# 원인: 대부분 환경변수 누락 또는 DB 연결 실패

# 1. Pod 로그 확인
kubectl logs -n app-dev <pod-name> --previous

# 2. describe로 이벤트 확인
kubectl describe pod -n app-dev <pod-name>
```

### 문제 4: Ingress에 접속 안됨 (502/504)

```bash
# 1. Ingress Controller Pod 확인
kubectl get pods -n ingress-nginx

# 2. Service Endpoint 확인
kubectl get endpoints app-svc -n app-dev

# 3. Cloudflare DNS가 NLB를 가리키는지 확인
```

---

## 다음 단계

이 가이드를 읽었다면, 이제 파일별 상세 주석이 달린 YAML 파일들을 순서대로 학습하세요.

첫 번째 파일: `#01 .github/workflows/validate.yaml`부터 시작합니다.
