# Changelog

이 프로젝트의 주요 변경사항을 기록합니다. 형식은 [Keep a Changelog](https://keepachangelog.com/ko/1.1.0/)를 따르며, 버전은 [SemVer](https://semver.org/lang/ko/)를 지향합니다.

> 이 리포지토리는 **폴리글랏 SDK**입니다. Java(`io.github.xzawed:keycloak-sdk`)·Python(`keycloak-sdk`)·Node(`@xzawed/keycloak-sdk`)·Go(`github.com/xzawed/KeyCloakSDK/go`)·C#/.NET(`Xzawed.Keycloak.Sdk`)·PHP(`xzawed/keycloak-sdk`)·Rust(`keycloak-sdk`)·Ruby(`keycloak-sdk`)·Kotlin(`io.github.xzawed:keycloak-sdk-kotlin`) 9개 언어가 독립 배포되며, 아래 항목은 언어 태그로 구분합니다. 지금까지 아홉 언어 전부가 **`1.0.0`**을 게시했습니다 — 같은 날 도달한 것은 [1.0 기준](docs/superpowers/plans/release-1.0.md)의 A–G를 아홉 곳이 동시에 충족했기 때문이지 함대로 움직여서가 아닙니다(이후에는 다시 갈립니다). 그 아래 `[0.2.x]`·`[0.1.x]`·RC 항목은 그대로 역사로 남습니다. ⚠️ 어느 레지스트리에 실제로 올라갔는지는 이 파일이 아니라 `scripts/lib/deploy-facts.sh`의 `df_published_version`이 소유합니다 — 태그를 밀었다는 것과 게시됐다는 것은 다릅니다.

## [Unreleased]

## [1.0.0] - 2026-08-30

**아홉 언어 전부.** 라이브러리 코드 변경은 0입니다 — **1.0 은 기능이 아니라 약속**이고, 이
릴리스는 그 약속을 **지킬 수단이 갖춰졌다**는 선언입니다.

### 무엇이 1.0 을 가능하게 했나

[1.0 릴리스 기준](docs/superpowers/plans/release-1.0.md)의 A–G 가 아홉 곳에서 동시에 충족됐습니다.
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
