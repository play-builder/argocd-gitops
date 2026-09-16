# Istio revision upgrade
권한 주체: mesh platform operator의 승인된 SSO role을 사용한다.
Git desired state: stable 1.30.4, candidate 1.31.0, revision tags, locked official charts와 singleton CNI를 관리한다.
증거: proxy-status, injected Pod security/resources, revision, ingress health, destination metrics와 canary AnalysisRun을 보존한다.
직접 namespace injection을 끄거나 old revision을 먼저 삭제하는 작업은 금지한다.

CNI readiness와 app PSA restricted 호환성을 확인한 후 Dev tag/re-injection부터 진행한다.
두 control-plane revision이 모두 유지되는 상태에서 prod-canary를 검증하고 승인된 tag 변경으로 승격한다.
proxy sync 실패, NET_ADMIN istio-init 등장, ingress15021 실패 또는 destination_rollout_hash 누락 시 중단한다.
rollback은 Git에서 stable tag와 namespace revision을 복원하고 pod re-injection 후 검증한다.
old revision 제거는 실제 proxy inventory와 workload rollback 증거 이후 별도 승인한다.
