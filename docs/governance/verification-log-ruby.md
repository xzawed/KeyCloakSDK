# 검증 로그 — Ruby SDK

[AI 거버넌스 프레임워크](ai-governance-framework.md)에 따른 Ruby SDK(`keycloak-sdk`, RubyGems) 태스크별 정량 검증 기록. 브랜치 `feature/ruby-sdk` → `main` 병합됨 (PR #19, 2026-07-07). 8번째(마지막) 언어.

**툴체인**: 포터블 Ruby **3.4.10**(`C:\Users\dirtc\tools\ruby`, non-devkit RubyInstaller — 리포지토리 미커밋) + Bundler 2. 명령은 `ruby/`에서: `bundle exec rspec`(단위) / `RUN_INTEGRATION=1 bundle exec rspec spec/integration --tag integration`(통합, Docker 필요) / `bundle exec rubocop`(린트) / `bundle exec bundler-audit check --update`(의존성 감사). ⚠️ **로컬 Windows 빌드는 MSYS2/DevKit이 필요**하다(racc·prism·bigdecimal 등 네이티브 gem — Windows precompiled 없음). MSYS2 pacman의 c-ares 리졸버가 이 네트워크에서 DNS를 못 풀어(mingw curl/MSYS2 wget은 정상) `pacman.conf`의 `XferCommand = /usr/bin/wget --timeout=30 -O %o %u` + origin-pinned mirrorlist + `/etc/hosts` 핀으로 우회(Rust의 VS2019 BuildTools 로컬 셋업과 동류 — CI ubuntu-latest는 무관, `ridk install 3`로 1회 셋업).

**게이트**: G1 정적분석/스타일(`rubocop` 무경고) · G2 단위테스트(`rspec`) · G3 커버리지(SimpleCov `minimum_coverage line: 90, branch: 85` — 네트워크 경계 `auth_client.rb`/`admin/**`/`client.rb` `add_filter` omit) · G4 스펙리뷰(§4 언어중립 계약과의 동형성) · G5 교차검증(태스크별 리뷰 루프 + 보안 하드닝 리뷰) · G6 보안(JWT 강화·JWKS DoS-safe·마스킹·경계 예외변환·SSRF) · G7 의존성 감사(`bundler-audit`).

> **실행 방식**: 승인된 WBS(12태스크: scaffold → errors/masking → config → tokens/oidc/http → token_provider → jwks → jwt → auth → admin → client → integration → CI/docs) → 태스크별 TDD(실패 테스트 → 구현 → 통과) + 계층별 커밋 + 태스크 직후 소규모 리뷰 루프. Task 7(JwtValidator, 보안핵심)은 opus 어드버서리얼 리뷰로 13개 강화 불변식을 소스 트레이스 검증.

---

## 딥리서치 (착수 전) — 라이브러리 API 확정

설계 스펙([2026-07-06-keycloak-ruby-sdk-design.md](../superpowers/specs/2026-07-06-keycloak-ruby-sdk-design.md)) 단계에서 4개 웹검증 에이전트(auth·admin·jwt·툴체인/테스트/패키징)로 아래를 **확정**(구현 중 재확인 불필요):

- **`rack-oauth2` `~> 2.3`**(auth, nov 유지 — OIDF 인증 RP 저자): 그랜트(client-credentials 기본·authorization-code)+PKCE-S256 passthrough+refresh 커버, Faraday2 백엔드(HTTP 스택 정렬). ⚠️ **PKCE는 1급 기능이 아니라 passthrough**라 S256 `code_verifier`/`code_challenge`는 SDK가 손수 생성(`SecureRandom`+`Digest::SHA256`+`Base64.urlsafe_encode64`)해 `access_token!(code_verifier:)`로 전달해야 한다(누락 시 Keycloak `invalid_grant`). introspection(RFC7662)·end_session(logout)은 어느 auth 라이브러리도 클라이언트측을 커버하지 않아 공유 Faraday로 손수 POST(Go/Rust/PHP와 동형).
- **admin — 성숙한 gem 부재로 `faraday`(HTTP 계층 재사용)로 Admin REST 직접 래핑**: 후보였던 `looorent/keycloak-admin`(v1.1.7, 살아있음)은 §4 결합 규칙에 비호환 — 자체 무캐시 토큰 라이프사이클(외부 `TokenProvider` 주입 시임 없음)·bare-string 오류·deprecated `rest-client` 의존이라 채택하지 않고, 5리소스(`users`/`clients`/`realms`/`roles`/`groups`) ~25개 얇은 메서드 + `raw()`를 직접 구현(C#/PHP의 raw-REST 선례와 동형). 캐싱 `ClientCredentialsTokenProvider`를 bearer 미들웨어로 주입.
- **`faraday` `~> 2.0`**(HTTP, admin·introspect·logout·JWKS 공유): `follow_redirects` 미들웨어를 절대 장착하지 않는다 — Faraday는 기본적으로 리다이렉트를 추종하지 않으므로 이것이 곧 SSRF 하드닝이다. rack-oauth2의 내부 백엔드와 동일 계열이라 타임아웃 설정이 정렬된다.
- **`jwt`(ruby-jwt) `~> 3.2`**(jwt, 강화 검증 프리미티브): ⚠️ 기본값이 안전하지 않다 — `algorithms` 미지정 시 `none` 포함 광범위 허용(→ SDK가 `["RS256"]`로 고정 핀), `verify_iss`/`verify_aud`/`verify_expiration`/`verify_not_before`가 기본 꺼짐(→ 전부 `true`로 강화), `required_claims`가 기본 없음(→ `%w[exp iss aud]` 명시), `leeway`가 기본 0(→ `config.clock_skew`로 명시 주입). alg 핀은 키 조회/서명 검증 **이전**에 발동(ruby-jwt 소스 확인)하므로 PHP(firebase/php-jwt `&$headers` 성공-후 채움)와 달리 원본 헤더를 직접 디코드해 사전 게이트할 필요가 없다(구조적으로 안전). DoS-safe JWKS는 라이브러리에 없어 자체 `JwksStore`로 구현(kid→JWK 캐시·미해결만 재조회·rate-limit gate를 재조회 *결정 시점*에 stamp — Go/Python/Rust 동형).
- **기각**: auth의 `openid_connect`(nov) — `rack-oauth2`의 상위집합이나 런타임 의존성 11개(activemodel·mail·tzinfo·swd·webfinger 등)로 무겁고 헤드라인 가치(id_token 검증·WebFinger/SWD discovery)가 SDK 설계와 중복. auth의 `oauth2`(pboling) — PKCE 완전 수작업(passthrough 헬퍼조차 없음)·OIDC 비인식·revoke 없음·마이크로 gem 공급망 표면 확대. admin의 `looorent/keycloak-admin`·`imagov/keycloak`·`keycloak-ruby-client` — 전부 공유 `TokenProvider` 주입 미지원(§4 캐싱 불변식 위반). jwt의 `json-jwt`(저수준·강화 스토리 약함)·`jose`/`ruby-jose`(stale, 2018→2024 유지보수 공백).

## 계층별 구현 (Task 1~11)

각 태스크 TDD(실패 테스트 → 구현 → 통과) 후 계층별 커밋. G1(정적분석/스타일)·G2(테스트)·G3(커버) 각 태스크 통과.

| Task | 커밋 | 내용 | G1 | G2 | G3 |
|---|---|---|---|---|---|
| 1 | `6a46c82` + `5f2d8f7` + `57ec158` | 스캐폴딩(gemspec·Gemfile·`.rubocop.yml`(double_quotes·lf)·`.gitattributes`(eol=lf)·spec_helper SimpleCov 90/85+WebMock·version) — 리뷰 Important(`RSpec/SpecFilePathFormat`) 수정 | ✅ | ✅ (버전 스펙 1) | — |
| 2 | `52bd43a` | 예외 계층(`Error`→`Config`/`Auth`/`Transport`/`TokenValidation`/`Admin`→`NotFound`/`Conflict`/`Forbidden`) + `Masking` | ✅ | ✅ (7, 누적 7) | ✅ (100%) |
| 3 | `fc6e2b4` | `Config`(불변·검증·후행슬래시 제거·`inspect` 마스킹·기본값) — `.rubocop.yml`에 `Metrics/ParameterLists CountKeywordArgs:false` 추가 | ✅ | ✅ (18, 누적 25) | ✅ (라인100%/브랜치92.86%) |
| 4 | `5b9346d` | 값타입(`TokenSet`/`ValidatedToken`/`IntrospectionResult`/`AuthorizationRequest`, `inspect` 마스킹) + `OidcEndpoints` + `Http` 팩토리(타임아웃·SSRF: follow_redirects 미장착) | ✅ | ✅ (29, 누적 54) | ✅ (라인99.11%/브랜치95.83%) |
| 5 | `919777a` | `TokenProvider` 덕 인터페이스 + `ClientCredentialsTokenProvider`(캐시·Mutex single-flight·오류변환) | ✅ | ✅ (33, 누적 87) | ✅ (라인100%/브랜치90.63%) |
| 6 | `05a2d2e` + `38a347e` | `JwksStore` — DoS-safe JWKS(Mutex 캐시·미해결 kid만 재조회·rate-limit·single-flight) + **리뷰 Important 수정**: rate-limit이 nil 캐시(콜드-스타트 IdP 다운)에도 적용되도록 가드 정정 | ✅ | ✅ (41, 누적 41 — 카운트 리셋 기준 재계산) | ✅ (라인100%/브랜치92.86%) |
| 7 | `801ba59` + `684d747` | `JwtValidator` 자체강화(RS256핀·`none`/confusion 구조적 거부·iss 정확·aud 포함·exp 필수·nbf·클록스큐·DoS-safe) — **보안 핵심, opus 어드버서리얼 리뷰** — 생성자 nil issuer/audience 가드(방어심층) + forced-refetch nil-guard 테스트 추가 | ✅ | ✅ (55, 누적 55) | ✅ (라인100%/브랜치93.48%) |
| 8 | `93a65ae` + `460980f` | `AuthClient` — rack-oauth2 래핑(그랜트·PKCE S256 손수) + introspect/logout 손수 + `validate` 위임 + `TokenProvider` 구현 — **리뷰 Important 2건**: id_token 추출(`raw_attributes`) + client_credentials scope 미전송 수정 | ✅ | ✅ (62, 누적 62 — auth_client는 커버리지 필터) | — |
| 9 | `64381bc` | `AdminClient` — Faraday raw-REST 5리소스(users/clients/realms/roles/groups)+bearer 미들웨어+오류경계(Location id·404/409/403)+`raw()` — 트레일링 슬래시 fix(base_url 조립 방식 정정) | ✅ | ✅ (68, 누적 68 — admin/은 커버리지 필터) | — |
| 10 | `922bba0` | `KeycloakClient` 통합 진입점(auth 즉시·admin 지연+전용 캐싱 `ClientCredentialsTokenProvider`·close) | ✅ | ✅ (71, 누적 71 — client는 커버리지 필터) | ✅ (**라인100%/브랜치93.48%**, 게이트 90/85 통과) |
| 11 | `44e02fb` | 통합 E2E(docker-CLI 셸아웃, 실제 Keycloak 26.6 — client-credentials→validate→introspect→user/client/role/group CRUD→realm CRUD(master-admin)→raw→NotFound) | ✅ | ✅ IT(1) | — |
| 12 | (본 커밋) | ruby-ci(매트릭스 3.2/3.3/3.4+bundler-audit+Docker 통합잡)·ruby-release(RubyGems Trusted Publishing, human-gated)·`examples/quickstart.rb`·`README.md`/`LICENSE`·spec_helper 통합-게이트 가드·문서 | ✅ | ✅ | ✅ |

### 태스크별 리뷰 루프 (Loops)

- **Task 1**(`57ec158`): 리뷰어가 `spec/unit/` 레이아웃(기본 RSpec 관용 `spec/keycloak_sdk/...`와 상이)이 `RSpec/SpecFilePathFormat` cop과 충돌해 향후 태스크의 describe-클래스 스펙이 전부 막힘을 포착 — `.rubocop.yml`에서 해당 cop 비활성화로 해소.
- **Task 6**(`38a347e`): 리뷰어가 `JwksStore#key_set`의 rate-limit 가드 `@cache && force && !refetch_allowed?`가 **nil 캐시**(초기부터 IdP 다운)에서 `@cache &&`에 막혀 rate-limit을 완전히 우회함을 포착(Important) — 위조 kid 폭주가 콜드-스타트 창에서 무제한 재조회를 유발할 수 있었다. `return @cache if force && !refetch_allowed?`로 정정하고, 실패-fetch에도 gate가 stamp됨을 증명하는 회귀테스트를 추가.
- **Task 7**(`684d747`, opus 어드버서리얼 보안리뷰): 13개 강화 불변식 전부 방어됨을 ruby-jwt 3.2 소스 트레이스로 확인(Critical/Important 0). Minor 2건 수정: (1) 생성자 nil issuer/audience 방어(ruby-jwt가 nil이면 iss/aud 검사를 조용히 스킵하므로 `from_config` 경로는 안전하나 공개 `new` 생성자에 방어심층 추가), (2) forced-refetch + nil-guard 조합 테스트 추가(실제 미발현 확인 — ruby-jwt `JWK::Set.new`가 nil을 `{}`로 강제하나 방어 유지).
- **Task 8**(`460980f`): 구현자가 WBS 원안의 버그 2건을 자가수정(`Rack::OAuth2.http_config` 블록 인자가 `Faraday::Connection`이라 `conn.options.open_timeout=`가 정답, `Rack::OAuth2::Client::Error`엔 `#error` 접근자가 없어 `e.response[:error]`). 리뷰가 추가로 **미테스트 그랜트 경로 2건**(Important)을 포착 — `to_token_set`의 id_token이 항상 nil(Bearer에 접근자 없음 → `raw_attributes[:id_token]`), `client_credentials_token`이 scope를 전송하지 않음(위치인자가 auth_method로 소비됨 → `access_token!(scope:...)`). WebMock 그랜트 테스트 2건으로 RED→GREEN 고정.
- **Task 9**(`64381bc` 예고 fix): brief 원안의 admin base_url 조립(`"{server_url}/admin/realms/"` + 상대경로)이 Faraday URI-join으로 `POST /admin/realms/`(트레일링 슬래시)를 만들어 실 KC/WebMock의 `/admin/realms`와 불일치 — `"{server_url}/"` + 리소스별 풀경로로 정정.
- **Task 11**(`44e02fb`): 실제 Keycloak 26.6 E2E에서 **SDK 코드 결함 0건**(8번째 언어로 선행 7개 SDK의 게차가 선반영). 실서버 진실 확인: 토큰 `aud=["it-client","realm-management"]`(다중 aud 실검증), `Roles#create`는 201+Location(role name — Task 9 우려 해소). 테스트-fix만: 픽스처 시드 충돌 회피(alice→랜덤 사용자명), `raw()` 경로가 Task 9의 base_url 정정을 반영.

## G6 — 보안 불변식 (실증)

- **JWT 강화**(`JwtValidator`): RS256 alg 핀(`algorithms: ["RS256"]`, 헤더 `alg` 미신뢰) · `none`/미서명 구조적 거부(핀된 알고리즘 목록 밖) · `iss` 정확일치(`verify_iss:true, iss:`) · `aud` 포함검사(`verify_aud:true, aud:`) · `exp` 필수(`required_claims: %w[exp iss aud]`) · `nbf` 검증(`verify_not_before:true`) · 클록 스큐(`leeway: config.clock_skew`). 14개 단위테스트(11 강화 스모크+거부 + 3 추가)로 실증.
- **JWKS DoS-safe**(`JwksStore`): kid→JWK 캐시(캐시 히트=네트워크 0) · 미해결 kid에만 재조회 · rate-limit(연속 미해결 재조회 억제, gate는 재조회 *결정 시점*에 stamp — nil 캐시(콜드-스타트 IdP 장애)에도 적용되도록 Task 6 리뷰로 정정) · Mutex로 동시 미스 직렬화(single-flight).
- **SSRF/전송 하드닝**(`Http.build`): 공유 Faraday 커넥션에 `follow_redirects` 미들웨어를 절대 장착하지 않는다(Faraday는 리다이렉트를 기본 추종하지 않음) + `open_timeout`/`timeout`(config 주입)으로 hung IdP 방지.
- **마스킹**: `Config`/`TokenSet`/`AuthorizationRequest`의 커스텀 `inspect`(+`to_s` alias)가 `client_secret`/`access_token`/`refresh_token`/`id_token`/`code_verifier`를 완전 불투명(`"***"`, 접두 노출 없음)하게 마스킹한다. Ruby `String`은 소거 가능한 타입이 아니므로(다른 7개 언어와 동일한 근본 한계) 마스킹은 심층방어일 뿐 end-to-end 소거 보장이 아니다.
- **경계 예외 변환**: Faraday 전송 실패(`Faraday::TimeoutError`/`Faraday::ConnectionFailed`) → `TransportError`, `Rack::OAuth2::Client::Error` → `AuthError{oauth_error}`, admin HTTP status → `AdminError.from_status`(404/409/403 하위클래스). `admin.raw`가 유일한 의도적 탈출구(내부 `Faraday::Connection` 반환).

## 최종 상태 (G1~G7 종합)

- **G1**: ✅ `bundle exec rubocop` 무경고(40 files inspected, no offenses — `examples/quickstart.rb` 추가 후 재검증 완료, Task 12 시점).
- **G2**: ✅ 단위 **73** GREEN(`bundle exec rspec`) + 통합 **1**(`full_flow`, docker-CLI 셸아웃 — 실제 Keycloak 26.6) = **총 74**. (전체브랜치 최종리뷰 수정 웨이브에서 단위 2건 추가 — `Faraday::Error` 경계 테스트 + §4 admin-wiring 고정 테스트 — 71→73.)
- **G3**: ✅ SimpleCov `minimum_coverage(line: 90, branch: 85) unless ENV["RUN_INTEGRATION"]` — **실측 라인 100.0%(210/210)/브랜치 93.48%(43/46)**, 게이트 통과(exit 0). 네트워크 경계(`auth_client.rb`/`admin/**`/`client.rb`)는 통합테스트로 검증하고 커버리지 게이트에서 제외(다른 7개 언어와 동일한 정책). **Task 12에서 확인**: `RUN_INTEGRATION=1 bundle exec rspec spec/integration --tag integration` 단독 실행 시 라인 90.48%/브랜치 39.13%로 게이트 미달치가 나오지만, 가드 덕에 exit 0(통합 CI 잡이 커버리지로 오탐 실패하지 않음) — 단위 게이트 자체는 그대로 90/85로 강제된다.
- **G7**: ✅ `bundle exec bundler-audit check --update` — 취약 의존성 0건(CI에 `ruby-ci.yml` build-test 잡으로 배선).
- **통합**: ✅ docker-CLI 셸아웃 E2E **1** GREEN(client-credentials→validate[실 JWKS·RS256 강화검증]→introspect→user/client/role/group CRUD→realm CRUD(master-admin)→`raw()` 탈출구→NotFound). **SDK 코드 결함 0건**(8번째 언어 — 선행 7개 언어의 강화 설계·게차가 선반영됨, PHP·Rust에 이은 세 번째 무결함 사례).
- **G4**: ✅ 설계 스펙 §4 언어중립 계약과 동형(계층: config→auth/jwt→admin→client, `admin`이 `auth`를 직접 모름·`TokenProvider` 덕 인터페이스만 접착제, 예외 기반 관용(Java/Python/Node/C#/PHP 동형 — Go/Rust의 error-값 관용과 대비), 값타입 필드명 snake_case). Ruby 관용 편차(admin representation은 plain Hash로 통과 — Python과 동형, `Data.define`으로 값타입 불변성 표현)는 §4 허용.
- **G5**: ✅ 태스크별 소규모 리뷰 루프(위 Loops, Task 1/6/8/9) + Task 7 opus 어드버서리얼 보안리뷰(13개 불변식 소스 트레이스 검증).
- **G6**: ✅ 위 "G6 — 보안 불변식" 절 참조.
- **배포**: 🔒 RubyGems(`keycloak-sdk`, `rubygems/release-gem@v1` — Trusted Publishing/OIDC, 저장 시크릿 없음), `ruby-v*` 태그 push 대기(human-gated, 미실행). 최초 1회는 API 키 수동 게시 또는 rubygems.org UI에서 Trusted Publisher 사전 등록이 필요(gem이 존재하기 전에는 Trusted Publisher를 붙일 수 없음). `feature/ruby-sdk` → `main` PR도 미실행.

## 커버리지 실측 (Task 12)

SimpleCov(`enable_coverage :branch`)로 `bundle exec rspec` 실행한 실측 결과(exit 0 — 게이트 통과):

```
Coverage report generated for RSpec to D:/Source/KeyCloakSDK/ruby/coverage.
Line Coverage: 100.0% (210 / 210)
Branch Coverage: 93.48% (43 / 46)
```

- **결과: 로직 모듈 라인 커버리지 100.0%, 브랜치 93.48%** — 게이트 ≥90/≥85 **통과**.
- 네트워크 경계 3개 파일(`auth_client.rb`/`admin/**`/`client.rb`)은 `spec_helper.rb`의 `add_filter`로 제외(다른 7개 언어와 동일하게 통합테스트로 검증).
- **spec_helper 가드 검증(Task 12 핵심 산출물)**: `RUN_INTEGRATION=1 bundle exec rspec spec/integration --tag integration`(통합 1건만 실행)은 라인 90.48%(190/210)/브랜치 39.13%(18/46)로 게이트 미달이지만 `minimum_coverage(...) unless ENV["RUN_INTEGRATION"]` 가드 덕에 **exit 0**으로 종료된다 — CI의 `integration` 잡이 이 환경변수를 설정하므로 커버리지 게이트 오탐 실패가 발생하지 않는다. 단위 전용 실행(`bundle exec rspec`, `RUN_INTEGRATION` 미설정)은 게이트가 그대로 적용됨을 위 결과로 재확인.

## 언어 간 비교 메모 (7개 선행 SDK 대비)

Ruby는 Java/Python/Node/Go/C#/PHP/Rust 다음의 **8번째(마지막)** 언어로, 앞선 언어들의 게차가 설계 단계에 선반영되어 통합테스트에서 **신규 SDK 코드 결함이 0건**이었다(PHP·Rust에 이은 세 번째 무결함 사례). 결합 규칙(`admin`이 `auth`를 모름, `TokenProvider` 덕 인터페이스만 접착제)·JWT 자체강화(알고리즘 핀·`none` 거부·iss/aud/exp·nbf·DoS-safe JWKS rate-limit-at-decision-time)·마스킹·경계 예외변환이 7개 선행 SDK와 동형이다. Ruby 고유의 실질적 편차는 (1) admin에 성숙한 gem이 없어 Faraday로 raw REST를 전부 직접 구현(PHP/C#의 부분 raw-REST보다 넓은 범위, 하지만 representation을 plain Hash로 통과 — Python과 동형), (2) `rack-oauth2`의 PKCE가 passthrough라 S256 생성을 SDK가 전담(다른 언어의 라이브러리 내장 PKCE 헬퍼와 대비), (3) 예외 기반 관용(Go/Rust의 error-값과 달리 Java/Python/Node/C#/PHP와 동형), (4) 로컬 Windows 빌드에 MSYS2/DevKit 네이티브 gem 컴파일 환경이 필요하다는 점(Rust의 VS2019 BuildTools와 동류의 Ruby 고유 로컬 개발 마찰 — CI의 ubuntu-latest는 무관).
