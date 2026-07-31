---
paths:
  - "rust/**"
  - "harness/apps/rust/**"
  - "harness/install/consume/rust*"
  - ".github/workflows/rust-*.yml"
---

# Rust 규칙

## 툴체인 (빌드 명령)

Rust는 시스템 설치(MSRV 1.88, edition 2024)를 사용한다. **Windows 로컬 빌드는 VS2019 BuildTools MSVC 환경(`vcvars64.bat`)이 필요**하다(`ring`/`rsa` 등 네이티브 의존성 컴파일 — CI의 ubuntu-latest는 무관). 명령은 `rust/`에서 실행한다:
```bash
cd rust && cargo build --all-targets              # 빌드(examples/tests 포함)
cd rust && cargo fmt --all --check                # 포맷 검사
cd rust && cargo clippy --all-targets -- -D warnings  # 린트(0 경고 게이트)
cd rust && cargo test                              # 단위테스트 45개. Docker 불필요
cd rust && cargo test --test integration_test -- --ignored  # 통합 E2E 1개(Docker 필요 — testcontainers, 실제 Keycloak 26.6)
cd rust && cargo run --example quickstart           # QuickStart 예제 실행(Keycloak 필요)
```
- 단일 테스트: `cargo test <test_name>` (예: `cargo test rejects_none_alg`)
- 커버리지 게이트(로직 모듈 라인 ≥90%, 네트워크 경계 omit): `rustup component add llvm-tools-preview` → `cargo install cargo-llvm-cov --locked` → `cargo llvm-cov --ignore-filename-regex '(auth|admin|client)\.rs' --fail-under-lines 90` — **실측 96.48%**(993줄 중 35줄 미실행; 파일별 `oidc.rs` 100%·`jwks.rs` 97.99%·`jwt.rs` 97.42%·`error.rs` 96.43%·`config.rs` 96.19%·`token_provider.rs` 95.30%·`tokens.rs` 86.44%. 2026-07-31 CI 커버리지 게이트 잡 실측 — [verification-log-rust.md](../../docs/governance/verification-log-rust.md)의 수치는 SDK 구축 완료 시점(`79ecf76`)의 스냅샷이라 이 값과 다르다. 그 문서는 구축 이력이므로 갱신하지 않는다)
- ⚠️ **로컬 셸에서 정규식 인자(`(auth|admin|client)\.rs`)에 포함된 `|`가 셸/배치 파서에 파이프로 오인될 수 있다** — PowerShell에서 배치 래퍼를 거칠 때는 `--ignore-filename-regex="(auth|admin|client)\.rs"`처럼 값 전체를 하나의 인자로 묶거나, 정규식을 하드코딩한 전용 스크립트를 쓴다(CI의 YAML `run:` 블록은 셸이 다르므로 이 문제가 없다).
- ⚠️ **`cargo-llvm-cov`는 `llvm-tools-preview` rustup 컴포넌트 미설치 시 인터랙티브 확인("Proceed? [Y/n]")으로 자동 설치를 시도한다** — 비대화형 셸(CI 잡, 자동화 스크립트)에서는 이 프롬프트가 응답을 받지 못해 **무기한 행(hang)** 된다(자식 프로세스 CPU 시간이 0에 가까운 것으로 진단 가능). `rustup component add llvm-tools-preview`를 먼저 명시 실행해 사전 설치하면 이후 호출이 프롬프트 없이 진행된다. CI의 `taiki-e/install-action@cargo-llvm-cov`는 이 설치를 자체 처리하므로 CI에서는 발생하지 않는다.
- 실제 crates.io 배포(`cargo publish`)는 로컬에서 실행하지 않는다 — `rust-v*` 태그 push 시 `.github/workflows/rust-release.yml`에서 `CARGO_REGISTRY_TOKEN` 시크릿으로 실행(사람 승인 게이트). 체크아웃 직후 태그↔`rust/Cargo.toml` `version` 정합성 가드가 돌고(추출 실패도 실패로 취급), 발행 전 게이트로 통합 E2E 잡이 `needs:`에 들어간다
- 크레이트명 `keycloak-sdk`(루트 모듈 `keycloak_sdk`), MSRV 1.88(edition 2024 + let-chain 문법 요구 — `jwks.rs`의 `if let ... && let ...`). CI 매트릭스는 1.88(MSRV 회귀 방지)·stable.

## 게차

