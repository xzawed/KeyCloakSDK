---
paths:
  - "ruby/**"
  - "harness/apps/ruby/**"
  - "harness/install/consume/ruby*"
  - ".github/workflows/ruby-*.yml"
---

# Ruby 규칙

## 툴체인 (빌드 명령)

Ruby는 포터블 설치 `${KCSDK_TOOLS:-$HOME/tools}/ruby`(3.4.10, non-devkit RubyInstaller — 리포지토리 미커밋)를 사용한다. 프리픽스를 인라인 지정하고 명령은 `ruby/`에서 실행한다:
```bash
export PATH="${KCSDK_TOOLS:-$HOME/tools}/ruby/bin:$PATH"
cd ruby && bundle install                                     # 의존성 설치
cd ruby && bundle exec rspec                                   # 단위테스트 + 커버리지 게이트(라인≥90%/브랜치≥85%). Docker 불필요
cd ruby && RUN_INTEGRATION=1 bundle exec rspec spec/integration --tag integration  # 통합 1개(Docker 필요 — docker CLI 셸아웃, 실제 Keycloak 26.6)
cd ruby && bundle exec rubocop                                 # 린트
cd ruby && bundle exec bundler-audit check --update            # 의존성 취약점 감사
```
> 다른 PC에서는 `KCSDK_TOOLS`(포터블 툴 상위 디렉터리, 기본 `$HOME/tools`)를 덮어쓰거나, 이미 PATH에 있으면 프리픽스를 생략한다. 설치·진단은 [development-setup.md](../../docs/guides/development-setup.md)(`node scripts/doctor.mjs ruby`).
- 단일 테스트: `bundle exec rspec spec/unit/<path>_spec.rb -e "<example name>"`
- 로컬 배포 빌드 검증(업로드 없이): `gem build keycloak-sdk.gemspec` → `keycloak-sdk-0.1.0.gem` 생성 확인(`gemspec`의 `spec.files`가 `lib/**/*.rb`+`LICENSE`+`README.md`를 포함 — 둘 다 `ruby/`에 로컬 사본 필요)
- 실제 RubyGems 배포는 로컬에서 실행하지 않는다 — `ruby-v*` 태그 push 시 `.github/workflows/ruby-release.yml`에서 RubyGems Trusted Publishing(OIDC, 저장 시크릿 없음)로 실행(사람 승인 게이트). 첫 게시 선행은 rubygems.org 프로필에 **pending** Trusted Publisher 등록 하나뿐이다(owner `xzawed`·repo `KeyCloakSDK`·workflow `ruby-release.yml`·environment `release`). ⚠️ **"gem이 존재해야 Trusted Publisher를 붙일 수 있다"고 적혀 있었는데 그건 npm 이야기지 RubyGems가 아니다** — RubyGems 가이드는 *"Trusted publishers are not just for existing gems, they can also be used to push new gems!"*라고 명시한다. 함께 권하던 "최초 1회 API 키로 `gem push`"는 **비싼 방향으로 틀린 지시**였다(손으로 민 push는 install-smoke·통합 게이트·태그↔매니페스트 버전 가드를 전부 우회하고 좌표를 파이프라인 밖에서 태운다). ⚠️ pending은 12시간 만료로 추정되므로 **등록과 태그 push는 같은 자리에서** 한다. 세 레지스트리 차이 표는 [DEPLOY.md §2-B](../../DEPLOY.md).
- ⚠️ **로컬 Windows 빌드는 MSYS2/DevKit이 필요하다.** 네이티브 gem(racc·prism·bigdecimal 등 — Windows precompiled 없음) 컴파일 때문(Rust의 VS2019 BuildTools와 동류, CI ubuntu-latest는 무관). MSYS2 pacman의 c-ares 리졸버가 이 네트워크에서 DNS를 못 풀어(mingw curl/MSYS2 wget은 정상) `msys64/etc/pacman.conf`의 `XferCommand = /usr/bin/wget --timeout=30 -O %o %u`(wget=getaddrinfo=hosts 사용)+origin-pinned mirrorlist+`/etc/hosts` 핀으로 우회 후 `ridk install 3`(mingw dev toolchain, 1회) 필요.
- ⚠️ `rubocop -a`(자동수정)가 Windows에서 CRLF를 쓸 수 있다 — Write 도구로 직접 덮어써 LF를 유지한다(`.gitattributes`의 `eol=lf`가 커밋 시점 정규화는 하지만 로컬 워킹트리 파일 자체는 CRLF로 남을 수 있음).
- 배포명 `keycloak-sdk`(gem), require명 `keycloak_sdk`(모듈 `KeycloakSdk` — 기존 `keycloak` gem의 `Keycloak` 모듈과 충돌 회피). Ruby 개발 3.4.10 / `required_ruby_version >= 3.2`(CI 매트릭스 3.2/3.3/3.4).

