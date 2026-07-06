# 검증 로그 — Rust SDK

[AI 거버넌스 프레임워크](ai-governance-framework.md)에 따른 Rust SDK(`keycloak-sdk`, crates.io) 태스크별 정량 검증 기록. 브랜치 `feature/rust-sdk`(아직 `main` 미병합, PR 예정).

**툴체인**: 시스템 설치 Rust(MSRV **1.88**, edition 2024) + `cargo-llvm-cov`(커버리지). ⚠️ **Windows 로컬 빌드는 VS2019 BuildTools MSVC 환경(`vcvars64.bat`)이 필요**하다 — `ring`(rustls 암호 백엔드)·`rsa`(dev-dependency) 등 네이티브 컴파일 의존성 때문(CI의 ubuntu-latest는 무관). 명령은 `rust/`에서: `cargo build --all-targets` / `cargo fmt --all --check` / `cargo clippy --all-targets -- -D warnings` / `cargo test` / `cargo test --test integration_test -- --ignored`(Docker 필요) / `cargo llvm-cov --ignore-filename-regex '(auth|admin|client)\.rs' --fail-under-lines 90`.

**게이트**: G1 정적분석/스타일(`cargo clippy -D warnings` 0 경고·`cargo fmt --check`) · G2 단위테스트(cargo test) · G3 커버리지(`--ignore-filename-regex`로 네트워크 경계 `auth.rs`/`admin.rs`/`client.rs` omit, 로직 모듈 라인 ≥90%) · G4 스펙리뷰(§4 언어중립 계약과의 동형성) · G5 교차검증(태스크별 리뷰 루프 + 보안 하드닝 리뷰) · G6 보안(JWT 강화·JWKS DoS-safe·마스킹·경계 예외변환·SSRF).

> **실행 방식**: 승인된 WBS(12태스크: scaffold → error → config → tokens/oidc → token_provider → jwks → jwt → auth → admin → client → integration → CI/docs) → 태스크별 TDD(실패 테스트 → 구현 → 통과) + 계층별 커밋 + 태스크 직후 소규모 리뷰 루프. Task 7(JwtValidator, 보안핵심)은 5개 공격 프로브(alg-confusion HS256/RS256-spoofed-HMAC·`none`·iss superstring·aud substring·future nbf) + 후속 리뷰로 malicious-JWKS 프로브 2개(`n` 배열·`n` invalid-base64) + clock-skew 경계 테스트를 추가 강화.

---

## 딥리서치 (착수 전) — 라이브러리 API 확정

설계 스펙([2026-07-06-keycloak-rust-sdk-design.md](../superpowers/specs/2026-07-06-keycloak-rust-sdk-design.md)) 단계에서 아래를 **확정**(구현 중 재확인 불필요):

