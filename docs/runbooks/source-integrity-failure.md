# Source integrity failure
권한 주체: source owner와 platform supply-chain operator가 독립적으로 증거를 확인한다.
Git desired state: signed Git revision, locked Helm archive, private ECR digest와 old/new migration-aware workflow identity를 유지한다.
증거: archive SHA-256, Git signature result, SLSA/SPDX attestation, numeric repository ID 1352247019를 보존한다.
직접 admission policy 비활성화 또는 mutable tag 배포는 금지한다.

hash 불일치, 잘못된 workflow/issuer/repository ID, 누락된 predicate가 있으면 sync를 중단한다.
올바른 producer artifact를 재확인하고 승인된 Git 변경으로 digest를 수정한다.
원격 repository rename과 push는 사용자만 수행한다. rename 전 identity를 임의로 제거하지 않는다.
