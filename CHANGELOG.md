# Changelog

이 프로젝트의 주요 변경사항을 기록합니다. 형식은 [Keep a Changelog](https://keepachangelog.com/ko/1.1.0/)를 따르며, 버전은 [SemVer](https://semver.org/lang/ko/)를 지향합니다.

> 이 리포지토리는 **폴리글랏 SDK**입니다. Java(`io.github.xzawed:keycloak-sdk`)·Python(`keycloak-sdk`)·Node(`@xzawed/keycloak-sdk`)·Go(`github.com/xzawed/KeyCloakSDK/go`)·C#/.NET(`Xzawed.Keycloak.Sdk`)·PHP(`xzawed/keycloak-sdk`)·Rust(`keycloak-sdk`)·Ruby(`keycloak-sdk`)·Kotlin(`io.github.xzawed:keycloak-sdk-kotlin`) 9개 언어가 독립 배포되며, 아래 항목은 언어 태그로 구분합니다. 지금까지 아홉 언어 전부가 **첫 릴리스 후보(RC)**를 게시했습니다(PHP `v0.1.0-rc.2` · Python `0.1.0rc1` · .NET `0.1.0-rc.1` · Rust `0.1.0-rc.1` · Ruby `0.1.0.rc1` · Node `0.1.0-rc.2` · Java `0.1.0-RC1` · Kotlin `0.1.0-RC1` · Go `0.1.0-rc.1`) — 정식(stable) 릴리스는 아직 어느 언어도 없으므로 아래 항목은 모두 `[Unreleased]`입니다.

## [Unreleased]

### Fixed
- **(PHP·Ruby·Go) `JwksStore`를 직접 생성한 소비자의 JWKS 재조회 기본값이 문서(30초)와 달랐다.** 파사드 경로는 무변경. PHP `60초 → 30초`, Ruby `10.0초 → 30.0초`(창이 넓어짐). Go 폴백은 비수출이라 소비자 도달 불가. 정의 자리는 이제 언어당 하나. 60→30 양방향 해석: [CLAUDE.md](CLAUDE.md) JWKS 재조회 게차. (2026-08-13)
- **(Python) `AsyncAdminClient.aclose()`가 중첩 토큰그랜트 httpx 클라이언트를 닫지 않아 FD가 누수됐다.** 게시된 `0.1.0rc1`에서 실측. 지금은 둘 다 닫는다. 경위: [`.claude/rules/python.md`](.claude/rules/python.md). (2026-08-03)
- **(Python) 게시된 휠이 자신을 `0.1.0`으로 보고했다** — `__version__`이 매니페스트와 어긋남. 이제 `importlib.metadata`에서 파생. 경위: [`.claude/rules/python.md`](.claude/rules/python.md). (2026-08-03)

### Added
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
