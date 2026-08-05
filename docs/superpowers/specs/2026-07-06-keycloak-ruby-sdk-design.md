# Keycloak Ruby SDK 설계 (Design) — 8번째 언어

> <!-- doc-status: complete -->
> **✅ 완료 — 이 설계는 구현됐다. 기록으로 읽어라.** 여기 적힌 "할 것"은 이미 한 것이고, 결정의
> *근거*가 이 문서의 가치다. 지금 상태는 [CLAUDE.md](../../../CLAUDE.md) ·
> [문서 지도](../../README.md)에 있다.

- **날짜**: 2026-07-06
- **브랜치**: `feature/ruby-sdk` (main 기준)
- **선행 정독**: [언어 중립 계약 §4](2026-07-02-keycloak-multilang-sdk-design.md) — **진실 원천** · [새 언어 추가 플레이북](../../guides/add-a-language-playbook.md) · 워크드 예제 [Rust 설계](2026-07-06-keycloak-rust-sdk-design.md)(직전 언어·자체강화 JWT) · [PHP 설계](2026-07-06-keycloak-php-sdk-design.md)(예외 기반·docker-CLI 통합) · [Go 설계](2026-07-04-keycloak-go-sdk-design.md)(sync·raw-REST admin)

## 1. 배경과 목표

