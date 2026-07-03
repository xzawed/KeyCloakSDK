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

## Phase 5 — facade

### 5.1 KeycloakClient
- **커밋**: 3f9044f..b36eea7 (AdminClient.close a8f3632, KeycloakClient b36eea7)
- **G1/G2**: ✅ 120 테스트 / mypy 17파일 / **G3**: ✅ client.py 100%/100% (전체 100%) / **G4**: ✅ 컨트롤러 리뷰(create 즉시auth/지연admin 캐시, close 가드, 컨텍스트매니저, _of 시드, 공개 export+__all__) / **G5 Codex**: ⚠️ 타임아웃 / **G6**: ✅
- **설계**: `.admin`은 지연 생성(구성은 저렴, secret 검증은 실제 admin 작업 시). public client는 auth만 secret 없이 사용 가능.

**✅ Phase 5 (facade) 완료.**

## Phase 6 — 통합 테스트 (testcontainers[keycloak], 실제 Keycloak 26.6.4)

### 6.1 하네스 · 6.2 인증 E2E · 6.3 관리 E2E
- **커밋**: d68e68f..df0347d (6.1 5dff1a4, 6.2 ac2fe9c, 6.3 df0347d)
- **G1/G2**: ✅ **통합 6 passed / 0 failed** (실제 Keycloak 26.6, 25s), 단위 120 무회귀 / **G6**: ✅
- **E2E 검증**: client_credentials 토큰·**하드닝 JwtValidator가 실제 다중 aud 토큰 검증 통과**·introspect active·user CRUD·delete후 404(KeycloakNotFoundError)·raw.get_server_info.
- **SDK 버그 0건 — 전부 첫 시도 통과** (Java 통합이 발견한 다중 aud 버그를 Python 설계에 선반영한 효과). testcontainers `with_realm_import_file`는 고정 경로 마운트.
- **G4/G5**: 통과한 실제-Keycloak E2E가 최강 검증 + 컨트롤러 리뷰(비-vacuous 단언 확인). Codex ⚠️ 타임아웃.

**✅ Phase 6 (통합) 완료. Python SDK가 실제 Keycloak 26.6.4로 end-to-end 동작. 버그 0.**

## Phase 7 — 배포 · 문서

### 7.1 pyproject 메타+릴리스 CI · 7.2 examples+문서
- **커밋**: dce0f34..6f3aeb1 (7.1 677b8b0, 7.2 6f3aeb1)
- **G1**: ✅ `python -m build` → wheel+sdist / **G2**: ✅ 120 단위 / mypy(src+examples) / **G6**: ✅ (deploy human-gated, Trusted Publisher OIDC 무시크릿)
- PEP 561 `py.typed` 추가(소비자 mypy 지원). CLAUDE.md Python 섹션(구조·명령·python-keycloak 래핑·자체 JWT).

**✅ Phase 7 완료.**

---

## 종합 (Python SDK 전 Phase 완료)
- **총 126 테스트** = 단위 120 + 통합 6(실제 Keycloak 26.6.4). 로직 모듈 커버리지 100%, mypy strict.
- **핵심 성과**: python-keycloak(admin+auth) 래핑 + joserfc 자체 강화 JWT. **Java 최종리뷰 학습을 설계에 선반영**(ValidatedToken·다중 aud·시크릿 마스킹·지연 admin·SignedJWT 강제·alg-confusion 방어) → 통합 E2E 버그 0, JWT 보안 루프 회피.
- **거버넌스**: Codex는 이번 세션 지속 타임아웃 → Claude 리뷰어(독립 모델, 실제 테스트 실행) + 실제 Keycloak E2E로 대체 검증(정직 기록). 루프: 3.1 JWT 보안 2건, 3b low 3건, 4 테스트조임 1건.

## 최종 전체 브랜치 리뷰 (opus) + 수정

- **opus 홀리스틱 리뷰**: 판정 **MERGEABLE-WITH-FIXES**, Critical 0. 120 단위+mypy 실행 확인. 보안 견고·JWT 정합·누출 0·예외변환 균일·**Java 학습 4개 반영 확인**(ValidatedToken·aud 포함검사·마스킹·auth-code+PKCE).
- **G5 Codex**: 이 세션 지속 타임아웃 → opus 리뷰 + Claude 리뷰어(전 태스크, 실제 테스트 실행) + 실제 Keycloak E2E로 대체.
- **수정** (ac172b0, 97a14e8, b8cbf94): I.1 미배선 `connect_timeout` 제거(no-op 옵션, Java tlsVerification과 평행) · I.2 JWKS 키회전 복원력(`TokenSignatureError`, 서명실패만 certs 재조회·재시도) · M.1 짧은 시크릿(len<8) 마스킹 강화. + 문서 동기화(spec/plan connect_timeout·캐시범위).
- **최종 게이트**: 단위 124 + mypy + 통합(재검증) — 아래 종합 참조.