- **`keycloak` crate `=26.6.2`**(admin, kilork 유지): 자동생성 representation struct(`keycloak::types::*`) + `KeycloakAdmin` 타입드 클라이언트. ⚠️ 기본 HTTP 백엔드가 `openidconnect`의 reqwest 0.12 고정과 어긋나므로 **`reqwest12` feature**(`default-features = false`)로 명시 정렬해야 두 크레이트가 같은 `reqwest::Client` 타입을 공유한다(안 맞추면 컴파일 실패 — 스캐폴딩 단계에서 확정). `KeycloakTokenSupplier` trait(`#[async_trait]`)로 토큰 공급자를 주입받으므로, SDK의 `TokenProvider`를 어댑트하는 `SdkTokenSupplier`가 admin↔auth의 유일한 접착 지점이 된다. `keycloak::KeycloakError`(`HttpFailure{status,..}`/`ReqwestFailure`)는 경계에서 SDK `KeycloakError`로 변환(`ReqwestFailure`는 네트워크 실패이므로 `Transport`로, `HttpFailure`는 상태코드로 분기).
- **`openidconnect` `=4.0.1`**(auth, ramosbugs 유지): RP(Relying Party) 플로우 — Authorization Code+PKCE(S256)·client-credentials·refresh·introspect. ⚠️ `CoreClient`는 6개 엔드포인트 typestate 파라미터(`HasAuthUrl`/`HasDeviceAuthUrl`/`HasIntrospectionUrl`/`HasRevocationUrl`/`HasTokenUrl`/`HasUserInfoUrl`)를 갖는 제네릭이라, auth/introspection/token만 `EndpointSet`으로 명시한 구체 타입 별칭(`KcOidcClient`)을 만들어야 exchange 빌더가 `?` 없이 호출 가능(infallible)해진다. id_token 자체 검증은 하지 않음(SDK의 강화 `JwtValidator`가 access_token을 검증하므로 `CoreClient::new`에 빈 `JsonWebKeySet`을 전달) — 단일 유지자·저빈도 릴리스라 버전은 정확 핀(`=`).
- **`jsonwebtoken` `=10.4.0`**(jwt, RS256 검증 프리미티브): ⚠️ `Validation` 기본값이 안전하지 않다 — `validate_nbf` 기본 `false`(강화: `true`), `leeway` 기본 60초(강화: `config.clock_skew`=30초), `required_spec_claims`는 기본 `exp`만 포함할 수 있어 `["exp","iss","aud"]`로 명시 확장. `Algorithm` enum에 `none` 변형이 없어 `alg:"none"` 헤더는 `decode_header` 단계에서 구조적으로 거부된다(런타임 체크 불필요). `&$headers`류 out-파라미터 문제(PHP firebase/php-jwt와 달리)는 없음 — `decode_header`가 검증 전에 독립 호출 가능.
- **DoS-safe JWKS는 라이브러리에 없어 자체 구현**(`JwksStore`): kid→JWK 캐시(캐시 히트=네트워크 0) · 미해결 kid만 rate-limited 재조회 · single-flight(`tokio::sync::Mutex`) · **rate-limit gate는 재조회 결정 시점에 stamp**(Go `forcedAt`/Python `_jwks_forced_at` 동형 — IdP 장애로 fetch가 실패해도 gate 소모).
- **기각**: 없음(별도 오픈소스 라이브러리 대안 조사보다 `keycloak`/`openidconnect`가 이미 활발히 유지되는 유일 후보로 확정됨 — 로드맵 문서의 사전 조사 단계에서 결정).

## 계층별 구현 (Task 1~11)

각 태스크 TDD(실패 테스트 → 구현 → 통과) 후 계층별 커밋. G1(정적분석/스타일)·G2(테스트)·G3(커버) 각 태스크 통과.

