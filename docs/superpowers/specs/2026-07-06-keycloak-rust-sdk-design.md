# Keycloak Rust SDK 설계 (Design) — 7번째 언어

> <!-- doc-status: complete -->
> **✅ 완료 — 이 설계는 구현됐다. 기록으로 읽어라.** 여기 적힌 "할 것"은 이미 한 것이고, 결정의
> *근거*가 이 문서의 가치다. 지금 상태는 [CLAUDE.md](../../../CLAUDE.md) ·
> [문서 지도](../../README.md)에 있다.

- **날짜**: 2026-07-06
- **브랜치**: `feature/rust-sdk` (main 기준)
- **선행 정독**: [언어 중립 계약 §4](2026-07-02-keycloak-multilang-sdk-design.md) — **진실 원천** · [새 언어 추가 플레이북](../../guides/add-a-language-playbook.md) · 워크드 예제 [Go WBS](../plans/2026-07-04-keycloak-go-sdk-wbs.md)(sync·타입드 오류) · [PHP WBS](../plans/2026-07-06-keycloak-php-sdk-wbs.md)(직전 언어)

## 1. 배경과 목표

폴리글랏 Keycloak SDK의 **7번째 언어 = Rust**(로드맵 rank 5). 기존 6개 언어(Java·Python·Node·Go·C#·PHP)와 §4 언어중립 계약에 **동형(isomorphic)** — 계층 `config → auth → jwt → admin → client`. Rust는 **비동기 전용(async-only, tokio/reqwest)** — 래핑 대상 크레이트가 전부 async이고 Node/C#과 동형. 예외 대신 **`Result<T, KeycloakError>` + `thiserror` enum**(Go의 error 값 + 센티넬 관용과 유사, §4 허용).

**목표**: Java(123)·Python(235)와 동일 품질 — 자체강화 JWT 검증, 단위 + 실제 Keycloak 26.6 Testcontainers 통합테스트, `clippy -D warnings`·`rustfmt`, 커버리지 게이트. 실배포만 human-gated.

**비목표**: 동기 API(async-only), 새 API 설계(§4 구현), 실배포 실행.

## 2. 기반 크레이트 (딥리서치 확정 — 2026-07 웹검증)

착수 전 딥리서치(4개 웹검증 에이전트)로 유지보수·라이선스·MSRV·async API를 재검증해 확정.

| 계층 | 확정 크레이트 | 버전(핀) | 라이선스 | MSRV | 근거 |
|---|---|---|---|---|---|
| **admin** | `keycloak`(kilork) 래핑 | **=26.6.2** | MIT/Unlicense | 1.88 | Keycloak OpenAPI 자동생성 → **Users/Clients/Realms/Roles/Groups 전부 타입드**(C#보다 넓음). `KeycloakAdmin::new(url,token,client)`, `KeycloakTokenSupplier` trait(TokenProvider 접착). 서버버전 추종(핀) |
| **auth** | `openidconnect`(ramosbugs) 래핑 | **=4.0.1** | MIT | 1.65 | async(`reqwest` feature). discovery+AuthCode+PKCE(S256)+client-creds+refresh. ⚠️단일유지자·2년 stale(feature-complete)→핀·얇은 표면 |
| **jwt(보안핵심)** | `jsonwebtoken`(Keats) + 자체 JwksStore | **=10.4** | MIT | **1.88** | **순수 Rust(no OpenSSL)** `rust_crypto` 백엔드. `Validation`에 필요한 노브 전부, `Algorithm`에 `none` 없음(구조적 거부). JWKS 캐시/재조회는 자체 |
| HTTP | `reqwest` | **0.13.4**(rustls·**reqwest13**) | MIT/Apache | 1.85 | 공유 async 클라이언트. `keycloak` crate의 `reqwest13` feature와 정렬(단일 HTTP 스택) |
| 런타임 | `tokio` | **1.52**(rt-multi-thread·macros·time·sync) | MIT | 1.71 | `sync`로 토큰캐시·JWKS single-flight |
| 오류 | `thiserror` | **2.0** | MIT/Apache | — | `KeycloakError` enum 파생 |
| serde | `serde`/`serde_json` | 1 | MIT/Apache | — | representation·토큰응답 |
| async trait | `async-trait` | 0.1 | MIT/Apache | — | object-safe `TokenProvider`(dyn 주입용) |

**dev-deps**: `testcontainers` **0.27.3**(GenericImage) · `wiremock` **0.6**(HTTP 경계 목킹) · (선택) `rstest`.

**기각**: jwt의 `josekit`(네이티브 OpenSSL 의존·14개월 stale·pre-1.0). auth의 `oauth2`-단독(discovery/id_token 손수 필요 — openidconnect가 그 위 계층 제공).

**MSRV 워크스페이스 = 1.88**(+edition 2024). 로컬 툴체인 1.89.0로 충족. 전부 permissive(Apache-2.0 SDK와 호환 — MIT 표기는 NOTICE에).

## 3. 아키텍처

`rust/` 단일 크레이트 `keycloak-sdk`(Cargo). Rust 관용 모듈 레이아웃(Go 단일 패키지와 유사).

```
rust/
├─ Cargo.toml            # keycloak-sdk 0.1.0 · Apache-2.0 · rust-version="1.88" · edition="2024"
├─ src/
│  ├─ lib.rs             # 공개 재수출(pub use) + 크레이트 문서
│  ├─ config.rs          # KeycloakConfig(불변) + 검증 + 시크릿 마스킹(수동 Debug)
│  ├─ error.rs           # 🔴 KeycloakError(thiserror enum): Config·Auth·Transport·Admin(NotFound/Conflict/Forbidden/Other{status})·TokenValidation
│  ├─ tokens.rs          # TokenSet·ValidatedToken·IntrospectionResult·AuthorizationRequest(수동 Debug 마스킹)
│  ├─ token_provider.rs  # TokenProvider trait(async_trait) + ClientCredentialsTokenProvider(single-flight 캐시)
│  ├─ oidc.rs            # OidcEndpoints 조립(네트워크 없음)
│  ├─ jwks.rs            # JwksStore(tokio RwLock 캐시 + Mutex single-flight + rate-limit, 미해결 kid만 재조회)
│  ├─ jwt.rs             # JwtValidator(jsonwebtoken RS256 + JwksStore + alg핀·none·iss·aud·exp/nbf)
│  ├─ auth.rs            # AuthClient(openidconnect 래핑 + introspect/logout 손수) — TokenProvider 구현
│  ├─ admin.rs           # AdminClient(keycloak crate 래핑 + KeycloakTokenSupplier 어댑터) + raw()
│  └─ client.rs          # KeycloakClient(auth 즉시·admin 지연)
├─ tests/
│  ├─ integration_test.rs   # testcontainers GenericImage(실제 KC 26.6) #[ignore] + Docker
│  └─ testdata/it-realm-realm.json  # go/testdata 재사용
├─ examples/quickstart.rs
```

**계층별 책임:**

- **config** — `KeycloakConfig`(불변 struct, `Clone`). 필수값(`server_url`/`realm`/`client_id`) 누락 → `KeycloakError::Config`. 시크릿은 `String`이며 **수동 `Debug` impl로 마스킹**(derive는 노출). 타임아웃(connect/read)·클록 스큐(30s)·스코프(`openid`) 기본값.
- **error(🔴)** — `#[derive(thiserror::Error)] enum KeycloakError`. 변형: `Config(String)`·`Auth{message, oauth_error: Option<String>}`·`Transport(String)`·`Admin(AdminError)`(내부 `enum AdminError { NotFound, Conflict, Forbidden, Other{status: u16} }`)·`TokenValidation(String)`. 하위 크레이트 오류를 여기로 변환(`From`/`.map_err`).
- **tokens** — `TokenSet`(access_token·token_type·expires_in·refresh_token·id_token·scope·expires_at, `is_expired()`, 수동 Debug 마스킹)·`ValidatedToken`(subject·audience: Vec<String>·issuer·expires_at·issued_at·claims)·`IntrospectionResult`(active·username·client_id·claims)·`AuthorizationRequest`(url·state·code_verifier).
- **token_provider** — `#[async_trait] trait TokenProvider { async fn token(&self) -> Result<String, KeycloakError>; }` + `ClientCredentialsTokenProvider`(공유 reqwest로 client-credentials POST, 만료 전 캐시 재사용, tokio Mutex single-flight). §4 동형 core 추상화. admin은 이 trait로만 토큰을 받는다.
- **oidc** — `OidcEndpoints`: `{server_url}/realms/{realm}` 규약 URL 조립(issuer·token·authorization·introspection·end_session·jwks). 네트워크 없음.
- **jwks** — `JwksStore`: 공유 reqwest로 JWKS 조회, `tokio::sync::RwLock<Arc<JwkSet>>` 캐시. `get_key(kid)`: 캐시 히트=네트워크 0. **미해결 kid만** 재조회(`tokio::sync::Mutex`로 single-flight 코얼레스 + rate-limit `min_refetch`). 위조 서명은 재조회 유발 안 함. Go/PHP와 동형.
- **jwt(자체강화, 🔴)** — `JwtValidator`: `jsonwebtoken::decode_header`로 kid 추출 → JwksStore로 `Jwk` → `DecodingKey::from_jwk` → `Validation::new(Algorithm::RS256)`(alg 핀·헤더 alg 검증선택에 미사용)·`set_issuer`(정확)·`set_audience`(포함)·`validate_nbf=true`·`leeway=30`·exp 필수 → `jsonwebtoken::decode::<Claims>` → `ValidatedToken` 매핑.
- **auth(OIDC 래핑 + 손수)** — `AuthClient`: openidconnect `CoreClient`(discovery 또는 규약 조립)로 AuthCode+PKCE·client-creds·refresh. **introspection(RFC7662)·end_session은 공유 reqwest로 손수 POST**(openidconnect 커버 부분적·verbose — Go/C# 동형). `validate`는 JwtValidator에 위임. `AuthClient`가 `TokenProvider` 구현(client-credentials 소스).
- **admin(파사드 + raw())** — `AdminClient`: `keycloak::KeycloakAdmin`을 래핑. **`KeycloakTokenSupplier` 어댑터**로 우리 `TokenProvider`를 연결(admin이 auth 비의존, 접착은 TokenProvider). `users()/clients()/realms()/roles()/groups()` 메서드가 keycloak crate 호출을 감싸고 오류 경계 변환. `raw()`는 내부 `KeycloakAdmin`(generic get/post) 노출.
- **client(통합 진입점)** — `KeycloakClient`: `auth()`는 **즉시**(공유 reqwest·JwksStore·JwtValidator·AuthClient 1회 조립), `admin()`은 **지연**. 공유 reqwest 1개(SSRF `redirect::none()`·타임아웃·rustls)를 auth·jwks·admin에 주입.

**결합 규칙(§4)**: `admin`은 `auth`를 직접 알지 못한다 — `keycloak` crate의 `KeycloakTokenSupplier` trait에 우리 `TokenProvider`(AuthClient의 client-credentials)를 어댑터로 연결. JWT만 자체강화(openidconnect 내부 검증 미신뢰). 하위 오류는 경계에서 `KeycloakError`로 변환.

**문서화된 은닉성 예외**: (a) admin 파사드가 `keycloak::types::{UserRepresentation,ClientRepresentation,RealmRepresentation,RoleRepresentation,GroupRepresentation,...}`(serde 파생)를 데이터 모델로 노출(Java/Node/Go/C# 동형·재래핑 안 함). (b) `AdminClient::raw()`(내부 `KeycloakAdmin`), 저수준 주입 시임 — 정상 경로(`client.auth()/admin()`)는 노출 안 함.

## 4. 오류 경계 변환

모든 하위 크레이트 오류는 경계에서 `KeycloakError`로 변환(공개 API 누출 0):

- **admin(keycloak crate)**: `keycloak::KeycloakError::HttpFailure{status,...}` → `status`(u16)로 404→`Admin(NotFound)`·409→`Conflict`·403→`Forbidden`·기타→`Admin(Other{status})`; `ReqwestFailure`(timeout/connect/DNS) → `Transport`. **중앙 변환기 1곳**(Go `toSDKError` 동형).
- **auth(openidconnect)**: `RequestTokenError`(OAuth 오류) → `Auth{oauth_error}`; `DiscoveryError`·`ConfigurationError` → `Config`/`Transport`; 네트워크 → `Transport`.
- **jwt(jsonwebtoken)**: `errors::Error`(`.kind()`: InvalidSignature/ExpiredSignature/InvalidIssuer/InvalidAudience/ImmatureSignature(nbf)/MissingRequiredClaim/InvalidAlgorithm 등) → `TokenValidation`; JWKS `reqwest::Error` → `TokenValidation`/`Transport`.

## 5. 보안 불변식 (CI 강제)

- **JWT 자체강화**(플레이북 3단계):
  - **알고리즘 핀닝** — `Validation::new(Algorithm::RS256)`(RS256만). **헤더 alg는 kid 키선택에만, 검증 알고리즘 선택엔 절대 미사용**(alg-confusion 차단).
  - **`none`/미서명 거부** — `jsonwebtoken::Algorithm`에 `None` variant 자체가 없어 구조적 표현 불가(방어).
  - **issuer 정확 일치**(`set_issuer(&[iss])`) · **audience 포함**(`set_audience(&[client_id])` — 토큰 aud가 string/array 모두 수용).
  - **exp 필수**(`required_spec_claims`에 exp) + **nbf**(⚠️`validate_nbf` 기본 false → **true 설정**) + **클록 스큐 30s**(⚠️기본 60 → 30).
  - **DoS-안전 JWKS** — 위조 서명은 재조회 없음, **kid 미해결에만** 재조회, **rate-limit + single-flight**(tokio). Go/PHP 동형.
- **SSRF 하드닝** — 공유 `reqwest::Client`를 **`redirect::Policy::none()`**로 빌드(discovery/token/introspect/JWKS 리다이렉트 SSRF 차단 — openidconnect 문서 명시).
- **마스킹** — Rust `derive(Debug)`가 시크릿 노출 → `TokenSet`·`KeycloakConfig`에 **수동 `Debug` impl**로 access/refresh/secret을 `***`(완전 불투명). 단위 테스트로 강제.
- **TLS 기본 on**(rustls) · no-op insecure 옵션 금지 · **타임아웃 주입**(config connect/read → 공유 reqwest → auth·JWKS·admin 전부; 미주입=hung IdP 무한대기).
- **의존성 감사** — CI에 `cargo audit`. RUSTSEC-2023-0071(rsa Marvin)은 **개인키 복호화 이슈로 공개키 서명검증엔 무영향**(우리 RSA 연산은 verify뿐) — verification-log에 명시. 위반 시 `aws_lc_rs` 백엔드 스위치.

## 6. 툴체인·테스트·CI

- **MSRV 1.88**(+edition 2024). CI 매트릭스 **1.88(MSRV) + stable**(`dtolnay/rust-toolchain`).
- **린트/포맷**: `cargo clippy --all-targets --all-features -- -D warnings` · `cargo fmt --all --check`(CI 차단).
- **테스트**: `cargo test` + `#[tokio::test]`(async). 단위 = PKCE(S256)·설정검증/기본값·토큰파싱·만료/스큐·JWT강화(alg핀·none 불가·iss·aud[다중]·exp 필수·nbf)·**오류 경계 매핑**(404→NotFound 등)·마스킹·JWKS DoS-안전(위조 서명 재조회 안 함·미해결 kid만·rate-limit). HTTP 경계는 **`wiremock`**으로 목킹, JWT는 **자체 RSA 키쌍**으로 서명.
- **커버리지 게이트**: **`cargo-llvm-cov`**(소스기반·크로스플랫폼 — Windows 로컬+CI 동일; tarpaulin은 Linux 전용 배제) `--fail-under-lines 90`, 네트워크 경계 omit `--ignore-filename-regex '(auth|admin|client)\.rs'`. 로직 모듈(config·error·tokens·token_provider·oidc·jwks·jwt)이 게이트.
- **통합(Testcontainers)**: `testcontainers` **0.27.3** `GenericImage`(`quay.io/keycloak/keycloak:26.6`, `start-dev --import-realm`, `it-realm-realm.json` 재사용, WaitFor HTTP readiness). 전용 Keycloak 모듈 없음 → GenericImage(Go/PHP 동형). `#[ignore]` + 별도 Docker CI 잡으로 단위 실행은 Docker-free.
- **CI**: `.github/workflows/rust-ci.yml`(빌드+clippy+fmt+test+llvm-cov 게이트 + cargo audit, 1.88·stable 매트릭스 + Docker 통합잡) + `rust-release.yml`(`rust-v*` 태그 → `cargo publish`, `CARGO_REGISTRY_TOKEN` 시크릿, human-gated).
- **배포명** crates.io **`keycloak-sdk`**(사용가능·404 확인), 태그 `rust-v*`.

## 7. 테스트 패리티 매트릭스 (§4단계)

| 층위 | 시나리오(다른 언어와 동형) |
|---|---|
| **단위** | PKCE(S256) 생성 · 설정 검증/기본값 · 토큰 응답 파싱 · 만료·클록 스큐 · JWT 강화(alg핀·`none` 불가·iss 정확·aud 포함[다중]·exp 필수·nbf·스큐) · **오류 경계 매핑**(404→`Admin(NotFound)` 등) · 마스킹(수동 Debug) · JWKS DoS-안전(위조 서명 재조회 안 함·미해결 kid만·rate-limit) |
| **통합(Testcontainers, 실제 KC 26.6)** | client-credentials 토큰 발급 · `validate`(다중 aud 수용) · introspect · user/client CRUD · `raw()` 탈출구 · delete 후 조회 → `Admin(NotFound)` |

## 8. 게차(Gotchas) — 딥리서치 확정

- ⚠️ **`keycloak` crate는 서버버전 추종·정확 핀**(26.6.2 = KC 26.6). representation struct는 자동생성이라 KC 버전 간 필드가 변한다(누출되는 데이터 모델이므로 crate bump가 소비자에 semver-가시). 의존 필드는 실 KC 26.6로 검증(Java admin-client≠server 교훈 동형).
- ⚠️ **`keycloak` crate 오류는 status가 `u16`**(rich per-endpoint 아님) — 404/409/403 판별은 중앙 변환기 1곳에서 u16으로. `reqwest13` feature로 reqwest 0.13 정렬(불일치=이중 트리·TLS 분리).
- ⚠️ **openidconnect는 id_token만 검증·access token은 미검증**(OIDC상 불투명) → 우리 자체강화 validator가 유일 권위. openidconnect 내부 검증에 절대 의존 금지. 단일유지자·2년 stale → 정확 핀·얇은 표면(introspect/logout은 손수).
- ⚠️ **jsonwebtoken 기본값 함정**: `validate_nbf` 기본 false(→true), leeway 기본 60(→30), exp는 required_spec_claims에 있어야 강제. `Validation::new(RS256)`로 alg 명시(헤더 alg 미신뢰).
- ⚠️ **JWKS DoS-안전은 어떤 Rust 크레이트도 내장 안 함** — 캐시+미해결-kid-only 재조회+rate-limit+single-flight를 자체 구현(위조 kid마다 IdP 증폭 차단).
- ⚠️ **SSRF**: reqwest는 `redirect::Policy::none()` 필수(리다이렉트 따라가면 discovery/token/JWKS SSRF).
- ⚠️ **RUSTSEC-2023-0071(rsa Marvin)**: 개인키 복호화 사이드채널 — **공개키 서명검증(우리 용도)엔 무영향**. `cargo audit`가 잡으면 verification-log에 명시(또는 aws_lc_rs 스위치).
- ⚠️ **testcontainers 0.27은 pre-1.0**(GenericImage 빌더 API가 minor bump에 깨질 수 있음·전용 Keycloak 모듈 없음) — 정확 핀 + WaitFor를 KC 26 start-dev readiness에 맞춤(port-open 아님).
- ⚠️ **async-fn-in-trait vs async-trait**: native async fn in trait(1.75+)은 dyn 비호환 → `Box<dyn TokenProvider>` 주입 위해 **`async-trait`** 사용(object-safe).
- ⚠️ **Rust `derive(Debug)`가 시크릿 노출** — `TokenSet`/`KeycloakConfig`는 **수동 Debug**로 마스킹.

## 9. 완료 기준 (DoD)

- [ ] `rust/` 전 계층(config→auth→jwt→admin→client) 구현 + §4 동형(명명·계층·오류 enum·값타입·보안 불변식)
- [ ] 단위 테스트(§7 시나리오 전부) + 실제 KC 26.6 Testcontainers 통합테스트 GREEN
- [ ] 커버리지 게이트(로직 모듈 라인 ≥90%, 경계 omit) 통과 · `clippy -D warnings` · `cargo fmt --check` · `cargo audit`
- [ ] 자체강화 JWT 불변식 전부(alg핀·none·iss·aud·exp/nbf·DoS-safe JWKS) 단위 테스트로 고정 · 마스킹·SSRF·TLS·타임아웃 강제
- [ ] `rust-ci.yml`(매트릭스 1.88·stable + Docker 통합) + `rust-release.yml`(준비, human-gated) · 문서(getting-started Rust 섹션·README·CLAUDE.md·로드맵·verification-log-rust) 갱신
- [ ] 로컬 설치 경로(`cargo build`·`cargo test`·`examples/quickstart.rs`) 동작
