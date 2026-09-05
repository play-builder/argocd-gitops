# Drift and orphan response
권한 주체: platform operator는 diff를 읽고 해당 resource owner에게 변경을 요청한다.
Git desired state: mini-commerce named HPA replicas, Service rollout hash, reloader annotation, primary route weights만 무시한다.
증거: Argo diff, resource UID/ownerReferences, Application revision, 기존 PVC/PV/VolumeSnapshot identity를 수집한다.
직접 orphan 삭제, PVC 삭제 또는 broad ignoreDifferences 추가는 금지한다.

legacy Application과 신규 owner가 같은 리소스를 참조하면 sync/prune를 중단한다.
DB 이동은 기존 StatefulSet 이름 mini-commerce-postgresql과 data PVC 이름을 보존하며 non-cascading ownership handoff 이후 수동 DB Application에 연결한다.
현재 PVC/PV reclaim policy와 VolumeSnapshotContent Retain을 확인하고 보존 동의 없이 이전 template 제거를 클러스터에 적용하지 않는다.
new namespace governance와 legacy namespace owner가 겹치면 cutover inventory로 owner를 하나로 만든 후 진행한다.