| Task | 커밋 | 내용 | G1 | G2 | G3 |
|---|---|---|---|---|---|
| 0 | `cf28024`, `e9c52ed` | 설계 스펙 + WBS(12태스크) | — | — | — |
| 1 | `c80c75d` | 스캐폴딩(`Cargo.toml` — `keycloak-sdk`·edition 2024·`rust-version 1.88`·reqwest 0.12 전역 정렬·빈 모듈) | ✅ | — | — |
| 2 | `21619c8` | `KeycloakError` enum(thiserror) — Config/Auth/Transport/Admin(NotFound/Conflict/Forbidden/Other)/TokenValidation + `from_admin_status` | ✅ | ✅ (2) | ✅ |
| 3 | `bf19801` | `KeycloakConfig`(불변·검증·후행슬래시 제거·수동 Debug 마스킹·기본값) | ✅ | ✅ (3, 누적 5) | ✅ |
| 4 | `6457ce9` | 값타입 `TokenSet`/`ValidatedToken`/`IntrospectionResult`/`AuthorizationRequest`(수동 Debug 마스킹) + `OidcEndpoints` | ✅ | ✅ (4, 누적 9) | ✅ |
| 5 | `abfbcb9` | `TokenProvider` trait(async, `#[async_trait]`) + `ClientCredentialsTokenProvider`(캐시·single-flight·오류변환) | ✅ | ✅ (2, 누적 11) | ✅ |
| 6 | `e314055` + `d305813` | `JwksStore` — DoS-safe JWKS(kid 캐시·미해결만 재조회·rate-limit·single-flight) + rate-limit gate를 재조회 *결정 시점*에 stamp(회귀, Go/Python 동형) | ✅ | ✅ (3, 누적 14) | ✅ |
| 7 | `1cb2429` + `6eb0be4` | `JwtValidator` 자체강화(RS256 핀·`none` 구조적 거부·iss 정확·aud 포함·exp 필수·nbf·클록스큐) + 공격 프로브 7 + malicious-JWKS 프로브 2(`n` 배열·`n` invalid-base64) + clock-skew 경계 1 | ✅ | ✅ (15, 누적 29) | ✅ |
| 8 | `bc446e0` | `AuthClient` — openidconnect 래핑(수동 EndpointSet typestate·PKCE S256) + introspect/logout 손수 + `TokenProvider` 구현 | ✅ | ✅ (1, 누적 30, omit — 네트워크 경계) | — |
| 9 | `cecba11` + `1cac11c` | `AdminClient` — keycloak crate 래핑 + `SdkTokenSupplier` 어댑터 + `map_admin`(u16 경계변환) + 5 리소스(users/clients/realms/roles/groups) 완성 + `raw()` | ✅ | ✅ (1, 누적 31, omit — 네트워크 경계) | — |
| 10 | `709896c` | `KeycloakClient` 통합 진입점(공유 reqwest 1개 — SSRF `redirect::none`·타임아웃·TLS, auth 즉시·admin 주입) | ✅ | ✅ (1, 누적 32, omit — 네트워크 경계) | — |
| 11 | `a27fc3b` + `45086e9` | 통합 E2E(testcontainers, 실제 Keycloak 26.6 — client-credentials→validate→introspect→user/client/role/group CRUD→realm CRUD(master-admin)→raw→delete→NotFound) | ✅ | ✅ IT(1, `#[ignore]`) | — |
| 12 | (본 커밋) | rust-ci(매트릭스 1.88/stable·clippy·llvm-cov 게이트·Docker 통합잡)·rust-release(crates.io, human-gated)·`examples/quickstart.rs`·문서 | ✅ | ✅ | ✅ |

### 태스크별 리뷰 루프 (Loops)

