# Changelog

이 프로젝트의 주요 변경사항을 기록합니다. 형식은 [Keep a Changelog](https://keepachangelog.com/ko/1.1.0/)를 따르며, 버전은 [SemVer](https://semver.org/lang/ko/)를 지향합니다.

> 이 리포지토리는 **폴리글랏 SDK**입니다. Java(`io.github.xzawed:keycloak-sdk`)·Python(`keycloak-sdk`)·Node(`@xzawed/keycloak-sdk`)·Go(`github.com/xzawed/KeyCloakSDK/go`)·C#/.NET(`Xzawed.Keycloak.Sdk`)·PHP(`xzawed/keycloak-sdk`)·Rust(`keycloak-sdk`)·Ruby(`keycloak-sdk`)·Kotlin(`io.github.xzawed:keycloak-sdk-kotlin`) 9개 언어가 독립 배포되며, 아래 항목은 언어 태그로 구분합니다. 지금까지 아홉 언어 전부가 **`1.0.0`**을 게시했습니다 — 같은 릴리스 물결에서 도달한 것은 1.0 기준(`git show d4e8958:docs/superpowers/plans/release-1.0.md`)의 A–G를 아홉 곳이 동시에 충족했기 때문이지 함대로 움직여서가 아닙니다(태그는 2026-08-30~09-01에 걸쳐 있고, 이후에는 다시 갈립니다). 그 아래 `[0.2.x]`·`[0.1.x]`·RC 항목은 그대로 역사로 남습니다. ⚠️ 어느 레지스트리에 실제로 올라갔는지는 이 파일이 아니라 `scripts/lib/deploy-facts.sh`의 `df_published_version`이 소유합니다 — 태그를 밀었다는 것과 게시됐다는 것은 다릅니다.

## [Unreleased]

### Security
- **(Kotlin)** IdP 가 이 요청이 보낸 값(클라이언트 시크릿·Basic 자격·refresh·introspect 토큰·인가 코드·verifier)을 `error_description` 에 다시 인코딩해 되울리면 `KeycloakAuthException` 의 메시지가 그 값을 찍었습니다 — 1.0.5 는 그대로의 꼴·Nimbus 가 지운 꼴·폼 인코딩된 꼴만 가려, RFC 3986 퍼센트 인코딩(「Client credentials failed: Bad credentials: sec%20ret%2F%2B%3D~0005%C3%A9」)·소문자 16진, 그리고 인코더마다 그대로 두는 글자가 다른 꼴(Go `url.QueryEscape`·Python `quote`·JS `encodeURI`·`escape`·ISO-8859-1 폼)·한 번 더 인코딩된 꼴·`%uXXXX`·HTML 숫자 참조로 온 값은 통째로 찍혔습니다(`clientCredentialsToken`·`refresh`·`introspect`·`exchangeCode` — `logout` 은 IdP 문구를 싣지 않습니다). 이제 보낸 값마다 그 꼴들과 함께, 퍼센트·`%u`·`\u`·`&#…;` 이스케이프를 두 겹까지 풀었을 때 그 값(UTF-8·ISO-8859-1·UTF-8 을 ISO-8859-1 로 읽은 깨진 꼴)이 되는 구간을 `***` 로 가리고, 사유 문구는 그대로 남습니다. 보내지 않은 값은 지금처럼 가리지 않습니다. admin 도 그랬습니다 — 내장 TokenManager 의 토큰 요청이 오류(400·401·503 등)를 받으면 `KeycloakTransportException`(`Admin request failed`)의 원인 사슬에 그 본문을 버퍼에 담은 `Response` 를 쥔 `NotAuthorizedException` 등이 남아, `close()` 뒤에도 `readEntity(String::class.java)` 가 본문(되울린 시크릿 포함)을 돌려줬습니다. 이제 그 사슬은 타입 이름과 프레임만 남긴 사본입니다 — 예외 타입·메시지는 그대로이고, 원인 사슬에서 `WebApplicationException` 을 꺼내던 코드는 그것을 더 받지 않습니다(admin 자원 오류 `KeycloakAdminException` 의 원인은 그대로). 공개 API 변경은 0 입니다.

## [1.4.0] - 2026-10-05 (PHP)

**2026-10-05 넷째 릴리스 물결 — 아홉 언어가 일곱 번호로 올라갑니다.** 셋째 물결(아래 `[1.3.0] - 2026-10-02 (PHP)` 절의 머리말) 뒤에 착지한 수정(#705–#723)을 싣습니다 — 아홉 언어 전부의 토큰 응답 1 MiB 상한(토큰·introspection 응답 본문을 1,048,576 바이트까지만 읽습니다 — logout·discovery·admin 의 자기 토큰 부여까지 덮는 범위는 언어마다 다르고 각 항목이 적습니다)과 Python sync 가 gzip 으로 부풀린 JWKS 를 51,200 바이트 상한을 판정하기 전에 한 번에 풀던 것(urllib3 2.6 미만), JWKS 강제 재조회 창을 호출자의 취소·인터럽트가 헛되이 쓰던 것(Go · Rust · Python `aio` · Java)과 장애 중에도 kid 마다 재조회하던 것(Node), Go 에서 그 창이 IdP 에 요청을 보내지 않은 `Validate` 에 찍히던 것과 JWKS 조회가 끝나는 순간과 겹친 `Validate` 가 낡은 miss 로 판정하던 것, `ValidateAsync` 가 `CancellationToken` 을 버리던 것(.NET), 디코드할 수 없는 응답과 헤더에 실을 수 없는 토큰이 하위 예외로 새던 것(.NET · Node · Ruby · PHP · Python — Python 은 UTF-8 이 아닌 admin 오류 본문의 `UnicodeDecodeError` 와, gzip·deflate 라고 표시만 하고 압축되지 않은 JWKS 본문에서 `aio` 가 낸 `zlib.error`), Kotlin 의 되울린 토큰·시크릿 마스킹 둘, Python admin 하드닝의 재확인, OAuth 오류 코드 검사(PHP · .NET)입니다. 공개 API 가 늘어난 셋은 minor 입니다 — PHP `1.4.0`(이 절 — 늘어난 것은 아래 Security 첫 항목 끝), Ruby `1.3.0`, Java `1.1.0`. 나머지는 patch 입니다 — Go `1.2.2`, Rust `1.1.3`, Kotlin `1.0.5`, Python · .NET · Node `1.0.4`(아래 절들). 실제로 어디까지 게시됐는지는 이 파일이 아니라 `scripts/lib/deploy-facts.sh` 의 `df_published_version` 이 소유합니다.

⚠️ **같은 번호의 절이 앞 물결에도 있습니다** — `[1.3.0]` 은 Ruby(이 물결)와 PHP(2026-10-02 셋째 물결), `[1.1.0]` 은 Java(이 물결)와 Ruby(2026-09-26 둘째 물결) · Go · PHP · Rust(2026-09-26 첫 물결), `[1.0.4]` 는 Python · .NET · Node(이 물결)와 Java · Kotlin(2026-10-02 셋째 물결)입니다. 번호는 언어별로 독립이라 제목의 언어 목록으로 가릅니다. ⚠️ **소비자가 알아야 할 동작 변화** — (1) 아홉 언어 모두 1 MiB 를 넘는 토큰·introspection 응답은 쓸 수 있는 토큰을 담았어도 거부하고, admin 은 그때 admin 요청을 보내지 않습니다(오류 타입은 언어마다 아래 항목). (2) Python admin 의 `raw` 는 그 클래스의 하위 클래스 인스턴스가 됩니다 — 정확한 타입 비교만 거짓이고, 그렇게 바꿀 수 없는 주입 admin 은 생성 때 `KeycloakConfigError` 입니다. (3) Go `NewClientCredentialsTokenProvider` 에 넘기는 `TokenSource` 는 호출자의 취소로 끝나지 않는 `ctx` 를 받습니다(갱신이 시작되고 60초 뒤 `context.DeadlineExceeded`). (4) Node 는 강제 재조회가 실패하면 그 창(최대 30초)이 끝날 때까지 회전한 새 키의 토큰도 거부합니다. (5) Ruby 의 토큰·introspection·logout·JWKS 요청은 `Accept-Encoding: identity` 를 보내 gzip 으로 답하는 서버에서 실패하고, 세 그랜트는 rack-oauth2 의 전역 연결이 아니라 SDK 커넥션으로 나갑니다. (6) .NET 의 raw admin 경로 메시지 `admin response body was not valid JSON` 이 `admin response body could not be decoded` 로 바뀌었습니다.

### Fixed
- **(PHP)** IdP 오류 응답의 `error` 가 OAuth 코드 모양 뒤에 줄바꿈을 하나 달고 오면(`"invalid_client\n"`) 그 줄바꿈째 코드로 받아, `KeycloakAuthError` 의 메시지와 `oauthError`, 원인(`getPrevious()`)의 메시지, admin 토큰 부여 실패(`KeycloakAdminError`)의 메시지에 실었습니다 — 그 오류를 찍는 로그 한 줄이 둘로 갈립니다(토큰·시크릿은 실리지 않습니다). 코드 모양 검사의 끝 닻 `$` 가 `D` 수식자 없이 쓰여 끝 줄바꿈 하나 앞에서도 맞았기 때문입니다. 이제 `error` 는 정확히 `[a-z_]{1,64}` 일 때만 코드로 싣고(`\A…\z`) 그 밖의 값은 싣지 않습니다(`oauthError` 는 `null`). CR·CRLF 로 끝나는 값은 전에도 걸렀습니다. 공개 API 변경은 0 입니다.

### Security
- **(PHP)** 토큰 엔드포인트·introspection·logout 의 응답 본문을 크기 제한 없이 읽었습니다 — `clientCredentialsToken()`·`refresh()`·`exchangeCode()`·`ClientCredentialsTokenProvider::getToken()`·`introspect()`·admin 의 자기 토큰 부여(fschmtt)가 쓸 수 있는 토큰 뒤에 JSON 공백 32 MiB 를 붙인 응답을 전부 받아들였고(zend 피크 앞의 셋 75 MB — league 가 본문 사본을 둘 쥐었습니다 — 그 밖 40 MB), memory_limit 보다 큰 본문은 잡을 수 없는 치명 오류(`Allowed memory size … exhausted`, exit 255)로 프로세스를 끝냈습니다. `logout()` 은 본문을 쓰지 않는데도 Guzzle 이 그것을 끝까지 받아, 16 MiB 본문이면 200·400 모두 16 MiB 를 다 받아 임시 파일에 썼습니다(php://temp 는 2 MB 를 넘으면 디스크로 옮깁니다). 이제 일곱 레인 모두 본문을 1,048,576 바이트(gzip 은 푼 뒤)까지만 한 번 읽고 읽은 만큼만 메모리를 잡으며(32 MiB 본문을 거부하는 호출의 zend 피크 약 5 MB, memory_limit 24M 에서도 치명 오류 없이), 넘으면 오류 상태(4xx)의 본문이어도 `KeycloakTransportError` 로 실패합니다 — 메시지는 `token response exceeds 1048576 bytes`, introspect 는 `introspection response exceeds 1048576 bytes`, logout 은 `logout response exceeds 1048576 bytes`, admin 은 admin 요청을 보내지 않고 `admin token response exceeds 1048576 bytes` 입니다. admin 의 탈출구 `raw()`(fschmtt 클라이언트)를 거친 호출은 같은 경우 admin 요청 없이 Guzzle `RequestException`(같은 메시지, 응답·원인 없음 — `GuzzleException` 으로 잡힙니다)을 받습니다(전에는 그 응답을 받아들였습니다). SDK 가 만든 클라이언트의 여섯 레인은 그 근처에서 전송도 끊습니다(전송은 지금처럼 curl 입니다). PSR-18 클라이언트를 주입받는 `ClientCredentialsTokenProvider` 는 그 클라이언트가 받아 둔 본문을 상한까지만 읽습니다. 이 상한은 Keycloak 26.6 이 기본 설정으로 받아들이는 가장 긴 Bearer(65,459 바이트)의 16 배라, 서버가 받는 토큰은 거부하지 않습니다. 본문 읽기가 실패하면(지연 본문을 주는 주입 클라이언트) `introspect()`·`getToken()` 이 raw `\RuntimeException` 대신, `logout()` 은 2xx 에서 돌아오는 대신 `KeycloakTransportError`(`… response could not be read`)를 던집니다. JWKS 상한(51,200 바이트)과 admin REST 응답은 그대로입니다. 공개 API 는 상수 하나가 늘었습니다 — `Xzawed\Keycloak\Admin\ErrorTranslation::TOKEN_PATH`(`private` 이던 것이 `public` 이 됐습니다 — 그래서 1.4.0 은 minor 입니다). 그 밖의 공개 API 변경은 없습니다.
- **(PHP)** admin 이 헤더에 실을 수 없는 access token(CR·LF·CRLF 를 담은 것)을 받으면 그 오류(`KeycloakAdminError`, `admin request failed unexpectedly`)의 원인 메시지가 Bearer 토큰을 통째로 인용했습니다 — psr7 이 거부한 헤더 값을 `"Bearer <토큰>" is not valid header value.` 로 인용하고 `SanitizedCause` 가 그 메시지를 감사한 라이브러리의 것으로 옮겨, 토큰이 `getPrevious()->getMessage()`·`(string)$e`·`var_dump`·`print_r` 에 찍혔습니다(sodium 확장이 없는 PHP 에서 — lcobucci 가 base64 의 공백을 건너뛰어 그 토큰을 받아들입니다. sodium 이 있으면 lcobucci 가 먼저 거부해 토큰이 찍히지 않습니다). 이제 psr7 의 헤더 검증이 던진 예외는 원인 메시지가 `(message withheld: it quotes a header value)` 이고 원본 클래스명(`InvalidArgumentException`)은 남습니다. 예외 타입과 메시지는 그대로이고, 토큰을 고쳐 쓰지 않으며 요청은 지금처럼 나가지 않습니다. introspect·refresh·logout 은 토큰을 폼 본문에 percent-encode 해 실어 이 경로가 없습니다. 공개 API 변경은 0 입니다.

## [1.3.0] - 2026-10-05 (Ruby)

**Ruby 의 minor 입니다**(같은 물결의 나머지는 위 `[1.4.0]` 절의 머리말) — 공개 API 가 상수 `Http::TOKEN_RESPONSE_MAX_BYTES` 와 헬퍼 `Http.read_capped` · `Http.decode_json` · `Http.utf8?` 로 늘었습니다. ⚠️ 같은 번호의 `[1.3.0] - 2026-10-02 (PHP)` 절(아래)은 셋째 물결의 것이고 이 절과 무관합니다.

### Security
- **(Ruby)** 토큰 엔드포인트·introspection·logout 의 응답 본문을 크기 제한 없이 통째로 읽었습니다 — `client_credentials_token`·`access_token`·`refresh`·`exchange_code`(rack-oauth2 가 자기 연결로 읽습니다)와 `introspect`, admin 이 쓰는 `ClientCredentialsTokenProvider` 모두, 쓸 수 있는 토큰 뒤에 JSON 공백 32 MiB 를 붙인 응답을 받아들였고 호출 하나에 프로세스 피크가 +86 MB 였습니다(gzip 으로 보낸 32 KB 도 같았습니다). 본문을 쓰지 않는 `logout` 도 16 MiB 본문을 끝까지 읽었고(할당 ~50 MB) 200 이면 그대로 성공했습니다. 이제 여섯 레인 모두 본문을 1,048,576 바이트까지만 읽고 읽은 만큼만 메모리를 잡습니다(32 MiB 본문을 거부하는 호출이 피크 +1.5 MB, 16 MiB 를 거부하는 `logout` 은 할당 ~2.2 MB) — Keycloak 26.6 이 기본 설정으로 받는 가장 긴 Bearer(65,459 바이트)의 16 배라 서버가 받는 토큰은 거부하지 않습니다. 넘으면 상태와 무관하게 `KeycloakSdk::TransportError`(`token response exceeds 1048576 bytes`, introspect 는 `introspection response exceeds 1048576 bytes`, logout 은 `logout response exceeds 1048576 bytes`)이고 admin 은 admin 요청을 보내지 않습니다. 상한 안에서 `logout` 의 결과는 그대로입니다(2xx 는 `nil`, 그 밖은 `AuthError`). 토큰·introspection·logout·JWKS 요청은 `Accept-Encoding: identity` 를 보냅니다(`logout` 이 보내는 것은 그 밖에 그대로입니다) — net-http 가 gzip 을 풀다 상한에서 끊기면 그때 읽은 압축 조각을 끝까지 풀어, JWKS 상한(51,200 바이트)이 지켜진 채로도 +24 MB 를 잡았습니다. ⚠️ 그래도 gzip 으로 답하는 서버는 압축된 바이트를 읽을 수 없어 실패합니다 — Content-Type 이 JSON 이면 `TransportError`, 아니면 압축되지 않은 text/plain 본문과 같은 `AuthError` 이고, JWKS 는 `TransportError` 입니다. ⚠️ 세 그랜트는 이제 rack-oauth2 의 프로세스 전역 연결이 아니라 SDK 커넥션으로 나갑니다 — `Config` 의 타임아웃이 클라이언트마다 걸리고, `User-Agent` 는 Faraday 기본값이 되며, 클라이언트 인증(HTTP Basic)·요청 파라미터·오류 대응은 그대로입니다. 빈 `code`·`refresh_token` 은 요청 없이 `AuthError`(`… failed: code is required`)입니다 — 전에는 raw `AttrRequired::AttrMissing` 이 샜습니다. admin REST 응답은 그대로입니다. 공개 API 는 상수 `Http::TOKEN_RESPONSE_MAX_BYTES` 와 내부 헬퍼 `Http.read_capped`·`Http.decode_json` 이 늘었고 그 밖의 변경은 없습니다.
- **(Ruby)** 잘못된 UTF-8 로 풀리는 응답과 헤더에 실을 수 없는 토큰이 하위 라이브러리 예외로 SDK 밖에 나왔고, 그중 하나는 토큰을 찍었습니다(§4). 잠긴 json 3.0.2 도 문자열 안의 날 잘못된 UTF-8 바이트(예: 0xFF)는 그대로 받아들이고, json 2.9–2.21 은 짝 없는 낮은 서로게이트 이스케이프(`\udc00`)까지 잘못된 UTF-8 로 풉니다 — 그런 토큰 응답에서 세 그랜트는 raw `ArgumentError`(OAuth 오류 코드 대조 — 원인 사슬에 서버가 보낸 `error_description` 이 실렸습니다)를, admin 은 raw `Encoding::CompatibilityError` 를 냈고, 그런 introspect 결과·토큰은 그대로 돌아갔으며, n·e 가 그런 JWKS 에서는 `validate` 가 raw `ArgumentError`(ruby-jwt 의 base64)를 냈습니다. admin 은 CR·LF 를 담은 access token 에서 **Bearer 전체를 메시지에 인용한** raw `ArgumentError` 를, 65,530 바이트 이상에서 raw `ArgumentError` 를 냈습니다. 잘못된 UTF-8 인 입력은 `validate`·`introspect`·`logout` 에서 raw `ArgumentError` 였습니다. 이제 값을 고쳐 쓰지 않고 전부 SDK 오류로 거부합니다 — 토큰·introspection 응답은 json 3 이 짝 없는 서로게이트를 거부할 때와 같은 `TransportError`(`token endpoint transport error: Faraday::ParsingError`, introspect 는 `introspection transport error: …`), JWKS 는 `TransportError`(`JWKS response unparsable (JSON::ParserError)` — 검증은 실패 쪽으로 닫힙니다), admin 의 Bearer 는 요청 없이 `AuthError`(`admin request not sent: the access token holds CR or LF, which an HTTP header cannot carry` · `… is not valid UTF-8` · `… (N bytes) does not fit an HTTP header field (65536 bytes with "Bearer ")`), 잘못된 UTF-8 토큰의 `validate` 는 `TokenValidationError`(`JWT validation failed: token is not valid UTF-8`), `introspect`·`logout`·세 그랜트는 요청 없이 `AuthError`(`… failed: <자리> is not valid UTF-8`)입니다. NUL·U+00FF 위 문자를 담은 토큰은 지금처럼 그대로 보냅니다(판정은 서버). admin REST 응답의 해석은 그대로입니다. JSON 버전과 무관하게 같은 결과입니다(json 3.0.2 · 2.21.2 에서 전체 단위 시험 통과). 공개 API 는 헬퍼 `Http.utf8?` 이 늘었고 그 밖의 변경은 없습니다.

## [1.2.2] - 2026-10-05 (Go)

**Go 의 patch 입니다**(같은 물결의 나머지는 위 `[1.4.0]` 절의 머리말). 공개 API 변경은 **0** 입니다.

### Fixed
- **(Go)** 호출자가 취소한 JWKS 강제 재조회가 30초 창을 써 버렸습니다 — 키가 회전된 뒤 첫 `Validate` 의 `ctx` 가 이미 취소됐거나 재조회 도중 취소되면, 그 조회는 IdP 에 닿지 않았거나 중간에 끊겼는데도 창이 소진돼, 같은 창 안에서 회전된 키의 토큰이 `(refetch rate-limited)` 로 거부됐습니다(실측: 미리 취소 /certs 1→1, 비행 중 취소 1→2, 이어지는 산 검증은 둘 다 거부). 이제 재조회는 어느 호출자의 취소에도 묶이지 않고(JWKS HTTP 클라이언트의 `Config.ReadTimeout` 만이 묶습니다) 끝나면 캐시를 채우며, 취소된 호출자는 지금처럼 곧바로 `context.Canceled` 를 감싼 `*TokenValidationError` 로 돌아오고, 이미 취소된 호출자는 창을 쓰지도 IdP 에 요청하지도 않습니다. 같은 부류 셋도 함께 고쳤습니다 — 창 안에서 그 창의 재조회가 아직 비행 중이면 둘째 호출자가 즉시 거부되지 않고 그 결과를 기다리며, 콜드 캐시에서 첫 호출자의 취소가 같이 기다리던 호출자를 실패시키거나 실패 백오프를 올리지 않고, admin 레인의 두 공유 비행(`Client.Admin` 의 생성 · 만료된 토큰의 갱신)도 첫 호출자의 취소로 대기자를 실패시키지 않습니다(취소된 호출자는 `errors.Is(err, context.Canceled)` 가 참인 `*TransportError` — 전에는 거짓이었습니다). IdP 가 503 처럼 **실패로 답한** 강제 재조회가 창을 쓰는 것은 그대로입니다. ⚠️ `NewClientCredentialsTokenProvider` 에 넘기는 `TokenSource` 는 이제 취소되지 않는 `ctx`(갱신을 시작한 호출자의 값은 유지)를 받습니다 — 직접 넘기는 소스는 자기 I/O 에 시간 제한을 둬야 합니다. 다만 그 `ctx` 는 갱신이 시작되고 60초 뒤에 `context.DeadlineExceeded` 로 끝납니다 — 자기 시간 제한 없이 `ctx` 로만 끝나는 소스(예: 기본 `http.Client` 로 `clientcredentials.Config.Token(ctx)` 를 부르는 함수)가 IdP 가 멈춘 채 공유 갱신을 붙잡으면 이후의 토큰 요청이 전부 거기에 합류할 뿐 새 갱신이 시작되지 않기 때문이며, 그 기한이 지나면 기다리던 호출자는 소스가 돌려준 오류를 받고 다음 호출이 새 갱신을 시작합니다(`Config.ReadTimeout` 을 60초보다 길게 잡아도 admin 토큰 갱신은 60초에서 끝납니다). 공개 API 변경은 0 입니다.
- **(Go)** JWKS 강제 재조회의 30초 창이 IdP 에 요청을 보내지 않은 `Validate` 에 찍혔습니다 — 창이 지난 직후의 miss 가 먼저 창을 찍은 뒤, 바로 앞 재조회의 실패로 걸린 실패 백오프에 거부되거나 이전 창의 아직 끝나지 않은 재조회에 합류해, 백오프가 끝나고 IdP 가 회복된 뒤에도 회전된 키의 토큰이 그 새 창 내내 `(refetch rate-limited)` 로 거부됐습니다(실측: 창 1초·`ReadTimeout` 1초, 첫 재조회가 시간 초과로 실패 — 회전된 키의 첫 수락이 2.04초 → 1.17초). 기본값에서 닿는 모양입니다 — 기본 `Config.ReadTimeout`(30초)이 기본 창(30초)과 같아, 시간 초과로 끝나는 재조회는 바로 창 끝에서 실패합니다. 이제 창은 그 창에서 시작한 재조회만 찍고, 백오프 거부와 비행 중인 조회에의 합류는 창을 건드리지 않습니다 — 창마다 새 재조회 하나라는 상한은 그대로입니다. 공개 API 변경은 0 입니다.
- **(Go)** JWKS 조회가 끝나는 순간과 겹친 `Validate` 가 낡은 miss 로 판정했습니다 — 캐시 조회는 잠금 밖, 조회 결정은 잠금 안이라 그 사이에 조회가 끝나 kid 가 캐시에 들어와도, 창 안에서는 그 조회가 방금 가져온 키의 토큰을 `(refetch rate-limited)` 로 거부했고(실측: 공개 API 만으로 키 회전 40 번에 1 번), 콜드 캐시에서는 강제 재조회를 하나 더 띄워 창을 찍어 첫 적재 뒤의 첫 키 회전이 거부됐습니다 — 첫 적재는 창을 쓰지 않는다는 불변식이 깨진 것입니다. 이제 조회 결정은 잠금 아래에서 캐시를 다시 보고, 그사이 들어온 kid 면 요청도 창 도장도 없이 그 키를 씁니다. 공개 API 변경은 0 입니다.

### Security
- **(Go)** 토큰 응답 본문의 크기를 막지 않았습니다 — admin 레인의 토큰 요청(gocloak→resty)과 `Introspect` 는 본문을 통째로 메모리에 읽어 수락했고(32 MiB 본문에 프로세스 피크 12→87 MB), `ClientCredentialsToken`·`Refresh`·`ExchangeCode` 는 x/oauth2 가 1 MiB 에서 **잘라** 읽어 메모리는 묶였지만 첫 MiB 가 유효한 토큰이면 그보다 긴 본문을 수락했습니다. 이제 다섯 레인 모두 본문을 1,048,576 바이트(gzip 은 푼 뒤)까지만 읽고 읽은 만큼만 메모리를 잡으며(16 MiB 본문을 거부하는 호출이 약 2.4 MB 를 할당합니다), 그보다 길면 그 레인이 실패한 응답에 쓰던 오류로 실패합니다 — 세 그랜트와 `Introspect` 는 상한을 말하는 `*AuthError`, admin 레인은 admin 요청 없이 `*TransportError` 입니다. 이 상한은 Keycloak 26.6 이 기본 설정으로 받아들이는 가장 긴 Bearer(65,459 바이트)의 16 배라, 서버가 받는 토큰은 거부하지 않습니다. ⚠️ `Logout` 은 `Introspect` 와 본문 읽기를 공유해 같은 상한이 걸립니다. 공개 API 변경은 0 입니다.

## [1.1.3] - 2026-10-05 (Rust)

**Rust 의 patch 입니다**(같은 물결의 나머지는 위 `[1.4.0]` 절의 머리말). 공개 API 변경은 **0** 입니다.

### Fixed
- **(Rust)** 키가 회전한 직후의 검증(`validate()`, nonce 를 넘긴 `exchange_code`·`exchange_code_with_redirect` 의 id_token 검증)을 호출자가 취소하면 — `tokio::time::timeout`·`select!`·`JoinHandle::abort` 로 그 future 를 버리면 — 강제 JWKS 재조회의 창(기본 30 초)은 찍힌 채 그 fetch 만 함께 죽어, 창이 끝날 때까지 회전한 키의 정상 토큰이 `unknown kid (refetch rate-limited)` 로 거부됐고 같은 fetch 를 기다리던 다른 검증도 함께 거부됐습니다. 이제 JWKS fetch(첫 로드 포함)는 호출자와 떨어진 태스크에서 HTTP 타임아웃까지 끝까지 돌아 그 결과로 캐시를 채우므로, 창 안의 다음 검증은 IdP 요청을 더 내지 않고 받아들여집니다. 취소된 호출은 지금처럼 즉시 돌아가고, 실패한 강제 fetch(503 등)는 지금처럼 창을 씁니다. ⚠️ 그 fetch 를 기다리는 검증은 fetch 를 시작한 호출자가 취소돼도 fetch 가 끝날 때까지 기다립니다 — 저수준 `JwksStore::new` 에 타임아웃 없는 `reqwest::Client` 를 주면 응답하지 않는 IdP 가 그만큼 붙잡습니다(`KeycloakClient` 의 공유 클라이언트는 기본 연결 5 초·전체 30 초로 끊습니다). 공개 API 변경은 0 입니다.

### Security
- **(Rust)** 토큰 엔드포인트와 introspection 의 응답 본문을 통째로 메모리에 읽었습니다 — `client_credentials_token`·`refresh`·`exchange_code`·`exchange_code_with_redirect`·`introspect`(openidconnect 가 `response.bytes()` 로 모읍니다)와 admin 이 쓰는 `ClientCredentialsTokenProvider`(`resp.json()`) 모두 그랬고, JSON 공백 32 MiB 로 부풀린 **쓸 수 있는** 토큰 응답이 다섯 레인 전부에서 힙 ~95 MiB 를 잡고 통과했습니다. 이제 다섯 레인이 같은 상한 1 MiB(1,048,576 바이트 — reqwest 가 디코딩하면 푼 뒤)까지만 읽고 읽은 만큼만 메모리를 잡습니다(32 MiB 본문의 판정이 1.3–2.0 MiB) — 이 상한은 Keycloak 26.6 이 기본 설정으로 받아들이는 가장 긴 Bearer(65,459 바이트)의 16 배라, 서버가 받아들이는 토큰은 거부하지 않습니다. ⚠️ 1 MiB 를 넘는 응답은 쓸 수 있는 토큰을 담았어도 `KeycloakError::Transport`(`token response exceeds 1048576 bytes`, introspect 는 `introspection response exceeds 1048576 bytes`)로 실패하고, admin 파사드는 다른 토큰 실패와 같이 admin 요청 없이 `Admin(Other { status: 401 })` 로 실패합니다. JWKS 상한(51,200 바이트)과 admin REST 응답은 그대로입니다. 공개 API 변경은 0 입니다.

## [1.1.0] - 2026-10-05 (Java)

**Java 의 minor 입니다**(같은 물결의 나머지는 위 `[1.4.0]` 절의 머리말) — 공개 API 가 상수 `io.github.xzawed.keycloak.core.ResponseLimits.MAX_TOKEN_RESPONSE_BYTES` 하나로 늘었습니다(japicmp 호환 추가). 이 물결에서 Java 와 Kotlin 은 번호가 갈립니다 — Kotlin 은 공개 API 가 그대로라 patch 입니다(아래 `[1.0.5]`). ⚠️ 같은 번호의 `[1.1.0] - 2026-09-26 (Ruby)` · `[1.1.0] - 2026-09-26 (Go · PHP · Rust)` 절(아래)은 앞 물결의 것이고 이 절과 무관합니다.

### Fixed
- **(Java)** JDK 21 가상 스레드에서 `validate()` 하던 스레드가 인터럽트되면(`Thread.interrupt()`·`Future.cancel(true)` 등) 진행 중이던 JWKS 강제 재조회(미해결 kid)가 「Closed by interrupt」로 끊겼는데, Nimbus 의 재조회 제한은 그 전에 창의 몫을 써 버려 — 같은 창(`jwksMinRefetch`, 기본 30 초) 안에서는 회전한 진짜 키의 토큰이 IdP 에 다시 묻지 않고 `TokenValidationException`(원인 `RateLimitReachedException`)으로 거부됐습니다. 같은 조회를 기다리던 다른 호출자도 그렇게 실패했습니다. 이제 JWKS 조회는 SDK 의 플랫폼 스레드에서 끝까지 가고(이 SDK 의 타임아웃이 묶는 것은 연결과 읽기 한 번 한 번이고 조회 전체가 아닙니다 — 바이트를 조금씩 흘리는 IdP 는 최악 JWKS 상한 51,200 바이트 × 읽기 타임아웃까지 붙잡을 수 있습니다; 연결·읽기 타임아웃 1 초에 700 ms 마다 1 바이트를 흘리면, 강제 조회 300 ms 째에 인터럽트된 호출자가 그 뒤 5,374 ms 만에 돌아왔습니다) 그 결과가 캐시를 채웁니다 — 인터럽트된 호출자는 그 조회가 끝날 때까지 기다렸다가 검증 결과를 돌려받고 인터럽트 표시는 그대로 남습니다(플랫폼 스레드에서 지금까지와 같은 동작입니다). 실패한 조회(503 등)는 지금처럼 그 창을 씁니다(의도된 동작). 공개 API 변경은 없습니다.

### Security
- **(Java)** admin 의 토큰 응답 검사가 2xx 본문을 통째로 메모리에 읽었습니다 — 힙보다 큰 본문은 `OutOfMemoryError` 를 냈고(RESTEasy 가 감싸 결과는 admin 요청 0 건의 `KeycloakTransportException` 이었지만 그 순간 같은 JVM 의 다른 작업도 메모리를 잃습니다), JSON 공백으로 부풀린 **쓸 수 있는** 토큰 응답도 그랬습니다(검사 없는 결합은 그것을 스트리밍으로 통과시킵니다). 이제 검사는 본문을 1 MiB(gzip 은 푼 뒤)까지만 읽고 읽은 만큼만 메모리를 잡습니다 — 이 상한은 Keycloak 26.6 이 기본 설정으로 받아들이는 가장 긴 Bearer(65,459 바이트)의 16 배라, 서버가 받아들이는 토큰은 거부하지 않습니다. ⚠️ 1 MiB 를 넘는 토큰 응답은 쓸 수 있는 토큰을 담았어도 쓸 수 없는 토큰과 똑같이 admin 요청 없이 `KeycloakTransportException` 으로 실패합니다. 공개 API 변경은 0 입니다.
- **(Java)** 토큰·introspect·logout 응답 본문을 크기 제한 없이 읽었습니다 — 쓸 수 있는 토큰 뒤에 JSON 공백 32 MiB 를 붙인 응답을 client credentials·refresh·코드 교환·introspect·logout 이 전부 받아들였고(Nimbus `HTTPRequest.send()` 가 본문을 통째로 담아 호출 하나에 약 235 MB 할당), admin 의 자기 토큰 부여는 2xx 본문에는 이미 상한이 있었지만 오류 상태(400 등)의 본문은 RESTEasy 가 통째로 버퍼에 담았습니다(32 MiB 에 약 107 MB). 이제 SDK 는 이 응답들의 본문을 오류 상태까지 1,048,576 바이트까지만 받아들입니다 — Keycloak 26.6 이 기본 설정으로 받아들이는 가장 긴 Bearer(65,459 바이트)의 16 배라 서버가 받는 토큰은 거부하지 않습니다. 넘으면 그 호출의 `KeycloakTransportException`(`Client credentials failed: token response exceeds 1048576 bytes` 처럼 무엇이 넘었는지 말합니다 — admin 은 지금처럼 `admin transport failure`)으로 실패하고, admin 은 admin 요청을 보내지 않습니다. SDK 가 요청하고 쥐는 본문은 본문 길이와 무관하게 상한+1 바이트(넘침을 알아챌 한 바이트)까지이고, HTTPS 에서 4 KiB 청크나 Content-Length 로 온 32 MiB 본문을 거부하는 client credentials 호출 하나가 2.57–2.72 MB 를, 1 바이트 청크면 상한의 약 51 배인 53.7–53.9 MB 를 할당합니다. ⚠️ 그래도 연결은 상한 너머를 더 읽을 수 있습니다 — auth 레인을 닫을 때 JDK(`HttpURLConnection`)는 HTTPS 면 소켓에 쌓인 바이트를 복호화하지 않고 버리며 바이트가 끊이지 않고 오는 동안 멈추지 않고(버리는 데 드는 할당은 작지만 그만큼 시간이 듭니다 — 루프백의 서버가 1 바이트 청크로 보낸 32 MiB 본문을 끝까지 읽기도 했습니다), 평문 `http://` 의 청크 응답이면 그때 쌓여 있던 바이트(커널 수신 버퍼가 묶습니다 — 측정한 리눅스 6.6(WSL2)에서 최대 6 MiB)를 청크로 풀기까지 해 비용이 그 양의 제곱에 비례하고 청크 크기에 반비례하며(루프백에서 빠르게 보낸 4 KiB 청크 32 MiB 본문에 호출 하나가 0.36–2.84 GB 를, 1 바이트 청크면 닫기 하나가 34–137 GB 를 할당하고 2.9–11.5 초 걸렸습니다), admin 레인은 닫을 때 HttpCore 가 남은 본문을 끝까지 읽습니다(시간이 본문 길이를 따르고, 할당도 비운 양에 비례해 늘어납니다 — HttpCore 가 청크 머리마다 문자열을 만들고 HTTPS 면 복호화도 할당해서, 4 KiB 청크면 1 MiB 마다 평문 약 0.01 MB·HTTPS 약 0.1 MB, 1 바이트 청크면 평문·HTTPS 모두 약 25 MB 입니다). 상한 이하의 응답은 지금과 같습니다(파서가 받는 본문 문자열까지 Nimbus 와 같습니다). admin REST 응답(사용자 목록 등)과 JWKS 상한(51,200 바이트)은 그대로입니다. 공개 API 는 상수 하나가 늘었습니다 — `io.github.xzawed.keycloak.core.ResponseLimits.MAX_TOKEN_RESPONSE_BYTES`(auth·admin 이 함께 쓰는 상한, japicmp 호환 추가). 그 밖의 공개 API 변경은 없습니다.

## [1.0.5] - 2026-10-05 (Kotlin)

**Kotlin 의 patch 입니다**(같은 물결의 나머지는 위 `[1.4.0]` 절의 머리말). 공개 API 변경은 **0** 입니다.

### Security
- **(Kotlin)** admin 의 토큰 응답 검사가 2xx 본문을 통째로 메모리에 읽었습니다 — 힙보다 큰 본문은 `OutOfMemoryError` 를 냈고(RESTEasy 가 감싸 결과는 admin 요청 0 건의 `KeycloakTransportException` 이었지만 그 순간 같은 JVM 의 다른 작업도 메모리를 잃습니다), JSON 공백으로 부풀린 **쓸 수 있는** 토큰 응답도 그랬습니다(검사 없는 결합은 그것을 스트리밍으로 통과시킵니다). 이제 검사는 본문을 1 MiB(gzip 은 푼 뒤)까지만 읽고 읽은 만큼만 메모리를 잡습니다 — 이 상한은 Keycloak 26.6 이 기본 설정으로 받아들이는 가장 긴 Bearer(65,459 바이트)의 16 배라, 서버가 받아들이는 토큰은 거부하지 않습니다. ⚠️ 1 MiB 를 넘는 토큰 응답은 쓸 수 있는 토큰을 담았어도 쓸 수 없는 토큰과 똑같이 admin 요청 없이 `KeycloakTransportException` 으로 실패합니다. 공개 API 변경은 0 입니다.
- **(Kotlin)** 토큰·introspection·logout 응답 본문을 크기 제한 없이 읽었습니다 — `clientCredentialsToken`·`refresh`·`exchangeCode`·`introspect`·`logout` 은 Nimbus `HTTPRequest.send()` 가 본문을 끝까지 담아, 쓸 수 있는 토큰 뒤에 JSON 공백 32 MiB 를 붙인 응답을 다섯 레인 전부 받아들이고 호출 하나가 약 230 MB 를 할당했습니다(오류 상태의 본문도 같았고, 힙이 작으면 raw `OutOfMemoryError` 가 공개 API 로 나갑니다). admin 은 2xx 토큰 응답에만 상한이 있어, 오류 상태의 토큰 응답과 admin 이 닫힐 때 보내는 logout 의 오류 응답은 RESTEasy 가 통째로 버퍼에 담았습니다(400 + 32 MiB 에 admin 호출 하나가 105–210 MB, `close()` 하나가 101 MB). 이제 SDK 는 auth 다섯 레인의 응답과 admin 의 토큰 응답(오류 상태 포함)·logout 오류 응답을 모두 같은 상수 1,048,576 바이트까지만 받아들이고, 요청하고 쥐는 본문은 본문 길이와 무관하게 상한+1 바이트(넘침을 알아챌 한 바이트)까지입니다(HTTPS 에서 4 KiB 청크나 Content-Length 로 온 32 MiB 본문을 거부하는 `clientCredentialsToken` 호출 하나가 2.57–2.72 MB 를, 1 바이트 청크면 상한의 약 51 배인 53.7–53.8 MB 를 할당합니다) — 이 상한은 Keycloak 26.6 이 기본 설정으로 받아들이는 가장 긴 Bearer(65,459 바이트)의 16 배라, 서버가 받아들이는 토큰은 거부하지 않습니다. 상한은 SDK 가 읽는 바이트로 잽니다 — auth 레인의 연결은 내용 코딩을 풀지 않고, admin 의 2xx 는 gzip 을 푼 뒤입니다. ⚠️ 1 MiB 를 넘는 응답은 쓸 수 있는 토큰을 담았어도 `KeycloakTransportException`(`Auth request failed: token response exceeds 1048576 bytes`, introspect 는 `Introspection request failed: …`, logout 은 `Logout request failed: …`)으로 실패합니다. ⚠️ 그래도 연결은 상한 너머를 더 읽을 수 있습니다 — auth 레인을 닫을 때 JDK(`HttpURLConnection`)는 HTTPS 면 소켓에 쌓인 바이트를 복호화하지 않고 버리며 바이트가 끊이지 않고 오는 동안 멈추지 않고(버리는 데 드는 할당은 작지만 그만큼 시간이 듭니다 — 루프백의 서버가 1 바이트 청크로 보낸 32 MiB 본문을 끝까지 읽기도 했습니다), 평문 `http://` 의 청크 응답이면 그때 쌓여 있던 바이트(커널 수신 버퍼가 묶습니다 — 측정한 리눅스 6.6(WSL2)에서 최대 6 MiB)를 청크로 풀기까지 해 비용이 그 양의 제곱에 비례하고 청크 크기에 반비례하며(루프백에서 빠르게 보낸 4 KiB 청크 32 MiB 본문에 호출 하나가 0.73–2.79 GB 를, 1 바이트 청크면 닫기 하나가 34–137 GB 를 할당하고 2.9–11.5 초 걸렸습니다), admin 레인은 닫을 때 HttpCore 가 남은 본문을 끝까지 읽습니다(시간이 본문 길이를 따르고, 할당도 비운 양에 비례해 늘어납니다 — HttpCore 가 청크 머리마다 문자열을 만들고 HTTPS 면 복호화도 할당해서, 4 KiB 청크면 1 MiB 마다 평문 약 0.01 MB·HTTPS 약 0.1 MB, 1 바이트 청크면 평문·HTTPS 모두 약 25 MB 입니다). admin 은 지금처럼 admin 요청 없이 `KeycloakTransportException`(`Admin request failed`)이며, 상한을 넘는 갱신 400 은 더 이상 client_credentials 재부여로 복구되지 않습니다. 상한 안의 응답은 예전과 같고(3xx 를 따라가지 않는 것도), admin REST 응답과 JWKS 상한(51,200 바이트)은 그대로입니다. 공개 API 변경은 0 입니다.
- **(Kotlin)** IdP 가 받은 값을 `error_description` 에 되울리면, 그 값에 RFC 6749 §5.2 의 문자 집합 밖의 글자(LF·NUL·U+00FF 위의 글자·`"`·`\` 등)가 있을 때 `KeycloakAuthException` 의 메시지가 보낸 토큰·시크릿을 찍었습니다 — Nimbus 가 `error_description` 에서 그 글자들을 지운 **뒤에** SDK 가 보낸 값을 그대로 찾았으므로, 지워진 꼴(LF·NUL·U+0100 을 담은 refresh 토큰이면 「Token refresh failed: Bad refresh_token: HDRLEAK-rtLFNULWIDE-tail-0002 (rejected)」)이 가려지지 않았습니다. `refresh` 의 refresh 토큰, `introspect` 의 토큰, `exchangeCode` 의 code, `clientCredentialsToken` 의 시크릿이 모두 그랬고, 짝 없는 서로게이트를 담은 값은 UTF-8 이 그 자리에 `?` 를 실어 보내 IdP 가 그 꼴로 되울려 역시 실렸습니다. 이제 보낸 값마다 IdP 가 받은 꼴과 §5.2 밖의 글자를 지운 꼴까지 `***` 로 가리고, 사유 문구는 그대로 남습니다. 값 자체는 고치지 않습니다(보내는 값도, 돌려주는 값도). 공개 API 변경은 0 입니다.
- **(Kotlin)** IdP 가 Basic 자격의 base64 만 풀고 폼 디코딩 없이 클라이언트 시크릿을 `error_description` 에 되울리면, `clientCredentialsToken`·`refresh`·`introspect`·`exchangeCode` 의 `KeycloakAuthException` 메시지가 그 시크릿을 폼 인코딩된 꼴로 찍었습니다 — SDK(Nimbus `ClientSecretBasic`)는 RFC 6749 §2.3.1 대로 시크릿을 `application/x-www-form-urlencoded` 로 인코딩해 Basic 의 비밀번호 칸에 싣는데(영숫자와 `.`·`-`·`*`·`_` 밖의 글자 — 공백·`/`·`+`·`=`·`~`·비 ASCII 등 — 가 든 시크릿은 「Client credentials failed: Bad BASIC: sec+ret%2F%2B%3D%7E0005 (rejected)」 처럼 바뀐 꼴로 돌아옵니다), SDK 는 grant 값(refresh 토큰·introspect 토큰·code·verifier)의 폼 인코딩된 꼴만 가리고 시크릿의 그 꼴은 가리지 않았습니다. 이제 보낸 값마다 폼 인코딩된 꼴도 `***` 로 가리고, 사유 문구는 그대로 남습니다. 값 자체는 고치지 않습니다(보내는 값도, 돌려주는 값도). 공개 API 변경은 0 입니다.

## [1.0.4] - 2026-10-05 (Python · .NET · Node)

**Python · .NET · Node 의 patch 입니다**(같은 물결의 나머지는 위 `[1.4.0]` 절의 머리말). 공개 API 변경은 **0** 입니다. ⚠️ 같은 번호의 `[1.0.4] - 2026-10-02 (Java · Kotlin)` 절(아래)은 셋째 물결의 것이고 이 절과 무관합니다.

### Fixed
- **(.NET)** 토큰·introspect 응답의 OAuth `error` 가 RFC 6749 §5.2 문법 밖의 문자열이어도(`"invalid_client\n"` 처럼 끝에 줄바꿈이 붙거나 CR·NUL·DEL·비 ASCII 를 담아도) 그 값을 그대로 `KeycloakAuthException` 에 실었습니다 — 400 응답이면 메시지와 `OAuthError` 둘 다에, 그 밖의 HTTP 오류면 `OAuthError` 에 실려 그 오류를 찍는 로그 한 줄이 둘로 갈렸습니다. 이제 `error` 는 문법(`1*NQSCHAR`, `NQSCHAR = %x20-21 / %x23-5B / %x5D-7E`)에 정확히 맞을 때만 그대로 싣고, 문법 밖의 문자열은 다듬어 코드로 만들지 않고 코드가 없는 것으로 칩니다 — `OAuthError` 는 400 이면 `null`, 그 밖의 HTTP 오류면 지금처럼 상태의 표준 reason phrase(`Unauthorized` 등)이고, 400 의 메시지 꼬리는 `error is not an RFC 6749 error code` 입니다. Keycloak 이 내는 코드(`invalid_grant` 등)를 포함해 문법에 맞는 값은 그대로입니다. 2xx 응답이 문법에 맞는 `error` 를 실어 오면 400 과 같이 그 코드로 실패합니다 — 공백만인 코드(`" "`)는 전에는 실패로 보지 않아, 토큰 호출은 `token response missing access_token`(`OAuthError` 없음)으로 실패하고 introspect 는 결과를 돌려줬습니다. 공개 API 변경은 없습니다.
- **(.NET)** `ValidateAsync(token, ct)`(`JwtValidator` · `AuthClient`)가 `CancellationToken` 을 버렸습니다 — 이미 취소된 토큰으로도, IdP 를 기다리는 도중 취소돼도 검증을 끝까지 하고 결과를 돌려줬습니다(콜드 캐시·JWKS 2 초 지연: 300 ms 에 취소했는데 2,117 ms 뒤 수락). nonce 를 넘긴 `ExchangeCodeAsync` 의 id_token 검사도 같았습니다. 이제 이미 취소된 토큰이면 아무것도 조회하지 않고 곧바로, 기다리는 도중 취소되면 그 자리에서 `OperationCanceledException` 을 던집니다. 이미 시작된 디스커버리·JWKS 조회는 취소하지 않고 끝까지 가서 캐시를 채우므로 취소가 재조회 창을 헛되이 쓰지 않습니다. 공개 API 변경은 없습니다.
- **(Node)** JWKS 캐시가 찬 채 IdP 의 JWKS 조회가 실패하면(503·연결 오류) kid 를 풀 수 없는 토큰마다 JWKS 를 다시 조회했습니다 — 30 초 재조회 창(`jwksMinRefetchSeconds`)이 jose 안에서 **성공한** 조회에만 찍혀, 장애 동안 위조 kid 토큰 5 개가 IdP 요청 5 건을, 60 초 동안 초당 하나가 60 건을 냈습니다. 이제 창은 SDK 가 조회를 **시도할 때** 찍어 장애 중에도 창마다 한 번입니다(같은 측정에서 1 건 · 2 건) — 창을 스스로 거는 다섯 언어(Python·Go·Rust·PHP·Ruby)와 같습니다. 캐시된 kid 의 토큰은 장애 중에도 IdP 없이 그대로 통과하고, 정상일 때는 지금처럼 창마다 정확히 한 번입니다. 빈 캐시의 적재와 만료(10 분)된 캐시의 갱신은 이 창에 걸리지 않습니다. ⚠️ 그래서 강제 재조회가 실패하면 그 창이 끝날 때까지(최대 30 초) 회전한 새 키의 토큰도 거부됩니다 — 전에는 IdP 가 돌아오는 즉시 받았습니다. 공개 API 변경은 0 입니다.
- **(Python)** `aio` 의 `validate()`(와 nonce 를 넘긴 `exchange_code()`)를 취소하면(시간 초과 포함) JWKS 강제 재조회 창(기본 30초)을 헛되이 썼습니다 — 서명 키(kid)를 못 찾아 재조회를 정하는 순간 창에 도장이 찍히는데 그 fetch 는 호출자 안에서 돌아 취소와 함께 버려졌고, 그래서 IdP 가 키를 회전한 직후라면 창이 끝날 때까지 새 키로 서명한 정상 토큰이 `TokenKeyError` 로 거부됐습니다(요청이 IdP 에 닿기 전에 취소해도, 도중에 취소해도). 이제 그 fetch 는 클라이언트가 소유해 호출자의 취소와 무관하게 SDK 의 HTTP 타임아웃 안에서 끝까지 가서 캐시를 채우고, 창 안의 다른 검증은 낡은 캐시 대신 진행 중인 그 fetch 를 기다립니다. 취소된 호출자는 지금처럼 곧바로 `CancelledError`(시간 초과면 `TimeoutError`)를 받고, 같은 fetch 를 기다리던 다른 호출자는 그 취소로 실패하지 않습니다. 실패한(예: 503) 재조회는 여전히 창을 쓰고, 창 하나에 IdP 요청 하나라는 상한도 그대로입니다 — 취소된 위조 kid 검증이 요청을 늘리지 않습니다. sync 는 취소가 없어 바뀌지 않습니다. 공개 API 변경은 0 입니다.

### Security
- **(Python)** admin 의 하드닝이 생성 때 그 객체들에 한 번만 걸려, python-keycloak 의 공개 세터로 연결을 갈아 끼우면(`raw.connection = …`) 빈 `access_token` 이 다시 `Authorization: Bearer ` 로 admin API 에 나갔습니다(sync — `aio` 는 h11 이 그 헤더를 거부해 `KeycloakTransportError`). 같은 교체는 리다이렉트 차단도 지워 `client_secret` 을 싣는 admin 그랜트가 307 을 따라갔고(중첩 `raw.connection.keycloak_openid.connection` 교체도 같았습니다), 이미 빈 bearer 를 쥔 채 주입된 admin 은 그랜트 없이 곧바로 보냈으며, 설치 도중의 실패는 raw `AttributeError` 와 반쯤 감긴 객체를 남겼습니다. 이제 admin 요청이 나가기 직전마다 **살아 있는** 연결에 하드닝이 걸렸는지 다시 보고 걸며, 보낼 bearer 가 쓸 수 없으면 요청 없이 auth 레인과 같은 `KeycloakAuthError`(`token response has no usable access_token`)를 던집니다 — 리소스 메서드와 탈출구 `raw` 의 메서드, sync·`aio` 모두입니다. 걸 수 없는 연결이면 — 그것을 읽다 무엇이 던져지든(예전 생성은 raw `TypeError` 등을 그대로 냈습니다), 훅 자리의 값을 슬롯·데이터 디스크립터가 가리든 — 아무것도 바꾸지 않고 `KeycloakConfigError` 로 거부하고, `close()`·`aclose()` 는 그래도 정리합니다. ⚠️ 그래서 `raw`(주입한 `KeycloakAdmin`·그 하위 클래스 포함)는 그 클래스의 하위 클래스 인스턴스가 됩니다 — `isinstance` 와 정체성은 그대로이고 정확한 타입 비교(`type(raw) is KeycloakAdmin`, 주입한 하위 클래스면 그 클래스와의 비교)만 거짓이며, 그렇게 바꿀 수 없는 주입 admin(하위 클래스·클래스 교체를 막거나 `connection` 이 프로퍼티가 아닌 클래스)은 생성 때 `KeycloakConfigError` 로 거부합니다. 공개 API 변경은 0 입니다.
- **(.NET)** 토큰·introspect·logout 응답 본문을 크기 제한 없이 메모리에 담았습니다 — 쓸 수 있는 토큰 뒤에 JSON 공백 32 MiB 를 붙인 응답을 client credentials·refresh·코드 교환·introspect·admin 의 자기 토큰 부여가 전부 받아들였습니다(프로세스 피크 35 → 195 MB, 호출 하나에 317 MB 할당). 이제 `KeycloakClient.Create` 가 만드는 클라이언트는 그 응답을 1,048,576 바이트까지만 담습니다 — Keycloak 26.6 이 기본 설정으로 받아들이는 가장 긴 Bearer(65,459 바이트)의 16 배라 서버가 받는 토큰은 거부하지 않습니다. 넘으면 그 호출은 본문을 버리고 `KeycloakTransportException`(`… failed: response exceeds a size limit`)으로 실패하며, admin 은 admin 요청을 보내지 않습니다. 할당은 본문 크기와 무관하게 상한 근처에서 멈춥니다(32 MiB 청크 본문을 거부하며 2.5 MB). admin REST 응답(사용자 목록 등)과 JWKS 상한(51,200 바이트)은 그대로입니다. ⚠️ `AuthClient` 공개 생성자에 직접 넘긴 `HttpClient` 는 이 상한을 받지 않고 자기 `MaxResponseContentBufferSize` 를 씁니다. 공개 API 변경은 없습니다.
- **(.NET)** 디코드할 수 없는 응답과 헤더에 실을 수 없는 토큰이 하위 라이브러리 예외로 SDK 밖에 나왔습니다(§4). 응답 문자열이 짝 없는 UTF-16 서로게이트 이스케이프(예: U+D800 하나)면 — `error` 가 그런 값일 때 client credentials·refresh·코드 교환·admin 의 토큰 부여가 400·200 에서, introspect 까지 다섯 호출이 401 에서, `access_token`·`refresh_token` 등 토큰 응답 멤버가 그런 값일 때도 raw `InvalidOperationException` 을 냈고, introspect 는 그런 값을 담은 JSON 객체를 「response body is not a JSON object」라는 거짓 메시지로 거부했습니다. admin 의 타입드 호출(사용자·그룹·realm 조회)은 200 본문의 잘못된 UTF-8·그런 이스케이프와 400·403·404 오류 본문의 그런 이스케이프에서 raw `System.Text.Json.JsonException` 을, CR·LF 를 담은 access token 은 모든 admin 호출에서 raw `FormatException` 을 냈습니다(어느 것도 토큰을 인용하지는 않았습니다). 이제 전부 SDK 예외이고 값은 고쳐 쓰지 않고 거부합니다 — 그런 `error` 는 코드가 없는 것으로 칩니다(`OAuthError` 는 400·2xx 에서 `null`, 그 밖에는 표준 reason phrase). 토큰 멤버면 `KeycloakAuthException`(`… failed: <멤버> holds an unpaired surrogate escape`), introspect 는 `Token introspection failed: response body is not a decodable JSON object`, admin 오류 본문은 원래 HTTP 상태를 지킨 예외(404 는 그대로 `KeycloakNotFoundException`, 메시지 `admin error response body could not be decoded`), 2xx 본문은 `KeycloakAdminException`(500, `admin response body could not be decoded`), CR·LF bearer 는 요청을 보내지 않고 `KeycloakTransportException`(`admin request failed: the access token holds a CR or LF, which an HTTP header cannot carry`)입니다. 요청 본문을 JSON 으로 쓸 수 없는 admin 쓰기 — 사용자·그룹·클라이언트·역할·realm 의 생성과 수정 열 가지, 탈출구 `Raw` 를 거친 쓰기도 — 는 representation 이 자기 자신을 담았을 때(raw `JsonException`)도, `AdditionalProperties` 에 `double.NaN`(raw `ArgumentException`)이나 `System.Type`(raw `NotSupportedException`)을 담았을 때도 `KeycloakTransportException`(`admin request failed: the request body could not be encoded as JSON`)입니다. ⚠️ raw admin 경로의 메시지 `admin response body was not valid JSON` 은 `admin response body could not be decoded` 로 바뀌었습니다 — 짝 없는 서로게이트 이스케이프는 JSON 문법(RFC 8259 §8.2)에 맞으므로 예전 말은 거짓이었습니다. 공개 API 변경은 없습니다.
- **(Node)** 토큰·introspection 응답 본문을 크기 제한 없이 메모리에 읽었습니다 — 쓸 수 있는 토큰 뒤에 JSON 공백 32 MiB 를 붙인 응답을 client credentials·refresh·코드 교환·introspection·admin 의 자기 토큰 부여가 전부 받아들였습니다(호출 하나에 프로세스 피크 +100~123 MB, gzip 으로 선 위 33 KB 인 본문도 같았습니다). 이제 그 응답과 discovery 응답은 푼 뒤 1,048,576 바이트까지만 읽습니다 — Keycloak 26.6 이 기본 설정으로 받아들이는 가장 긴 Bearer(65,459 바이트)의 16 배라 서버가 받는 토큰은 거부하지 않습니다. 넘으면 그 호출은 지금의 실패와 같은 `KeycloakAuthError`(`… failed: response body exceeds 1048576 bytes`, discovery 는 `OIDC discovery failed: response body exceeds 1048576 bytes`)로 실패하고, admin 은 admin 요청을 보내지 않습니다. 읽기는 정확히 1,048,577 바이트에서 멈추고 메모리는 읽은 만큼만 잡습니다(32 MiB 본문을 거부하며 피크 +6~10 MB). admin REST 응답(사용자 목록 등)과 JWKS 상한(51,200 바이트)은 그대로입니다. 공개 API 변경은 0 입니다.
- **(Node)** 토큰 엔드포인트가 HTTP 헤더에 실을 수 없는 access token 을 주면 admin 호출이 하위 런타임 예외로 SDK 밖에 나왔고(§4), LF·CR·NUL 이면 그 메시지가 토큰을 통째로 인용했습니다 — 토큰에 LF·CR·NUL 이 있으면 모든 admin 호출(탈출구 `raw()` 포함)이 raw `TypeError: Headers.append: "Bearer <토큰>" is an invalid header value.` 를, U+00FF 를 넘는 문자(U+0100 · 짝 없는 서로게이트 · 잘못된 UTF-8 이 풀린 U+FFFD)면 raw `TypeError: Cannot convert argument to a ByteString …` 을 냈습니다(요청은 나가지 않았습니다). 이제 `admin()`·`AdminClient.create` 가 그런 토큰을 받으면 곧바로, 만료 뒤 다시 받은 토큰이 그렇다면 그 admin 호출이 요청 없이 `KeycloakAuthError`(`admin access token cannot be sent: an HTTP header cannot carry it (it holds CR, LF, NUL or a character above U+00FF)`)로 실패하고, 메시지·원인 사슬·스택 어디에도 토큰이 없습니다. 값은 고쳐 쓰지 않고, 거르는 것은 플랫폼(undici)이 거부하는 것과 같습니다 — U+00E9 같은 Latin-1 과 플랫폼이 다듬어 보내는 끝의 공백·LF 는 지금처럼 나가고, 길이는 서버가 판정합니다(65,459 바이트 Bearer 는 그대로 나갑니다). 토큰을 폼 본문에 싣는 introspect·refresh·logout 은 바뀌지 않았습니다. 공개 API 변경은 0 입니다.
- **(Python)** 토큰·introspection 응답 본문을 통째로 메모리에 읽었습니다 — `client_credentials_token`·`refresh`·`exchange_code`·`introspect` 와 admin 의 자체 토큰 그랜트가 sync·`aio` 모두 상한도 `Content-Length` 검사도 없이 본문 전체를 쥐어, JSON 공백으로 32 MiB 를 덧댄 **쓸 수 있는** 토큰 응답도 그대로 받아들이고 프로세스 메모리를 약 70 MB 늘렸습니다. 이제 이 응답들은(같은 세션의 `logout` 응답도) 본문을 1 MiB(1,048,576 바이트 — gzip·deflate 는 푼 뒤)까지만 읽고 읽은 만큼만 메모리를 잡습니다 — 이 상한은 Keycloak 26.6 이 기본 설정으로 받아들이는 가장 긴 Bearer(65,459 바이트)의 16 배라, 서버가 받아들이는 토큰은 거부하지 않습니다. ⚠️ 1 MiB 를 넘는 응답은 쓸 수 있는 토큰을 담았어도 `KeycloakAuthError`(`token response exceeds 1048576 bytes`, introspect 는 `introspection response …`)로 실패하고, admin 은 REST 요청을 보내지 않습니다. sync·`aio` 모두 토큰 엔드포인트에 `Accept-Encoding: gzip, deflate` 만 요구합니다 — `brotli`·`zstandard` 가 깔려 있어도 `br`·`zstd` 는 상한 안에서 풀 수 없어 요구하지 않습니다. admin REST 응답과 JWKS 상한(51,200 바이트)은 그대로입니다. 공개 API 변경은 0 입니다.
- **(Python)** admin 오류 응답의 본문이 UTF-8 이 아니면(예: `0xFF` 바이트, UTF-8 로 인코딩한 서로게이트 `ED A0 80`) admin 호출이 SDK 오류가 아니라 raw `UnicodeDecodeError` 를 냈습니다 — sync·`aio`, 리소스 메서드(`users`·`clients`·`realms`·`roles`·`groups`) 전부입니다. 그 예외의 `__context__` 는 응답 본문을 통째로 실은 python-keycloak 오류라 `logging.exception`·오류 수집기가 본문을 찍었고, `keycloak_sdk.exceptions` 를 잡는 소비자는 아무것도 잡지 못했습니다(§4). 이제 상태에 맞는 `KeycloakAdminError`(404 면 `KeycloakNotFoundError` 등)이고 원인 사슬에는 요약(`LowerLibraryError`)뿐이며, `keycloak_error` 는 풀 수 없는 바이트를 버리거나 바꾸지 않고 `\xff` 처럼 이스케이프해 본문을 보존합니다. 공개 API 변경은 0 입니다.
- **(Python)** JWKS 응답의 압축 해제가 두 경로에서 경계를 넘었습니다 — sync 는 urllib3 2.6 미만(requests 가 허용하는 1.26 이상)에서 gzip 으로 부풀린 JWKS 를 51,200 바이트 상한을 판정하기 전에 한 번에 풀어 프로세스가 약 22 MB 를 잡았고(실측: 1.26.20·2.5.0), `aio` 는 gzip·deflate 라고 표시만 하고 압축되지 않은 JWKS 본문에서 raw `zlib.error` 가 `validate()` 로 나왔습니다(§4). 이제 두 미러 모두 SDK 가 상한을 두고 직접 풀어(urllib3 의 압축 해제를 쓰지 않습니다) 상한을 넘기 전에 멈추고, 풀 수 없는 본문은 `KeycloakTransportError` 입니다. 공개 API 변경은 0 입니다.

## [1.3.0] - 2026-10-02 (PHP)

**2026-10-02 셋째 릴리스 물결 — 아홉 언어가 여섯 번호로 올라갑니다.** 둘째 물결(아래 `[1.2.0] - 2026-09-26 (Go · PHP)` 절의 머리말)과 Node 의 `[1.0.2] - 2026-09-27` 뒤에 착지한 수정을 싣습니다 — 아홉 언어 전부의 id_token audience 수정(#663–#671 — `expectedAudience` 를 재정의하면 nonce 를 넘긴 코드 교환이 정상 id_token 을 거부하던 것), Python 의 traceback 프레임 로컬 누출 수정(#666), admin 수정 넷(Python #685 · PHP #686 · Java #687 · Kotlin #688). 새 공개 API 가 들어간 PHP(`JwtValidator::validateIdToken`)는 minor(`1.3.0`, 이 절)이고 Ruby(`JwtValidator#validate` 의 `audience:` 키워드)도 minor(`1.2.0`), 나머지는 patch 입니다 — Go `1.2.1`, Rust `1.1.2`, Java · Kotlin `1.0.4`, Python · .NET · Node `1.0.3`(아래 절들). 실제로 어디까지 게시됐는지는 이 파일이 아니라 `scripts/lib/deploy-facts.sh` 의 `df_published_version` 이 소유합니다.

⚠️ **같은 번호의 절이 앞 물결에도 있습니다** — `[1.2.0]` 은 Ruby(이 물결)와 Go · PHP(2026-09-26 둘째 물결), `[1.0.3]` 은 Python · .NET · Node(이 물결)와 Java · Kotlin(2026-09-26 둘째 물결)입니다. 번호는 언어별로 독립이라 제목의 언어 목록으로 가릅니다. ⚠️ **소비자가 알아야 할 동작 변화 셋** — (1) Python admin 은 자기 client_credentials 그랜트 응답의 `access_token` 이 없거나 `null`·문자열이 아니면 `KeycloakTransportError` 를 던지고, 비어 있으면 빈 Bearer 로 admin 요청을 보냈습니다(`aio` 는 `KeycloakTransportError`). 이제 그 모두가 admin 요청 없이 `KeycloakAuthError` 입니다. (2) PHP admin 오류의 원인(`getPrevious()`)은 이제 Guzzle·fschmtt 예외가 아니라 `SanitizedCause` 이고 메시지는 SDK 가 만듭니다(`admin request failed: HTTP <상태>` 등) — 원인을 하위 타입으로 검사하던 코드는 그 타입을 더 찾지 못합니다. 예외 타입과 `getStatusCode()` 는 그대로입니다. (3) Java · Kotlin admin 은 토큰 응답의 숫자·불리언·빈 문자열 `access_token` 을 결합 전에 거부해 admin 요청을 보내지 않고 `KeycloakTransportException` 으로 실패합니다(전에는 그 값을 Bearer 로 실었습니다).

### Fixed
- **(PHP)** `expectedAudience` 를 client id 가 아닌 값(리소스 서버)으로 재정의하면 nonce 를 넘긴 `exchangeCode()` 가 `invalid id_token: audience does not contain <재정의 값>` 으로 **실패했습니다** — id_token 을 액세스 토큰과 같은 기대 aud 로 검증했기 때문입니다. 이제 교환의 id_token `aud` 는 OIDC Core §2 · §3.1.3.7 대로 `clientId` 를 담는지로 검사해 재정의 아래서도 교환이 통과하고, 재정의 값만 담고 `clientId` 가 없는 id_token 은 거부합니다. `validate()` 의 액세스 토큰 검증은 지금처럼 재정의를 씁니다. 이 검증은 새 공개 메서드 `JwtValidator::validateIdToken(string $idToken, string $clientId)` 가 합니다 — `final` 클래스에 메서드가 는 것이라 minor 입니다.

### Security
- **(PHP)** admin 의 자기 토큰 부여나 admin 요청이 실패하면 그 오류가 토큰·시크릿·응답 본문·보낸 representation 을 찍었습니다 — `Admin\ErrorTranslation` 이 Guzzle·fschmtt 예외를 원인(`getPrevious()`)에 원본째 달고 Guzzle 메시지(응답 본문 앞부분)를 그대로 옮겼기 때문입니다. 그래서 `getMessage()` 가 되울린 `error_description`·토큰을, `(string)$e`·`var_dump`·`print_r` 가 하위 프레임 인자로 토큰 응답 본문·`client_secret`·admin 요청의 `Bearer` 토큰을, 파사드 프레임 인자로 보낸 비밀번호·client secret·검색어를 찍었습니다(`zend.exception_ignore_args=Off`, 404 같은 흔한 실패 포함). 토큰을 받은 뒤 admin 검색이 시간 초과·연결 실패하면 원인의 Guzzle 메시지가 요청 URL 을 쿼리째 인용해 검색어·username 을 찍었습니다(이 경로는 `exception_ignore_args` 와 무관합니다). 이제 원인은 `SanitizedCause` 이고(인용하는 요청 URL 에서 쿼리를 뺍니다), 메시지는 `admin request failed: HTTP <상태>`(토큰 부여면 `admin token request failed: HTTP <상태> (<코드>)` — OAuth `error` 가 코드 모양 `[a-z_]` 일 때만, 분류 밖 예외면 `admin request failed unexpectedly`)이며, 파사드가 보내는 representation 과 검색 조건(`Criteria` · `findIdByUsername` 의 username) 인자는 `#[\SensitiveParameter]` 로 가립니다 — 경로로 가는 식별자(사용자 id·역할 이름 등)는 원인의 URL 처럼 남습니다. 예외 타입과 `getStatusCode()` 는 그대로지만 원인을 Guzzle 타입으로 검사하던 코드는 그 타입을 더 찾지 못합니다. 공개 API 변경은 0 입니다.

## [1.2.1] - 2026-10-02 (Go)

**Go 의 patch 입니다**(같은 물결의 나머지는 위 `[1.3.0]` 절의 머리말). 공개 API 변경은 **0** 입니다.

### Fixed
- **(Go)** `Config.ExpectedAudience` 를 client id 가 아닌 값(리소스 서버)으로 재정의하면 nonce 를 넘긴 `ExchangeCode` 가 `invalid id_token` 으로 **실패했습니다** — id_token 을 액세스 토큰과 같은 audience 로 검증했기 때문입니다. 이제 그 교환은 통과하고, id_token 의 `aud` 는 OIDC Core §2·§3.1.3.7 대로 `ClientID` 를 담는지 검사합니다(`ClientID` 가 없으면 재정의 값만 담겨도 거부합니다). `Validate` 의 액세스 토큰 검증은 그대로 `ExpectedAudience` 를 쓰고, iss·알고리즘 핀·exp·nonce 검사와 JWKS 캐시·재조회 제한(둘이 하나를 공유합니다)은 바뀌지 않습니다. 공개 API 변경은 없습니다.

## [1.2.0] - 2026-10-02 (Ruby)

**Ruby 의 minor 입니다**(같은 물결의 나머지는 위 `[1.3.0]` 절의 머리말) — 공개 API 가 `JwtValidator#validate(token, audience:)` 키워드로 늘었습니다. ⚠️ 같은 번호의 `[1.2.0] - 2026-09-26 (Go · PHP)` 절(아래)은 둘째 물결의 것이고 이 절과 무관합니다.

### Fixed
- **(Ruby)** `expected_audience` 를 client_id 가 아닌 값(리소스 서버)으로 재정의하면, nonce 를 넘긴 `exchange_code` 가 서버의 정상 id_token 을 `invalid id_token`(`Invalid audience`)으로 거부했습니다 — id_token 도 액세스 토큰과 같은 재정의 값으로 검사했기 때문입니다. 이제 id_token `aud` 는 OIDC Core §2·§3.1.3.7 대로 **client_id** 로 검사하므로 그 교환이 통과하고, `aud` 에 client_id 가 없는 id_token 은 재정의 값을 담고 있어도 거부합니다. `validate` 의 액세스 토큰 검증은 그대로 재정의를 쓰고, JWKS 캐시·재조회 제한은 두 토큰이 하나를 나눠 씁니다. 공개 API 가 늘어나 **minor** 입니다 — `JwtValidator#validate(token, audience:)` 키워드(생략하면 종전과 같고, nil·공백은 `ConfigError`).

## [1.1.2] - 2026-10-02 (Rust)

**Rust 의 patch 입니다**(같은 물결의 나머지는 위 `[1.3.0]` 절의 머리말). 공개 API 변경은 **0** 입니다.

### Fixed
- **(Rust)** `with_expected_audience(…)` 로 기대 aud 를 재정의하면 nonce 를 넘긴 코드 교환(`exchange_code` · `exchange_code_with_redirect`)이 **실패했습니다** — id_token 을 access 토큰과 같은 기대 aud 로 검증해, client id 를 담은 진짜 id_token 이 `invalid id_token … audience mismatch` 로 거부됐습니다. 이제 id_token 의 `aud` 는 OIDC Core §2 · §3.1.3.7 대로 **client id** 로 검증하므로 그 교환이 통과하고, client id 를 담지 않은 id_token 은 `aud` 가 재정의 값과 같아도 거부합니다. `validate()` 의 access 토큰 검증은 지금처럼 재정의 값을 씁니다. JWKS 캐시 · 재조회 제한 · 콜드 실패 백오프는 두 경로가 하나를 공유하고, 공개 API 변경은 없습니다.

## [1.0.4] - 2026-10-02 (Java · Kotlin)

**Java · Kotlin 의 patch 입니다**(같은 물결의 나머지는 위 `[1.3.0]` 절의 머리말). 공개 API 변경은 **0** 입니다.

### Fixed
- **(Kotlin)** `expectedAudience` 를 재정의하면 nonce 를 넘긴 `exchangeCode` 가 서버가 서명한 정상 id_token 에서도 「invalid id_token」으로 실패했습니다 — id_token 을 액세스 토큰과 같은 기대 audience(재정의 값)로 봤기 때문입니다. 이제 id_token 의 `aud` 는 OIDC Core §2 · §3.1.3.7 대로 `clientId` 로 보므로 그 교환이 성공하고, `aud` 에 client id 가 없는 id_token 은 재정의 값을 담았어도 거부합니다. `validate()` 의 액세스 토큰 검증은 지금처럼 재정의 값을 쓰고, JWKS 조회는 늘지 않습니다(저장소 하나를 공유). 공개 API 변경은 **0** 입니다.
- **(Java)** `expectedAudience` 를 client id 가 아닌 값(리소스 서버 이름 등)으로 정하면 nonce 를 넘긴 `exchangeCode(…, nonce)` 가 서버가 낸 정상 id_token 을 `invalid id_token` 으로 거부했습니다 — id_token 을 액세스 토큰과 같은 검증기(aud = `expectedAudience`)로 봤기 때문입니다. 이제 그 교환이 통과합니다: id_token 의 `aud` 는 client id 로 검사합니다(OIDC Core §2·§3.1.3.7 — id_token 의 `aud` 는 client_id 를 담아야 합니다). client id 가 없는 id_token 은 `aud` 가 재정의 값이어도 거부합니다. `validate()` 의 액세스 토큰 검증은 그대로 `expectedAudience` 를 쓰고, iss·알고리즘 핀·exp·skew·nonce 대조와 JWKS 캐시·재조회 제한(둘이 하나를 나눕니다)도 그대로입니다. 공개 API 변경은 없습니다.

### Security
- **(Java)** admin 이 토큰 응답의 숫자·불리언·빈 문자열 `access_token` 을 그대로 Bearer 로 실어 admin API 를 불렀습니다(`Authorization: Bearer 12345` · `Bearer true` · `Bearer `) — admin 이 토큰을 맡기는 keycloak-admin-client 내장 TokenManager 의 Jackson 이 그 값을 문자열로 강제변환했기 때문입니다(null·객체·배열·누락은 이미 거부했습니다). 이제 그런 토큰 응답은 결합 전에 거부되어 admin 요청을 하나도 보내지 않고, null·객체·배열·누락과 같은 `KeycloakTransportException` 으로 실패합니다. 공개 API 변경은 0 입니다.
- **(Kotlin)** admin 이 토큰 응답의 숫자·불리언·빈 문자열 `access_token` 을 그대로 Bearer 로 실어 admin API 를 불렀습니다(`Authorization: Bearer 12345` · `Bearer true` · `Bearer `) — admin 이 토큰을 맡기는 keycloak-admin-client 내장 TokenManager 의 Jackson 이 그 값을 문자열로 강제변환했기 때문입니다(null·객체·배열·누락은 이미 거부했습니다). 이제 그런 토큰 응답은 결합 전에 거부되어 admin 요청을 하나도 보내지 않고, null·객체·배열·누락과 같은 `KeycloakTransportException` 으로 실패합니다. 공개 API 변경은 0 입니다.

## [1.0.3] - 2026-10-02 (Python · .NET · Node)

**Python · .NET · Node 의 patch 입니다**(같은 물결의 나머지는 위 `[1.3.0]` 절의 머리말). 공개 API 변경은 **0** 입니다. ⚠️ 같은 번호의 `[1.0.3] - 2026-09-26 (Java · Kotlin)` 절(아래)은 둘째 물결의 것이고 이 절과 무관합니다.

### Fixed
- **(Node)** `expectedAudience` 를 client id 가 아닌 값(리소스 서버)으로 재정의하면 `exchangeCode(…, nonce)` 가 Keycloak 이 발급한 정상 id_token 을 `invalid id_token` 으로 거부했습니다 — 액세스 토큰의 기대 audience 를 id_token 에도 요구했기 때문입니다. 이제 id_token 의 `aud` 는 OIDC Core §2·§3.1.3.7 대로 **client id** 로 검사하므로 재정의 아래에서도 교환이 통과하고, `aud` 에 client id 가 없는 id_token 은 재정의 값과 같아도 계속 거부합니다. 액세스 토큰 `validate` 는 지금처럼 재정의 값을 쓰고, 두 검증은 JWKS 캐시·재조회 제한을 하나로 공유합니다. 선언된 공개 API(`.d.ts`) 변경은 **0** 입니다 — `@internal` 메서드 `JwtValidator#withAudience` 가 런타임 번들(`dist/jwt.js`)에만 늘어납니다.
- **(.NET)** `KeycloakConfig.ExpectedAudience` 를 client id 가 아닌 값(리소스 서버)으로 재정의하면 nonce 를 넘긴 `ExchangeCodeAsync` 가 **실패했습니다** — id_token 을 access 토큰과 같은 audience 로 검증해, Keycloak 이 client_id 를 담아 서명한 id_token 을 `id_token validation failed` 로 거부했습니다. 이제 통과합니다. id_token 의 `aud` 는 OIDC Core §2 · §3.1.3.7 대로 client id 를 담는지로 검증하고(재정의 값만 담은 id_token 은 거부), 서명 · 알고리즘 핀 · iss · exp 와 JWKS 캐시 · 재조회 제한은 `ValidateAsync` 와 하나를 씁니다. access 토큰 검증(`ValidateAsync`)은 그대로 재정의 값을 요구합니다. 공개 API 변경은 없습니다.
- **(Python)** `expected_audience` 를 client id 가 아닌 값(리소스 서버)으로 재정의하면 nonce 를 넘긴 `exchange_code` 가 `invalid id_token`(원인 `Audience not contained`)으로 **실패했습니다** — id_token 을 액세스 토큰과 같은 기대 audience 로 검증했기 때문입니다(실제 Keycloak 으로 실측). 이제 id_token 의 `aud` 는 OIDC Core §2·§3.1.3.7 대로 **`client_id`** 로 잽니다: 재정의 아래에서도 `aud` 에 client id 가 든 교환은 통과하고, client id 가 빠진 id_token 은 `aud` 가 재정의 값 그 자체여도 거부합니다. `validate()` 의 액세스 토큰 검증은 지금처럼 재정의를 쓰고, JWKS 캐시·재조회 제한도 두 경로가 하나를 함께 씁니다. sync·`aio` 둘 다이며 공개 API 변경은 0 입니다.

### Security
- **(Python)** 실패한 인증 호출의 오류가 **프레임 로컬**로 토큰을 들고 나갔습니다 — 거부된 `exchange_code` 는 받은 토큰 응답(raw refresh token 포함)을 교환 프레임의 `response` 에, 원문 id_token 을 `JwtValidator`·joserfc 프레임에 남겨 원인 사슬(`__cause__`)로 닿게 했고, 인자로 받은 `code`·`code_verifier`·refresh/introspect 토큰도 같은 자리에 있었습니다. `str`·`repr`·`logging.exception` 에는 없지만 `TracebackException(capture_locals=True)` 와 Sentry Python(프레임 로컬 수집이 기본값)이 그것을 찍었습니다(수정 전 실측: `client_credentials_token`·`exchange_code`·`refresh`·`logout`·`introspect` 가 sync·`aio` 모두 샜습니다). 같은 부류로 `authorization_url` 이 조립 도중 실패하면 생성한 `code_verifier` 가, 하위 클라이언트 생성이 실패하면(예: `SSL_CERT_FILE` 이 없는 파일) python-keycloak 프레임이 쥔 **client secret** 이 찍혔습니다(auth 생성자·admin 의 지연 생성 모두). 이제 이 자리들과 `validate()` 는 실패하면 SDK 안쪽 프레임과 원인 사슬의 traceback 을 떼고 인자를 지운 뒤 **같은 예외**를 던집니다 — 타입·메시지·사슬 모양은 그대로이고 잃는 것은 SDK 안쪽 프레임의 줄 번호뿐입니다. 공개 API 변경은 0 입니다.
- **(Python)** admin 이 자기 client_credentials 그랜트 응답의 **빈** `access_token` 으로 admin REST 요청을 보냈습니다(`Authorization: Bearer `) — python-keycloak 의 토큰 세터는 그 값의 타입도 빈 값도 보지 않고, SDK 는 admin 레인에서 그 응답을 검사하지 않았기 때문입니다. `aio` 는 h11 이 그 헤더 값을 거부해 우연히 막혔지만 `KeycloakTransportError`(`Can't connect to server`)로 잘못 보고됐고, 없거나 `null`·문자열이 아닌 `access_token` 은 sync·`aio` 모두 `KeycloakTransportError` 였습니다(auth 레인은 같은 응답을 `KeycloakAuthError` 로 거부합니다). 이제 첫 그랜트·만료 갱신·401 재시도·`Refresh token expired` 폴백 어디서든 그런 응답이면 admin 요청을 보내지 않고 auth 레인과 같은 `KeycloakAuthError`(`token response has no usable access_token`)를 던지며, 그 오류의 원인 사슬과 프레임 로컬에는 거부된 응답·이전 refresh token 이 남지 않습니다. 쓸 수 있는 토큰은 지금처럼 동작하고, 탈출구 `raw` 로 부르는 python-keycloak 메서드도 같은 응답에서 `KeycloakAuthError` 로 멈춥니다. 공개 API 변경은 0 입니다.

## [1.0.2] - 2026-09-27 (Node)

**Node 의 security patch 입니다** — 다른 여덟 언어는 움직이지 않습니다(같은 번호의 아래 `[1.0.2]` 두 절은 다른 언어의 것입니다). 공개 API 변경은 **0** 입니다. 코드 교환을 실제 Keycloak 에 대고 돌리는 통합 테스트를 아홉 언어에 세우다(#640–#648) node 에서만 나온 결함입니다.

### Security
- **(Node)** `exchangeCode(…, nonce)` 가 id_token 의 **서명을 검증하지 않았습니다** — openid-client v6 는 토큰 엔드포인트가 준 id_token 의 서명을 `enableNonRepudiationChecks` 없이는 보지 않고(OIDC Core §3.1.3.7 이 TLS 로 갈음하는 것을 허용), alg 도 SDK 의 `signatureAlgorithms` 가 아니라 서버 메타데이터로만 거릅니다. 그래서 realm JWKS 밖 키(HS256 클라이언트)나 위조 RS256 으로 서명된 id_token 도 nonce 만 맞으면 통과했습니다(실제 Keycloak 과 단위 가짜 IdP 로 실측). 이제 nonce 를 넘기면 id_token 을 SDK 강화 검증기에 태워 서명 · `signatureAlgorithms` 핀 · iss · aud · exp 를 강제하고, id_token 이 없으면 거부합니다 — `SECURITY.md` 가 아홉 언어에 약속한 계약이고, 다른 여덟 언어는 이미 그렇게 합니다. nonce 없이 부르는 교환은 지금처럼 id_token 을 검증하지 않습니다.

## [1.2.0] - 2026-09-26 (Go · PHP)

**2026-09-26 둘째 릴리스 물결 — 여덟 언어가 다섯 번호로 올라갑니다.** 첫 물결(아래 `[1.1.0] (Go · PHP · Rust)` · `[1.0.2] (Java · Kotlin)` · `[1.0.1] (Python · .NET · Ruby · Node)`) 뒤에 착지한 원인 사슬 누출 수정(#617–#624)을 싣습니다. 새 공개 API 가 들어간 Go(`AuthError.GoString`) · PHP(`SanitizedCause`)는 minor(`1.2.0`, 이 절)이고 Ruby(`RedactedCause`)도 minor(`1.1.0`), 나머지는 patch 입니다 — Rust `1.1.1`, Java · Kotlin `1.0.3`, Python · .NET `1.0.2`(아래 절들). Node 는 `node-v1.0.1` 뒤 게시 소스 변경이 없어 `1.0.1` 그대로입니다. 실제로 어디까지 게시됐는지는 이 파일이 아니라 `scripts/lib/deploy-facts.sh` 의 `df_published_version` 이 소유합니다.

⚠️ **같은 번호의 절이 둘씩 있습니다** — `[1.1.0]` 은 Ruby(이 물결)와 Go · PHP · Rust(첫 물결), `[1.0.2]` 는 Python · .NET(이 물결)과 Java · Kotlin(첫 물결)입니다. 번호는 언어별로 독립이라 제목의 언어 목록으로 가릅니다. ⚠️ **Rust 를 뺀 일곱 언어는 오류의 원인 사슬이 바뀝니다** — 하위 라이브러리 예외 원본 대신 정화된 사본이나 요약이 달리므로(언어별 범위는 각 항목), 원인을 하위 타입으로 검사하던 코드는 그 타입을 더 찾지 못합니다. Rust 는 `oauth_error` 가 코드 모양의 OAuth 오류 코드만 싣습니다.

### Security
- **(Go)** 형식이 틀리거나 적대적인 토큰·introspect 응답의 오류가 원인 사슬과 메시지로 그 응답의 토큰을 찍었습니다 — x/oauth2 `RetrieveError` 가 실패 본문·`error_description` 을, net/http 가 깨진 상태줄·헤더·트레일러 줄을, admin 로그인이 `error_description`·리다이렉트 대상을, `AuthError` 의 `%#v` 가 `error` 값을 실었습니다. 이제 하위 타입·HTTP 상태·코드 모양의 OAuth 오류만 남고(admin 로그인 메시지에서 `error_description` 이 빠집니다), 분류와 `errors.Is(err, context.Canceled)`·`net.Error` 는 그대로입니다. **게시본 `1.0.0`·`1.1.0` 에 들어 있습니다.** (#620)
- **(PHP)** 형식이 틀리거나 적대적인 IdP 응답에서 난 오류가 토큰과 응답 본문을 찍었습니다 — 오류 응답의 `error_description`·`error` 가 SDK 메시지와 `oauthError` 에 그대로 실렸고, 원인(`getPrevious()`)으로 단 하위 예외 원본이 응답 본문·토큰 응답·호출 입력(refresh token·code·Basic 헤더)·원문 JWT 를 메시지와 트레이스 인자(`zend.exception_ignore_args=Off`)로 쥐어 `(string)$e`·`var_dump`·`print_r` 가 찍었으며, 문자열이 아닌 `access_token`·`refresh_token` 과 소수 `expires_in` 은 토큰 응답을 쥔 `\TypeError` 로 공개 API 를 빠져나갔습니다. 이제 원인은 원본 클래스명·코드·위치·인자 없는 트레이스만 남긴 `SanitizedCause` 이고(메시지는 감사한 하위 라이브러리가 만든 것만 옮깁니다), 토큰 거부 메시지와 `oauthError` 는 OAuth 오류 코드 모양(`[a-z_]`)일 때만 그 코드를 싣고, 쓸 수 없는 `access_token` 은 `KeycloakAuthError`, 토큰 provider·JWKS 조회의 PSR-18 밖 예외는 `KeycloakTransportError` 입니다. **게시본 `1.1.0` 에 들어 있습니다.** (#622)

## [1.1.1] - 2026-09-26 (Rust)

**Rust 의 patch 입니다**(같은 물결의 나머지는 위 `[1.2.0]` 절의 머리말). 공개 API 변경은 **0** 입니다.

### Security
- **(Rust)** 토큰·introspect 엔드포인트의 오류 응답이 받은 토큰을 되울리면 SDK 오류가 그것을 원문으로 찍었습니다 — `oauth_error` 가 `error_description`·`error_uri`(코드 자리에 온 코드 아닌 값까지)를 그대로 실어 `{:?}` 에, 응답 Content-Type 값·id_token 헤더의 kid·JWKS 본문의 값을 인용한 문구가 `{}` 에도 샜습니다. 이제 `oauth_error` 는 코드 모양의 OAuth 오류 코드(`invalid_grant` 등)만 싣고, 나머지 문구는 인용하던 값을 빼고 의미(분류·위치)만 남깁니다. (#623)

## [1.1.0] - 2026-09-26 (Ruby)

**Ruby 의 minor 입니다**(같은 물결의 나머지는 위 `[1.2.0]` 절의 머리말). ⚠️ 같은 번호의 `[1.1.0] - 2026-09-26 (Go · PHP · Rust)` 절(아래)은 첫 물결의 것이고 이 절과 무관합니다.

### Security
- **(Ruby)** 형식이 틀리거나 적대적인 IdP 응답의 오류가 원인(`cause`) 사슬과 메시지로 그 응답과 SDK 가 보낸 비밀을 찍었습니다 — `full_message`(로거)가 JSON 아닌 본문 앞부분·되울린 `error_description`·깨진 상태 줄을, 하위 `Faraday::ParsingError` 의 `inspect` 가 요청의 클라이언트 시크릿·refresh 토큰·admin 베어러를 남겼고, Ruby 3.2 에서는 감싸이지 않은 `NoMethodError` 가 응답 본문을 인용했습니다. 이제 원인 사슬은 하위 클래스 이름과 백트레이스만, OAuth 오류는 코드와 HTTP 상태만 싣고, 형식이 틀린 200 은 `AuthError` 입니다. **게시본 `1.0.1` 에 들어 있습니다.** (#624)

## [1.0.3] - 2026-09-26 (Java · Kotlin)

**Java · Kotlin 의 patch 입니다**(같은 물결의 나머지는 위 `[1.2.0]` 절의 머리말). 공개 API 변경은 **0** 입니다.

### Security
- **(Java)** 형식이 틀린 토큰·introspect 응답의 오류가 원인 사슬(`printStackTrace` 의 「Caused by:」)로 응답 본문의 토큰을 찍었고(admin 의 토큰 요청도 같았습니다), 요청을 되울린 `error_description` 은 보낸 refresh 토큰·code·verifier·Basic 자격을 메시지에 실었습니다 — 이제 파서 예외 사슬은 타입 이름과 프레임만 남고, 설명은 보낸 비밀과 토큰 모양의 연속을 `***` 로 가립니다. 태그 `v1.0.2` 의 소스에 들어 있습니다. (#617)
- **(Kotlin)** 형식이 틀린 토큰·introspect 응답의 오류가 원인 사슬로 응답을 찍었습니다 — JSON 아닌 본문은 파서가 토큰째(auth), 앞부분·JSON 문자열 값을(admin 내장 TokenManager) 인용했고, IdP 가 error_description 에 되울린 호출자의 refresh·introspect 토큰·시크릿이 SDK 메시지에 실렸습니다. 하위 파서 오류는 타입 이름·스택만 남긴 사본으로 달고, 그 요청에 보낸 비밀은 `***` 로 가립니다. **게시본 `1.0.2` 에 들어 있습니다.** (#618)

## [1.0.2] - 2026-09-26 (Python · .NET)

**Python · .NET 의 patch 입니다**(같은 물결의 나머지는 위 `[1.2.0]` 절의 머리말). 공개 API 변경은 **0** 입니다. ⚠️ 같은 번호의 `[1.0.2] - 2026-09-26 (Java · Kotlin)` 절(아래)은 첫 물결의 것이고 이 절과 무관합니다. ⚠️ **Python 의 introspect `active` 는 이제 JSON boolean 만 받습니다** — 문자열 `"false"` 를 활성으로 읽던 것을 거부합니다(#619).

### Security
- **(Python)** 형식이 틀리거나 요청을 되돌리는 토큰·introspect·logout 응답에서 난 오류가 메시지와 원인 사슬로 그 응답의 토큰과 되돌린 `client_secret` 을 찍었습니다 — python-keycloak 은 오류 메시지에 응답 본문을 싣고 200 인데 JSON 객체가 아니면 본문을 인용한 `TypeError` 를 던지는데, SDK 가 그 메시지를 옮기고 원본을 원인으로 달았습니다(admin 토큰 그랜트도 같았고, `expires_in` 의 raw `ValueError` 는 값을 인용했으며, HTTP 로 파싱되지 않는 상태·헤더 줄은 전송 오류의 원인 사슬로 찍혔습니다). 이제 메시지는 HTTP 상태와 OAuth 오류 코드뿐이고 원인은 하위 오류의 타입·상태·던진 자리만 담은 요약입니다. 전에 raw 로 새던 `TypeError`·`ValueError` 는 auth 에서 `KeycloakAuthError`, admin 에서 `KeycloakTransportError` 이고, 타입이 틀린 `refresh_token`·`id_token`·`token_type`·`scope`·`expires_in` 과 introspect 의 `username`·`client_id` 는 거부합니다. ⚠️ introspect 의 `active` 가 JSON boolean 이 아니면(예: 문자열 `"false"`) **활성**으로 읽던 것도 이제 거부합니다. **게시본 `1.0.0`·`1.0.1` 에 들어 있습니다.** (#619)
- **(.NET)** 형식이 틀린 토큰·introspect 응답의 오류가 원인 사슬과 메시지로 그 응답을 찍었습니다 — 폼 인코딩 본문이면 `ToString()` 이 살아 있는 액세스 토큰째 본문을, JSON 이 아닌 id_token 헤더·페이로드면 IdentityModel 이 가린 디코드 내용을, 잘못된 응답 헤더 줄·알 수 없는 `charset` 이면 그 값을 남겼고, 서버의 reason phrase 와 문자열이 아닌 `error` 멤버는 메시지·`OAuthError` 에 그대로 실렸습니다. 이제 입력을 인용하는 하위 예외는 타입·위치만 남긴 사본으로 달리고, JSON 루트가 객체가 아니거나 본문이 빈 응답은 하위 `InvalidOperationException` 대신 `KeycloakAuthException` 입니다. **게시본 `1.0.0`·`1.0.1` 에 들어 있습니다.** (#621)

## [1.1.0] - 2026-09-26 (Go · PHP · Rust)

**2026-09-26 릴리스 물결 — 아홉 언어가 세 번호로 갈립니다.** 새 공개 API 가 들어간 Go · PHP · Rust 는 minor(`1.1.0`, 이 절), 나머지는 patch 입니다 — Java · Kotlin `1.0.2`, Python · .NET · Ruby · Node `1.0.1`(아래 두 절). 대부분이 보안 수정이라 권장 업그레이드입니다. 실제로 어디까지 게시됐는지는 이 파일이 아니라 `scripts/lib/deploy-facts.sh` 의 `df_published_version` 이 소유합니다.

⚠️ 세 절은 `1.0.0` 태그 이후(JVM 은 `1.0.1` 이후) **게시되는 라이브러리 소스를 고친 커밋**에서 왔습니다. 경위·측정·변이증명은 각 PR 의 커밋 메시지에 있고 여기 옮기지 않습니다. 소비자 행동이 안 바뀌는 소스 변경(주석 교정 #398 · #458)은 적지 않습니다. ⚠️ **여러 언어를 이름한 항목은 해당하는 절마다 그대로 되풀이했습니다** — 항목의 언어 태그 중 **그 절 제목의 언어만** 그 번호로 올라갑니다. 「같은 결함」을 가리키는 항목의 원 결함: #404 ← #403(콜드 캐시 + IdP 장애에서 매 검증이 IdP 를 때림), #551·#556 ← #520(빈 JWKS 키셋이 좋은 캐시를 덮음).

⚠️ **Go `1.1.0` 은 최소 Go 를 1.25 → 1.26 으로 올립니다** — `go/v1.0.0` 의 `go.mod` 는 `go 1.25.0`, 이 릴리스는 `go 1.26.0` 입니다(`golang.org/x/oauth2` v0.37 · `golang.org/x/sync` v0.23 이 선언). 1.25 에 남는 모듈은 `v1.0.0` 에 머뭅니다.

### Security
- **(Go)** 백채널 3xx 가 SSRF 와 fail-open 을 함께 열고 있었습니다 — raw HTTP 세 자리에 2xx 계약을 세웠습니다. (#380)
- **(Go)** 마스킹 바닥 계약을 깨고 있었습니다 — 아홉 언어 교차가드로 켰습니다. (#387)
- **(Go)** 클라이언트·auth·admin 파사드와 토큰 provider 의 기본 표현이 클라이언트 시크릿과 캐시된 액세스 토큰을 원문으로 찍었습니다 — `log.Printf("%+v", client)` 가 시크릿을 남겼습니다. **게시본 `1.0.0` 에 들어 있습니다.** (#592)
- **(Go · PHP · Ruby)** 덤프 경로에서 막을 수 있는 것을 막고, 못 막는 것은 경계로 적었습니다. (#491)
- **(.NET · Node · PHP)** PKCE verifier 와 토큰이 기본 직렬화기로 새고 있었습니다 — **게시본 `1.0.0` 에 들어 있습니다.** (#382)
- **(PHP · Ruby)** 만료 시각 미상을 「안 만료됨」으로 읽었습니다 — PHP 캐시가 죽은 토큰을 영원히 재사용합니다. (#399)
- **(PHP)** 비밀을 인자로 받는 아홉 자리가 스택트레이스에 원문으로 샜습니다. (#467)
- **(PHP)** 클라이언트·auth·admin 파사드의 `var_dump`·`print_r` 가 클라이언트 시크릿과 **진행 중인 PKCE verifier** 를 원문으로 찍었고, `JwtValidator` 두 자리가 스택트레이스에 토큰 앞부분을 남겼습니다 — **게시본 `1.0.0` 에 들어 있습니다.** (#593)
- **(PHP · Ruby)** JWKS 응답에 바이트 상한이 없었습니다 — PHP 는 상태를 보기도 전에 슬러프했습니다. (#466)
- **(PHP · Ruby · Rust)** 빈 JWKS 키셋(200)이 좋은 캐시를 덮어 검증기를 눈멀게 했습니다. (#520)
- **(Rust)** 마스킹 축이 `TokenSet` 하나만 겨눴습니다 — 형제 타입은 무방비였습니다. (#437)
- **(Rust)** JWKS 응답의 HTTP 상태와 본문 크기를 안 봤습니다 — 500 본문이 JSON 이면 파싱됐습니다. (#440)
- **(Rust)** 공개 클라이언트에 빈 시크릿을 강제해 Basic 인증을 켰습니다 — 세 자리 전부. (#441)

### Fixed
- **(Node · Python · PHP)** 0 이하·비유한 타임아웃과 음수 clock skew 를 조용히 받아 쓸 수 없는 클라이언트를 만들었습니다 — **PHP 의 0 은 타임아웃 없는 무한 대기**였고, Node 는 2^31 ms 이상에서 타이머가 1ms 로 바뀌어 즉시 abort 됐습니다. 이제 설정을 만들 때 `ConfigError` 입니다(Node 의 타임아웃 상한은 2147483647 ms). Ruby·.NET·Java·Kotlin 과 같은 규칙입니다. (#590)
- **(Rust)** `logout` 이 400/401/404 에도 `Ok(())` 를 돌려줬습니다 — 세션이 살아있는데 성공입니다. (#397)
- **(.NET · Go · Node · PHP · Python · Rust)** 같은 결함을 나머지 여섯에 복제했습니다(Ruby 는 #403 의 참조 구현 + 보강). (#404)
- **(.NET · PHP · Python · Ruby · Rust)** 존재 검사는 타입 검사가 아닙니다 — 다섯 SDK 가 쓸 수 없는 토큰을 성공으로 냈습니다. (#481)

### Added
- **(Go)** godoc 이 약속한 `TokenProvider` 주입 자리를 만들었습니다 — 지금까지 없었습니다. (#449)
- **(PHP · Rust)** 인가·교환의 `redirect_uri` 를 호출당 받습니다 — 일곱은 되고 둘만 안 됐습니다. (#485)
- **(Rust)** `reqwest` · `RawKeycloakError` · `Jwk` 를 크레이트 루트에서 재노출합니다 — 없으면 `raw()` 소비자가 하위 크레이트를 직접 의존해야 합니다. (#523)

## [1.0.2] - 2026-09-26 (Java · Kotlin)

**Java · Kotlin 의 patch 입니다**(같은 물결의 나머지는 위 `[1.1.0]` 절의 머리말). 공개 API 변경은 **0** 입니다. ⚠️ **설정 검증이 조여졌습니다** — 연결·읽기 타임아웃 `0`(무한 대기)은 이제 `KeycloakConfigException` 입니다(#588). 아래 #551 의 「같은 결함」은 빈 JWKS 키셋(200)이 좋은 캐시를 덮는 결함입니다(#520, 위 절).

### Security
- **(Java · Kotlin · .NET)** 같은 결함이 셋에도 있었습니다 — .NET 은 last-known-good 폴백이 최대 1 시간 가리고 있었을 뿐입니다. (#551)

### Fixed
- **(Java · Kotlin)** 공개(시크릿 없는) 클라이언트가 `refresh`·`logout` 을 할 수 없었습니다 — Keycloak 은 둘 다 허용합니다. 로컬 거부는 서버도 거부하는 `clientCredentials`·`introspect` 에만 남았습니다. (#557)
- **(Java · Kotlin)** 호출 인자를 Nimbus 가 로컬에서 거부하면 그 예외가 SDK 타입으로 번역되지 않고 샜습니다 — 잘못된 PKCE verifier·빈 code·빈 refresh/introspect 토큰은 이제 `KeycloakAuthException`, 잘못된 `redirect_uri` 는 `KeycloakConfigException` 입니다(나머지 일곱은 같은 값을 서버가 거절해 이미 SDK 인증 오류였습니다). `clientCredentialsToken` 은 공백 scope 로 실패하지 않습니다. Java 의 null `code`·`codeVerifier`·`redirectUri` 는 SDK 메시지의 `IllegalArgumentException` 입니다. (#585)
- **(Java · Kotlin)** 형식이 틀린 설정값이 첫 호출에서 하위 예외로 샜습니다(상대 `serverUrl` 은 Nimbus `SerializeException` 자체였습니다) — 이제 설정을 만들 때 `KeycloakConfigException` 입니다: `serverUrl` 은 절대 http(s) URL(포트 65535 이하), 연결·읽기 타임아웃은 1 ms 이상 int 밀리초 이하입니다(**0 은 무한 대기라 이제 거부합니다**). `clockSkew`·`jwksMinRefetch` 는 음수·null 을, Java 의 `scopes`·`signatureAlgorithms` 는 null 을 거부합니다. realm 은 엔드포인트 URL 에서 퍼센트 인코딩되고, `openid` 가 없는 scopes 는 인가 요청에 그대로 실립니다 — 나머지 일곱과 같고, 전에는 Nimbus 예외가 났습니다. (#588)

## [1.0.1] - 2026-09-26 (Python · .NET · Ruby · Node)

**Python · .NET · Ruby · Node 의 patch 입니다**(같은 물결의 나머지는 위 `[1.1.0]` 절의 머리말). ⚠️ 같은 번호의 `[1.0.1] - 2026-09-23` 절(아래)은 **Java · Kotlin** 의 것이고 이 절과 무관합니다 — 번호는 언어별로 독립입니다. ⚠️ **설정 검증이 조여졌습니다** — 형식이 틀린 서버 URL(Ruby·.NET·Node, #589)과 0 이하·비유한 타임아웃·음수 clock skew(Python·Node, #590)는 이제 설정을 만들 때 거부됩니다.

### Security
- **(Go · PHP · Ruby)** 덤프 경로에서 막을 수 있는 것을 막고, 못 막는 것은 경계로 적었습니다. (#491)
- **(Ruby)** admin 경로 세그먼트가 무이스케이프 보간이었습니다 — 엔드포인트 우회 + stdlib 예외 누출. (#383)
- **(Ruby)** provider 의 기본 `inspect` 가 캐시된 액세스 토큰을 원문으로 찍었습니다. (#490)
- **(.NET · Node · PHP)** PKCE verifier 와 토큰이 기본 직렬화기로 새고 있었습니다 — **게시본 `1.0.0` 에 들어 있습니다.** (#382)
- **(PHP · Ruby)** 만료 시각 미상을 「안 만료됨」으로 읽었습니다 — PHP 캐시가 죽은 토큰을 영원히 재사용합니다. (#399)
- **(PHP · Ruby)** JWKS 응답에 바이트 상한이 없었습니다 — PHP 는 상태를 보기도 전에 슬러프했습니다. (#466)
- **(PHP · Ruby · Rust)** 빈 JWKS 키셋(200)이 좋은 캐시를 덮어 검증기를 눈멀게 했습니다. (#520)
- **(Node)** 같은 결함의 마지막 자리였습니다 — jose 의 원격 키셋은 그대로 두고 JWKS fetch 이음매에서 막았습니다. (#556)
- **(Java · Kotlin · .NET)** 같은 결함이 셋에도 있었습니다 — .NET 은 last-known-good 폴백이 최대 1 시간 가리고 있었을 뿐입니다. (#551)
- **(Python)** sync 인가 URL 이 인코딩 없이 조립돼 파라미터가 주입됐습니다. (#442)
- **(Python)** JWKS 응답에 바이트 상한을 걸었습니다 — 9 언어 보안 부류의 마지막 이음매. (#480)
- **(Node)** 사용처 skew 기본값이 무보호였고, 설정값이 아예 도달하지 않았습니다. (#445)
- **(Node)** IdP 가 형식이 틀린 토큰 응답을 주면 SDK 오류가 원인(`cause`) 사슬로 그 응답의 토큰을 찍었습니다 — `console.log(err)` 가 원문 id_token 을, 깊은 직렬화가 access/refresh 토큰을, JSON 아닌 본문이면 그 본문을 남겼습니다. 이제 원인 사슬은 이름·메시지·`code` 만 남깁니다. **게시본 `1.0.0` 에 들어 있습니다.** (#603)
- **(Node)** `jose` 에는 JWKS 크기 상한이 없습니다 — 「미측정」이 「괜찮다」가 아니었습니다. (#471)
- **(.NET)** JWKS·discovery 에 바이트 상한을 걸었습니다 — 공유 `HttpClient` 은 묶지 않습니다. (#477)
- **(.NET)** 토큰 provider 가 캐시한 액세스 토큰을 내부 레코드의 `ToString` 이 원문으로 찍었습니다 — 디버거 조사식·리플렉션 덤프로만 닿는 private 타입입니다. (#594)

### Fixed
- **(Ruby · .NET · Node)** 형식이 틀린 설정 URL 이 첫 호출이나 클라이언트 조립 중 하위 예외(`URI::InvalidURIError`·`UriFormatException`·`TypeError` 등)로 샜습니다 — 이제 설정을 만들 때 `ConfigError` 입니다. Ruby 는 realm 을 엔드포인트 URL 에서 퍼센트 인코딩합니다(전에는 공백 든 realm 이 예외를 냈습니다). (#589)
- **(Node · Python · PHP)** 0 이하·비유한 타임아웃과 음수 clock skew 를 조용히 받아 쓸 수 없는 클라이언트를 만들었습니다 — **PHP 의 0 은 타임아웃 없는 무한 대기**였고, Node 는 2^31 ms 이상에서 타이머가 1ms 로 바뀌어 즉시 abort 됐습니다. 이제 설정을 만들 때 `ConfigError` 입니다(Node 의 타임아웃 상한은 2147483647 ms). Ruby·.NET·Java·Kotlin 과 같은 규칙입니다. (#590)
- **(Ruby)** 콜드 캐시 + IdP 장애에서 매 검증이 IdP 를 때렸습니다 — 참조 구현(20 → 1). (#403)
- **(.NET · Go · Node · PHP · Python · Rust)** 같은 결함을 나머지 여섯에 복제했습니다(Ruby 는 #403 의 참조 구현 + 보강). (#404)
- **(Python)** sync admin 의 `close()` 가 no-op 이었고, 테스트가 그것을 의도로 고정하고 있었습니다. (#469)
- **(.NET · PHP · Python · Ruby · Rust)** 존재 검사는 타입 검사가 아닙니다 — 다섯 SDK 가 쓸 수 없는 토큰을 성공으로 냈습니다. (#481)

## [1.0.1] - 2026-09-23

**Java · Kotlin 둘만 올라갑니다.** 나머지 일곱은 `1.0.0`에 머뭅니다 — 번호는 언어별로 독립이므로 갈리는 것이 정상입니다. 공개 API 변경은 **0**이고, `japicmp`(Java)·japicmp against the published jar(Kotlin) 게이트가 그것을 기계로 확인합니다.

⚠️ **이 릴리스의 요점은 JDK 하한을 21 → 17 로 내리는 것입니다.** 소스는 2026-09-04(#389)부터 17 을 겨눴으나 **게시된 적이 없어**, 지금까지 `1.0.0`을 받은 JDK 17~20 소비자는 `UnsupportedClassVersionError` 를 맞았습니다. 호환을 **넓히는** 변경이라 파괴적이지 않습니다.

- Java: `maven.compiler.release=17` · enforcer `[17,)` (CI 가 17·21·25 셋을 모두 돕니다)
- Kotlin: `jvmTarget = JVM_17` + `-Xjdk-release=17` (`jvmTarget` 만으로는 JDK 21 의 API 표면이 남습니다). 소비자 Kotlin 하한은 **2.2+** 그대로입니다.

### Security
- **(Java · Kotlin)** 하드닝 리트리버를 주입하면서 Nimbus 의 JWKS 51,200 바이트 상한을 지웠습니다. (#400)

### Fixed
- **(Java · Kotlin)** 공백 스코프 하나가 Nimbus 예외를 공개 API 로 흘렸습니다. (#468)

## [1.0.0] - 2026-08-30

**아홉 언어 전부.** 라이브러리 코드 변경은 0입니다 — **1.0 은 기능이 아니라 약속**이고, 이
릴리스는 그 약속을 **지킬 수단이 갖춰졌다**는 선언입니다.

### 무엇이 1.0 을 가능하게 했나

1.0 릴리스 기준(`git show d4e8958:docs/superpowers/plans/release-1.0.md`)의 A–G 가 아홉 곳에서 동시에 충족됐습니다.
결정적인 것은 **A — 공개 API 파괴적 변경을 기계가 막는다**로, 이번 사이클에 아홉 레인 전부에
배선됐습니다(#331–#340):

| 레인 | 도구 | 기준선 |
|---|---|---|
| java · kotlin | japicmp | 게시된 JAR |
| rust | cargo-semver-checks | crates.io 직전판 |
| python | griffe check | 직전 태그 |
| dotnet | SDK Package Validation | NuGet 직전판 |
| go | gorelease | 추론 기준선 |
| php | php-semver-checker | 직전 태그 |
| ruby | yard diff | 직전 태그 |
| node | api-extractor ×2 | npm tarball |

⚠️ **아홉 중 넷은 도구 종료코드가 거짓말한다**(go·php·ruby·node) — 파괴적 변경을 정확히
출력하고도 `exit 0` 이라 리포트 **본문**을 근거로 삼습니다.

### 감추지 않은 것

- **ruby·node 는 커버리지가 좁습니다.** ruby 는 **삭제만** 잡고 시그니처 변경은 못 잡습니다
  (생태계에 등가 도구가 없습니다). node 는 입력 인터페이스에 **필수 필드 추가**를 통과시킵니다
  (위음성 — 실측 재현). 두 자리는 **리뷰가 막습니다.** 각 README 와 SECURITY.md 에 그대로 적었습니다.
- **아홉 게이트 전부 「표면」만 봅니다.** 표면이 그대로인 채 동작이 바뀌는 파괴(예: `clockSkew`
  기본값 30→300)는 못 봅니다. 그 부류 중 **보안 기본선만** 별도 가드가 덮습니다.

### 게시되는 문서를 함께 고쳤습니다 — 이 저장소가 두 번 태워 먹은 부류

`0.1.1`(#318)·`0.2.1`(a7629ef)이 **문서 전용 릴리스**였던 이유가 그것입니다: 레지스트리는 README 를
**버전마다 고정**하므로, 게시 시점에 틀린 문장은 영구히 서빙됩니다. 이번에는 태그 **전에** 아홉
README·루트 README(영/한)·`SECURITY.md`·`compatibility.md`·`getting-started.md`·`language-support.md`·
`CLAUDE.md`·`DEPLOY.md` 와 SSOT(`df_published_version`)를 **한 커밋에서** 옮겼습니다.

⚠️ 릴리스 전 감사에서 이 부류가 아홉 레인 전부에 살아 있었습니다 — rust 는 「`0.1.1` is on
crates.io … this crate is **pre-1.0**」, node 는 「a bare install resolves `0.2.1`」, python 은
`Development Status :: 4 - Beta`. 그대로 태그를 밀었다면 아홉 좌표가 「아직 pre-1.0」이라고
말하는 페이지로 영구 고정됐을 것입니다.

### 가드

- `test-publication-claims.sh` 의 버전 추출이 `0\.` 만 보고 있었습니다 — **1.0 에서 통째로
  공허해집니다**(펜스가 `1.0.0` 을 핀해도 추출 0건). `[01]\.` 로 넓혔습니다.
- 함대 요약 앵커를 **정렬/갈림 두 갈래**로 나눴습니다. ⚠️ 그 루프를 `printf | while read` 로
  쓰면 파이프 오른쪽이 서브셸이라 어서션 실패 카운터가 부모로 돌아오지 않습니다 — 평범한
  `for` 로 씁니다.

## [0.1.1] - 2026-08-28

**Go · C#/.NET · Rust 셋만 올라갑니다. 라이브러리 코드 변경은 0입니다 — 문서 전용입니다.**

게시된 랜딩 페이지가 소비자에게 **거짓 설치 안내**를 하고 있었습니다. 배너를 정식형으로 고친
커밋 `ea4dce1`(2026-08-18 02:04)이 여섯 릴리스 태그보다 **뒤**에 와서, 그 태그가 실어 보낸
README 는 여전히 「the first release candidate … there is no stable release yet」이었습니다.
레지스트리는 README 를 **버전마다 고정**하므로 고치는 방법은 새 버전뿐입니다.

실측(2026-08-28, 기본 랜딩 페이지 기준):

| 레지스트리 | 낡은 문구를 서빙 | 근거 |
|---|---|---|
| crates.io | 예 | `GET /api/v1/crates/keycloak-sdk/0.1.0/readme` → 200, 「there is no stable release yet」 |
| pkg.go.dev | 예 | `@v0.1.0` 페이지가 「the first release candidate (`v0.1.0-rc.1`)」 |
| nuget.org | 예 | 게시 nuspec 의 `<readme>README.md`(출처는 `dotnet/Directory.Build.props`) |

⚠️ **ruby 는 올리지 않습니다.** gem 파일 안에는 같은 텍스트가 있으나 rubygems.org 페이지는
README 를 렌더하지 않아 소비자에게 닿지 않습니다 — 번호는 실제 변경에 씁니다.
⚠️ **java·kotlin 도 아닙니다.** Maven Central 은 README 를 게시하지 않고 POM `<description>`
은 정상입니다.
⚠️ **`0.1.0` 페이지는 영원히 낡은 채로 남습니다.** 세 레지스트리 모두 append-only 이고,
yank·unlist 는 해결이 아니라 악화입니다(정식이 사라지면 RC 가 다시 기본 설치가 됩니다).
고쳐지는 것은 **기본 랜딩**이며, 그것이 소비자가 실제로 보는 자리입니다.

절차는 이미 옳았습니다 — `DEPLOY.md` 가 「같은 커밋이 그 언어의 README 도 고쳐야 한다」고
적습니다. 그 규칙이 쓰인 뒤 `main` 의 증상은 사라졌지만 **이미 게시된 여섯은 아무도 되돌아가
보지 않았습니다.** 이번 릴리스가 그 셋을 갚습니다.

## [0.2.1] - 2026-08-23

**Node · Python 둘만 올라갑니다. 공개 API·타입 표면 변경은 없습니다.**

⚠️ **정확히 적자면 Node는 「문서 전용」이 아닙니다.** `0.2.0` 이후 `node/src/jwt.ts`에 테스트 이음매 `JwtValidator.forKeySource(...)`가 들어갔고(`@internal`), `stripInternal`이 이를 방출 선언에서 지우므로 **`dist/jwt.d.ts`에는 없지만 `dist/jwt.js`에는 있습니다**(실측: `.d.ts` 히트 0 · `.js` 히트 1). 타입 표면은 그대로이나 런타임 번들에는 정적 메서드 하나가 늘어납니다 — 문서화되지 않았고 소비자 경로가 아닙니다. Python은 `python/src` 델타가 **0**이라 진짜 문서 전용입니다.

레지스트리는 README를 **버전마다 고정**하므로, 게시된 페이지의 문장을 고치는 방법은 새 버전밖에 없습니다(`DEPLOY.md` §4 step 1). `0.2.0` 페이지가 `close()`에 대해 사실이 아닌 것을 말하고 있었습니다.

### Fixed
- **(Node) README의 `client.close()` 설명이 거짓이었습니다.** 「cleans up admin + auth resources」라고 적혀 있었는데 실측하면 **양쪽 다 no-op**입니다 — `auth.ts:203`·`admin/index.ts:93`이 둘 다 `return undefined`이고, openid-client 함수형 API와 admin-client가 전역 `fetch` 기반이라 보유 연결이 없기 때문입니다(각 소스의 주석이 그 이유를 적고 있습니다). 소비자가 그 문장을 읽고 커넥션 해제를 기대할 수 있어 고칩니다. **코드는 그대로입니다** — 닫을 자원이 없다는 사실이 맞고, 틀린 것은 문장이었습니다.
- **(Python) README의 `with` 블록 설명이 절반만 참이었습니다.** 「cleans up the admin and auth sessions」 중 auth 쪽은 참이지만(`auth.py:279`가 requests 세션을 실제로 닫습니다) **admin 쪽은 no-op**입니다(`admin/__init__.py:83`이 `return None`이고 독스트링도 그렇게 적습니다). 참인 절반만 남기도록 좁혔습니다. ⚠️ `aio` 비동기 미러는 **다릅니다** — `aio/admin/__init__.py`는 실제로 `aclose()`합니다.

⚠️ 아홉 언어 중 이 부류를 재스캔해 셋을 고쳤고(`node`·`python`·`kotlin`), **java·dotnet은 원래 정확했습니다.** `java/README.md`의 「releases the admin client **if it was created** (AuthClient holds no closeable session)」이 어느 절반이 실재인지 이름으로 밝히는 모범 문장이라 나머지를 그 형태로 맞췄습니다. Kotlin은 Maven Central이 README를 렌더링하지 않고 POM 링크가 저장소를 가리켜 **릴리스 없이 이미 반영**됐습니다.

## [0.2.0] - 2026-08-21

**아홉 중 셋만 올라갑니다 — Node · Python · PHP.** 나머지 여섯(Java·Kotlin·Go·Rust·Ruby·.NET)은 이번 구간에 소비자 영향 변경이 없어 `0.1.0`에 머뭅니다. 버전은 언어별로 독립이므로 번호가 갈리는 것이 정상입니다.

세 언어가 함께 움직인 이유는 하나입니다: **§4(하위 라이브러리 타입은 파사드 뒤에 숨는다)를 실제로 지키지 못하던 자리를 닫았고**, 그 대가가 전부 시그니처 변경이었습니다. 셋 다 pre-1.0이고 **정상 사용 경로(`kc.auth.validate(...)` · `kc.admin.users.search(...)`)는 무변경**입니다.

⚠️ **PHP를 쓰신다면 이번 것은 기능 복구입니다.** `0.1.0`의 `roles()->update(Role $role)`로는 **롤 rename을 표현할 수 없었습니다**(경로가 body에서 나와 PUT이 새 이름 쪽으로 갔습니다). 다른 여덟 언어에는 없던 결함이라, 고치는 방법이 시그니처 변경밖에 없었습니다.

### Changed
- ⚠️ **BREAKING (PHP) `roles()->update()`가 인자를 둘 받습니다 — `update(string $name, Role $role)`.** 종전 `update(Role $role)`은 **롤 rename을 표현할 수 없었습니다**: 하위 fschmtt가 경로를 `$role->getName()`에서 만들어 경로와 body가 한 값에서 나왔고, 실측하면 PUT이 `/roles/{새 이름}`으로 나가 현재 이름은 요청 어디에도 실리지 않았습니다(존재하지 않는 롤에 대한 갱신이므로 rename이 아닙니다). 자매 8개 언어는 전부 `(이름, representation)` 두 인자라 이번 변경으로 §4 동형이 회복됩니다. 구현은 fschmtt의 **공개** 탈출구 `Keycloak::resource()`로 같은 `Command`를 경로/body 분리해 다시 냅니다 — 토큰·HTTP 클라이언트·직렬화기를 그대로 재사용하므로 **토큰 추가 발급이 없습니다**(테스트가 grant 횟수 1을 단언합니다). ⚠️ 이 우회로는 fschmtt가 `@internal`로 표시한 `CommandExecutor` 위에 서 있고, 그것을 안전하게 만드는 것은 `composer.json`의 **정확 핀 `0.42.0`** 하나뿐입니다 — 새 테스트가 실제 HTTP 스택을 태우므로 핀을 올릴 때의 드리프트 가드 역할도 합니다. 경위: [`.claude/rules/php.md`](.claude/rules/php.md).
- ⚠️ **BREAKING (Node) `JwtValidator`를 `new`로 만들 수 없습니다 — `JwtValidator.forJwksUri(...)`를 쓰세요.** 생성자가 `private`이 됐습니다. 런타임 동작은 그대로이고, 타입 수준에서만 막힙니다. 이유는 취향이 아니라 §4 은닉성입니다 — 공개 생성자가 jose의 `JWTVerifyGetKey`를 받는 바람에 방출된 `dist/jwt.d.ts`에 `from 'jose'`가 박혀 하위 라이브러리 타입이 공개 API로 새고 있었습니다. **정상 검증 경로(`kc.auth.validate(token)`)는 무변경**이고, 문서·예제·퀵스타트에 `new JwtValidator(...)`는 없었습니다(테스트만 쓰고 있었습니다).
- ⚠️ **BREAKING (Node) admin 리소스 5종(`UsersResource` 등)의 생성자가 방출 선언에서 사라집니다.** `@internal` + `stripInternal`로 처리했습니다. 이들은 `AdminClient`가 조립하는 내부 이음매라 소비자 생성 경로가 아니었고, 그 생성자가 `KcAdminClient`를 공개 표면에 올리고 있었습니다. **`kc.admin.users.search(...)` 같은 정상 사용은 무변경**이며, 클래스 이름 자체는 계속 export합니다. .NET·Java·Kotlin·Go가 같은 이음매를 이미 `internal`/비공개로 봉인해 둔 것과 같은 처리입니다.
- ⚠️ **BREAKING (Python) `keycloak_sdk.jwt` 모듈이 `keycloak_sdk._internal.jwt`로 옮겨졌습니다.** `from keycloak_sdk.jwt import JwtValidator`를 직접 쓰던 코드만 영향을 받습니다 — `__all__`에도 없었고 README·퀵스타트·예제 어디에도 없던 경로입니다. **정상 검증 경로(`kc.auth.validate(token)`)는 무변경**입니다. 이유는 §4 은닉성입니다: `JwtValidator.validate(token, key_set: KeySet)`가 joserfc의 `KeySet`을 공개 시그니처에 올리고 있었고, `py.typed` 때문에 타입 검사기가 이를 소비자 API로 해석했습니다. ⚠️ **애너테이션을 `Any`로 바꾸는 쪽은 기각했습니다** — 실측하면 잘못된 타입을 넘겼을 때 `KeySet`은 mypy 오류 2건을 내고 `Any`는 **0건**입니다. 이름을 가리는 대가로 실제 검사를 죽이는 교환이라, 파이썬 관용대로 모듈을 `_internal/`(패키지가 `secrets`·`redirects`에 이미 쓰는 자리)로 옮겼습니다.
- **(Node) 공개 타입 표면에 남는 하위 라이브러리 타입은 이제 문서화된 §4(b) 예외 둘뿐입니다** — admin representation 타입과 `raw()`가 돌려주는 하위 클라이언트. `scripts/check-node-public-surface.mjs`가 방출된 `.d.ts`를 훑어 이를 강제하며, Node CI의 build 뒤에 돕니다.

## [0.1.0] - 2026-08-17

아홉 언어의 **첫 정식(stable) 릴리스**입니다. 아래 항목은 전부 첫 RC부터 이 릴리스까지 누적된 것이고, 그중 `⚠️ BREAKING` 셋은 **RC 라인 대비**입니다 — 정식은 이번이 처음이라 깨질 stable 소비자가 없습니다. RC를 쓰던 분만 해당하고, 셋 다 이미 게시된 RC에 들어 있어 정식으로 오면서 새로 깨지는 것은 없습니다(PHP는 `php-v0.1.0-rc.2`, Node는 `node-v0.1.0-rc.2`, Java는 `v0.1.0-RC1`).

⚠️ **npm만 한 가지가 다릅니다.** `@xzawed/keycloak-sdk`는 첫 게시가 프리릴리스라 `latest` 태그가 RC를 가리킨 채였고 레지스트리가 그 태그의 삭제를 거부합니다 — `0.1.0`이 올라가면서 비로소 `latest`가 정식을 가리킵니다.

### Fixed
- **(PHP·Ruby·Go) `JwksStore`를 직접 생성한 소비자의 JWKS 재조회 기본값이 문서(30초)와 달랐다.** 파사드 경로는 무변경. PHP `60초 → 30초`, Ruby `10.0초 → 30.0초`(창이 넓어짐). Go 폴백은 비수출이라 소비자 도달 불가. 정의 자리는 이제 언어당 하나. 60→30 양방향 해석: [CLAUDE.md](CLAUDE.md) JWKS 재조회 게차. (2026-08-13)
- **(Python) `AsyncAdminClient.aclose()`가 중첩 토큰그랜트 httpx 클라이언트를 닫지 않아 FD가 누수됐다.** 게시된 `0.1.0rc1`에서 실측. 지금은 둘 다 닫는다. 경위: [`.claude/rules/python.md`](.claude/rules/python.md). (2026-08-03)
- **(Python) 게시된 휠이 자신을 `0.1.0`으로 보고했다** — `__version__`이 매니페스트와 어긋남. 이제 `importlib.metadata`에서 파생. 경위: [`.claude/rules/python.md`](.claude/rules/python.md). (2026-08-03)

### Added
- **(Rust) admin 파사드가 25/25가 됐다 — 아홉 언어 전부 25/25 달성.** 갭 9개(`update_user`·`list_clients`/`update_client`·`list_realms`/`update_realm`·`list_roles`/`update_role`·`list_groups`/`update_group`)를 메웠다. 파사드는 평평한 관용을 유지한다(`update_role(name, rep)`). ⚠️ **`list_*`의 `max`는 `Option`이 아니다** — `search_users`와 같은 이유로 상한은 항상 호출부에 보여야 한다(Keycloak은 미전송 시 조용히 상한을 적용한다). `list_realms()`만 예외인데 `GET /admin/realms`에 페이지네이션 파라미터가 없다. 경위: [`.claude/rules/rust.md`](.claude/rules/rust.md).
- **(Kotlin) admin 파사드가 25/25가 됐다 — `realms.list`·`realms.update`·`roles.update`·`groups.update` 추가.** Java와 같은 admin-client를 감싸므로 구현도 동형이되 전부 `suspend` + `adminCall {}` 경계 변환이다.
- **(Java) admin 파사드가 25/25가 됐다 — `realms.list`·`realms.update`·`roles.update`·`groups.update` 추가.** admin-client가 fluent 리소스 경로(`realm(name)`·`roles().get(name)`·`groups().group(id)`)로 주소를 잡고 representation을 따로 받으므로 경로/body가 구조적으로 분리돼 rename이 네이티브로 된다.
- **(Python) admin 파사드가 25/25가 됐다 — `realms.list`·`realms.update`·`roles.update`·`groups.update` 추가(sync + `aio` 미러라 구현 단위는 8개).** python-keycloak이 경로 인자와 payload를 분리해 받으므로 rename이 네이티브로 된다. sync와 async가 갈리지 않도록 단위 테스트도 두 미러에 1:1로 넣었다.
- **(Node) admin 파사드가 25/25가 됐다 — `realms.list`·`realms.update`·`roles.update`·`groups.update` 추가.** 시그니처는 자매 언어와 동형이다(`update(주소, representation): Promise<void>`). admin-client가 경로(query)와 body(payload)를 이미 분리해 받으므로 **rename이 네이티브로 된다** — Go처럼 raw REST로 우회할 필요가 없었다.
- **(Go) admin 파사드가 25/25가 됐다 — `realms.List`·`realms.Update`·`roles.Update`·`groups.Update` 추가.** 갭 넷은 `Raw()`로만 닿던 자리였다. 시그니처는 자매 언어와 동형이다(`Update(ctx, 주소, representation) error`). ⚠️ **`Realms.Update`만 gocloak을 거치지 않는다** — gocloak의 `UpdateRealm`이 경로를 body의 `.Realm`에서 만들어 rename을 표현할 수 없어서, §4 동형(Ruby·.NET·PHP는 rename이 된다)을 지키려고 그 한 자리만 직접 요청한다. 오류 분류는 다른 메서드와 동일하다. 경위: [`.claude/rules/go.md`](.claude/rules/go.md).
- **(PHP) admin 파사드에 다섯 리소스 `update()`와 `realms.all()`을 노출.** 반환은 전부 `void`(§4 동형 — fschmtt가 representation을 되돌려주는 불균질은 버린다). `Users::all()`은 `search()`와 같은 엔드포인트라 만들지 않았다. PHP 행은 25/25. 이슈 #190.
- **(PHP) OIDC nonce / `id_token` 재생 방지.** `createAuthorizationRequest()`가 nonce를 항상 만들어 URL에 싣는다. `exchangeCode`의 옵셔널 3번째 인자에 넘기면 `id_token`을 완전 검증한 뒤 nonce를 대조한다. 생략하면 기존처럼 검증을 건너뛴다. 소비자 시그니처 영향은 아래 BREAKING. 이슈 #188.
- **(harness) 교차언어 검증·점수 하네스 `main` 병합 (PR #20).** 8개 언어 샘플 앱 + conformance/security/suites + 4차원 스코어카드. 상세: [`harness/README.md`](harness/README.md). (2026-07-07)
- **(Ruby) `keycloak-sdk` gem 추가 — 8번째 언어 (sync-only).** `faraday`로 Admin REST 직접 래핑 + `rack-oauth2`(PKCE S256 손수) + `jwt` 자체 강화. 경위는 해당 언어 README. (2026-07-06)
- **(Rust) `keycloak-sdk` crate 추가 — 7번째 언어 (1.88+ · async-only).** `keycloak` crate + `openidconnect` + `jsonwebtoken` 자체 강화. 경위는 해당 언어 README. (2026-07-06)
- **(PHP) `xzawed/keycloak-sdk` 추가 — 6번째 언어 (8.3+).** `fschmtt` + `league`/`stevenmaguire` + `firebase/php-jwt` 자체 강화. 게시는 미러 저장소 경로([DEPLOY.md](DEPLOY.md) §2-D). 경위는 해당 언어 README. (2026-07-06)
- **(dotnet) `Xzawed.Keycloak.Sdk` 추가 — 5번째 언어 (net8 · async-first).** `Duende.IdentityModel` + `Microsoft.IdentityModel` + `Keycloak.AuthServices.Sdk` 2.7.0. 경위는 해당 언어 README. (2026-07-05)
- **(Go) `github.com/xzawed/KeyCloakSDK/go` 추가 — 4번째 언어 (sync + `context.Context`).** `gocloak` + `x/oauth2` + `go-jose/v4` 자체 강화. `go/v*` 태그가 곧 릴리스. 경위는 해당 언어 README. (2026-07-04)
- **(Node) `@xzawed/keycloak-sdk` 추가 — 3번째 언어 (ESM · async-only).** 공식 admin-client + `openid-client` v6 + `jose` 자체 강화. 경위는 해당 언어 README. (2026-07-04)
- **(Docs) Keycloak *서버* 배포 가이드** — [`docs/guides/deploying-keycloak-server.md`](docs/guides/deploying-keycloak-server.md). (2026-07-03)
- **(Docs) getting-started · language-support · add-a-language 플레이북 신설.** README는 요약+딥링크만. (2026-07-03)

### Changed
- **(PHP) ⚠️ BREAKING — `AuthorizationRequest`에 `string $nonce` 필드가 추가됐고 `exchangeCode` 시그니처에 옵셔널 3번째 인자가 붙었다.** 게시된 Packagist `0.1.0-rc.1`을 쓰는 소비자: (1) `new AuthorizationRequest(url:, state:, codeVerifier:)`를 **직접** 호출하면 필수 인자 누락으로 TypeError — 이 타입은 SDK가 만들어 주는 값이라 손수 생성하는 소비자는 드물다. (2) `createAuthorizationRequest()` 반환값을 읽기만 하는 소비자는 필드가 **늘어난** 것이라 기존 접근은 그대로다. (3) `exchangeCode($code, $verifier)` 두 인자 호출은 바이너리 호환(기본값 `null`) — 다만 그 경로에서는 여전히 id_token을 검증하지 않는다. 재생 방지를 쓰려면 세 번째 인자로 `$req->nonce`를 넘겨야 한다. 다음 PHP RC에서 소비자 코드가 깨지는 자리는 (1)뿐이다. ✅ **`php-v0.1.0-rc.2`로 게시됐다**(2026-08-17, #196 사람 판정 — 정식 `0.1.0`으로 건너뛰지 않고 RC 계약 안에서 끝냈다). rc.1 소비자용 마이그레이션 안내는 Packagist 랜딩(`php/README.md`의 "Upgrading from `0.1.0-rc.1`")에 있다.
- **(Ruby) `create_authorization_request`가 nonce를 기본 생성한다.** 이전에는 `nonce: nil`이 기본이라 호출자가 `nonce:`를 넘겨야만 인가 URL에 실렸다(아홉 중 유일). 지금은 `state:`와 같이 `SecureRandom.urlsafe_base64(24)`가 기본이고 URL에 항상 실린다. `exchange_code(expected_nonce:)`는 그대로 옵셔널 — 생략하면 id_token 검증을 건너뛴다. `AuthorizationRequest` `Data.define`에 `:nonce`가 추가됐으므로 이 값을 **직접** `new`하던 소비자는 키워드를 더해야 한다(파사드 경로는 무변경).
- **(Java·Kotlin) `keycloak-admin-client` 26.0.11 → 26.0.12 · `junit` 6.1.2 → 6.1.3 (PR #185).** `StreamMessageBodyReader`는 26.0.12에도 있다(컴파일로 확인).
- **(Java·Kotlin) ⚠️ admin 부분 업데이트에서 `null`로 필드를 비울 수 없게 된다 — 공식 admin-client 동작으로의 복원 (PR #84·#85).** `resteasyClient(...)` 주입이 상류 `JacksonProvider` 등록을 우회해 NON_NULL을 잃고 있었다. **소비자 영향**: 미설정 필드는 전송되지 않아 서버가 '변경 없음'으로 처리하므로, 필드를 비우려면 빈 문자열이나 전용 API를 써야 한다. 경위: [`.claude/rules/java.md`](.claude/rules/java.md). (2026-07-22)
- **(Node) ⚠️ BREAKING — 지원 런타임 하한을 Node 20 → 22로 상향 (PR #87).** Node 20은 2026-04-30 EOL이고 DefinitelyTyped가 `types/node/v20`을 제거해 기존 `@types/node ^20` 핀 자체가 유지보수 종료 상태였다. `engines.node >= 22` · `@types/node ^22`(타입은 최신이 아니라 engines 하한을 따라간다) · CI 매트릭스 `['22','24']` · 하네스 이미지 `node:22-alpine` · 문서를 함께 옮겼다. 레지스트리 게시 0회 시점이라 소비자 비용 없음. (2026-07-22)
- **(Node) 의존성 메이저 전진 (PR #79·#80·#86).** `jose` 5 → 6 (공개 API 동일, JWKS rate-limit 유지) · `typescript` 5 → 6 (산출 `dist/**` 바이트 동일). 소비자 런타임 표면 무변경. 경위: [`.claude/rules/node.md`](.claude/rules/node.md). (2026-07-22)
- **(Rust) `jsonwebtoken` 10.4.0 → 11.0.0 (PR #108).** 기형 JWKS 거부 단계가 파싱(`Transport`)에서 키 생성(`TokenValidation`)으로 옮겨졌다. fail-closed는 유지되고, 미지 kty가 섞여 있어도 세트 전체가 죽지 않는다. MSRV 1.88 그대로. 경위: [`.claude/rules/rust.md`](.claude/rules/rust.md). (2026-07-31)
- **(CI) SonarCloud를 Dependabot PR에서 건너뛴다 (PR #83).** Dependabot run에는 Actions 시크릿이 없어 스캔이 항상 실패했다. 사람 PR·push 게이트는 불변. 경위: [`.claude/rules/ci.md`](.claude/rules/ci.md). (2026-07-22)
- **(Java) ⚠️ BREAKING — 요구 런타임을 JDK 17 → 21 LTS로 상향.** `maven.compiler.release=21` + enforcer `requireJavaVersion=[21,)`. 아티팩트는 `--release 21`로 컴파일되므로 **소비자도 JDK 21+에서 실행**해야 하며, 이전 JDK에서는 `UnsupportedClassVersionError`가 발생합니다. `maven-compiler-plugin`을 `3.11.0`으로 명시 고정(기본값 드리프트 방지). CI·릴리스 워크플로도 JDK 21 단일 사용. 소스·공개 API 무변경. (2026-07-03)

- **(9개 언어) JWKS 재조회 최소 간격 기본값을 30초로 정렬했다(기존 10·30·60초 세 갈래).** PR #71 config화의 산물이었고, 같은 위조 kid 폭주에 Ruby가 Python보다 IdP를 6배 자주 때렸다. 소비자 API 무변경. 경위·60초를 버려 잃은 것: [CLAUDE.md](CLAUDE.md) JWKS 재조회 게차.
- **(릴리스) `release-trigger.sh`가 언어별 RC 표기를 받는다** — PEP 440 / RubyGems / Maven / SemVer. 절차: [DEPLOY.md](DEPLOY.md) §7.
- **(릴리스) Java도 발행 전 통합 게이트를 `needs:` 잡 경계에 둔다.** 아홉 언어가 같은 서술. 절차: [DEPLOY.md](DEPLOY.md) §1.

### Security
- **(9개 언어) JWT 하드닝 6불변식을 행동 테스트로 닫았다.** 감사 당시 테스트로 증명된 언어는 Rust·Ruby뿐이었다. JWKS rate-limit 테스트에는 대조군이 있다. 공개 API 무변경.
- **(Java·Kotlin) `jwksMinRefetch`가 Nimbus 캐시 TTL 이상이면 이제 `KeycloakConfigException`이다.** 예전에는 `IllegalStateException`이 공개 API로 샜다(§4 위반). 경위: [`.claude/rules/java.md`](.claude/rules/java.md).
- **(Java) jackson-databind `2.21.2` → `2.21.4`.** CVE 6건 해소. 후속 핀 이력은 CLAUDE.md 의존성 표. (2026-07-03)
- **(Java) Jackson default/polymorphic typing 도입을 CI `invariant` 잡이 막는다.** 위 무위험 판정의 전제. (2026-07-03)

---

<!-- 릴리스 시: [Unreleased] 아래에 `## [x.y.z] - YYYY-MM-DD` 섹션을 만들고 해당 항목을 이동한다.
     태그: Java `v*` · Python `py-v*` · Node `node-v*` · Go `go/v*` · C#/.NET `dotnet-v*` · PHP `php-v*` · Rust `rust-v*` · Ruby `ruby-v*`. -->
