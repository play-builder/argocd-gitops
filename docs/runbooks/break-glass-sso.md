# Break-glass SSO
권한 주체: 기록된 platform-break-glass 그룹의 단기 SSO 세션을 사용한다.
Git desired state: 평상시 최소 권한과 수동 Prod sync, anonymousAccess=false를 유지한다.
증거: SSO principal/session, 승인 ticket, 시작/종료 시각, exact command, Argo audit와 notification event ID를 기록한다.
직접 영구 admin 부여, credential Git 저장, 인증 비활성화는 금지한다.

일반 operator 권한으로 조치 불가능한 장애만 대상으로 한다.
대상 cluster ARN이나 principal이 승인 범위와 다르면 작업을 중단한다.
복구 후 임시 권한을 회수하고 정상 role allow/deny 검증과 Git desired state 수렴을 확인한다.
