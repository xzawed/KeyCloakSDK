# Changelog

이 프로젝트의 주요 변경사항을 기록합니다. 형식은 [Keep a Changelog](https://keepachangelog.com/ko/1.1.0/)를 따르며, 버전은 [SemVer](https://semver.org/lang/ko/)를 지향합니다.

> 이 리포지토리는 **폴리글랏 SDK**입니다. Java(`io.github.xzawed:keycloak-sdk`)·Python(`keycloak-sdk`)·Node(`@xzawed/keycloak-sdk`)·Go(`github.com/xzawed/KeyCloakSDK/go`)·C#/.NET(`Xzawed.Keycloak.Sdk`)·PHP(`xzawed/keycloak-sdk`)·Rust(`keycloak-sdk`)·Ruby(`keycloak-sdk`)·Kotlin(`io.github.xzawed:keycloak-sdk-kotlin`) 9개 언어가 독립 배포되며, 아래 항목은 언어 태그로 구분합니다. 지금까지 아홉 언어 전부가 **`1.0.0`**을 게시했습니다 — 같은 릴리스 물결에서 도달한 것은 1.0 기준(`git show d4e8958:docs/superpowers/plans/release-1.0.md`)의 A–G를 아홉 곳이 동시에 충족했기 때문이지 함대로 움직여서가 아닙니다(태그는 2026-08-30~09-01에 걸쳐 있고, 이후에는 다시 갈립니다). 그 아래 `[0.2.x]`·`[0.1.x]`·RC 항목은 그대로 역사로 남습니다. ⚠️ 어느 레지스트리에 실제로 올라갔는지는 이 파일이 아니라 `scripts/lib/deploy-facts.sh`의 `df_published_version`이 소유합니다 — 태그를 밀었다는 것과 게시됐다는 것은 다릅니다.

> 이전 릴리스(월별 보관본): [2026-10](changelog/2026-10.md) · [2026-09](changelog/2026-09.md) · [2026-08](changelog/2026-08.md)

## [Unreleased]

### Changed
- **(Rust)** ⚠️ 토큰·인트로스펙션 응답이 **끝까지 왔지만 쓸 수 없으면** `KeycloakError::Transport` 가 아니라 `KeycloakError::Auth` 입니다 — JSON 아님(503 HTML 포함) · 필드 타입이 틀린 JSON · `access_token`·`active` 없음 · 빈 본문 · JSON 아닌 Content-Type · 값 뒤 꼬리, 그리고 주입한 `reqwest::Client` 가 따라가다 실패한 리다이렉트. `AuthClient` 의 토큰 호출과 `introspect`, `ClientCredentialsTokenProvider` 가 그렇습니다(provider 는 `access_token` 없는 JSON 이 원래 `Auth`). 그 응답을 transport 로 잡아 재시도하던 코드는 auth 쪽을 보십시오. 안쪽 문구는 그대로이고 `Display` 접두가 `transport error:` 에서 `authentication error:` 로 바뀝니다. 다 오지 않은 응답(네트워크 · 타임아웃 · 1,048,576 바이트 상한 초과)과 보내지 못한 요청은 그대로 `Transport`, admin 파사드의 토큰 실패도 그대로 `Admin(Other { status: 401 })` 입니다.
- **(Go)** ⚠️ 토큰·인트로스펙션·admin 로그인 요청의 오류 계급을 「응답이 끝까지 왔는가」로 가릅니다. 다 오지 않은 응답(네트워크 실패 · 타임아웃 · 끊긴 본문 · 깨진 HTTP 틀 · 1,048,576 바이트 상한 초과 · 응답 머리 상한 초과)은 세 그랜트도 `*AuthError` 가 아니라 `*TransportError` 이고, `Introspect`·`Logout` 의 상한 초과도 그렇습니다. admin 자기 그랜트는 끝까지 온 응답이면 상태와 무관하게 `*AuthError` 입니다 — `*AdminError` 였던 탓에 토큰 엔드포인트의 404·403·409 가 `ErrNotFound`·`ErrForbidden`·`ErrConflict` 로 읽혀, 토큰을 다시 받지 못한 `Users.Delete` 가 admin 요청 없이 「이미 없음」으로 보였습니다. 그 상태로 재시도를 가르던 코드는 상태가 이제 메시지에만 있습니다. `v1.2.3` 노트의 「머리 상한 초과는 세 그랜트에서 `*AuthError`」는 이제 `*TransportError` 입니다.
- **(Node)** ⚠️ 토큰·인트로스펙션·로그아웃·discovery 응답이 **끝까지 오지 않으면** `KeycloakAuthError` 가 아니라 `KeycloakTransportError` 입니다 — 네트워크 실패(`fetch failed` · 연결 끊김) · 읽기 타임아웃 · 1,048,576 바이트 상한 초과. 세 그랜트와 `introspect` · `logout`, admin 의 자기 토큰이 그렇습니다(지금까지는 discovery 의 네트워크 실패만 transport 였습니다). 끝까지 왔지만 쓸 수 없는 응답(503 HTML · 깨진 JSON · `access_token` 없음 · 비-2xx)은 그대로 `KeycloakAuthError` 이고, 메시지는 계급과 상관없이 그대로입니다. 그 실패를 auth 로 잡아 재시도를 가르던 코드는 transport 쪽을 보십시오. `1.0.4` 노트의 「상한을 넘는 응답은 `KeycloakAuthError`」는 이제 `KeycloakTransportError` 입니다.
- **(Python)** ⚠️ 토큰·인트로스펙션·로그아웃 응답 본문이 1,048,576 바이트 상한을 넘으면 `KeycloakAuthError` 가 아니라 `KeycloakTransportError` 입니다 — 본문을 다 읽지 않은 응답이라 네트워크 실패와 같은 쪽입니다(sync · async · admin 의 자기 토큰). 메시지(`token response exceeds 1048576 bytes` 등)는 그대로이고, 끝까지 왔지만 쓸 수 없는 응답과 두 번 압축된 응답(본문을 읽기 전에 거부)은 그대로 `KeycloakAuthError` 입니다.

### Fixed
- **(PHP)** 릴리스 노트의 세 문장을 바로잡습니다(코드는 그대로입니다). `[1.5.0]` 의 「256,000 바이트를 넘는 `id_token` 을 돌려주는 IdP 앞에서는 `exchangeCode()` 가 이제 `TokenValidationError` 입니다」는 틀렸습니다 — nonce 를 준 `exchangeCode()` 는 `1.0.0` 부터 id_token 검증 실패를 `KeycloakAuthError`(`getPrevious()` 가 `TokenValidationError`)로 던지고, nonce 가 없으면 id_token 을 검증하지 않습니다. `[1.5.2]` 의 「메시지는 그대로이고」는 `access_token` 이 없는 JSON 에서 틀렸고, 「`KeycloakTransportError` 는 네트워크 실패만 뜻합니다」도 틀렸습니다(숫자가 아닌 `expires_in` 은 여전히 그것입니다) — 그 절을 고쳤습니다. 그리고 `php/README.md` 에 `1.0.0` 이후 동작 변경을 모은 「Upgrading from `1.0.0`」 절을 더했습니다.
- **(Node)** JWKS 의 `keys` 에 JWK 가 아닌 원소(문자열 · 숫자 · null · 배열)가 하나라도 있으면 jose 가 키셋 전체를 「JSON Web Key Set malformed」로 거부해, 같은 키셋의 지원되는 키로 서명한 토큰까지 `KeycloakTokenValidationError` 였습니다. 이제 그런 원소는 건너뜁니다(RFC 7517 §5 — 지원 밖 `kty` · 곡선 · 기형 멤버는 jose 가 이미 건너뜁니다). 남는 원소가 없으면 빈 키셋처럼 조회 실패이고 이전 키 캐시를 덮지 않습니다.
- **(Ruby)** JWKS 에 ruby-jwt 가 못 읽는 원소(`n` 이 빠진 RSA · `kty` 없는 원소 · 숫자/null/배열 원소)가 하나라도 있으면 키셋 전체를 버려, 같은 키셋의 지원되는 키로 서명한 토큰까지 `TokenValidationError` 였습니다. 이제 ruby-jwt 가 읽지 못하는 원소는 무엇이든 건너뜁니다(RFC 7517 §5). 쓸 수 있는 원소가 없으면 빈 키셋처럼 `TransportError` 이고 이전 키 캐시를 덮지 않습니다.
- **(Rust)** JWKS 의 `keys` 에 JWK 가 아닌 원소(문자열 · 숫자 · null · 배열)가 하나라도 있으면 키셋 전체가 파싱 오류(`KeycloakError::Transport`, `JWKS parse: …`)여서, 같은 키셋의 지원되는 키로 서명한 토큰까지 거부됐습니다. 이제 `Jwk` 로 풀리지 않는 원소는 건너뜁니다(RFC 7517 §5). 남는 원소가 없으면 빈 키셋처럼 `Transport`(`no usable keys`)이고 이전 키 캐시를 덮지 않습니다.
- **(Python)** `1.0.7` 은 urllib3 의 pyOpenSSL 을 주입한 프로세스(`urllib3.contrib.pyopenssl.inject_into_urllib3()`)에서 sync 클라이언트의 호출이 서버와 상관없이 전부 `KeycloakTransportError`(「Can't connect to server」)였습니다 — 응답 읽기 마감이 그 소켓에 없는 `gettimeout` 을 불렀습니다(urllib3 2.7.0 의 `WrappedSocket`). 이제 그 아래 소켓의 타임아웃을 씁니다. `1.0.6` 이하와 async 클라이언트는 해당하지 않습니다.
- **(Go)** JWKS 에 go-jose 가 못 읽는 키가 하나라도 있으면 키셋 전체를 버려, 같은 키셋의 지원되는 키로 서명한 토큰까지 `Validate` 와 nonce 를 준 `ExchangeCode` 에서 거부했습니다 — Keycloak realm 에 Ed448 키(`eddsa-generated`)를 더하면 그 키셋을 받은 뒤의 검증이 전부 실패했습니다. 이제 go-jose 가 거부하는 원소는 무엇이든 건너뜁니다(RFC 7517 §5) — 모르는 `kty` · 곡선(Ed448 · X25519 · P-192), 4,096 비트를 넘는 RSA 모듈러스, 빠진 멤버, 키와 맞지 않는 `x5c` · `x5t`, JWK 가 아닌 원소. 거부된 키는 쓰지 않습니다. 쓸 수 있는 키가 하나도 없는 키셋은 빈 키셋처럼 거부하고(`*TransportError` — 첫 키의 거부 원인을 담습니다) 이전 키 캐시를 덮지 않습니다.

### Security
- **(Ruby)** JWKS 의 문자열 원소는 거부되지 않고 ruby-jwt 에서 **그 문자열이 비밀인 HMAC 키**가 되었습니다(`JWT::JWK::HMAC` 이 `String` 을 받습니다). `signature_algorithms` 에 HS 계열을 허용한 소비자에게는, JWKS 에 그런 원소가 있을 때 공개된 그 문자열로 서명한 위조 토큰이 통과했습니다(실측 — 기본값 `["RS256"]` 은 해당하지 않습니다). 이제 해시가 아닌 원소는 키로 읽지 않고 버립니다.
- **(Java · Kotlin)** admin 레인도 응답 머리·청크 크기 줄·트레일러·TLS 레코드까지 요청을 보낸 때부터 읽기 타임아웃 안에 읽습니다 — 지금까지는 그 틀을 읽기마다만 묶어, 바이트를 읽기 타임아웃보다 조금 짧게 흘리는 서버가 1 초 설정에 7 초(틀)·33.5 초(TLS 레코드 하나) 호출을 붙잡았습니다. 이제 같은 `KeycloakTransportException` 으로 1.5 초 안에 끝납니다. ⚠️ 컨테이너가 RESTEasy `ClientConfigProvider` 를 두면(WildFly Elytron 등) 그 TLS 정책을 지키려 RESTEasy 의 풀을 그대로 쓰고, 그때 머리·틀은 지금처럼 읽기마다만 묶입니다.
- **(Java · Kotlin)** `com.nimbusds:oauth2-oidc-sdk` 를 11.38.2 에서 **11.39** 로 올립니다 — 상류가 `IDTokenValidator` · `LogoutTokenValidator` 에서 JWE `cty: JWT` 없는 암호화 토큰이 JWS 검증을 건너뛰던 것을 막았습니다(iss #5PWT). SDK 의 id_token 검증은 그 두 클래스를 쓰지 않고 서명된 JWT 만 받으므로(`JWTParser.parse` 뒤 `SignedJWT` 가 아니면 거부) 동작은 그대로입니다 — 그 클래스를 직접 쓰는 앱이 이 SDK 를 거쳐 받는 판이 올라갑니다.
- **(Go)** 모듈이 `github.com/go-jose/go-jose/v4` **4.1.9** 를 요구합니다(4.1.6 에서) — 4.1.7 이 권고 다섯을 고쳤습니다: [GHSA-p9j4-2j95-j4rv](https://github.com/go-jose/go-jose/security/advisories/GHSA-p9j4-2j95-j4rv) · [GHSA-c67m-wr4h-2ccg](https://github.com/go-jose/go-jose/security/advisories/GHSA-c67m-wr4h-2ccg) · [GHSA-v6h2-qj3f-2h6v](https://github.com/go-jose/go-jose/security/advisories/GHSA-v6h2-qj3f-2h6v) · [GHSA-27pc-rm86-68pq](https://github.com/go-jose/go-jose/security/advisories/GHSA-27pc-rm86-68pq) · [GHSA-r39w-98wm-9pp6](https://github.com/go-jose/go-jose/security/advisories/GHSA-r39w-98wm-9pp6). SDK 는 그 경로를 쓰지 않습니다(JWE · JSON 직렬화 · `x5c` · `Thumbprint` 없음, 토큰은 compact 만) — 이 SDK 를 거쳐 go-jose 를 받는 앱의 하한이 올라갑니다.
- **(Python)** HTTPS 프록시(`HTTPS_PROXY=https://…`) 뒤와 pyOpenSSL 을 주입한 프로세스의 sync 호출도 응답을 요청을 보낸 때부터 읽기 타임아웃 안에 읽습니다 — 거기서는 TLS 읽기 하나가 아래 소켓을 여러 번 읽는데 그 하나하나에 처음의 타임아웃이 걸려, TLS 레코드 하나의 꼬리를 흘리는 서버가 1 초 설정에 7 초 호출을 붙잡았습니다. 이제 같은 `KeycloakTransportError` 로 마감에 끝납니다.

## [1.5.2] - 2026-11-03 (PHP)

**2026-11-03 여덟째 릴리스 물결 — PHP 와 Kotlin 이 patch 로 올라갑니다.** 일곱째 물결(아래 `[1.5.1] - 2026-10-31 (PHP)` 절 머리말) 뒤에 착지한 소비자 가시 변경을 아래 두 절에 싣습니다 — PHP `AuthClient` 의 토큰 응답 분류와 Kotlin POM 의 JDK 하한 문구입니다. 나머지 일곱 언어는 마지막 태그 뒤 소비자에게 보이는 변경이 없습니다.

번호는 PHP `1.5.2`, Kotlin `1.0.9` 입니다. 동작이 바뀌는 항목(⚠️)이 있어도 번호는 게시된 공개 API 표면으로 정하고(DEPLOY.md §4 step 0), 두 언어 모두 그 표면이 그대로라 patch 입니다 — PHP 의 새 클래스 `Internal\TokenResponseUnusable` 은 `@internal` 입니다. 실제로 어디까지 게시됐는지는 이 파일이 아니라 `scripts/lib/deploy-facts.sh` 의 `df_published_version` 이 소유합니다.

### Changed
- **(PHP)** ⚠️ `AuthClient` 의 토큰 그랜트(`clientCredentialsToken` · `refresh` · `exchangeCode`)가 토큰 엔드포인트의 **JSON 이 아닌 응답**(503 HTML 페이지 · 200 의 비-JSON 본문 등)과 **`access_token` 이 없는 JSON 객체**을 `KeycloakTransportError` 가 아니라 `KeycloakAuthError` 로 던집니다 — 같은 응답을 `ClientCredentialsTokenProvider` 는 원래 `KeycloakAuthError` 로 던졌고, 그 응답을 transport 로 잡아 재시도하던 코드는 auth 쪽을 보십시오. JSON 이 아닌 응답의 메시지는 그대로이고 `access_token` 이 없는 JSON 은 `token request failed` 가 `token response has no usable access_token` 이 됩니다(2026-11-04 정정 — 처음에는 「메시지는 그대로」라고 적었습니다). 상한 초과(`KeycloakTransportError`)와 OAuth 오류 응답(`KeycloakAuthError`)은 바뀌지 않았습니다.

## [1.0.9] - 2026-11-03 (Kotlin)

**Kotlin 의 patch 입니다**(같은 물결의 나머지는 위 `[1.5.2] - 2026-11-03 (PHP)` 절의 머리말). 공개 API 변경은 **0** 이고, 아래 항목의 「다음 Kotlin 릴리스」가 이 `1.0.9` 입니다.

### Fixed
- **(Kotlin)** Maven Central 의 POM `<description>` 이 하한을 「Kotlin 2.2+ / JDK 21+」로 적고 있었습니다 — JDK 하한은 `1.0.1` 부터 **17** 입니다(`jvmTarget = JVM_17` · `-Xjdk-release=17`, README 와 같다). `1.0.1`–`1.0.8` 의 게시 POM 이 그 문구이고, 다음 Kotlin 릴리스부터 「JDK 17+」로 나갑니다. 코드와 바이트코드는 그대로입니다.

## [1.5.1] - 2026-10-31 (PHP)

**2026-10-31 일곱째 릴리스 물결 — 아홉 언어가 일곱 번호로 올라가고, 아홉 모두 patch 입니다.** 여섯째 물결(보관본 `changelog/2026-10.md` 의 `[1.4.0] - 2026-10-27 (Ruby)` 절 머리말) 뒤에 착지한 수정을 아래 일곱 절에 싣습니다 — admin Bearer 를 아홉 언어가 같은 문법으로 판정하는 것, JWKS 키 집합을 300 초 뒤 콜드 캐시로 다시 받는 것(아홉 언어), SDK 가 읽는 응답을 설정한 타임아웃 안에 전부 읽는 것(Java · Kotlin · Python · Ruby · .NET — Node 는 JWKS), 그려지는 문서의 영문화(여덟 언어 — 이로써 아홉 SDK 모두)와 언어별 수정입니다.

번호는 PHP `1.5.1`, Ruby `1.4.1`, Go `1.2.5`, Java `1.2.4`, Rust `1.1.5`, Kotlin `1.0.8`, Python · .NET · Node `1.0.7` 입니다. 동작이 바뀌는 항목(⚠️)이 있어도 번호는 게시된 공개 API 표면으로 정하고(DEPLOY.md §4 step 0), 아홉 언어 모두 그 표면이 그대로라 patch 입니다. 실제로 어디까지 게시됐는지는 이 파일이 아니라 `scripts/lib/deploy-facts.sh` 의 `df_published_version` 이 소유합니다.

⚠️ **여러 언어를 이름한 항목은 해당하는 절마다 그대로 되풀이했습니다** — 항목의 언어 태그 중 그 절 제목의 언어만 그 번호로 올라갑니다(선례: 2026-09-26 첫 물결, 보관본 `changelog/2026-09.md` 의 `[1.1.0] - 2026-09-26 (Go · PHP · Rust)` 머리말). 그래서 `(전 언어)` 항목 둘은 일곱 절 모두에 있습니다. 되풀이한 항목 안의 「아래」·「위」는 [Unreleased] 에서의 이웃 줄을 가리킵니다 — 그 줄이 그 절에 없으면 이 물결의 다른 절에 있습니다.

⚠️ **같은 번호의 절이 앞 물결에도 있습니다** — `[1.4.1]` 은 Ruby(이 물결)와 PHP(`[1.4.1] - 2026-10-23 (PHP)`, 다섯째 물결), `[1.2.4]` 는 Java(이 물결)와 Go(`[1.2.4] - 2026-10-27 (Go)`, 여섯째 물결), `[1.0.7]` 은 Python · .NET · Node(이 물결)와 Kotlin(`[1.0.7] - 2026-10-27 (Kotlin)`, 여섯째 물결)입니다 — 앞 절 셋은 모두 보관본 `changelog/2026-10.md` 에 있습니다. 번호는 언어별로 독립이라 제목의 언어 목록으로 가릅니다. `[1.5.1]` · `[1.2.5]` · `[1.1.5]` · `[1.0.8]` 은 앞 절이 없습니다.

### Changed
- **(PHP)** `composer.json` 이 `ext-curl` 을 요구하고 하한을 `guzzlehttp/guzzle ^7.15.2` · `guzzlehttp/psr7 ^2.12.3` 으로 올립니다 — curl 이 없으면 Guzzle 이 PHP stream 처리기로 내려가 응답 헤더 한 줄을 길이 제한 없이 읽었고(16 MiB 한 줄에 +57 MB, 손잡이가 없다), psr7 2.11 아래는 상한에서 전송을 멈추지 못해 큰 오류 본문을 끝까지 받았습니다. 두 하한은 권고 GHSA-v5mv-p594-2x33 · GHSA-f7vp-7xgx-4w4r(Guzzle)과 GHSA-c2w2-prh8-qm98(psr7)도 닫습니다. ⚠️ curl 확장이 없으면 Composer 는 이 판을 고르지 않습니다 — 제약 없는 `composer require` 는 경고(`Cannot use … latest version … requires ext-curl`)만 내고 직전 판을 설치하며(종료 코드 0), 이 판을 지정한 제약과 이 판이 든 lock 의 `composer install` 은 거부됩니다(Composer 는 확장을 설치 때 확인합니다).
- **(PHP)** IDE 호버에 뜨는 docblock(클래스와 public·protected 멤버)과 README 가 링크하는 `examples/quickstart.php` 의 주석을 영문으로 옮겼습니다 — 지금까지는 한글이었습니다. 코드와 PHPDoc 태그·타입은 그대로이고(phpstan 의 PhpDocParser 로 태그 70 · 타입 65 를 대조), 공개 선언 docblock 덤프의 한글은 343 줄 → 0 입니다.

### Security
- **(전 언어)** admin 이 Bearer 로 보내는 access token 을 아홉 언어가 같은 규칙으로 판정합니다 — 앞뒤의 SP·HTAB·CR·LF 를 떼고, 남은 값이 비지 않은 RFC 6750 `b64token`(ASCII 영숫자와 `-._~+/`, `=` 는 끝에만)이 아니면 요청을 보내지 않고 그 레인의 기존 오류로 끝냅니다(토큰은 인용하지 않습니다). SDK 의 토큰 provider 와 공개 provider 는 그런 토큰을 캐시하지 않습니다. 지금까지는 언어마다 안쪽 공백·탭·Latin-1·C1·U+0100 위·NBSP 를 그대로 보내거나 `?` 로 바꿔 보내거나 SDK 밖 예외로 실패했습니다(아래 줄들). ⚠️ 끝 개행을 거부하던 rust·.NET·go·python·ruby 와 앞뒤 공백·탭을 거부하던 ruby 도 이제 떼고 보냅니다(java·kotlin·php 는 아래처럼 그랜트 때 거부합니다).
- **(PHP)** admin 레인은 하위 라이브러리가 Bearer 를 직접 지으므로 그랜트 응답의 access token 이 다듬을 것 없는 `b64token` 일 때만 받습니다(`KeycloakAdminError`, 상태 없음) — sodium 이 없는 PHP 에서는 JWT 안쪽 공백·탭을 그대로 보냈고 `raw()` 의 psr7 예외가 Bearer 전체를 인용했습니다. 독립 `ClientCredentialsTokenProvider` 는 앞뒤를 떼고 받습니다.
- **(전 언어)** JWKS 키 집합은 그것을 받은 적재가 끝나고 300 초 뒤에 만료되고, 만료된 집합은 콜드 캐시와 같습니다 — 다음 검증이 콜드 적재 길(같은 단일 비행 · 같은 실패 백오프)로 다시 받고, 실패하면 거부합니다(낡은 키로 받지 않습니다). 지금까지는 수명이 언어마다 달랐고(node 600 초 · JVM 300 초 · .NET 12 시간 · python·go·rust·php·ruby 는 없음), 수명 없는 다섯은 IdP 가 뺀 키를 새 kid 토큰이 올 때까지, .NET 은 장애 중에도 계속 받았습니다. ⚠️ JWKS 에 300 초 넘게 닿지 못하면 검증이 실패합니다 — 의도된 판정입니다(닿지 않는 JWKS 와 IdP 가 뺀 키를 SDK 는 가를 수 없습니다).
- **(Python · Go · Rust · PHP · Node · Ruby · .NET)** 실패 백오프의 지터(×[0.5, 1.0))를 검사할 때마다 다시 뽑아, 같은 실패 하나가 190 ms 에는 거부하고 191 ms 에는 IdP 로 나갈 수 있었습니다 — 이제 실패할 때 한 번 뽑아 고정합니다.

## [1.4.1] - 2026-10-31 (Ruby)

**Ruby 의 patch 입니다**(같은 물결의 나머지는 위 `[1.5.1] - 2026-10-31 (PHP)` 절의 머리말). 공개 API 변경은 **0** 입니다. ⚠️ 같은 번호의 `[1.4.1] - 2026-10-23 (PHP)` 절(보관본 `changelog/2026-10.md`)은 다섯째 물결의 것이고 이 절과 무관합니다.

### Changed
- **(Java · Kotlin · Python · Ruby)** ⚠️ admin 응답은 목록과 `raw()` 의 성공 본문까지 설정한 타임아웃 안에 **다** 와야 합니다(아래 Security 의 응답 기한) — 지금까지는 읽기마다만 걸려 느린 링크의 큰 목록도 끝까지 받았지만, 이제 그 경우는 타임아웃 오류입니다. 큰 목록을 느린 링크로 받는다면 타임아웃을 늘리십시오. Go·Rust·Node·PHP·.NET admin 은 이미 그랬습니다.
- **(Ruby)** YARD 가 그리는 문서 주석(공개 API · 공개 메서드의 소스 보기 안 주석 포함)을 영문으로 옮겼습니다 — 지금까지는 한글이었습니다. 코드는 그대로이고(주석을 뗀 코드와 Ripper 토큰이 같다), `yard doc` 산출물의 한글은 26 파일 → 0 입니다.

### Fixed
- **(Ruby)** `KeycloakClient` 를 만들면 rack-oauth2 의 프로세스 전역 `Rack::OAuth2.http_config` 에 `Config` 의 타임아웃을 걸었습니다 — rack-oauth2 는 먼저 건 블록만 남기므로, SDK 가 먼저 만들어지면 호스트 애플리케이션이 나중에 건 블록이 조용히 버려졌습니다. SDK 의 요청은 그 연결을 쓰지 않으므로 이제 걸지 않습니다. ⚠️ 같은 프로세스에서 rack-oauth2 를 직접 쓰는 코드는 SDK 의 타임아웃을 더는 물려받지 않습니다 — 필요하면 직접 `Rack::OAuth2.http_config` 를 거세요.

### Security
- **(전 언어)** admin 이 Bearer 로 보내는 access token 을 아홉 언어가 같은 규칙으로 판정합니다 — 앞뒤의 SP·HTAB·CR·LF 를 떼고, 남은 값이 비지 않은 RFC 6750 `b64token`(ASCII 영숫자와 `-._~+/`, `=` 는 끝에만)이 아니면 요청을 보내지 않고 그 레인의 기존 오류로 끝냅니다(토큰은 인용하지 않습니다). SDK 의 토큰 provider 와 공개 provider 는 그런 토큰을 캐시하지 않습니다. 지금까지는 언어마다 안쪽 공백·탭·Latin-1·C1·U+0100 위·NBSP 를 그대로 보내거나 `?` 로 바꿔 보내거나 SDK 밖 예외로 실패했습니다(아래 줄들). ⚠️ 끝 개행을 거부하던 rust·.NET·go·python·ruby 와 앞뒤 공백·탭을 거부하던 ruby 도 이제 떼고 보냅니다(java·kotlin·php 는 아래처럼 그랜트 때 거부합니다).
- **(Ruby)** `BearerAuth`(파사드 · `raw`)와 SDK provider 가 같은 판정입니다(`AuthError`) — 지금까지는 앞뒤 공백·탭을 거부했고(이제 뗍니다) 안쪽 공백·ASCII 밖은 그대로 보냈습니다.
- **(전 언어)** JWKS 키 집합은 그것을 받은 적재가 끝나고 300 초 뒤에 만료되고, 만료된 집합은 콜드 캐시와 같습니다 — 다음 검증이 콜드 적재 길(같은 단일 비행 · 같은 실패 백오프)로 다시 받고, 실패하면 거부합니다(낡은 키로 받지 않습니다). 지금까지는 수명이 언어마다 달랐고(node 600 초 · JVM 300 초 · .NET 12 시간 · python·go·rust·php·ruby 는 없음), 수명 없는 다섯은 IdP 가 뺀 키를 새 kid 토큰이 올 때까지, .NET 은 장애 중에도 계속 받았습니다. ⚠️ JWKS 에 300 초 넘게 닿지 못하면 검증이 실패합니다 — 의도된 판정입니다(닿지 않는 JWKS 와 IdP 가 뺀 키를 SDK 는 가를 수 없습니다).
- **(Python · Go · Rust · PHP · Node · Ruby · .NET)** 실패 백오프의 지터(×[0.5, 1.0))를 검사할 때마다 다시 뽑아, 같은 실패 하나가 190 ms 에는 거부하고 191 ms 에는 IdP 로 나갈 수 있었습니다 — 이제 실패할 때 한 번 뽑아 고정합니다.
- **(Ruby)** admin 이 String 이 아닌 access token 에는 헤더 검사를 걸지 않았습니다 — 소비자 `TokenProvider` 가 CR·LF 를 담은 Symbol 을 돌려주면 `raw` 커넥션은 Bearer 전체를 인용한 raw `ArgumentError` 를, 파사드는 `TransportError`(`admin transport error: ArgumentError`)를 냈고, NUL·끝 공백을 담은 Symbol 은 그대로·공백이 지워진 채 나갔으며, `nil`·`""` 은 `Authorization: Bearer` 로 나갔습니다(실측). 이제 String 이 아닌 값도 헤더에 실릴 그 글로 같은 검사를 받아 String 과 같은 `AuthError` 이고, 빈 토큰은 요청 없이 `admin request not sent: the access token is empty` 입니다. 검사를 지나는 Symbol·숫자는 지금처럼 그 글로 나가고, SDK 의 `ClientCredentialsTokenProvider` 는 늘 비지 않은 String 이라 달라지지 않습니다. 공개 API 변경은 0 입니다.
- **(Java · Kotlin · Python · Ruby · .NET)** SDK 가 직접 읽는 응답(토큰·introspection·디스커버리·JWKS·admin)을 요청을 보낸 때부터 설정한 타임아웃 안에 **전부** 읽습니다 — 지금까지는 읽기마다만 걸려(.NET 의 디스커버리·JWKS 본문은 그것도 없이) 바이트를 읽기 타임아웃보다 조금 짧게 흘리는 서버가 호출 하나를 ≈ 상한 × 읽기 타임아웃 동안 붙잡았습니다(1 초 설정에 7 초 · JVM 은 흘린 TLS 레코드 하나로 33.6 초). 이제 그 레인의 기존 타임아웃 오류로 끝납니다(기한 + 읽기 하나 안 · python aio 와 .NET JWKS 는 기한 정확히). 남은 칸: JVM admin 의 헤더·청크 틀은 아직 읽기마다입니다.

## [1.2.5] - 2026-10-31 (Go)

**Go 의 patch 입니다**(같은 물결의 나머지는 위 `[1.5.1] - 2026-10-31 (PHP)` 절의 머리말). 공개 API 변경은 **0** 입니다.

### Changed
- **(Go)** pkg.go.dev 에 그려지는 문서 주석(마스킹 훅 여섯 · admin `Update` 셋의 ⚠️ 주석)을 영문으로 옮겼습니다 — 나머지는 이미 영문이었습니다. 코드는 그대로이고(`go/scanner` 로 주석을 뺀 토큰열이 같다), `go doc -all` 의 한글은 38 줄 → 0 입니다.

### Fixed
- **(Go)** 공유 비행(첫 `Client.Admin` · client_credentials 토큰 · JWKS 조회)의 결과와 호출자 ctx 의 취소가 함께 준비되면 둘 중 하나를 무작위로 돌려줬습니다(동점 200 회에 `context.Canceled` 93–103 회) — 이제 준비된 결과가 이깁니다(캐시 적중이 이미 그렇다). 결과가 아직 없으면 전처럼 ctx 오류입니다.

### Security
- **(전 언어)** admin 이 Bearer 로 보내는 access token 을 아홉 언어가 같은 규칙으로 판정합니다 — 앞뒤의 SP·HTAB·CR·LF 를 떼고, 남은 값이 비지 않은 RFC 6750 `b64token`(ASCII 영숫자와 `-._~+/`, `=` 는 끝에만)이 아니면 요청을 보내지 않고 그 레인의 기존 오류로 끝냅니다(토큰은 인용하지 않습니다). SDK 의 토큰 provider 와 공개 provider 는 그런 토큰을 캐시하지 않습니다. 지금까지는 언어마다 안쪽 공백·탭·Latin-1·C1·U+0100 위·NBSP 를 그대로 보내거나 `?` 로 바꿔 보내거나 SDK 밖 예외로 실패했습니다(아래 줄들). ⚠️ 끝 개행을 거부하던 rust·.NET·go·python·ruby 와 앞뒤 공백·탭을 거부하던 ruby 도 이제 떼고 보냅니다(java·kotlin·php 는 아래처럼 그랜트 때 거부합니다).
- **(Go)** `AdminClient` 와 공개 `NewClientCredentialsTokenProvider` 가 같은 판정입니다(`*AuthError`) — 지금까지는 공백뿐인 토큰을 `Authorization` 헤더 **없이** 보냈고 공개 provider 는 못 쓰는 토큰을 만료까지 캐시했습니다. 소비자 `TokenSource` 가 `(nil, nil)` 을 돌려주면 프로세스가 nil 역참조 패닉으로 죽던 것도 `*AuthError` 로 바꿨습니다(공유 비행 안의 패닉은 어느 호출자도 recover 할 수 없었습니다).
- **(전 언어)** JWKS 키 집합은 그것을 받은 적재가 끝나고 300 초 뒤에 만료되고, 만료된 집합은 콜드 캐시와 같습니다 — 다음 검증이 콜드 적재 길(같은 단일 비행 · 같은 실패 백오프)로 다시 받고, 실패하면 거부합니다(낡은 키로 받지 않습니다). 지금까지는 수명이 언어마다 달랐고(node 600 초 · JVM 300 초 · .NET 12 시간 · python·go·rust·php·ruby 는 없음), 수명 없는 다섯은 IdP 가 뺀 키를 새 kid 토큰이 올 때까지, .NET 은 장애 중에도 계속 받았습니다. ⚠️ JWKS 에 300 초 넘게 닿지 못하면 검증이 실패합니다 — 의도된 판정입니다(닿지 않는 JWKS 와 IdP 가 뺀 키를 SDK 는 가를 수 없습니다).
- **(Python · Go · Rust · PHP · Node · Ruby · .NET)** 실패 백오프의 지터(×[0.5, 1.0))를 검사할 때마다 다시 뽑아, 같은 실패 하나가 190 ms 에는 거부하고 191 ms 에는 IdP 로 나갈 수 있었습니다 — 이제 실패할 때 한 번 뽑아 고정합니다.

## [1.2.4] - 2026-10-31 (Java)

**Java 의 patch 입니다**(같은 물결의 나머지는 위 `[1.5.1] - 2026-10-31 (PHP)` 절의 머리말). 공개 API 변경은 **0** 입니다. ⚠️ 같은 번호의 `[1.2.4] - 2026-10-27 (Go)` 절(보관본 `changelog/2026-10.md`)은 여섯째 물결의 것이고 이 절과 무관합니다.

### Changed
- **(Java · Kotlin · Python · Ruby)** ⚠️ admin 응답은 목록과 `raw()` 의 성공 본문까지 설정한 타임아웃 안에 **다** 와야 합니다(아래 Security 의 응답 기한) — 지금까지는 읽기마다만 걸려 느린 링크의 큰 목록도 끝까지 받았지만, 이제 그 경우는 타임아웃 오류입니다. 큰 목록을 느린 링크로 받는다면 타임아웃을 늘리십시오. Go·Rust·Node·PHP·.NET admin 은 이미 그랬습니다.
- **(Java)** Maven Central 에 게시되는 `-javadoc.jar` 의 문서 주석(공개 API)과 README 가 링크하는 `QuickStart.java` 의 주석을 영문으로 옮겼습니다 — 다른 언어를 옮길 때 java 만 빠져 지금까지 한글이었습니다. 코드는 그대로이고(`javap -v -p` 가 main 빌드와 같다 — 59 클래스), javadoc jar 의 한글은 221 줄 → 0 입니다. 이로써 아홉 SDK 의 그려지는 문서가 모두 영문입니다.

### Security
- **(전 언어)** admin 이 Bearer 로 보내는 access token 을 아홉 언어가 같은 규칙으로 판정합니다 — 앞뒤의 SP·HTAB·CR·LF 를 떼고, 남은 값이 비지 않은 RFC 6750 `b64token`(ASCII 영숫자와 `-._~+/`, `=` 는 끝에만)이 아니면 요청을 보내지 않고 그 레인의 기존 오류로 끝냅니다(토큰은 인용하지 않습니다). SDK 의 토큰 provider 와 공개 provider 는 그런 토큰을 캐시하지 않습니다. 지금까지는 언어마다 안쪽 공백·탭·Latin-1·C1·U+0100 위·NBSP 를 그대로 보내거나 `?` 로 바꿔 보내거나 SDK 밖 예외로 실패했습니다(아래 줄들). ⚠️ 끝 개행을 거부하던 rust·.NET·go·python·ruby 와 앞뒤 공백·탭을 거부하던 ruby 도 이제 떼고 보냅니다(java·kotlin·php 는 아래처럼 그랜트 때 거부합니다).
- **(Java · Kotlin)** admin 라이브러리가 저장된 토큰을 직접 붙이므로, 그랜트 응답의 access token 이 다듬을 것 없는 `b64token` 일 때만 받습니다(아니면 `KeycloakTransportException`, 캐시 안 함) — 지금까지는 HTAB·SP·Latin-1 을 그대로, C1·U+0100 위를 HttpCore 가 `?` 로 바꿔 보냈습니다(실측).
- **(전 언어)** JWKS 키 집합은 그것을 받은 적재가 끝나고 300 초 뒤에 만료되고, 만료된 집합은 콜드 캐시와 같습니다 — 다음 검증이 콜드 적재 길(같은 단일 비행 · 같은 실패 백오프)로 다시 받고, 실패하면 거부합니다(낡은 키로 받지 않습니다). 지금까지는 수명이 언어마다 달랐고(node 600 초 · JVM 300 초 · .NET 12 시간 · python·go·rust·php·ruby 는 없음), 수명 없는 다섯은 IdP 가 뺀 키를 새 kid 토큰이 올 때까지, .NET 은 장애 중에도 계속 받았습니다. ⚠️ JWKS 에 300 초 넘게 닿지 못하면 검증이 실패합니다 — 의도된 판정입니다(닿지 않는 JWKS 와 IdP 가 뺀 키를 SDK 는 가를 수 없습니다).
- **(Java · Kotlin)** Nimbus 의 기본 TTL 300 초와 꺼진 outage tolerance 를 SDK 가 명시합니다(동작은 같습니다). refresh-ahead 는 남깁니다 — 만료 30 초 전의 검증이 뒤에서 한 번 갱신하고, 그 갱신이 실패해도 수명은 늘지 않습니다.
- **(Java · Kotlin · Python · Ruby · .NET)** SDK 가 직접 읽는 응답(토큰·introspection·디스커버리·JWKS·admin)을 요청을 보낸 때부터 설정한 타임아웃 안에 **전부** 읽습니다 — 지금까지는 읽기마다만 걸려(.NET 의 디스커버리·JWKS 본문은 그것도 없이) 바이트를 읽기 타임아웃보다 조금 짧게 흘리는 서버가 호출 하나를 ≈ 상한 × 읽기 타임아웃 동안 붙잡았습니다(1 초 설정에 7 초 · JVM 은 흘린 TLS 레코드 하나로 33.6 초). 이제 그 레인의 기존 타임아웃 오류로 끝납니다(기한 + 읽기 하나 안 · python aio 와 .NET JWKS 는 기한 정확히). 남은 칸: JVM admin 의 헤더·청크 틀은 아직 읽기마다입니다.

## [1.1.5] - 2026-10-31 (Rust)

**Rust 의 patch 입니다**(같은 물결의 나머지는 위 `[1.5.1] - 2026-10-31 (PHP)` 절의 머리말). 공개 API 변경은 **0** 입니다.

### Changed
- **(Rust)** docs.rs 에 그려지는 문서 주석(공개 항목 · 모듈 문서)과 README 가 링크하는 `examples/quickstart.rs` 의 주석을 영문으로 옮겼습니다 — 지금까지는 한글이었습니다. 코드는 그대로이고(바뀐 줄 전부가 주석), `cargo doc --no-deps` 산출물의 한글은 22 파일 → 0 입니다.

### Fixed
- **(Rust)** auth 레인이 토큰·introspection 응답의 JSON 값 뒤에 붙은 바이트를 버리고 받았습니다 — oauth2 가 값 하나만 읽어, `client_credentials_token`·`refresh`·`exchange_code`(`_with_redirect`)·`introspect`·`AuthClient` 의 `TokenProvider` 가 `{…}garbage`·`{…}{…}`·`{…}` + NUL 을 성공으로 돌려줬고 같은 꼬리를 단 400 오류 본문은 `Auth` 였습니다. admin 의 `ClientCredentialsTokenProvider` 는 같은 본문을 `Transport` 로 거부했습니다(실측). 이제 그 레인들도 상태와 무관하게 다른 형식 오류와 같은 `KeycloakError::Transport`(`token request failed: Failed to parse server response`)로 거부합니다. JSON 공백(SP·HTAB·LF·CR)만 붙은 본문은 전처럼 받습니다. 공개 API 변경은 0 입니다.

### Security
- **(전 언어)** admin 이 Bearer 로 보내는 access token 을 아홉 언어가 같은 규칙으로 판정합니다 — 앞뒤의 SP·HTAB·CR·LF 를 떼고, 남은 값이 비지 않은 RFC 6750 `b64token`(ASCII 영숫자와 `-._~+/`, `=` 는 끝에만)이 아니면 요청을 보내지 않고 그 레인의 기존 오류로 끝냅니다(토큰은 인용하지 않습니다). SDK 의 토큰 provider 와 공개 provider 는 그런 토큰을 캐시하지 않습니다. 지금까지는 언어마다 안쪽 공백·탭·Latin-1·C1·U+0100 위·NBSP 를 그대로 보내거나 `?` 로 바꿔 보내거나 SDK 밖 예외로 실패했습니다(아래 줄들). ⚠️ 끝 개행을 거부하던 rust·.NET·go·python·ruby 와 앞뒤 공백·탭을 거부하던 ruby 도 이제 떼고 보냅니다(java·kotlin·php 는 아래처럼 그랜트 때 거부합니다).
- **(Rust)** 파사드(`Transport`) · `raw()`(토큰 공급자의 `HttpFailure` 401) · provider(`Auth`)가 같은 판정입니다 — 지금까지는 U+00FF 위 글자를 날 UTF-8 헤더 바이트로, 안쪽 공백·Latin-1 을 그대로 보냈습니다.
- **(전 언어)** JWKS 키 집합은 그것을 받은 적재가 끝나고 300 초 뒤에 만료되고, 만료된 집합은 콜드 캐시와 같습니다 — 다음 검증이 콜드 적재 길(같은 단일 비행 · 같은 실패 백오프)로 다시 받고, 실패하면 거부합니다(낡은 키로 받지 않습니다). 지금까지는 수명이 언어마다 달랐고(node 600 초 · JVM 300 초 · .NET 12 시간 · python·go·rust·php·ruby 는 없음), 수명 없는 다섯은 IdP 가 뺀 키를 새 kid 토큰이 올 때까지, .NET 은 장애 중에도 계속 받았습니다. ⚠️ JWKS 에 300 초 넘게 닿지 못하면 검증이 실패합니다 — 의도된 판정입니다(닿지 않는 JWKS 와 IdP 가 뺀 키를 SDK 는 가를 수 없습니다).
- **(Python · Go · Rust · PHP · Node · Ruby · .NET)** 실패 백오프의 지터(×[0.5, 1.0))를 검사할 때마다 다시 뽑아, 같은 실패 하나가 190 ms 에는 거부하고 191 ms 에는 IdP 로 나갈 수 있었습니다 — 이제 실패할 때 한 번 뽑아 고정합니다.

## [1.0.8] - 2026-10-31 (Kotlin)

**Kotlin 의 patch 입니다**(같은 물결의 나머지는 위 `[1.5.1] - 2026-10-31 (PHP)` 절의 머리말). 공개 API 변경은 **0** 입니다.

### Changed
- **(Java · Kotlin · Python · Ruby)** ⚠️ admin 응답은 목록과 `raw()` 의 성공 본문까지 설정한 타임아웃 안에 **다** 와야 합니다(아래 Security 의 응답 기한) — 지금까지는 읽기마다만 걸려 느린 링크의 큰 목록도 끝까지 받았지만, 이제 그 경우는 타임아웃 오류입니다. 큰 목록을 느린 링크로 받는다면 타임아웃을 늘리십시오. Go·Rust·Node·PHP·.NET admin 은 이미 그랬습니다.
- **(Kotlin)** Dokka 가 그리는 문서 주석(게시되는 `-javadoc.jar` 포함)과 README 가 링크하는 `examples/quickstart.kt` 의 주석을 영문으로 옮겼습니다 — 지금까지는 한글이었습니다. 코드는 그대로이고(`javap -c` 역어셈블이 main 과 같다), Dokka HTML 의 한글은 41 파일 → 0 입니다.

### Security
- **(전 언어)** admin 이 Bearer 로 보내는 access token 을 아홉 언어가 같은 규칙으로 판정합니다 — 앞뒤의 SP·HTAB·CR·LF 를 떼고, 남은 값이 비지 않은 RFC 6750 `b64token`(ASCII 영숫자와 `-._~+/`, `=` 는 끝에만)이 아니면 요청을 보내지 않고 그 레인의 기존 오류로 끝냅니다(토큰은 인용하지 않습니다). SDK 의 토큰 provider 와 공개 provider 는 그런 토큰을 캐시하지 않습니다. 지금까지는 언어마다 안쪽 공백·탭·Latin-1·C1·U+0100 위·NBSP 를 그대로 보내거나 `?` 로 바꿔 보내거나 SDK 밖 예외로 실패했습니다(아래 줄들). ⚠️ 끝 개행을 거부하던 rust·.NET·go·python·ruby 와 앞뒤 공백·탭을 거부하던 ruby 도 이제 떼고 보냅니다(java·kotlin·php 는 아래처럼 그랜트 때 거부합니다).
- **(Java · Kotlin)** admin 라이브러리가 저장된 토큰을 직접 붙이므로, 그랜트 응답의 access token 이 다듬을 것 없는 `b64token` 일 때만 받습니다(아니면 `KeycloakTransportException`, 캐시 안 함) — 지금까지는 HTAB·SP·Latin-1 을 그대로, C1·U+0100 위를 HttpCore 가 `?` 로 바꿔 보냈습니다(실측).
- **(전 언어)** JWKS 키 집합은 그것을 받은 적재가 끝나고 300 초 뒤에 만료되고, 만료된 집합은 콜드 캐시와 같습니다 — 다음 검증이 콜드 적재 길(같은 단일 비행 · 같은 실패 백오프)로 다시 받고, 실패하면 거부합니다(낡은 키로 받지 않습니다). 지금까지는 수명이 언어마다 달랐고(node 600 초 · JVM 300 초 · .NET 12 시간 · python·go·rust·php·ruby 는 없음), 수명 없는 다섯은 IdP 가 뺀 키를 새 kid 토큰이 올 때까지, .NET 은 장애 중에도 계속 받았습니다. ⚠️ JWKS 에 300 초 넘게 닿지 못하면 검증이 실패합니다 — 의도된 판정입니다(닿지 않는 JWKS 와 IdP 가 뺀 키를 SDK 는 가를 수 없습니다).
- **(Java · Kotlin)** Nimbus 의 기본 TTL 300 초와 꺼진 outage tolerance 를 SDK 가 명시합니다(동작은 같습니다). refresh-ahead 는 남깁니다 — 만료 30 초 전의 검증이 뒤에서 한 번 갱신하고, 그 갱신이 실패해도 수명은 늘지 않습니다.
- **(Java · Kotlin · Python · Ruby · .NET)** SDK 가 직접 읽는 응답(토큰·introspection·디스커버리·JWKS·admin)을 요청을 보낸 때부터 설정한 타임아웃 안에 **전부** 읽습니다 — 지금까지는 읽기마다만 걸려(.NET 의 디스커버리·JWKS 본문은 그것도 없이) 바이트를 읽기 타임아웃보다 조금 짧게 흘리는 서버가 호출 하나를 ≈ 상한 × 읽기 타임아웃 동안 붙잡았습니다(1 초 설정에 7 초 · JVM 은 흘린 TLS 레코드 하나로 33.6 초). 이제 그 레인의 기존 타임아웃 오류로 끝납니다(기한 + 읽기 하나 안 · python aio 와 .NET JWKS 는 기한 정확히). 남은 칸: JVM admin 의 헤더·청크 틀은 아직 읽기마다입니다.

## [1.0.7] - 2026-10-31 (Python · .NET · Node)

**Python · .NET · Node 의 patch 입니다**(같은 물결의 나머지는 위 `[1.5.1] - 2026-10-31 (PHP)` 절의 머리말). 공개 API 변경은 **0** 입니다. .NET 의 키 회전 항목(Fixed)이 「그대로」라고 적은 last-known-good 은 그 뒤 착지한 .NET 항목(Security, 낡은 설정의 두 길)이 껐습니다. ⚠️ 같은 번호의 `[1.0.7] - 2026-10-27 (Kotlin)` 절(보관본 `changelog/2026-10.md`)은 여섯째 물결의 것이고 이 절과 무관합니다.

### Changed
- **(Java · Kotlin · Python · Ruby)** ⚠️ admin 응답은 목록과 `raw()` 의 성공 본문까지 설정한 타임아웃 안에 **다** 와야 합니다(아래 Security 의 응답 기한) — 지금까지는 읽기마다만 걸려 느린 링크의 큰 목록도 끝까지 받았지만, 이제 그 경우는 타임아웃 오류입니다. 큰 목록을 느린 링크로 받는다면 타임아웃을 늘리십시오. Go·Rust·Node·PHP·.NET admin 은 이미 그랬습니다.
- **(Node)** 방출되는 `.d.ts` 의 문서 주석(IDE 호버에 뜨는 것)과 README 가 링크하는 `examples/quickstart.ts` 의 주석을 영문으로 옮겼습니다 — 지금까지는 한글이었습니다. 코드와 공개 API 리포트는 그대로이고(api-extractor 리포트가 main 과 같다), `.d.ts` 의 한글은 19 파일 → 0 입니다.
- **(Python)** ⚠️ sync 응답은 응답마다 바이트 예산(본문 상한 + 65,536 B — 토큰·introspection·logout·admin 오류 1,114,112 · JWKS 116,736 · admin 성공 본문은 없음)을 넘으면 `KeycloakTransportError` 입니다 — 지금까지는 16 MiB 트레일러(트레일러 수를 묶지 않는 CPython 판에서)와 gzip 토큰 본문 뒤의 꼬리를 받았고, 틀이 큰 admin 오류 응답은 `KeycloakNotFoundError` 등으로 나왔습니다. JWKS 오류 메시지에 `HTTP response exceeds 116736 bytes on the wire` 가 실릴 수 있습니다.
- **(Python)** `help()`·IDE 호버에 뜨는 공개 API 의 독스트링(`keycloak_sdk`·`keycloak_sdk.aio` 의 `__all__` 에서 닿는 것)과 README 가 링크하는 예제 둘의 주석을 영문으로 옮겼습니다 — 지금까지는 한글이었습니다. 코드는 그대로이고(독스트링을 자리표시로 바꾼 AST 가 24 파일 모두 같다), 공개 표면 pydoc 의 한글은 358 줄 → 0 입니다.
- **(Node · Python)** ⚠️ 한글이던 런타임 오류 메시지 다섯을 영문으로 옮겼습니다 — node `KeycloakTokenValidationError` 의 `JWT 검증 실패: …` 는 `JWT validation failed: …`, python `KeycloakConfigError` 넷은 `admin API access requires client_secret (client-credentials grant)` · `admin access requires config (use KeycloakClient.create(config))`(aio 도 같은 꼴)입니다. 예외 타입과 원인 사슬은 그대로이고, 메시지 문자열을 대조하던 코드만 영향을 받습니다. 소비자에게 닿는 한글 문구는 이것이 전부였습니다 — 나머지 일곱은 0 입니다.

### Fixed
- **(Python)** README 가 `keycloak_sdk.aio` 는 이벤트 루프를 막지 않는다고 적었습니다 — 요청은 전부 await 하지만, `AsyncKeycloakClient.create(config)` 와 첫 `kc.admin` 접근은 호출 스레드에서 HTTP 클라이언트를 만들고 TLS 신뢰 저장소를 읽습니다(Windows 에서는 1 초에 가까울 수 있습니다). README 를 고쳤습니다 — 클라이언트는 앱이 시작할 때 한 번 만들어 재사용하세요. 동작은 바뀌지 않았습니다.
- **(.NET)** IdP 가 서명 키를 회전하면 새 `kid` 의 첫 토큰을 IDX10503 으로 거부하고 다음 토큰부터 받았습니다(실측) — 키를 못 찾은 Microsoft.IdentityModel 핸들러가 `RequestRefresh()` 를 부르면 그 매니저는 재조회를 배경(`Task.Run`)에 띄우고 곧장 돌아와, 핸들러가 같은 설정을 다시 받아 재시도하지 않았기 때문입니다. 이제 그 재조회는 SDK 가 돌리고, 요청한 검증이 같은 호출 안에서 기다려 새 키로 다시 검증합니다(재조회 한 번). 30 초 창(결정할 때 찍고 실패도 창을 씁니다)·단일 비행·호출자가 취소해도 끝까지 가는 재조회·실패 백오프·last-known-good 은 그대로이고, 키가 풀리는 토큰은 기다리지 않습니다. 프로세스 전역 AppContext 스위치는 건드리지 않습니다.
- **(.NET)** 소비자 `ITokenProvider` 가 admin 호출 안에서 던진 `JsonException` 을 typed 읽기·쓰기 아홉 호출(본문 없는 `DeleteAsync` 까지)이 「요청 본문을 JSON 으로 인코딩할 수 없다」는 `KeycloakTransportException` 으로 바꿨습니다(실측) — 토큰 제공자는 요청 본문보다 먼저 불리는데, 응답 전의 `JsonException` 을 전부 요청 본문 실패로 읽었기 때문입니다. 이제 제공자의 예외가 그대로 나갑니다 — `AdminClient.CreateAsync` 의 예열·typed 생성·raw 호출이 이미 그랬습니다. 요청 본문을 쓰지 못한 실패는 그 메시지 그대로입니다.

### Security
- **(전 언어)** admin 이 Bearer 로 보내는 access token 을 아홉 언어가 같은 규칙으로 판정합니다 — 앞뒤의 SP·HTAB·CR·LF 를 떼고, 남은 값이 비지 않은 RFC 6750 `b64token`(ASCII 영숫자와 `-._~+/`, `=` 는 끝에만)이 아니면 요청을 보내지 않고 그 레인의 기존 오류로 끝냅니다(토큰은 인용하지 않습니다). SDK 의 토큰 provider 와 공개 provider 는 그런 토큰을 캐시하지 않습니다. 지금까지는 언어마다 안쪽 공백·탭·Latin-1·C1·U+0100 위·NBSP 를 그대로 보내거나 `?` 로 바꿔 보내거나 SDK 밖 예외로 실패했습니다(아래 줄들). ⚠️ 끝 개행을 거부하던 rust·.NET·go·python·ruby 와 앞뒤 공백·탭을 거부하던 ruby 도 이제 떼고 보냅니다(java·kotlin·php 는 아래처럼 그랜트 때 거부합니다).
- **(Python)** sync 는 앞 탭·안쪽 공백·Latin-1·C1·NBSP 를 그대로 보냈고 aio 는 안쪽 공백을 보냈으며, 끝 개행은 두 레인 모두 다듬지 않고 거부했습니다 — 이제 두 레인이 같은 판정입니다(`KeycloakAuthError`).
- **(Node)** 파사드·`raw()`·공개 `ClientCredentialsTokenProvider` 가 같은 판정입니다(`KeycloakAuthError`, 원인 없음) — 지금까지는 안쪽 공백·Latin-1·C1·NBSP 를 보냈고, DEL·VT 는 `fetch` 안에서 실패해 `raw()` 로 SDK 밖 `TypeError` 가 샜습니다. 끝 개행 떼기는 undici 가 아니라 SDK 가 합니다.
- **(.NET)** `BearerHandler`(typed · raw REST · `Raw`)와 SDK 토큰 provider 가 같은 판정입니다(보낼 때 `KeycloakTransportException` · SDK 그랜트 `KeycloakAuthException`) — 지금까지는 안쪽 HTAB·SP 를 그대로(Keycloak 26.6 은 401), null·빈 값을 맨 `Bearer` 로 보냈고, ASCII 밖은 `Raw` 로 SDK 밖 `HttpRequestException` 이었습니다.
- **(전 언어)** JWKS 키 집합은 그것을 받은 적재가 끝나고 300 초 뒤에 만료되고, 만료된 집합은 콜드 캐시와 같습니다 — 다음 검증이 콜드 적재 길(같은 단일 비행 · 같은 실패 백오프)로 다시 받고, 실패하면 거부합니다(낡은 키로 받지 않습니다). 지금까지는 수명이 언어마다 달랐고(node 600 초 · JVM 300 초 · .NET 12 시간 · python·go·rust·php·ruby 는 없음), 수명 없는 다섯은 IdP 가 뺀 키를 새 kid 토큰이 올 때까지, .NET 은 장애 중에도 계속 받았습니다. ⚠️ JWKS 에 300 초 넘게 닿지 못하면 검증이 실패합니다 — 의도된 판정입니다(닿지 않는 JWKS 와 IdP 가 뺀 키를 SDK 는 가를 수 없습니다).
- **(Python · Go · Rust · PHP · Node · Ruby · .NET)** 실패 백오프의 지터(×[0.5, 1.0))를 검사할 때마다 다시 뽑아, 같은 실패 하나가 190 ms 에는 거부하고 191 ms 에는 IdP 로 나갈 수 있었습니다 — 이제 실패할 때 한 번 뽑아 고정합니다.
- **(Python)** 실패 백오프의 지수에 상한이 없어, 연속 실패가 약 1,025 번을 넘으면 `OverflowError` 로 JWKS 를 다시는 받지 못했습니다(IdP 가 돌아와도 — 1,100 번에서 재현) — 지수를 16 에서 묶었습니다.
- **(.NET)** 낡은 설정으로 받던 두 길을 막았습니다 — `ConfigurationManager` 는 갱신 간격이 지나도 쥔 설정을 돌려주고 뒤에서 새로 받으며 실패는 로그만 남겼고, 처리기는 적재 실패(IDX10500)를 last-known-good 설정으로 다시 검증했습니다(그 수명은 마지막 수락부터 1 시간). 이제 SDK 가 다시 받을 때 매니저를 새로 지어 콜드 적재로 받고 last-known-good 은 껐습니다 — 회전으로 IdP 가 뺀 키의 토큰을 더는 받지 않습니다.
- **(Java · Kotlin · Python · Ruby · .NET)** SDK 가 직접 읽는 응답(토큰·introspection·디스커버리·JWKS·admin)을 요청을 보낸 때부터 설정한 타임아웃 안에 **전부** 읽습니다 — 지금까지는 읽기마다만 걸려(.NET 의 디스커버리·JWKS 본문은 그것도 없이) 바이트를 읽기 타임아웃보다 조금 짧게 흘리는 서버가 호출 하나를 ≈ 상한 × 읽기 타임아웃 동안 붙잡았습니다(1 초 설정에 7 초 · JVM 은 흘린 TLS 레코드 하나로 33.6 초). 이제 그 레인의 기존 타임아웃 오류로 끝납니다(기한 + 읽기 하나 안 · python aio 와 .NET JWKS 는 기한 정확히). 남은 칸: JVM admin 의 헤더·청크 틀은 아직 읽기마다입니다.
- **(Python)** sync 레인은 상태 줄·헤더·청크 크기 줄·트레일러·TLS 레코드까지 소켓의 원문 읽기마다 기한을 봅니다 — 위 줄의 본문 기한만으로는 그것들을 흘리는 서버가 http.client 한 호출 안에서 7 초를 붙잡았습니다(1 초 설정). 이제 약 1.0 초에 같은 `KeycloakTransportError` 로 끝납니다. 남은 칸: HTTPS 프록시(TLS 안의 TLS).
- **(Node)** `AuthClient` 가 만드는 검증기는 JWKS 응답을 보낸 때부터 설정한 `readTimeoutMs` 안에 **전부** 읽습니다 — 지금까지는 설정과 무관하게 jose 자신의 5 초여서, 흘리거나 멈춘 JWKS 가 1 초 설정에서도 검증 하나를 5 초 붙잡았고 5 초보다 느린 IdP 는 설정이 그보다 길어도 거부됐습니다. 이제 1 초 설정에서 약 1.04 초에 실패하고(흘리기·멈춤 둘 다), 5.5 초 늦은 IdP 는 8 초 설정에서 받습니다. 설정 없이 만든 단독 `JwtValidator.forJwksUri` 는 지금처럼 jose 의 5 초입니다.