## 게차

- ⚠️ **(Ruby) `jwt`(ruby-jwt) 기본값은 안전하지 않다** — `algorithms:` 미지정 시 `none` 포함 광범위 허용→`["RS256"]` 고정. `verify_iss`/`verify_aud`/`verify_expiration`/`verify_not_before` 기본 꺼짐→전부 true, `required_claims: %w[exp iss aud]`, `leeway: config.clock_skew`. **alg 핀은 키조회/서명검증 이전 발동**(PHP `&$headers`와 달리 헤더 사전 base64url 디코드 불필요 — 구조적으로 안전).
- ⚠️ **(Ruby) `JwtValidator.new`에 nil `issuer`/`audience`를 넘기면 ruby-jwt의 verify_iss/verify_aud가 조용히 no-op** — 생성자에서 nil·공백이면 `ConfigError`로 fail-closed(방어심층, `from_config` 경로는 미발현이나 직접 `new` 호출 대비).
- ⚠️ **(Ruby) `JwksStore`의 rate-limit 가드는 nil 캐시(콜드스타트 IdP다운)에도 적용돼야 함** — `@cache && force && !refetch_allowed?` 순서면 캐시 없을 때 rate-limit이 완전 우회돼 위조kid 폭주 유발 → `force && !refetch_allowed?`(캐시 무관 게이트 우선)로 정정(Task6 리뷰, Go/Python/Rust와 동일 클래스 결함).
- ⚠️ **(Ruby) `rack-oauth2`의 PKCE는 passthrough** — S256 verifier/challenge는 SDK가 `SecureRandom`+SHA256+base64url로 손수 생성해 `access_token!(code_verifier:)` 전달(누락시 invalid_grant). `Client::Error`엔 `#error` 없어 `e.response[:error]`로 읽음. scope는 `access_token!(scope:)` 키워드 필수(위치인자는 무음누락). id_token은 `raw_attributes[:id_token]`으로 추출. `http_config` 블록인자는 `#options`에 타임아웃 설정(`conn.options.open_timeout=`).
- ⚠️ **(Ruby) admin에 성숙한 gem이 없어 `faraday`로 Admin REST 직접구현** — `looorent/keycloak-admin`은 TokenProvider 주입 시임 없어 §4 비호환. **base_url은 `"{server_url}/"` + 리소스별 풀경로**(`"{server_url}/admin/realms/"`+상대경로 조립 시 트레일링슬래시로 실KC 불일치 — Task9 발견·정정). `Users#create` 등은 201+`Location` 헤더에서 id 추출.
- ⚠️ **(Ruby) SimpleCov `minimum_coverage`는 프로세스 전역 게이트** — `spec/integration` 단독 실행은 브랜치커버리지가 게이트(85%) 미달로 실패 → `unless ENV["RUN_INTEGRATION"]`로 가드(단위전용 게이트는 90/85 그대로). 근거: `spec_helper.rb`.
- ⚠️ **(Ruby) 로컬 Windows 빌드는 MSYS2/DevKit 필요**(racc/prism/bigdecimal 네이티브 컴파일, Rust VS2019와 동류) — MSYS2 pacman c-ares가 이 네트워크 DNS 해석 실패 → `pacman.conf`의 `XferCommand=wget`+mirrorlist 핀+`/etc/hosts` 핀 후 `ridk install 3`(1회) 필요.
- ⚠️ **(Ruby) 최소 3.2, CI 상단 3.4**(4.0 존재하나 매트릭스 미포함). gem명 `keycloak-sdk`(하이픈)·require/모듈명 `keycloak_sdk`/`KeycloakSdk`(언더스코어) — 기존 `keycloak` gem의 `Keycloak` 모듈과 충돌 회피 목적.
- ⚠️ **(Ruby) `Config` 문자열 속성은 인스턴스만 freeze, deep-frozen 아님** — `#server_url`/`#realm` 등이 반환하는 `String` 자체는 미freeze(다른 언어와 동류 근본 한계).
- ⚠️ **(Ruby) 시크릿 메모리 위생은 언어 차원에서 불가능** — Ruby `String`은 소거불가라 `client_secret`은 항상 `String`. 마스킹(`inspect`의 `***`)은 심층방어일 뿐(다른 7개 언어와 동일한 근본 한계).
- ⚠️ **(Ruby) `client.auth.validate`는 IdP 장애 시 `TransportError`를 raise할 수 있다(fail-closed, 의도)** — 호출자는 `TokenValidationError`뿐 아니라 `TransportError`도 처리해야 함.
- ⚠️ **(Ruby) `Faraday::SSLError`/`ParsingError`는 `Faraday::Error`의 직계형제**(ConnectionFailed/TimeoutError의 서브클래스 아님) — 네 경계 모두 `rescue Faraday::Error`로 넓게 잡아야 TLS실패·파싱실패가 `TransportError`로 변환됨. **안전한 이유**: `RaiseError` 미들웨어를 설치하지 않아(리소스가 `resp.success?`를 손수 검사) status 기반 `Faraday::ClientError`는 이 경계에 도달하지 않는다(좁게 잡으면 raw 예외 누출 — §4 위반, 최종리뷰 Important).
- ⚠️ **(Ruby) 공유 Faraday 커넥션 팩토리(`http.rb`)는 `follow_redirects` 미들웨어를 일부러 장착하지 않는다** — SSRF 하드닝이다(Rust `redirect::Policy::none()`과 동형 결정). token_provider·jwks·admin·introspect/logout 네 경로가 전부 이 팩토리를 쓰므로 여기가 유일한 집행 지점이다. **미들웨어를 추가하면 조용히 무너진다** — 회귀는 `spec/unit/http_spec.rb`의 "does not install a follow-redirects middleware (SSRF hardening)"가 잡는다(⚠️ 이 검사는 미들웨어 **목록**을 보는 것이지 302 응답을 실제로 태워보는 행동 프로브가 아니다).
- ⚠️ **(Ruby) `admin`은 `auth`에 의존하지 않는다 — `TokenProvider` 덕 인터페이스가 유일 접착제다.** admin은 전용 `ClientCredentialsTokenProvider`를 주입받는다. `AuthClient`도 `TokenProvider`를 구현하지만 **admin에 직접 주입되지 않는다** — Rust가 최종리뷰에서야 배운 캐시 불변식(무캐시 provider를 admin에 꽂으면 호출마다 토큰을 새로 받는다)을 Ruby는 처음부터 지켰다.
- ⚠️ **(Ruby) `Rack::OAuth2::Client::Error`도 경계에서 변환 대상이다** — Faraday 계열(`TimeoutError`/`ConnectionFailed`/`SSLError`/`ParsingError`)만 잡으면 auth 경로의 rack-oauth2 예외가 그대로 공개 API로 샌다(§4 위반).
