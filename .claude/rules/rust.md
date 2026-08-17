---
paths:
  - "rust/**"
  - "harness/apps/rust/**"
  - "harness/install/consume/rust*"
  - ".github/workflows/rust-*.yml"
---

# Rust 규칙

## 툴체인

시스템 설치. MSRV **1.88**(edition 2024 + let-chain 문법). CI 매트릭스는 1.88·stable.
⚠️ **Windows 로컬 빌드는 VS2019 BuildTools MSVC 환경(`vcvars64.bat`)이 필요하다**(`ring`·`rsa` 네이티브 컴파일 — CI ubuntu는 무관).

```bash
cd rust && cargo build --all-targets
cd rust && cargo fmt --all --check
cd rust && cargo clippy --all-targets -- -D warnings
cd rust && cargo test                                         # 단위. Docker 불필요
cd rust && cargo test --test integration_test -- --ignored    # 통합 E2E. Docker 필요(KC 26.6)
```

- 단일 테스트: `cargo test <test_name>`
- 커버리지(로직 라인 ≥90%, 네트워크 경계 omit): `rustup component add llvm-tools-preview` → `cargo llvm-cov --ignore-filename-regex '(auth|admin|client)\.rs' --fail-under-lines 90`. 실측 96.48%(993줄 중 35줄 미실행).
  - ⚠️ **`llvm-tools-preview`를 먼저 설치한다** — 없으면 `cargo-llvm-cov`가 인터랙티브 확인을 띄우고 비대화형 셸에서 **무기한 hang**한다(CPU 시간 0으로 진단).
  - ⚠️ PowerShell에서 정규식의 `|`가 파이프로 오인될 수 있다 — `--ignore-filename-regex="…"`로 값 전체를 묶는다.
- 배포는 `rust-v*` 태그 → `rust-release.yml`(사람 승인 게이트). 태그↔`Cargo.toml` 정합 가드 + 통합 E2E가 `needs:`에 있다.
- 크레이트 `keycloak-sdk`(루트 모듈 `keycloak_sdk`).

## 의존성 정책

- ⚠️ **라이브러리 크레이트에서 정확 핀(`=`)을 쓰지 않는다 — 소비자 의존성 해소를 하드 실패시킨다.** cargo는 semver 호환 요구를 하나로 통일하므로 `=26.6.2`로 박으면 같은 트리에서 26.6.3을 요구하는 크레이트와 만족 가능한 조합이 없고, 소비자에게 우회 수단이 없다.
- **연산자가 크레이트마다 다르다**: `openidconnect`·`jsonwebtoken`은 평범한 semver라 **캐럿**, `keycloak`은 **틸드 `~26.6.2`** — 이 크레이트의 버전은 semver가 아니라 **Keycloak 서버 라인을 추종**해서 "26.7"이 곧 서버 마이너 업그레이드이고, 그 경계에서 reqwest feature 구성이 재편된 전례가 있다.
- ⚠️ **커밋된 `Cargo.lock`은 소비자에게 닿지 않는다** — cargo는 의존 크레이트의 lockfile을 무시한다. lock이 고정하는 것은 CI·로컬·`--locked` 빌드뿐이고, 다운스트림을 실제로 보호하는 것은 위의 범위 선택이다. 메이저/마이너 상향은 lock 갱신 + 아래 게차 재확인을 동반해 **수동으로** 한다.
- ⚠️ **`keycloak` crate와 `openidconnect`는 reqwest 메이저를 정렬해야 한다** — `keycloak`에 `reqwest12` feature(`default-features=false`)를 명시해야 같은 `reqwest::Client`를 공유한다. 안 맞으면 컴파일 실패.
- dev-dep `testcontainers`는 pre-1.0이라 마이너에 파괴적 변경이 온다 — 범프 시 통합테스트를 반드시 돌린다. 핀은 루트 `CLAUDE.md` 의존성 표가 SSOT.
- RUSTSEC-2023-0071(rsa Marvin Attack)은 무영향 — `rsa`는 dev-dep 테스트 키 생성 전용이고 런타임은 서명 검증만 한다.

## 재노출 (§4(b))