**✅ Python SDK 병합 준비 완료.**

---

## async 변형 (keycloak_sdk.aio) — feature/python-async

- **배치1 (Task1 기반 + Task2 AsyncAuthClient)**: 874be96,a623c53 + fix ff89265. 리뷰어 SPEC✅/Approved(실제 RSA 키회전 라운드트립으로 validate 검증). 루프🔁1: sync 패리티(issued 타임스탬프) + JWKS 동시성 단일화(asyncio.Lock, 동시 1회/강제 2회 증명) + 문서.
- **배치2 (Task3 admin)**: 13ca1c5. 78 async admin 테스트, 커버리지 100%/100%(acall+5파사드; AsyncAdminClient omit), 오류경로 특정 예외 단언. acall이 sync translate 재사용. 컨트롤러 리뷰 CONFIRMED.
- **배치3 (Task4 AsyncKeycloakClient + Task5 async E2E + Task6 문서)**: f60eb1e,ff3ccee,e654685. aio/client.py 100%/100%, **통합 11/11(async 5 첫 시도 통과)**.
- **종합**: 단위 216(sync 129 + async 87) + 통합 11(sync 6 + async 5) = **227**(pytest --collect-only 실측). 로직 커버리지 100%(`--cov-fail-under=100` 강제), mypy strict(27파일), ruff clean(보안 S 포함 확장 룰셋)·ruff format. **sync API 무회귀**. (이후 보안 감사 후속으로 단위 +8 → **224 / 총 235**, 아래 참조.) sync `JwtValidator`·값타입·예외·config 재사용 → 보안 하드닝 자동 일관. async E2E 버그 0.
- **G5 Codex**: 세션 지속 타임아웃 → Claude 리뷰어 + 실제 Keycloak async E2E 대체.

---

## 보안·캡슐화 정밀 감사 후속 (2026-07-03) — 레드팀 다중에이전트 + 적대적 검증

- **방법**: 5개 관점(시크릿·JWT우회·은닉성/캡슐화·TLS/SSRF/DoS·동시성/의존성) 병렬 finder가 실제 Java+Python 코드를 읽고, 각 발견을 적대적 검증(반증 시도)으로 필터. 17건 생존(반박 0, critical/high 보안결함 0 — 인증우회·시크릿 로깅·alg 혼동 없음). HIGH 2건은 컨트롤러가 코드로 직접 재확인.
- **조치(전체 + 은닉성 문서 정합)**:
  - 🔴 **HIGH 자원누수(async)**: `AsyncAuthClient.aclose()` 신설(httpx AsyncClient 정리) + `AsyncKeycloakClient.aclose()`가 auth도 정리. sync도 `AuthClient.close()`/`KeycloakClient.close()` 동형 추가.
  - 🔴 **HIGH 타임아웃 무력화(Java admin)**: `AdminClient`가 `config`의 connect/read 타임아웃을 `KeycloakBuilder.resteasyClient(ClientBuilder…)`로 주입 — 무한대기·스레드고갈 차단. **AdminOpsIT 2/2로 E2E 재검증**.
  - 🟠 **Medium DoS 증폭(Python JWKS)**: `jwt.py`가 kid미해결(`InvalidKeyIdError`→신규 `TokenKeyError`)과 서명위조(`BadSignatureError`→`TokenSignatureError`)를 구분 — 위조 토큰은 재조회 안 함. `_load_jwks(force)`에 최소재조회간격 rate-limit(kid 변조 공격 상한). sync `_load_jwks`에 `threading.Lock` 추가.
  - 🟡 하드닝: mask 완전 불투명(접두 유출 제거, 양 언어), `ValidatedToken.claims` 읽기전용(`MappingProxyType`, Java unmodifiableMap 동형), `read_timeout` 0-붕괴 가드(`max(1,round)`), `joserfc>=1.7,<2` 상한.
  - 🟢 은닉성 문서 정합: CLAUDE.md §4에 "문서화된 은닉성 예외"(Java admin representation 타입·저수준 주입 지점) 명문화 + char[] 위생 경계 정직화(재래핑 대신 문서화 — 재설계 비용 과다).
- **게이트**: Python ruff(확장)·ruff format·mypy strict·pytest **224 단위(+8 보안 회귀테스트: kid미해결→TokenKeyError, 위조 무재조회, 재조회 rate-limit, 세션 close, 읽기전용 claims, opaque mask) 커버리지 100%**. Java `mvn verify` **BUILD SUCCESS**(단위 117 + IT 6, JaCoCo 90/85 통과, AdminOpsIT E2E). PR #6.
- **G5 Codex**: 세션 지속 타임아웃 → 다중에이전트 적대적 검증(반박 라운드) + 컨트롤러 코드 재확인 + 실제 Keycloak E2E로 대체.
