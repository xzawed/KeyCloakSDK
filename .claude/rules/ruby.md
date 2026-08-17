---
paths:
  - "ruby/**"
  - "harness/apps/ruby/**"
  - "harness/install/consume/ruby*"
  - ".github/workflows/ruby-*.yml"
---

# Ruby 규칙

## 툴체인

포터블 설치 `${KCSDK_TOOLS:-$HOME/tools}/ruby`. 개발 3.4 / `required_ruby_version >= 3.2`(CI 3.2·3.3·3.4).

```bash
export PATH="${KCSDK_TOOLS:-$HOME/tools}/ruby/bin:$PATH"
cd ruby && bundle install
cd ruby && bundle exec rspec                    # 단위 + 커버리지 게이트(라인≥90/브랜치≥85). Docker 불필요
cd ruby && RUN_INTEGRATION=1 bundle exec rspec spec/integration --tag integration   # Docker 필요(KC 26.6)
cd ruby && bundle exec rubocop
cd ruby && bundle exec bundler-audit check --update
cd ruby && gem build keycloak-sdk.gemspec       # 배포 빌드 검증
```

- 단일 테스트: `bundle exec rspec spec/unit/<path>_spec.rb -e "<example name>"`
- gem명 `keycloak-sdk`(하이픈) / require·모듈명 `keycloak_sdk`·`KeycloakSdk`(언더스코어) — 기존 `keycloak` gem의 `Keycloak` 모듈과 충돌을 피한다.
- 배포는 `ruby-v*` 태그 → RubyGems **Trusted Publishing**(OIDC, 저장 시크릿 없음). 선행은 rubygems.org 프로필에 **pending** Trusted Publisher 등록 하나뿐이고 새 gem에도 쓸 수 있다. ⚠️ pending은 12시간 만료로 추정되니 **등록과 태그 push를 같은 자리에서** 한다. ⚠️ 손으로 `gem push`하지 않는다 — install-smoke·통합 게이트·태그↔매니페스트 가드를 전부 우회한다.
- ⚠️ **로컬 Windows 빌드는 MSYS2/DevKit이 필요하다**(racc·prism·bigdecimal 네이티브 컴파일. CI ubuntu는 무관). MSYS2 pacman의 c-ares 리졸버가 이 네트워크에서 DNS를 못 풀어 `pacman.conf`에 `XferCommand = /usr/bin/wget …` + mirrorlist·`/etc/hosts` 핀으로 우회한 뒤 `ridk install 3`(1회).
- ⚠️ `rubocop -a`가 Windows에서 CRLF를 쓸 수 있다 — Edit/Write 도구로 덮어써 LF를 유지한다.
- ⚠️ **SimpleCov `minimum_coverage`는 프로세스 전역 게이트다** — `spec/integration` 단독 실행은 브랜치 커버리지 미달로 실패하므로 `unless ENV["RUN_INTEGRATION"]`로 가드한다.

## JWT·JWKS

- ⚠️ **`jwt`(ruby-jwt) 기본값은 안전하지 않다** — `algorithms:` 미지정 시 `none` 포함 광범위 허용이라 `["RS256"]` 고정. `verify_iss`/`verify_aud`/`verify_expiration`/`verify_not_before`가 전부 기본 꺼짐 → 전부 true, `required_claims: %w[exp iss aud]`, `leeway: config.clock_skew`. alg 핀은 키 조회·서명 검증 **이전에** 발동한다(PHP와 달리 헤더 사전 디코드가 불필요).
- ⚠️ **`JwtValidator.new`에 nil `issuer`/`audience`를 넘기면 verify_iss/verify_aud가 조용히 no-op이 된다** — 생성자에서 nil·공백이면 `ConfigError`로 fail-closed.
- ⚠️ **`JwksStore`의 rate-limit 가드는 nil 캐시(콜드스타트 + IdP 다운)에도 적용돼야 한다** — `@cache && force && !refetch_allowed?` 순서면 캐시가 없을 때 rate-limit이 완전히 우회된다. `force && !refetch_allowed?`(캐시 무관 게이트 우선)가 맞다.

## auth·admin

- ⚠️ **`rack-oauth2`의 PKCE는 passthrough다** — S256 verifier/challenge를 SDK가 `SecureRandom`+SHA256+base64url로 손수 만들어 `access_token!(code_verifier:)`에 넘긴다(누락 시 invalid_grant). scope도 **키워드 필수**(위치 인자는 무음 누락). `Client::Error`엔 `#error`가 없어 `e.response[:error]`로 읽고, id_token은 `raw_attributes[:id_token]`에서 꺼낸다.
- `create_authorization_request`는 `nonce:`를 `state:`와 같이 **항상** 생성해 URL에 싣는다. `exchange_code(expected_nonce:)`는 옵셔널(생략 시 id_token 검증 스킵).
- ⚠️ **admin은 성숙한 gem이 없어 `faraday`로 Admin REST를 직접 구현한다**(`looorent/keycloak-admin`은 TokenProvider 주입 시임이 없어 §4 비호환). **base_url은 `"{server_url}/"` + 리소스별 풀경로**다 — `"{server_url}/admin/realms/"`에 상대경로를 조립하면 트레일링 슬래시로 실서버와 어긋난다. `create`류는 201 + `Location` 헤더에서 id를 뽑는다.
- ⚠️ **admin은 `auth`에 의존하지 않는다 — `TokenProvider` 덕 인터페이스가 유일한 접착제다.** admin은 전용 `ClientCredentialsTokenProvider`를 받는다. `AuthClient`도 `TokenProvider`를 구현하지만 **admin에 직접 주입하지 않는다**(무캐시 provider를 꽂으면 호출마다 토큰을 새로 받는다).

## 오류 경계 (§4)

- ⚠️ **`Faraday::SSLError`/`ParsingError`는 `Faraday::Error`의 직계 형제다**(ConnectionFailed·TimeoutError의 서브클래스가 아니다) — 네 경계 모두 `rescue Faraday::Error`로 **넓게** 잡아야 TLS·파싱 실패가 `TransportError`로 변환된다. 넓게 잡아도 안전한 이유는 `RaiseError` 미들웨어를 설치하지 않아(리소스가 `resp.success?`를 손수 검사) status 기반 `Faraday::ClientError`가 이 경계에 도달하지 않기 때문이다.
- ⚠️ **`Rack::OAuth2::Client::Error`도 변환 대상이다** — Faraday 계열만 잡으면 auth 경로의 rack-oauth2 예외가 공개 API로 샌다.
- ⚠️ **`client.auth.validate`는 IdP 장애 시 `TransportError`를 raise할 수 있다**(fail-closed, 의도) — 호출자는 `TokenValidationError`뿐 아니라 이것도 처리해야 한다.
- ⚠️ **공유 Faraday 커넥션 팩토리(`http.rb`)는 `follow_redirects`를 일부러 장착하지 않는다**(SSRF 하드닝). token_provider·jwks·admin·introspect/logout 네 경로가 전부 이 팩토리를 쓰므로 **여기가 유일한 집행 지점**이다. 회귀는 `spec/unit/http_spec.rb`가 잡지만 ⚠️ 그 검사는 미들웨어 **목록**을 보는 것이지 302를 실제로 태워보는 프로브가 아니다.
- **한계**: `Config` 문자열 속성은 인스턴스만 freeze되고 deep-frozen이 아니다. 시크릿 메모리 위생은 Ruby `String`이 소거 불가라 언어 차원에서 불가능하다 — 마스킹은 심층방어일 뿐이다.