- **Task 6**(`d305813`): 리뷰어가 `JwksStore::get_key`의 rate-limit gate가 fetch **성공 후**에만 stamp되는 초기 구현을 포착 — IdP 장애창(fetch 실패)에서는 gate가 unset으로 남아 재조회 rate-limit이 무력화됨(Go/Python이 이미 겪은 동일 클래스 결함). 재조회를 **결정한 시점**(fetch 시도 직전)에 stamp하도록 수정 + 회귀테스트(`fetch_failure_still_stamps_gate_rate_limiting_next_lookup`)로 certs 엔드포인트 히트 수를 정확히 카운트해 증명(2회만 — 초기 로드 + 1회 게이트된 재조회, 3회째는 rate-limit).
- **Task 7**(`6eb0be4`): 보안 하드닝 리뷰(Important+Minor)로 2건 보강 — (1) 악성 JWKS 클래스 2종(`n`이 JSON 배열 → `JwkSet` serde 역직렬화 실패를 깨끗한 `Transport` 오류로 흡수하는지, `n`이 문법적으로 유효하나 base64url이 아님 → `DecodingKey::from_jwk` 실패를 깨끗한 `TokenValidation` 오류로 흡수하는지)의 **panic-vs-clean-Err** 경계 테스트 추가(PHP 자매 구현에서 이 클래스가 Critical로 실제 발견된 전례를 선반영). (2) 클록 스큐 경계 테스트(`exp`가 45초 전 — leeway=60이면 통과했을 토큰을 config leeway=30에서 거부함을 실증) + 오류 메시지 sanitize(`kind_str()`로 `jsonwebtoken::errors::Error`의 원문 대신 짧은 분류 문자열만 노출 — 내부 구현 세부 누출 방지).
- **Task 9**(`1cac11c` 크로스태스크): Task 9 최초 커밋(`cecba11`)은 users/clients만 구현했고, 스펙 §admin(users/clients/realms/roles/groups 5리소스 동형)과의 정합을 위해 realms/roles/groups를 완성하는 후속 커밋을 별도로 커밋(C# sibling과 동형 — WBS 문서(`a27fc3b`)로 Task 11 통합 시나리오도 5리소스 전체로 확장).
- **Task 11**(`45086e9`): 실제 Keycloak 26.6에 대한 E2E에서 **SDK 코드 결함 0건** 발견(7번째 언어로 선행 6개 SDK의 게차 — JWKS DoS-safe rate-limit stamp 시점, admin representation 은닉성 예외, reqwest 정렬 등 — 가 설계 단계에 이미 선반영됨). 발견된 것은 실 서버 동작 확인뿐: `POST /admin/realms`(신규 realm 생성)·`DELETE /admin/realms/{realm}`은 master-realm 권한 전용(realm 서비스계정 403) — C#/.NET SDK가 먼저 발견한 것과 동일한 Keycloak 서버 동작.

## G6 — 보안 불변식 (실증)

- **JWT 강화**(`JwtValidator`): RS256 alg 핀(`v.algorithms = vec![Algorithm::RS256]`, 헤더 `alg` 미신뢰) · `none`/미서명 구조적 거부(`Algorithm` enum에 `none` 변형 부재) · `iss` 정확일치(`set_issuer`, 접두/상위문자열 거부) · `aud` 집합 포함검사(`set_audience`, 부분문자열 거부) · `exp` 필수(`required_spec_claims`) · `nbf` 강화(`validate_nbf=true`, 라이브러리 기본 false) · 클록 스큐(`leeway=30`, 라이브러리 기본 60) · 악성 JWKS(`n` 배열/invalid-base64)를 panic 없이 `Transport`/`TokenValidation`으로 깨끗이 흡수. 15개 단위테스트(7 정상+거부 스모크 + 5 공격 프로브 + 2 악성-JWKS + 1 클록스큐 경계)로 실증.
- **JWKS DoS-safe**(`JwksStore`): kid→JWK 캐시(캐시 히트=네트워크 0) · 미해결 kid에만 재조회(정확히 1회) · rate-limit(연속 미해결 재조회 억제, gate는 재조회 *결정 시점*에 stamp — IdP 장애창에서도 유효) · single-flight(`tokio::sync::Mutex`로 동시 미스 직렬화). 위조 kid 스팸에 의한 미인증 DoS 증폭 차단을 wiremock `expect(N)`/요청 카운트로 실증(3개 테스트).
- **SSRF/전송 하드닝**(`KeycloakClient`): 공유 `reqwest::Client`가 `redirect::Policy::none()`(리다이렉트 전면 차단) + `connect_timeout`/`read_timeout`(config 주입) + rustls(TLS 검증 기본 on)로 조립되어 auth·admin·JWKS 조회 전체에 재사용된다.
- **마스킹**: `KeycloakConfig`/`TokenSet`/`AuthorizationRequest`의 수동 `Debug` impl이 `client_secret`/`access_token`/`refresh_token`/`code_verifier`를 완전 불투명(`"***"`, 접두 노출 없음)하게 마스킹한다(derive 매크로는 전체 노출하므로 의도적으로 수동 구현). Rust는 문자열 소거가 표준 라이브러리 차원에서 보장되지 않아(`String`은 이동/복사 시 이전 버퍼가 즉시 지워지지 않음) 마스킹은 **심층방어**일 뿐 end-to-end 소거 보장이 아님(다른 6개 언어의 동일 근본 한계).
- **경계 예외 변환**: `keycloak::KeycloakError`(`HttpFailure`/`ReqwestFailure`) → `map_admin`으로 SDK `KeycloakError`(`Admin(NotFound|Conflict|Forbidden|Other)`/`Transport`) 변환, `openidconnect::RequestTokenError` → `map_token_err`로 `Auth{oauth_error}`/`Transport` 변환. `admin().raw()`가 유일한 의도적 탈출구(`&KeycloakAdmin<SdkTokenSupplier>` 반환).

## 최종 상태 (G1~G6 종합)

- **G1**: ✅ `cargo clippy --all-targets -- -D warnings` 0 경고 · `cargo fmt --all --check` 0 diff — `examples/quickstart.rs` 추가 후에도 재검증 완료(Task 12 시점).
- **G2**: ✅ 단위 **32** GREEN(`cargo test`) + 통합 **1**(`full_flow`, `#[ignore]` — 실제 Keycloak 26.6, testcontainers) = **총 33**.
- **G3**: ✅ `cargo llvm-cov --ignore-filename-regex '(auth|admin|client)\.rs' --fail-under-lines 90` — **실측 로직 모듈 라인 커버리지 94.80%**(827줄 중 43줄 미실행, 게이트 ≥90% 통과, exit 0). 네트워크 경계(`auth.rs`/`admin.rs`/`client.rs`)는 통합테스트로 검증하고 커버리지 게이트에서 제외(다른 6개 언어와 동일한 정책). 파일별: `error.rs` 100.00% · `oidc.rs` 100.00% · `jwks.rs` 96.05% · `token_provider.rs` 95.97% · `jwt.rs` 94.26% · `config.rs` 93.85% · `tokens.rs` 87.93%(함수 커버리지가 라인보다 낮은 이유 — `Debug` 마스킹의 `finish_non_exhaustive()` 분기·`is_expired` 일부 경계값 조합 미실행).
- **통합**: ✅ testcontainers E2E **1** GREEN(client-credentials→validate[실 JWKS·RS256 강화검증]→introspect→user/client/role/group CRUD→delete→404→realm CRUD(master-admin)→`raw()` 탈출구). **SDK 코드 결함 0건**(7번째 언어 — 선행 6개 언어의 강화 설계·게차 학습이 선반영됨). 실서버 확인: `POST`/`DELETE /admin/realms`는 master-realm 권한 전용(C#/.NET이 먼저 발견한 것과 동일한 Keycloak 동작).
- **G4**: ✅ 설계 스펙 §4 언어중립 계약과 동형(계층: config→auth/jwt→admin→client, `admin`이 `auth`를 직접 모름·`TokenProvider` trait만 접착제, 예외 대신 `thiserror` 기반 `Result<T, KeycloakError>`, 값타입 필드명 snake_case). Rust 관용 편차(모듈=파일·trait 기반 추상화·admin representation 완전 재노출은 문서화된 예외로 허용)는 §4 허용.
- **G5**: ✅ 태스크별 소규모 리뷰 루프(위 Loops, Task 6/7/9) + Task 7 보안 하드닝 리뷰(공격 프로브 5 + 악성-JWKS/클록스큐 후속 2).
- **G6**: ✅ 위 "G6 — 보안 불변식" 절 참조.
- **배포**: 🔒 crates.io(`keycloak-sdk`, `cargo publish` — `CARGO_REGISTRY_TOKEN` 시크릿 필요), `rust-v*` 태그 push 대기(human-gated, 미실행). `feature/rust-sdk` → `main` PR도 미실행.

## 커버리지 실측 (Task 12)

`cargo-llvm-cov`(로컬 설치: `cargo install cargo-llvm-cov --locked`, `rustup component add llvm-tools-preview` 선행 필요)로 `cargo llvm-cov --ignore-filename-regex '(auth|admin|client)\.rs' --fail-under-lines 90`을 실행한 실측 결과(exit 0 — 게이트 통과):

```
Filename            Regions  Missed Regions   Cover   Functions  Missed Functions  Executed   Lines  Missed Lines   Cover
config.rs                97               5  94.85%           7                 1  85.71%        65             4  93.85%
error.rs                 32               5  84.38%           3                 0 100.00%        26             0 100.00%
jwks.rs                 264              12  95.45%          18                 1  94.44%       152             6  96.05%
jwt.rs                  596              32  94.63%          48                 1  97.92%       366            21  94.26%
oidc.rs                  50               0 100.00%           8                 0 100.00%        36             0 100.00%
token_provider.rs       165              12  92.73%          17                 4  76.47%       124             5  95.97%
tokens.rs                77              11  85.71%           6                 1  83.33%        58             7  87.93%
--------------------------------------------------------------------------------------------------------------------
TOTAL                  1281              77  93.99%         107                 8  92.52%       827            43  94.80%
```

- **결과: 로직 모듈 라인 커버리지 94.80%**(827줄 중 43줄 미실행) — 게이트 ≥90% **통과**(exit code 0).
- 네트워크 경계 3개 파일(`auth.rs`/`admin.rs`/`client.rs`)은 `--ignore-filename-regex '(auth|admin|client)\.rs'`로 제외(다른 6개 언어와 동일하게 통합테스트로 검증) — 위 표에 이 3개 파일이 나타나지 않음이 제외가 정확히 적용됐음을 확인해준다. 나머지 로직 모듈(`config.rs`/`error.rs`/`jwks.rs`/`jwt.rs`/`oidc.rs`/`token_provider.rs`/`tokens.rs`)의 32개 단위테스트 전체(`jwt.rs`의 15개 포함)가 실측 대상이다.
- ⚠️ **로컬 실행 함정**: `cargo-llvm-cov`가 `llvm-tools-preview` 컴포넌트 미설치를 감지하면 `rustup component add`를 인터랙티브 확인("Proceed? [Y/n]")으로 실행하려 시도한다 — 비대화형 셸(CI 잡, 자동화 스크립트)에서는 이 프롬프트가 답을 받지 못해 **무기한 행(hang)** 된다(본 세션에서 실제로 ~45분간 행 발생, `Get-Process`로 자식 프로세스 CPU 시간이 0에 가까운 것으로 진단). 해결: `rustup component add llvm-tools-preview`를 먼저 명시 실행해 컴포넌트를 사전 설치하면 이후 `cargo llvm-cov` 호출이 프롬프트 없이 바로 진행된다(CI의 `taiki-e/install-action@cargo-llvm-cov`는 이 컴포넌트 설치를 자체적으로 처리하므로 CI에서는 발생하지 않는다).

## 언어 간 비교 메모 (6개 선행 SDK 대비)

Rust는 Java/Python/Node/Go/C#/PHP 다음의 **7번째** 언어로, 앞선 언어들의 게차가 설계 단계에 선반영되어 통합테스트에서 **신규 SDK 코드 결함이 0건**이었다(PHP에 이어 두 번째 무결함 사례). 결합 규칙(`admin`이 `auth`를 모름, `TokenProvider` trait만 접착제)·JWT 자체강화(알고리즘 핀·`none` 구조적 거부·iss/aud/exp·nbf·DoS-safe JWKS rate-limit-at-decision-time)·마스킹·경계 예외변환이 6개 선행 SDK와 동형이다. Rust 고유의 실질적 편차는 (1) 예외 대신 `Result<T, KeycloakError>` + `thiserror`(Go의 error-값 관용과 유사하나 센티넬 대신 enum 매칭), (2) `openidconnect`의 typestate 제네릭이라는 컴파일타임 강제(다른 언어에 없는 표현력 — 엔드포인트 미설정 상태에서 exchange 빌더 자체가 호출 불가능하도록 타입이 막는다), (3) admin representation을 그대로 노출(Java/Node/Go/C#/PHP와 동일한 문서화된 은닉성 예외, Python만 plain dict), (4) 로컬 Windows 빌드에 VS2019 BuildTools MSVC 환경이 필요하다는 점(네이티브 암호 백엔드 `ring`/`rsa` 컴파일 — 다른 언어에는 없는 Rust 고유의 로컬 개발 마찰, CI의 ubuntu-latest는 무관).
