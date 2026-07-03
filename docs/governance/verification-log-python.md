# 검증 로그 — Python SDK

[AI 거버넌스 프레임워크](ai-governance-framework.md)에 따른 Python SDK(`keycloak-sdk`) 태스크별 정량 검증 기록. 브랜치 `feature/python-sdk`.

**툴체인**: venv `python/.venv` (Python 3.13.11). 명령: `/d/Source/KeyCloakSDK/python/.venv/Scripts/python.exe -m <pip|pytest|mypy>`.

**게이트**: G1 설치/빌드 · G2 pytest · G3 커버리지(pytest-cov, 로직 라인≥90/브랜치≥85; 네트워크경계 omit) · G4 리뷰 · G5 Codex · G6 보안.

> ⚠️ **Codex 상태**: 이번 세션은 Java 후반부터 Codex CLI가 반복 타임아웃(환경 저하). Python 구현 동안 Codex 정상화 시 교차검증하고, 아니면 Claude 리뷰 + 실제 Keycloak E2E + 실증(install/pytest/mypy)으로 대체하며 정직하게 기록.

---

## Phase 1 — 기반

### 1.1 pyproject+골격 · 1.2 도구 · 1.3 CI
- **커밋**: ed6cd5c..f1b9962 (1.1 78d8362, 1.2 707b571, 1.3 f1b9962)
- **G1**: ✅ `pip install -e ".[dev]"` 성공 — python-keycloak 7.1 + joserfc + testcontainers[keycloak] + pytest/mypy 전부 Python 3.13에서 해결(버전 조정 불필요) / **G2**: ✅ pytest 1 통과 / mypy strict 통과
- **G4**: ✅ 컨트롤러 리뷰(diff가 계획과 일치, hatchling/src레이아웃/커버리지 omit 정확) / **G5 Codex**: ⚠️ 타임아웃(미완) → 실증(install+pytest+mypy) 대체 / **G6**: ✅
- **모델**: 구현=sonnet

## Phase 2 — core

### 2.1~2.5 (예외·마스킹·Config·토큰·OIDC)
- **커밋**: 5d8681b..6fbc09c (2.1 dcd2acc, 2.2 a4d6757, 2.3 0dc044e, 2.4 a148c40, 2.5 f8a3000, 커버리지 6fbc09c)
- **G1/G2**: ✅ 14 테스트, mypy strict / **G3**: ✅ **라인 100% / 브랜치 100%** / **G4**: ✅ Approved(리뷰어가 직접 설치·실행 실증) / **G5 Codex**: ⚠️ 타임아웃 → Claude 리뷰+실증 대체 / **G6**: ✅ (repr/str 마스킹 누출 0 확인)
- **Minor(최종리뷰)**: from_response None경로 미테스트 · config.py 미사용 `field` import(plan 유래, ruff F401) · server_url/client_id 공란 명시 테스트 부재 · 일부 예외 coverage-by-import.
- **모델**: 구현=sonnet, 리뷰=sonnet
