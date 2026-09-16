# Production sync and canary abort
권한 주체: platform-prod application operator의 승인된 SSO role을 사용한다.
Git desired state: immutable image digest, latest-hash 분석과 5→20→50→100 route, 100% 전 human pause를 유지한다.
증거: Application Git SHA, Rollout revision, primary VirtualService 100/0 상태, AnalysisRun raw metrics, notification event ID를 기록한다.

승인된 sync는 `argocd app sync mini-commerce-prod --revision "$APPROVED_GIT_SHA"`이다.
위험한 진행 중 canary는 승인된 `kubectl argo rollouts abort mini-commerce -n app-prod`로 중단하고 Git revert로 최종 수렴한다.
직접 `kubectl patch rollout`, route weight edit 또는 Deployment image 변경은 금지한다.
traffic floor 0.1 req/s 미만, 5xx/latency 실패, newest hash label 누락, proxy 비동기화가 있으면 promote를 중단한다.
[Istio Rollouts](https://argoproj.github.io/argo-rollouts/features/traffic-management/istio/) controller만 named primary weights와 Service hash selector를 변경한다.