폴리글랏 Keycloak SDK의 **8번째 언어 = Ruby**(로드맵 rank 6). 기존 7개 언어(Java·Python·Node·Go·C#·PHP·Rust)와 §4 언어중립 계약에 **동형(isomorphic)** — 계층 `config → auth → jwt → admin → client`. Ruby는 **동기 전용(sync-only)** — 래핑 대상 gem(`rack-oauth2`·`jwt`·`faraday`)이 전부 동기이고 Rails/Sinatra 소비자도 동기(Java/Go/PHP 동형). 오류는 Ruby 관용 **예외 계층**(`raise`/`rescue` — Python/Node/C#/PHP 동형, Go/Rust의 error-값 관용과 대비).

**목표**: Java(123)·Python(235)와 동일 품질 — 자체강화 JWT 검증, 단위 + 실제 Keycloak 26.6 통합테스트, `rubocop`·SimpleCov 커버리지 게이트. 실배포만 human-gated.

**비목표**: 비동기 API(sync-only), 새 API 설계(§4 구현), RBS/Sorbet 정적 타입(RuboCop+SimpleCov가 실용 패리티), 실배포 실행.

## 2. 기반 라이브러리 (딥리서치 확정 — 2026-07 웹검증)

착수 전 딥리서치(4개 웹검증 에이전트: auth·admin·jwt·툴체인/테스트/패키징)로 유지보수·라이선스·Ruby 3.x 호환·API를 재검증해 확정.

| 계층 | 확정 | 버전(핀) | 라이선스 | 근거 |
|---|---|---|---|---|
| **jwt(보안핵심)** | `jwt`(ruby-jwt) 래핑 + 자체 JwksStore | **`~> 3.2`**(3.2.0) | MIT | de-facto 표준(~779M dl·활발). `algorithms:['RS256']`이 서명검증 **前** none/alg-confusion 구조적 거부. 기본값 위험(HS256·exp 미필수·iss/aud off·leeway0)→전부 오버라이드. JWKS 캐시/rate-limit/single-flight는 로더 람다에 자체 |
| **auth** | `rack-oauth2`(nov) 래핑 + introspect/logout 손수 | **`~> 2.3`**(2.3.0) | MIT | nov(OIDF 인증 RP 저자)의 OAuth2/OIDC 클라이언트. 그랜트(client-creds 기본·authcode)+PKCE-S256 passthrough+revoke! 커버. **Faraday2 백엔드**(우리 HTTP 스택 정렬). introspection(RFC7662)·logout은 어느 라이브러리도 클라이언트측 미커버→Faraday 손수(Go/Rust/PHP 동형) |
| **admin** | **gem 없이 `faraday`로 Admin REST 직접 래핑** | — | — | `looorent/keycloak-admin`(v1.1.7·살아있음)은 §4 비호환: 자체 무캐시 토큰 라이프사이클(TokenProvider 주입 시임 없음)·bare-string 오류·deprecated `rest-client` 의존. → 5리소스 ~25 얇은 메서드 + raw(). 캐싱 provider를 bearer 미들웨어로 주입. C#/PHP raw-REST 선례 동형 |
| **HTTP** | `faraday` | **`~> 2.0`** | MIT | 공유 클라이언트(admin·introspect·logout·JWKS). follow_redirects 미들웨어 미장착=SSRF 하드닝, 타임아웃 주입. rack-oauth2의 백엔드와 동일 |
| 테스트 | `rspec` + `webmock` + `simplecov` + `rubocop`(+`rubocop-rspec`) | — | MIT | 라이브러리 gem 지배 관용. WebMock=네트워크 경계 목, SimpleCov 라인90/브랜치85 게이트, rubocop 린트 |
| 통합 | **docker-CLI 셸아웃**(실제 KC 26.6) | — | — | testcontainers-core는 stale 0.2.0(2024-02·pre-1.0)·docker-api가 Windows npipe 미지원 → 로컬+CI 동일 셸아웃(PHP 동형) |
| 감사 | `bundler-audit` | — | — | 의존성 취약점 CI 게이트 |

**dev-deps**: `rspec` · `webmock` · `simplecov` · `rubocop`+`rubocop-rspec` · `bundler-audit` · `rake`. JWT 테스트용 RSA 키쌍은 stdlib `openssl`로 생성(추가 gem 불요).

**기각**:
- auth의 `openid_connect`(nov) — `rack-oauth2`의 상위집합이나 런타임 deps 11개(activemodel 8.1·mail·tzinfo·swd·webfinger…)로 무겁고, 헤드라인 가치(id_token 검증·WebFinger/SWD discovery)가 우리에겐 **중복**(JWT는 별도 강화 계층·엔드포인트는 realm URL 조립). 클라이언트가 세션/Rack 결합은 아님(오해)이나 무게/중복이 문제.
- auth의 `oauth2`(pboling) — 가장 활발하나 PKCE 완전 수작업(passthrough 헬퍼 없음)·OIDC 비인식·revoke 없음·단일유지자 마이크로 gem 4개(snaky_hash/version_gem/anonymous_loader/auth-sanitizer) 공급망 표면. `rack-oauth2`가 커버리지·deps 청결도 우위.
- admin의 `looorent/keycloak-admin`·`imagov/keycloak`·`keycloak-ruby-client` — 어느 것도 공유 `TokenProvider` 주입을 지원 안 함(§4 캐싱 불변식 위반). 참조 구현으로만 활용.
- jwt의 `json-jwt`(nov·rack-oauth2 트랜지티브) — 저수준 API·alg 수동 전달·강화 스토리 약함. `jose`/`ruby-jose` — stale(2018→2024 갭). `jwe` — 암호화 토큰용(Keycloak access token은 서명 JWS라 무관).

**Ruby 버전**: **Ruby 4.0으로 메이저 상승**(4.0.0 2025-12-25·**4.0.5** 2026-05-20 현재 stable — 지식 컷오프 이후, ruby-lang.org 이중검증). 비-EOL: 4.0.x·3.4.x·3.3.x·3.2.x(3.1 EOL). gem CI 매트릭스가 대체로 3.4까지라 **로컬 dev는 3.4.x**(gem 호환 안정성), gemspec `required_ruby_version ">= 3.2"`(최광 비-EOL 도달). 전 의존이 pure Ruby → 네이티브 컴파일 툴체인 불요.

## 3. 아키텍처

`ruby/` 단일 gem `keycloak-sdk`(모듈 `KeycloakSdk`·require path `keycloak_sdk`). Ruby 관용 모듈 레이아웃.

```
ruby/
├─ keycloak-sdk.gemspec        # keycloak-sdk 0.1.0 · Apache-2.0 · required_ruby_version ">= 3.2" · rubygems_mfa_required
├─ Gemfile · Rakefile · .rubocop.yml
├─ lib/
│  ├─ keycloak_sdk.rb          # 공개 배럴 require + module KeycloakSdk + 크레이트 문서
│  └─ keycloak_sdk/
│     ├─ version.rb            # KeycloakSdk::VERSION
│     ├─ config.rb             # Config(불변 class·검증·후행슬래시 제거·inspect 마스킹·기본값)
│     ├─ errors.rb             # 🔴 Error 계층(§4)
│     ├─ masking.rb            # mask()
│     ├─ tokens.rb             # TokenSet/ValidatedToken/IntrospectionResult/AuthorizationRequest (Data.define + inspect 마스킹)
│     ├─ token_provider.rb     # TokenProvider(덕 인터페이스) + ClientCredentialsTokenProvider(캐시 + Mutex single-flight)
│     ├─ oidc_endpoints.rb     # OidcEndpoints 조립(네트워크 없음)
│     ├─ jwks_store.rb         # 🔴 JwksStore(Mutex 캐시·rate-limit·single-flight·미해결 kid만 재조회)
│     ├─ jwt_validator.rb      # 🔴 JwtValidator(ruby-jwt RS256 강화 + JwksStore 로더 람다)
│     ├─ auth_client.rb        # AuthClient(rack-oauth2 래핑 + introspect/logout 손수) — TokenProvider 구현
│     ├─ admin/
│     │  ├─ admin_client.rb    # AdminClient(Faraday conn·bearer 미들웨어·오류경계·raw())
│     │  ├─ users.rb · clients.rb · realms.rb · roles.rb · groups.rb
│     └─ client.rb             # KeycloakClient(auth 즉시·admin 지연·close)
├─ spec/
│  ├─ spec_helper.rb           # SimpleCov(90/85·경계 filter) + WebMock 설정
│  ├─ unit/*_spec.rb
│  ├─ support/keycloak_container.rb   # docker CLI 셸아웃 헬퍼(run/port/rm)
│  ├─ integration/full_flow_spec.rb   # 실제 KC 26.6, tag :integration
│  └─ fixtures/it-realm-realm.json    # go/testdata 재사용
├─ examples/quickstart.rb
└─ .github/workflows/ruby-ci.yml · ruby-release.yml (repo 루트 .github/)
```

**계층별 책임:**

- **config** — `Config`(불변 class, 생성 후 `freeze`, 키워드 인자). 필수값(`server_url`/`realm`/`client_id`) 누락 → `KeycloakSdk::ConfigError`. `client_secret`은 `String`이며 **`inspect` 오버라이드로 마스킹**(기본 inspect는 인스턴스 변수 노출). server_url 후행슬래시 제거. 타임아웃(connect/read 기본 10s)·클록 스큐(30s)·스코프(`["openid"]`) 기본값. (Ruby에 소거 가능 문자열 타입이 없어 secret은 심층방어 마스킹만 — §5.)
- **errors(🔴)** — `KeycloakSdk::Error < StandardError` 루트 아래 계층(§4).
- **masking** — `mask(secret)` → 완전 불투명 `"***"`(접두 노출 없음). 값타입 inspect·Config inspect가 사용.
- **tokens** — `Data.define`(Ruby 3.2+ 불변 값타입) + **`inspect` 오버라이드 마스킹**. `TokenSet`(access_token·token_type·expires_in·refresh_token·id_token·scope·expires_at + `expired?`)·`ValidatedToken`(subject·audience[Array]·issuer·expires_at·issued_at·claims)·`IntrospectionResult`(active·username·client_id·claims)·`AuthorizationRequest`(url·state·code_verifier).
- **token_provider** — 덕 인터페이스: `#access_token → String`. `ClientCredentialsTokenProvider`: 공유 Faraday로 client-credentials POST, 만료 전(스큐 여유) 캐시 재사용, `Mutex` single-flight(동시 갱신 코얼레스). §4 동형 core 추상화. **admin은 이 캐싱 provider로만 토큰 수령**(AuthClient 직접 주입 금지 — Rust `79ecf76` 교훈: per-call 재발급 방지·§4 캐시 불변식).
- **oidc_endpoints** — `{server_url}/realms/{realm}` 규약 URL 조립(issuer·token·authorization·introspection·end_session·jwks). 네트워크 없음(discovery 왕복 불요 — 7개 자매 동형).
- **jwks_store(🔴)** — 공유 Faraday로 JWKS 조회, `Mutex` 보호 캐시(kid→JWK). `get_key(kid)`: 캐시 히트=네트워크 0. **미해결 kid만** 재조회(`Mutex` single-flight + rate-limit `min_refetch`, **재조회 결정 시점에 gate stamp** — 성공 아님, IdP 장애창 DoS 상한, Go/Rust/Python 동형). 위조 서명(알려진 kid·나쁜 서명)은 재조회 유발 안 함(캐시 키 반환→검증 실패는 다운스트림).
- **jwt_validator(자체강화, 🔴)** — `JwtValidator`: `JWT.decode(token, nil, true, options)` 호출. options = `algorithms: ["RS256"]`(alg 핀·검증 前 none/confusion 구조적 거부)·`verify_iss: true`+`iss:`(정확)·`verify_aud: true`+`aud: client_id`(포함·문자열/배열 수용)·`required_claims: ["exp","iss","aud"]`(부재 거부)·`verify_expiration: true`·`verify_not_before: true`·`leeway: 30`·`jwks: 로더람다`. 로더 람다가 JwksStore에 위임(`kid_not_found: true` 분기에서만 재조회). 결과→`ValidatedToken` 매핑.
- **auth_client(OIDC 래핑 + 손수)** — `AuthClient`: `Rack::OAuth2::Client`(엔드포인트는 oidc_endpoints 조립)로 client-credentials·authcode+PKCE·refresh. **PKCE S256 verifier/challenge는 손수 생성**(SecureRandom+SHA256+base64url), `access_token!(code_verifier:)`로 완결. **introspection(RFC7662)·end_session(logout)은 공유 Faraday로 손수 POST**(rack-oauth2 클라이언트측 미커버). `validate`는 JwtValidator 위임. `AuthClient#access_token`이 client-credentials 소스(TokenProvider 구현).
- **admin(파사드 + raw())** — `AdminClient`: `faraday` 커넥션(`{server_url}/admin/realms/{realm}` 베이스·**bearer 미들웨어**가 주입 TokenProvider에서 토큰 소싱·JSON req/res·타임아웃·follow_redirects 미장착). `users`/`clients`/`realms`/`roles`/`groups` 서브리소스가 create/get/list/update/delete를 감싸고 오류 경계 변환. 생성 id는 **Location 헤더**(201 빈 바디)에서 마지막 세그먼트(realm은 name 키·client는 내부 uuid — clientId 조회는 list+filter). representation=plain hash(허용된 누출). `raw()`는 내부 Faraday 커넥션 노출(탈출구).
- **client(통합 진입점)** — `KeycloakClient`: `auth`는 **즉시**(공유 Faraday·JwksStore·JwtValidator·AuthClient 1회 조립), `admin`은 **지연**(메모이즈). config가 전 계층 타임아웃 구동. admin에 **전용 `ClientCredentialsTokenProvider`** 배선(AuthClient 아님 — §4 캐싱 불변식). `close`(Faraday 커넥션 정리 — FD 위생).

**결합 규칙(§4)**: `admin`은 `auth`를 직접 알지 못한다 — `TokenProvider` 덕 인터페이스가 유일 접착제(admin은 `ClientCredentialsTokenProvider` 소비). JWT만 자체강화(rack-oauth2 내부 id_token 검증 미신뢰). 하위 오류(Faraday·ruby-jwt·rack-oauth2)는 경계에서 `KeycloakSdk::*Error`로 변환.

**문서화된 은닉성 예외**: (a) admin 파사드가 Keycloak representation을 **plain hash**로 통과(Python admin 동형 — 누출 아님, SDK 자체 DTO 재래핑은 범위 밖). (b) `AdminClient#raw()`(내부 Faraday 커넥션), 저수준 주입 시임 — 정상 경로(`client.auth`/`client.admin`)는 노출 안 함.

## 4. 오류 경계 변환

`KeycloakSdk::Error < StandardError` 루트:
- `ConfigError` — 설정 검증 실패.
- `AuthError` — OAuth/인증 실패(`oauth_error` 속성으로 OAuth 오류 코드 보존).
- `TransportError` — 네트워크(타임아웃/연결거부/DNS).
- `TokenValidationError` — JWT 검증 실패.
- `AdminError`(`status` 속성) → `NotFoundError`(404)·`ConflictError`(409)·`ForbiddenError`(403).

경계 변환(공개 API 누출 0):
- **admin(Faraday)**: 응답 status 404→`NotFoundError`·409→`ConflictError`·403→`ForbiddenError`·기타 4xx/5xx→`AdminError(status)`; `Faraday::TimeoutError`/`Faraday::ConnectionFailed`→`TransportError`. **중앙 변환기 1곳**(Go `toSDKError`·Rust `map_admin` 동형).
- **auth(rack-oauth2)**: OAuth 오류 응답(`Rack::OAuth2::Client::Error` 등)→`AuthError{oauth_error}`; 네트워크→`TransportError`.
- **jwt(ruby-jwt)**: `JWT::IncorrectAlgorithm`(alg/none/confusion)·`JWT::VerificationError`(서명)·`JWT::ExpiredSignature`·`JWT::ImmatureSignature`(nbf)·`JWT::InvalidIssuerError`·`JWT::InvalidAudError`·`JWT::MissingRequiredClaim`→`TokenValidationError`; JWKS Faraday 오류→`TransportError`/`TokenValidationError`.

## 5. 보안 불변식 (CI 강제)

- **JWT 자체강화**(플레이북 3단계):
  - **알고리즘 핀닝** — `algorithms: ["RS256"]`. ruby-jwt는 검증 前 `verify_algo`에서 헤더 alg를 allowlist와 교집합해 비면 `JWT::IncorrectAlgorithm` raise, 서명은 교집합(RS256)으로 검증 — **헤더 alg를 검증 알고리즘 선택에 절대 미사용**(alg-confusion·RSA공개키-as-HMAC 구조적 차단).
  - **`none`/미서명 거부** — `["RS256"]` allowlist에서 `alg:none`·`alg:HS256`·alg 부재 토큰은 `verify_algo`에서 거부(키 조회·서명검증 前). **수동 헤더 pre-gate 불요**(⚠️ PHP firebase/php-jwt와 발산 — 그쪽은 alg가 decode 후에만 채워져 pre-gate 필수였음. Ruby는 불필요하므로 과잉설계 금지).
  - **issuer 정확 일치**(`verify_iss: true` + `iss:` String — `===` 정확 매치, Regexp/Proc 금지) · **audience 포함**(`verify_aud: true` + `aud: client_id` — `[*token_aud] & [*expected]` 교집합으로 문자열/배열 모두 수용). ⚠️ 각각 플래그+값 **둘 다** 필요(하나만 주면 무검증).
  - **exp 필수**(`required_claims: ["exp","iss","aud"]` — `verify_expiration: true`만으론 부재 미검출) + **nbf**(`verify_not_before: true`) + **클록 스큐 30s**(⚠️ `leeway` 기본 0 → 30).
  - **DoS-안전 JWKS** — 위조 서명은 재조회 없음, **kid 미해결에만**(로더의 `kid_not_found: true` 분기) 재조회, **rate-limit + single-flight**(`Mutex`), gate는 재조회 결정 시점 stamp. Go/Rust/PHP 동형.
- **마스킹** — Ruby 기본 `inspect`/`Data`/`Struct`가 시크릿 노출 → `Config`·`TokenSet`에 **`inspect` 오버라이드**로 access/refresh/id 토큰·client_secret을 `***`(완전 불투명). 단위 테스트로 강제.
- **SSRF 하드닝** — 공유 Faraday에 `faraday-follow_redirects` 미들웨어를 **미장착**(Faraday 기본 미추종) — discovery/token/introspect/JWKS 리다이렉트 SSRF 차단(Rust `redirect::none()` 동형).
- **TLS 기본 on**(https 검증) · http는 로컬/테스트만 투명 허용 · no-op insecure 옵션 금지 · **타임아웃 주입**(config connect/read → auth·JWKS·admin 전부; 미주입=hung IdP 무한대기).
- **의존성 감사** — CI에 `bundler-audit`(취약 gem 차단).
- **시크릿 메모리 위생 한계** — Ruby에 소거 가능한 문자열 타입이 없어 `client_secret`은 항상 일반 `String`이다. 마스킹은 심층방어일 뿐 end-to-end 소거 보장이 아니다(타 7개 언어와 동일한 근본 한계 — 과대광고 금지).

## 6. 툴체인·테스트·CI

- **Ruby**: 포터블 plain Ruby **3.4.x** x64(7z) @ `C:\Users\dirtc\tools\ruby`(리포지토리 미커밋). 전 의존 pure Ruby → 네이티브 컴파일 불요(선택적 `ridk install`로 MSYS2 보험). `required_ruby_version ">= 3.2"`. CI 매트릭스 **3.2·3.3·3.4**(`ruby/setup-ruby`).
- **린트/포맷**: `rubocop`(+`rubocop-rspec`) — CI 차단.
- **테스트**: `rspec` + **`webmock`**(네트워크 경계 목킹) + `bundle exec rspec`. 단위 = PKCE(S256) 생성·설정 검증/기본값·토큰 파싱·만료/스큐·JWT강화(alg핀·none 불가·iss·aud[다중]·exp 필수·nbf)·**오류 경계 매핑**(404→NotFound 등)·마스킹·JWKS DoS-안전(위조 서명 재조회 안 함·미해결 kid만·rate-limit). JWT는 **자체 RSA 키쌍**(stdlib openssl)으로 서명.
- **커버리지 게이트**: **SimpleCov**(라인 ≥90/브랜치 ≥85, `enable_coverage :branch`·`minimum_coverage line: 90, branch: 85`). 네트워크 경계 omit: `add_filter`로 `auth_client.rb`·`admin/**`·`client.rb` 제외. 로직 모듈(config·errors·masking·tokens·token_provider·oidc_endpoints·jwks_store·jwt_validator)이 게이트. `spec_helper.rb`에서 **SDK require 前** `SimpleCov.start`.
- **통합(docker-CLI 셸아웃)**: `spec/support/keycloak_container.rb`가 `docker run`(`quay.io/keycloak/keycloak:26.6`·`start-dev --import-realm`·`it-realm-realm.json` 재사용)·`docker port`·`docker rm`을 `Open3`로 직접 구동, HTTP readiness 폴링. testcontainers-ruby는 **stale 0.2.0 + docker-api Windows npipe 미지원**으로 미사용(PHP 동형·ubuntu CI 러너에서도 동일 동작). `:integration` tag로 단위 실행에서 제외(Docker-free).
- **CI**: `.github/workflows/ruby-ci.yml`(매트릭스 3.2·3.3·3.4 + rubocop + rspec + SimpleCov 게이트 + bundler-audit + 별도 Docker 통합잡) + `ruby-release.yml`(`ruby-v*` 태그 → **RubyGems Trusted Publishing** OIDC, `rubygems/release-gem@v1`·`permissions: id-token: write`·environment `release`·저장 시크릿 없음, human-gated).
- **배포명** RubyGems **`keycloak-sdk`**(rubygems 404=사용가능·모듈 `KeycloakSdk`로 기존 `keycloak` gem의 `Keycloak` 모듈 충돌 회피), 태그 `ruby-v*`. 첫 게시는 gem 부재로 1회 API키 push 또는 `gem configure_trusted_publisher` 선행.

## 7. 테스트 패리티 매트릭스 (§4단계)

| 층위 | 시나리오(다른 언어와 동형) |
|---|---|
| **단위** | PKCE(S256) 생성 · 설정 검증/기본값 · 토큰 응답 파싱 · 만료·클록 스큐 · JWT 강화(alg핀·`none` 불가·iss 정확·aud 포함[다중]·exp 필수·nbf·스큐) · **오류 경계 매핑**(404→`NotFoundError` 등) · 마스킹(inspect) · JWKS DoS-안전(위조 서명 재조회 안 함·미해결 kid만·rate-limit) |
| **통합(docker-CLI, 실제 KC 26.6)** | client-credentials 토큰 발급 · `validate`(다중 aud 수용) · introspect · user/client/role/group CRUD · realm CRUD(master-admin) · `raw()` 탈출구 · delete 후 조회 → `NotFoundError` |

## 8. 게차(Gotchas) — 딥리서치 확정

- ⚠️ **ruby-jwt 기본값이 안전하지 않다.** `algorithms` 기본 `["HS256"]`(가장 위험 — RSA공개키-as-HMAC 혼동 표면)·`verify_expiration`은 exp **부재 시 통과**(`required_claims` 필요)·`verify_iss`/`verify_aud` 기본 off(각각 플래그+값 둘 다 필요)·`leeway` 기본 0. → `["RS256"]`·`required_claims:["exp","iss","aud"]`·`verify_iss/aud:true`+값·`leeway:30` 명시 강화.
- ⚠️ **`algorithms:["RS256"]`이 none/confusion을 검증 前 구조적 거부.** ruby-jwt `verify_algo`가 헤더 alg∉allowlist를 서명검증·키조회 前 reject. **수동 헤더 pre-gate 불요**(PHP와 발산 — 문서화해 과잉설계 방지). `none`은 allowlist에 없으면 도달 불가.
- ⚠️ **ruby-jwt `KeyFinder`는 `JWT.decode`마다 재생성**되어 내부 `@jwks ||=` 캐시가 호출 간 미유지. → 캐시·rate-limit·single-flight를 `jwks:` 로더 람다 안 **공유 스레드세이프 스토어**(`JwksStore`·`Mutex`)에 자체 구현. 로더는 초기 `{kid:}` 호출=캐시 반환(cold면 1회 fetch), `{kid_not_found:true, invalidate:true, kid:}` 분기에서**만** 네트워크(rate-limit+single-flight gate 통과 시). gate는 재조회 **결정 시점** stamp.
- ⚠️ **rack-oauth2 PKCE는 passthrough**(1급 기능 아님) → S256 `code_verifier`/`code_challenge`를 손수 생성하고 `access_token!(code_verifier:)`로 전달(누락→Keycloak `invalid_grant`). `Rack::` 네임스페이스≠Rack 런타임 의존(클라이언트 반쪽은 결정적 HTTP 클라이언트·세션/미들웨어 불요).
- ⚠️ **어떤 Ruby admin gem도 공유 `TokenProvider` 주입을 지원 안 함**(`looorent`는 자체 무캐시 토큰·bare-string 오류·deprecated rest-client). → Faraday raw-REST + bearer 미들웨어(캐싱 `ClientCredentialsTokenProvider` 소싱)가 §4 캐싱 불변식 유일 경로(Rust `79ecf76` 교훈 동형).
- ⚠️ **admin 생성 id는 Location 헤더**(POST 201 빈 바디)에서 마지막 경로 세그먼트. realm은 name 키(UUID 없음)·client는 내부 uuid(clientId 조회는 `GET /clients?clientId=` list+filter). role/realm은 name 키.
- ⚠️ **`POST /admin/realms`(신규 realm 생성)는 master realm 전용** — realm service account는 403(전역 부트스트랩 권한). E2E는 master bootstrap admin으로 검증(C#/.NET·Rust 동형).
- ⚠️ **representation은 plain hash로 통과**(허용된 누출) — 자체 DTO 미재래핑(Keycloak 26 필드 드리프트가 SDK 변경 강제 안 함).
- ⚠️ **testcontainers-core는 stale 0.2.0(2024-02·pre-1.0)이고 docker-api(Excon)가 Windows npipe 미지원** → docker-CLI 셸아웃(PHP 동형·CI ubuntu에서도 동일).
- ⚠️ **Ruby 4.0 존재**(4.0.5) but gem CI가 대체로 3.4까지 → dev는 3.4·floor `>=3.2`. gem명 `keycloak-sdk`이나 모듈은 `KeycloakSdk`(require `keycloak_sdk`) — 기존 `keycloak` gem의 top-level `Keycloak` 모듈과 충돌 회피.
- ⚠️ **시크릿 메모리 위생은 언어 차원 불가**(소거 가능 문자열 타입 없음) — 마스킹은 심층방어만(타 언어 동일).
- ⚠️ **rack-oauth2는 activesupport/json-jwt를 트랜지티브로 끌어옴**(전부 pure Ruby). json-jwt는 우리가 검증에 미사용이나 의존 그래프에 있으므로 패치 유지(`>=1.16`).

## 9. 완료 기준 (DoD)

- [ ] `ruby/` 전 계층(config→auth→jwt→admin→client) 구현 + §4 동형(명명·계층·예외·값타입·보안 불변식)
- [ ] 단위 테스트(§7 시나리오 전부) + 실제 KC 26.6 docker-CLI 통합테스트 GREEN
- [ ] SimpleCov 게이트(로직 모듈 라인 ≥90%/브랜치 ≥85%, 경계 omit) 통과 · `rubocop` · `bundler-audit`
- [ ] 자체강화 JWT 불변식 전부(alg핀·none·iss·aud·exp/nbf·DoS-safe JWKS) 단위 테스트로 고정 · 마스킹·SSRF·TLS·타임아웃 강제
- [ ] `ruby-ci.yml`(매트릭스 3.2·3.3·3.4 + Docker 통합) + `ruby-release.yml`(준비·human-gated) · 문서(getting-started Ruby 섹션·README·CLAUDE.md·로드맵·verification-log-ruby) 갱신
- [ ] 로컬 설치 경로(`bundle install`·`bundle exec rspec`·`examples/quickstart.rb`) 동작
