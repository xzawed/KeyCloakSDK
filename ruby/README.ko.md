# keycloak-sdk (Ruby)

Keycloak SDK for Ruby — 인증(OIDC/OAuth2) + 관리(Admin REST) API. Keycloak을 위한 **9개 언어 폴리글랏 SDK**(Java·Python·Node·Go·C#·PHP·Rust·Ruby·Kotlin) 중 Ruby 구현이다. auth는 [`rack-oauth2`](https://github.com/nov/rack-oauth2)를 감싸고(그랜트/PKCE), admin은 성숙한 gem이 없어 [`faraday`](https://lostisland.github.io/faraday/)로 raw REST를 직접 구현한다. JWT 검증만은 [`jwt`](https://github.com/jwt/ruby-jwt)(ruby-jwt) 위에 자체 강화 계층을 얹는다. [Java SDK](https://github.com/xzawed/KeyCloakSDK/tree/main/java/)와 개념·계층·흐름이 동형(isomorphic)이다.

[English](https://github.com/xzawed/KeyCloakSDK/blob/main/ruby/README.md) · 한국어

> **사전 릴리스** — 첫 릴리스 후보(`0.1.0.rc1`)가 RubyGems에 게시됐다. 안정 릴리스는 아직 없다. ⚠️ **RubyGems는 프리릴리스를 기본으로 설치하지 않는다** — 안정 버전이 생기기 전까지 맨 `gem install keycloak-sdk`는 아무것도 찾지 못한다. `--pre`를 붙이거나 아래처럼 버전을 명시해야 한다.

## 설치

```bash
gem install keycloak-sdk -v 0.1.0.rc1
```

또는 `Gemfile`:

```ruby
gem "keycloak-sdk", "0.1.0.rc1"
```

`0.1.0.rc1`이 유일한 릴리스인 동안은 버전을 명시해야 한다 — 맨 `gem install keycloak-sdk`와 버전 없는 `gem "keycloak-sdk"`는 둘 다 프리릴리스를 건너뛰어 아무것도 해석하지 못한다. 안정 릴리스가 나오면 핀을 지운다.

require 경로는 `require "keycloak_sdk"`(gem명은 하이픈 `keycloak-sdk`, 모듈/require명은 언더스코어 `keycloak_sdk`/`KeycloakSdk` — 기존 `keycloak` gem의 `Keycloak` 모듈과 충돌 회피).

## 빠른 시작

```ruby
require "keycloak_sdk"

config = KeycloakSdk::Config.new(
  server_url: "https://kc.example.com",
  realm: "myrealm",
  client_id: "admin-cli",
  client_secret: "changeme" # 실제 값은 환경변수/시크릿 매니저에서 로드할 것(inspect는 자동 마스킹)
)

client = KeycloakSdk::KeycloakClient.new(config)

# 1) client-credentials 그랜트로 토큰 발급. TokenSet#inspect는 access/refresh/id 토큰을 마스킹한다.
token = client.auth.client_credentials_token

# 2) 발급받은 액세스 토큰을 자체 강화 검증(알고리즘 핀·iss 정확일치·aud 포함검사·exp 필수·nbf·클록 스큐).
validated = client.auth.validate(token.access_token)
puts "subject=#{validated.subject} aud=#{validated.audience}"

# 3) 관리 API — admin은 최초 접근 시 지연 생성된다(전용 캐싱 TokenProvider). create()는 생성된 id를 반환.
user_id = client.admin.users.create({ username: "alice", enabled: true })
puts "created user_id=#{user_id}"

client.close
```

> **aud 주의:** 검증은 토큰의 `aud`가 `client_id`를 포함할 것을 요구한다. 기본 realm은 client-credentials 토큰의 `aud`에 client_id를 넣지 않으므로, 기본 realm에서는 `expected_audience: "my-api"`(realm이 실제로 발급하는 오디언스)를 지정하거나 Keycloak 클라이언트에 *Audience* 프로토콜 매퍼를 추가한다.

전체 예제: [`examples/quickstart.rb`](https://github.com/xzawed/KeyCloakSDK/blob/main/ruby/examples/quickstart.rb).

## 설정 (`KeycloakSdk::Config`)

`KeycloakSdk::Config.new(...)`는 불변(`freeze`) 값 객체다. 인스턴스 자체는 freeze되나 문자열 속성 자체는 deep-frozen이 아니다(다른 언어 SDK와 동류의 근본 한계).

| 키워드 인자 | 필수 | 기본값 | 설명 |
|---|---|---|---|
| `server_url:` | ✅ | — | Keycloak base URL. 후행 슬래시는 자동 제거 |
| `realm:` | ✅ | — | realm 이름 |
| `client_id:` | ✅ | — | 클라이언트 ID |
| `client_secret:` | | `nil` | 클라이언트 시크릿(confidential client) |
| `scopes:` | | `["openid"]` | 토큰 요청/authorization URL에 threading되는 스코프 |
| `signature_algorithms:` | | `["RS256"]` | JWT 서명 검증 허용 알고리즘 핀(ES256/PS256 realm용, 빈 배열 거부) |
| `connect_timeout:` | | `10` | 커넥션 타임아웃(초, `> 0`) |
| `read_timeout:` | | `10` | 읽기 타임아웃(초, `> 0`) |
| `clock_skew:` | | `30` | JWT 검증 클록 스큐 허용치(초, `>= 0`) — ruby-jwt `leeway`로 전달 |
| `jwks_min_refetch:` | | `30.0` | 미해결 kid로 인한 JWKS 재조회의 최소 간격(초, `>= 0`) — DoS 증폭 상한 |
| `expected_audience:` | | `nil` | 토큰 `aud`에 들어있어야 할 값. 미설정이면 `client_id`(기본 realm은 client-credentials 토큰 `aud`에 client_id를 넣지 않는다) |

값 검증 실패(필수 누락·공백·타임아웃 비양수 등)는 `KeycloakSdk::ConfigError`를 raise한다.

## Auth (`client.auth`)

| 메서드 | 설명 |
|---|---|
| `client_credentials_token` | client-credentials 그랜트. `config.scopes`가 threading됨 |
| `create_authorization_request(redirect_uri:, scopes: nil, state: ..., nonce: …)` | authorization-code+PKCE(S256) 시작 — nonce는 `state:`와 같이 항상 생성되어 URL에 실림. `AuthorizationRequest#url/#state/#code_verifier/#nonce` 반환(네트워크 없음, 동기) |
| `exchange_code(code:, code_verifier:, redirect_uri:, expected_nonce: nil)` | 콜백에서 받은 code를 code_verifier와 교환. `expected_nonce:`를 주면 id_token을 서명·iss·aud·exp 검증한 뒤 nonce 클레임을 대조(생략 시 검증 스킵 — 아홉 공통) |
| `refresh(refresh_token:)` | refresh_token 그랜트 |
| `introspect(token)` | RFC 7662 introspection → `IntrospectionResult#active?` |
| `logout(refresh_token:)` | 세션 종료(RP-initiated logout) |
| `validate(token)` | 자체 강화 JWT 검증 → `ValidatedToken#subject/#audience/#issuer/#claims` |

인가 코드(PKCE) 흐름은 `state`(호출자가 콜백에서 직접 대조 — `exchange_code`는 무상태)와 함께 사용한다. `rack-oauth2` 관용 그랜트 오류는 `KeycloakSdk::AuthError#oauth_error`(OAuth 에러 코드 보존)로, 전송 실패는 `KeycloakSdk::TransportError`로 변환된다.

## Admin (`client.admin`)

`client.admin`은 최초 접근 시 지연 생성되며 admin 전용 캐싱 `ClientCredentialsTokenProvider`를 사용한다(§4 결합 규칙 — `admin`은 `auth`를 직접 알지 못한다). 5개 리소스가 대칭적 CRUD를 제공한다: `users` / `clients` / `roles` / `groups`(realm-scoped) · `realms`(top-level, master realm 전용 create/delete).

```ruby
admin = client.admin
user_id = admin.users.create({ username: "bob", enabled: true })  # Location 헤더에서 id 추출
admin.users.get(user_id)
admin.users.list(max: 20)
admin.users.update(user_id, { firstName: "Bob" })
admin.users.delete(user_id)

role_name = admin.roles.create({ name: "my-role" })  # 201 + Location(role name)
realm_name = admin.realms.create({ realm: "new-realm", enabled: true })  # master realm 전용
```

탈출구: `admin.raw`는 내부 `Faraday::Connection`(base `{server_url}/`, bearer 자동 첨부)을 그대로 반환한다 — SDK가 감싸지 않은 Admin REST 엔드포인트를 직접 호출할 때 쓴다.

## 보안

- **JWT 자체강화**(`JwtValidator`): ruby-jwt의 안전하지 않은 기본값을 전부 오버라이드 — 알고리즘 핀(헤더 `alg` 미신뢰, `none`/HS256-confusion 구조적 거부), `iss` 정확일치, `aud` 포함검사, `exp` 필수(`required_claims`), `nbf` 검증, 클록 스큐(`leeway`).
- **DoS-safe JWKS**(`JwksStore`): kid→키 캐시(히트=네트워크 0), 미해결 kid만 재조회, 재조회는 *결정 시점*에 rate-limit gate를 stamp(IdP 장애창에서도 위조 kid 폭주에 상한 — Go/Python/Rust와 동형).
- **마스킹**: `Config#inspect`/`TokenSet#inspect`/`AuthorizationRequest#inspect`가 시크릿·토큰·code_verifier를 완전 불투명(`"***"`, 접두 노출 없음)하게 마스킹한다. 다만 Ruby `String`은 소거 가능한 타입이 아니므로 심층방어일 뿐 end-to-end 소거 보장은 아니다(다른 언어 SDK와 동일한 근본 한계).
- **SSRF 하드닝**: 공유 `Faraday` 커넥션(`Http.build`)은 리다이렉트 추종 미들웨어를 절대 장착하지 않는다(Faraday는 기본적으로 리다이렉트를 따라가지 않음).
- **TLS**: Faraday의 `net_http` 어댑터가 https를 기본 검증한다(로컬/테스트 http 완화 로직 불필요 — Go와 동형).
- **타임아웃**: `Config#connect_timeout`/`#read_timeout`이 모든 Faraday 커넥션(auth/admin/JWKS)에 주입되어 hung IdP에 무한 대기하지 않는다.

## 예외 계층

```
KeycloakSdk::Error (StandardError)
├─ ConfigError            # Config 검증 실패
├─ AuthError              # 인증/토큰 발급 실패(#oauth_error로 OAuth 에러코드 보존)
├─ TransportError         # 네트워크 전송 실패(타임아웃/연결거부/DNS)
├─ TokenValidationError   # JWT 검증 실패
└─ AdminError             # Admin REST 오류(#status로 HTTP 상태 보존)
   ├─ NotFoundError       # 404
   ├─ ConflictError       # 409
   └─ ForbiddenError      # 403
```

## 요구 사항

- Ruby **>= 3.2**(CI 매트릭스 3.2/3.3/3.4)
- 의존성: `faraday ~> 2.0` · `jwt ~> 3.2` · `rack-oauth2 ~> 2.3`

## 문서

- [Getting started](https://github.com/xzawed/KeyCloakSDK/blob/main/docs/guides/getting-started.md#ruby)
- [Keycloak 서버 배포 가이드](https://github.com/xzawed/KeyCloakSDK/blob/main/docs/guides/deploying-keycloak-server.md)
- [보안 정책](https://github.com/xzawed/KeyCloakSDK/blob/main/SECURITY.md)
- 개발/빌드 명령: [CONTRIBUTING.md](https://github.com/xzawed/KeyCloakSDK/blob/main/CONTRIBUTING.md)

## 라이선스

[Apache-2.0](https://github.com/xzawed/KeyCloakSDK/blob/main/ruby/LICENSE)