- ⚠️ **(Rust) `search_users`는 `max=20`·`exact=true`·`first=0`을 하드코딩한다 — 21번째 사용자를 볼 방법이 파사드에 없다.** 오프셋·페이지 크기·매치 모드가 전부 리터럴이라(`admin.rs:106-115`) 소비자는 결과가 잘렸다는 사실조차 알 수 없다. 다른 여덟 언어는 `first`/`max`를 노출한다. 이름이 동작을 오해하게 만드는 유일한 지점이므로 배포 전에 파라미터화를 판단할 것 — 지금은 `raw().realm_users_get(...)`이 유일한 우회로다.
- ⚠️ **(Rust) 라이브러리 크레이트에서 정확 핀(`=`)을 쓰지 말 것 — 소비자 의존성 해소를 하드 실패시킨다.** cargo는 semver 호환 요구를 하나의 버전으로 통일하므로 `keycloak = "=26.6.2"`처럼 박아두면, 같은 트리에서 `keycloak 26.6.3`(또는 `openidconnect 4.0.2`·`jsonwebtoken 11.0.1`)을 요구하는 다른 크레이트와 만족 가능한 조합이 없어 소비자 빌드가 실패한다 — 소비자에게 우회수단이 없고 우리가 새 버전을 내야만 풀린다. 그래서 셋 다 범위 요구이되 **연산자는 다르다**: `openidconnect "4.0.1"`·`jsonwebtoken "11.0.0"`은 평범한 semver 크레이트라 **캐럿**, `keycloak`은 **틸드 `"~26.6.2"`**(`>=26.6.2, <26.7.0`)다 — 이 크레이트의 버전은 semver가 아니라 **Keycloak 서버 라인을 추종**해서 "26.7"이 곧 Keycloak 마이너 업그레이드이고, 실제로 그 경계에서 reqwest feature 구성이 재편된 전례가 있다(우리가 의존하는 `reqwest12` feature의 존속이 보장되지 않는다). 대신 틸드는 트리 안에서 `keycloak 26.7`을 요구하는 소비자와는 여전히 충돌하므로, 그때는 아래 게차를 재확인하고 우리가 의도적으로 상향한다.
- ⚠️ **(Rust) 커밋된 `rust/Cargo.lock`은 *우리* 빌드만 재현 가능하게 한다 — 소비자에게는 닿지 않는다.** cargo는 의존 크레이트의 lockfile을 무시하므로(lockfile은 최상위 패키지의 것만 쓰인다) 커밋된 lock(318 패키지 — `rust/.gitignore`에서 `Cargo.lock` 제거)이 고정하는 것은 CI·로컬 개발·`--locked` 빌드뿐이고, 소비자는 자기 lockfile로 스스로 고정한다. 즉 다운스트림을 실제로 보호하는 것은 lockfile이 아니라 **위의 범위 선택**이다. 세 크레이트는 reqwest 메이저 정렬·typestate 제네릭·`Validation` 필드가 버전 간 깨지기 쉬운 표면이므로 **메이저/마이너 상향은 lockfile 갱신 + 아래 게차 재확인을 동반해 수동으로** 한다.
- ⚠️ **(Rust) `keycloak` crate와 `openidconnect`는 reqwest 메이저를 정렬해야 함** — openidconnect 4.0.1이 reqwest 0.12 고정, `keycloak` crate는 `reqwest12` feature(`default-features=false`) 명시해야 같은 `reqwest::Client` 공유(안 맞으면 컴파일 실패, `Cargo.toml` 주석 명문화).
- ⚠️ **(Rust) admin 파사드의 공개 시그니처가 foreign 타입이라 재노출이 없으면 게시된 퀵스타트가 컴파일되지 않는다** — `keycloak::types`의 5종 representation을 `keycloak_sdk::types`로 미러 재노출하고, `AdminClient::raw()` 반환 타입을 이름 붙이는 데 필요한 `KeycloakAdmin`·`SdkTokenSupplier`와 저수준 ctor가 받는 `reqwest`를 크레이트 루트에서 재노출한다(`src/lib.rs`). 재노출이 없으면 crates.io 소비자가 `keycloak`/`reqwest`를 자기 `Cargo.toml`에 버전까지 맞춰 직접 추가해야만 admin을 호출할 수 있다. 새 공개 시그니처에 foreign 타입을 들이면 재노출도 같이 늘려야 한다(§4(b) 문서화된 은닉성 예외).
- ⚠️ **(Rust) `openidconnect`의 `CoreClient`는 6개 엔드포인트 typestate 제네릭** — auth/introspection/token만 `EndpointSet`으로 타입별칭(`KcOidcClient`) 만들어야 빌더가 `?` 없이 호출 가능. id_token은 openidconnect 자체검증 대신 SDK `JwtValidator`가 access_token만 검증(의도된 설계, `CoreClient::new`엔 빈 `JsonWebKeySet`).
- ⚠️ **(Rust) `jsonwebtoken`의 `Validation` 기본값은 안전하지 않다** — `validate_nbf` 기본 false→true 강화, `leeway` 기본60초→`config.clock_skew`(30초)로 강화(45초-만료 토큰 거부 실증), `set_required_spec_claims(&["exp","iss","aud"])` 명시, `algorithms=[RS256]` 고정(`Algorithm`엔 `none` 변형 자체가 없어 구조적으로 거부).
- ⚠️ **(Rust) jsonwebtoken 11.0.0부터 기형 JWKS의 거부가 파싱 단계가 아니라 키 생성 단계에서 일어난다.** 11.0.0의 "JWKs with unknown key types are now deserializable" 변경 때문이다 — 10.x는 RSA 변형에 맞지 않는 키(예: `n`이 JSON 배열)를 만나면 `JwkSet` serde 역직렬화가 **통째로** 실패해 `JwksStore::fetch`가 `Transport`로 흡수했으나, 11.x는 그 키를 미지 키타입으로 역직렬화에 성공시키고 한 단계 뒤 `DecodingKey::from_jwk`가 거부해 `TokenValidation`이 된다. **거부 자체는 그대로라 fail-closed는 유지**되며, 오히려 세트 전체가 죽지 않는 쪽이 안전하다 — 10.x에서는 Keycloak이 realm에 EdDSA 등 우리가 모르는 키를 하나만 추가해도 같은 세트의 멀쩡한 RSA 키까지 못 써 **모든 검증이 죽는** 가용성 사고였다. 두 성질 모두 테스트로 고정돼 있다(`rejects_jwks_with_n_as_array`가 새 오류 계급을, `tolerates_unknown_kty_alongside_valid_key`가 관용성을). ⚠️ 이 오류 계급을 `Transport`로 되돌리려 `fetch` 뒤에 세트 검사를 넣지 말 것 — 그건 방금 얻은 관용성을 다시 버리는 것이다.
- ⚠️ **(Rust) JWKS rate-limit은 재조회 *결정 시점*에 stamp(Go/Python 동형).** `JwksStore::get_key`의 `refetch_gate`는 fetch 성공 후가 아니라 재조회 결정 순간 갱신 — IdP 장애로 fetch 실패해도 gate가 소모돼 장애창의 위조 kid 연속주입도 상한. 근거: `fetch_failure_still_stamps_gate_rate_limiting_next_lookup`.
- ⚠️ **(Rust) 공유 `reqwest::Client`는 `redirect::Policy::none()`으로 리다이렉트 전면차단(SSRF 하드닝)** — 예상 밖 3xx가 내부망을 가리켜도 자동추적 안 함. auth·admin·JWKS 전부 이 공유 클라이언트(타임아웃 주입됨) 재사용.
- ⚠️ **(Rust) MSRV 1.88** — `edition="2024"`+let-chain 문법이 요구하는 최소버전. CI 매트릭스는 1.88(회귀방지)·stable 둘 다 검증. 근거: `jwks.rs`의 `get_key`·`token_provider.rs`.
- ⚠️ **(Rust) dev-dep `testcontainers 0.27.3`은 pre-1.0** — 언어별 편의모듈 없어 `GenericImage` 베이스로 이미지·포트·헬스체크 직접 조립(Go `testcontainers-go`와 동일 이유).
- ⚠️ **(Rust) RUSTSEC-2023-0071(rsa crate Marvin Attack)은 무영향** — `rsa`는 dev-dep로 테스트 키생성에만 사용, advisory는 개인키 복호화 타이밍 사이드채널이나 SDK 런타임은 서명검증만 수행. `cargo audit`는 CI 미배선(Task12 스코프 밖). 근거: `jwt.rs`의 JWKS 공격 프로브 픽스처.
- ⚠️ **(Rust) 로컬 Windows 빌드는 VS2019 BuildTools MSVC 환경 필요**(`ring`·`rsa` 네이티브 컴파일 — `vcvars64.bat` 소싱 셸에서 cargo 실행. CI ubuntu-latest는 무관).
- ⚠️ **(Rust) admin 파사드는 캐싱 `ClientCredentialsTokenProvider`를 쓴다 — 무캐시 `AuthClient` 직접주입 아님(`79ecf76`)** — 직접 주입하면 admin 호출마다 토큰재발급으로 §4 캐시/single-flight 불변식(6개 자매SDK 준수) 위반. 공유 `http`는 재사용하되 admin 전용 provider 인스턴스 별도생성. 같은 커밋에서 `config.scopes`를 token-provider+authorization URL 양쪽에 threading(이전 `"openid"` 하드코딩 버그).