⚠️ **admin 파사드의 공개 시그니처가 foreign 타입이라, 재노출이 없으면 게시된 퀵스타트가 컴파일되지 않는다.** `keycloak::types`의 representation 5종을 `keycloak_sdk::types`로 미러 재노출하고, `AdminClient::raw()` 반환 타입을 이름 붙이는 데 필요한 `KeycloakAdmin`·`SdkTokenSupplier`와 저수준 ctor가 받는 `reqwest`를 크레이트 루트에서 재노출한다. **새 공개 시그니처에 foreign 타입을 들이면 재노출도 함께 늘린다.**

## 라이브러리 게차

- ⚠️ **`search_users`의 `max`에 `Option`을 두지 않는다 — Keycloak은 미전송 시 조용히 100을 적용한다**(`Constants.DEFAULT_MAX_RESULTS`). `None`은 "무제한"이 아니라 "100에서 잘림"이고, 옵션이면 호출부에 상한이 보이지 않는다. "무제한"은 음수 `max`(-1)로 표현한다. 정확일치 단건은 `find_user_by_username`(`max=2`를 요청해 username 유일성 위반을 잘림과 구분하고 `Conflict`로 표면화 — `max=1`이면 둘을 구분할 수 없다).
- ⚠️ **`openidconnect`의 `CoreClient`는 6개 엔드포인트 typestate 제네릭이다** — auth/introspection/token만 `EndpointSet`으로 타입별칭(`KcOidcClient`)을 만들어야 빌더를 `?` 없이 호출할 수 있다. id_token은 openidconnect 자체검증 대신 SDK `JwtValidator`가 검증한다(의도된 설계).
- ⚠️ **`jsonwebtoken`의 `Validation` 기본값은 안전하지 않다** — `validate_nbf` false→true, `leeway` 60초→`config.clock_skew`(30초), `set_required_spec_claims(["exp","iss","aud"])`, `algorithms=[RS256]`(`Algorithm`에 `none` 변형 자체가 없어 구조적으로 거부).
- ⚠️ **jsonwebtoken 11.0.0부터 기형 JWKS 거부가 파싱이 아니라 키 생성 단계에서 일어난다**(`Transport` → `TokenValidation`). fail-closed는 유지되고, 미지 kty가 섞여도 세트 전체가 죽지 않는다 — 10.x에서는 모르는 키 하나가 멀쩡한 RSA 키까지 못 쓰게 만드는 가용성 사고였다. ⚠️ **이 오류 계급을 되돌리려 `fetch` 뒤에 세트 검사를 넣지 말 것** — 방금 얻은 관용성을 버리는 것이다.
- ⚠️ **JWKS rate-limit은 재조회 *결정 시점*에 stamp한다**(Go·Python 동형) — IdP 장애로 fetch가 실패해도 gate가 소모돼 장애 창에서의 위조 kid 연속 주입에도 상한이 걸린다.
- ⚠️ **공유 `reqwest::Client`는 `redirect::Policy::none()`으로 리다이렉트를 전면 차단한다**(SSRF 하드닝). auth·admin·JWKS 전부 이 클라이언트를 재사용한다.

## SDK 구조

- ⚠️ **admin은 캐싱 `ClientCredentialsTokenProvider`를 쓴다 — 무캐시 `AuthClient` 직접 주입이 아니다.** 직접 주입하면 admin 호출마다 토큰이 재발급돼 §4 캐시/single-flight 불변식을 깬다. 공유 `http`는 재사용하되 provider 인스턴스는 별도다.
- **admin 경계 변환은 `map_admin`이다** — `keycloak::KeycloakError`가 여기서 SDK 타입이 된다. `AuthClient`가 `TokenProvider`를 구현하고 `SdkTokenSupplier`가 그것을 crate의 `KeycloakTokenSupplier`로 어댑트한다. **두 단계가 §4 은닉의 전부라 어느 한쪽을 건너뛰면 foreign 타입이 샌다.**
- 다섯 리소스에 `update`/`list`가 없는 것은 결정이다 — `raw()`가 전부 도달하므로 릴리스 차단요소가 아니다(v0.2 대상).
