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

## Phase 3 — auth

### 3.1 JwtValidator (joserfc 자체 강화) — 보안 핵심
- **커밋**: 3e184a9..08e5a92 (ff97475 + 보안fix 08e5a92)
- **G2**: ✅ 12 jwt 테스트 / **G3**: ✅ 100%/100% / **G4/보안**: ✅ (보안 리뷰어가 실제 joserfc 1.7.2로 검증 — RS256 핀닝이 none/HS256혼동을 UnsupportedAlgorithmError로 차단, 다중aud 포함검사, jwk/jku/x5u 헤더 우회 없음) / **G5 Codex**: ⚠️ 타임아웃 → Claude 보안리뷰어 대체 / **G6**: ✅
- **루프**: 🔁 1회 (Important 2: 잘못된 클레임 타입 raw ValueError 누출 → TokenValidationError 래핑; 빈 allowed_algs → HS256 폴백 footgun → ValueError 가드). Java 학습 선반영으로 alg-confusion 루프 회피.

### 3.2~3.5 AuthClient (KeycloakOpenID 래핑)
- **커밋**: 08e5a92..9ee7588 (3.2 53c0a7b, 3.3 8e05db0, 3.4 559f4eb, 3.5 2657176 + low fix 9ee7588)
- **G2**: ✅ 25 auth 테스트(51 총) / **G3**: ✅ core+jwt 100%(auth.py omit) / mypy strict / **G4**: ✅ Approved(리뷰어 실제 테스트 실행 + python-keycloak 7.1.11 라이브 API 검증, PKCE 파생·validate 배선 실증) / **G5 Codex**: ⚠️ 타임아웃 → Claude 리뷰 대체 / **G6**: ✅
- **PKCE 자체구현**(stdlib), validate는 certs()→joserfc KeySet→하드닝 JwtValidator 위임(client_id=aud). 리뷰어가 "raw 전송오류 미변환" 구현자 concern을 오탐으로 정정(_wrap이 KeycloakConnectionError 처리).
- **루프**: 🔁 1회 (low 3: AuthorizationUrl verifier 마스킹[보안]·timeout 배선·client_credentials scope).
- **모델**: 구현=sonnet, 리뷰=sonnet

**✅ Phase 3 (auth) 완료.**

## Phase 4 — admin

### 4.1~4.4 (AdminClient·_translate·users/clients/realms/roles/groups)
- **커밋**: cba6d01..9ee7578 (4.1 06afd5a, 4.2 26560b0, 4.3 fc1ea6a, 4.4 ef386fa + 테스트조임 9ee7578)
- **G1/G2**: ✅ 107 단위테스트 / mypy 16파일 strict / **G3**: ✅ **100% 라인/100% 브랜치**(_translate+5파사드+core+jwt; AdminClient/auth omit) / **G4**: ✅ Approved(리뷰어 python-keycloak 7.1.1 라이브 검증, 21개 델리게이트 전부 _translate.call 래핑 grep 확인, NotFound 전파, 시그니처 누출 0) / **G5 Codex**: ⚠️ 타임아웃 → Claude 리뷰 대체 / **G6**: ✅
- **API**: KeycloakAdmin 직접 kwargs 생성, 메서드명·예외 전부 일치. create_group str|None cast.
- **루프**: 🔁 1회 (Moderate: 7 오류경로 테스트가 broad `raises(Exception)` → 특정 SDK 예외로 조임, 누출 회귀 방어).
- **모델**: 구현=sonnet, 리뷰=sonnet

**✅ Phase 4 (admin) 완료.**
