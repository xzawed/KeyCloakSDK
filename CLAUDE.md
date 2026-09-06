# CLAUDE.md
<!-- doc-budget: max-bytes=24641 max-lines=308 -->
<!-- 24380 → 24641 (2026-09-06, +261B): 래칫 조건 (1) — 증가분이 **가드 자체**를 사 온다.
     이 문단이 정하는 규칙(래칫 인상 조건)에 오래 **가드가 없었다**. 검사 8 은 상한 초과만 보고
     상한을 올려 버리면 그 초과가 사라지므로, 인상은 사람이 눈으로 잡는 수밖에 없었다 — 실측
     2026-09-06: 한 세션에서 거짓 문장을 고치다 네 번 넘겼고(+300 · +236 · +120 · +84B) 네 번 다
     사람 판정으로 갔다. 이제 `check-docs.mjs` 검사 8b 가 `main` 과 대조해 인상을 보고, 교환
     기록(`옛값 → 새값`)과 300B 상한을 강제한다(자가테스트 10건 · 공허 방지 포함).
     ⚠️ **이 인상 자체가 그 규칙의 첫 적용이다** — 초안 379B 를 261B 로 압축해 상한 안에 넣었다.
     ⚠️ 절대 바이트인 이유(퍼센트가 아니라): 5% 면 이 문서에 1,200B 를 무심사로 주고 5.5KB
     짜리 `security.md` 의 300B 인상은 막는다. 실측 인상 넷은 84~300B 로 파일 크기 15배 차에도
     좁은 절대 대역에 모여 있었다. -->
<!-- 24,159 → 24,380 (2026-09-05, +221B): 래칫 조건 (1) — 증가분이 **가드 자체**를 사 온다.
     직전 래칫(+44B)이 「넷째 종류」를 손으로 적고 끝냈고, 가드가 없어서 이틀 만에 또 어긋났다 —
     실측 `.github/dependabot.yml` 의 `ignore` 는 8건인데 그 목록은 5건만 덮었다. 이제
     `kind=ignores` 앵커가 이 문단을 그 파일과 **양방향**으로 대조한다(항목이 늘면 문단이,
     줄면 min 이 빨개진다 — 변이 5건 + 대조군으로 확인). facts 64→72.
     ⚠️ **빠진 셋을 다섯째 종류로 접지 말 것**(초안이 그렇게 썼다가 되돌렸다): `@types/node` 는
     소비자 하한이라 둘째 종류가 맞지만, `vitest`·`@vitest/coverage-v8` 은 **종류가 아니다** —
     앞의 넷은 값이 *다른 결정*을 뜻해 영구히 사람이 올리는 것이고, 이 둘은 v4 이관만 끝나면
     지울 **일시적 보류**다(실측: dependabot.yml 주석 중 「그때 이 항목을 지운다」는 이 둘뿐).
     그래서 「네 종류 + 나머지」이고, 그 나머지 단서가 곧 다음 세션이 또 접는 것을 막는다.
     같은 이유로 ci.md 에서 개수·열거를 **지웠다** — 두 곳에 있던 것이 두 번 어긋난 원인이고,
     해제 조건도 `gh api` 명령도 이미 dependabot.yml 주석이 소유한다(ci.md 8,870B/9,985B). -->
<!-- 24,115 → 24,159 (2026-09-03, +44B): 래칫 조건 (1) — 증가분이 **기계 집행**을 사 온다.
     dependabot 이 올려선 안 되는 핀에 **넷째 종류**(대상 서버 라인 = rust `keycloak`)가 생겼고,
     `.github/dependabot.yml` 의 `ignore` 가 그것을 실제로 막는다. 근거·실측(PR #394: 서버 26.6
     대상 integration 이 초록인데도 받지 않는 이유)은 그 파일 주석이 소유하고, 여기에는 「몇
     종류이고 어느 것인가」만 남긴다 — 그 목록이 없으면 다음 세션이 ignore 를 오탐으로 지운다.
     44B 는 항목 이름만큼이고 더 줄이면 어느 핀인지가 사라진다. -->

<!-- 23,800 → 24,100 (2026-08-29, 5회 품질검증 결과): §4(b) 정정. 「두 자리」가 실제로는 **세 자리**였고
     (Rust 저수준 생성자가 `reqwest::Client` 를 받는다 — lib.rs 주석이 이미 그렇게 적고 있었다),
     마무리 문장 「정상 소비 경로는 이들을 노출하지 않는다」는 **자기모순**이었다: 노출 자리 (a)가
     곧 admin 파사드이고 Go 예제가 스스로를 "the primary flow" 라 부른다. 계약 서술이 틀린 것은
     압축 대상이 아니라 정정 대상이라 올린다.
     23,125/301 → 23,800/304 (2026-08-29): 래칫 조건 (2). 사람 판정 — 「작업문서는 지나친 압축보단
     정확한 작업 수행이 우선」. 늘어난 한 문단은 **래칫 규칙 자신에 붙는 단서**다: 압축이 판정
     방법을 지우면 줄이지 말고 올려라. ⚠️ 이 문단을 압축하면 그 자체로 자기모순이므로,
     여기가 이 규칙의 예외 없는 최소 단위다. 실례(sonar 487)를 함께 남긴 것은 다음 세션이
     「결론만 남기고 명령을 지운 문장」을 알아볼 수 있어야 하기 때문이다.
     21,750/285 → 23,085/301. 사람이 문서의 **역할**을 바꿨다: 「작업 프로세스」 6단계와 PM 역할이
     상주해야 한다는 판정(2026-08-17). 기계 검증 교환이 아니므로 그 사실을 여기 적는다.
     상쇄로 process.md와 중복된 「하지 말 것」 2건은 걷어냈다.
     23,085 → 23,125 (2026-08-21): 래칫 조건 (1) — 증가분 40B가 **기계 검증을 사 왔다**.
     진입 명령에 `--min-anchor-links=24`이 붙었고, 그건 신설된 검사 10(링크 `#앵커` ↔ 실제 헤딩)의
     공허함 방어 하한이다. 산문이 아니라 가드가 늘어난 자리라 교환이 성립한다.
     24,100 → 24,115 (2026-09-02): 같은 부류의 15B. 진입 명령에 `--min-blob-refs=4` 가 붙었고,
     그건 신설된 검사 10c(아카이브 참조 `git show <sha>:<path>` 가 실제로 해석되는가)의 공허함
     방어 하한이다. ⚠️ 이 줄을 CI 와 **함께** 옮겨야 하는 이유가 A2 다 — 여기가 「맨 명령」이 되면
     로컬 초록·CI 빨강이 다시 만들어진다(CONTRIBUTING·development-setup 의 사본도 같다). -->


Keycloak **폴리글랏 SDK** — 9개 언어(Java·Python·Node·Go·C#/.NET·PHP·Rust·Ruby·Kotlin)가 같은 API 모양을 각 언어 관용으로 구현한다. 인증(OIDC/OAuth2)과 관리 REST API 두 표면을 모두 덮는다. Apache-2.0 · groupId `io.github.xzawed`.

> **이 파일은 "지금 이 코드에서 어떻게 일하는가"만 적는다.** 사고 이력·설계 경위·측정 로그는 git log와 [CHANGELOG.md](CHANGELOG.md)에 있고 여기 옮겨 적지 않는다. 규칙은 **무엇을 하라**로 쓰고, 왜 그런지는 한 절 이상 쓰지 않는다.

## 작업 프로세스

**모든 작업은 6단계를 밟고 WBS가 뼈대다.** 작아지면 단계가 한 줄로 압축될 수는 있어도 건너뛰지 않는다.

| 단계 | 나가는 조건 |
|---|---|
| ① 기획 | 전제가 **명령 출력**으로 확인됐다 (또는 기각 + 되살릴 조건) |
| ② 계획 | **WBS** — 모든 항목이 검증 가능한 단위다 |
| ③ 검토 | 기각 체크리스트 8항목 판정 완료 |
| ④ 일정 수립 | 의존 위상정렬 + 게이트 위치 + 비가역 지점 `[!]` 표시 |
| ⑤ 수행 | 항목별 TDD 통과, **커밋이 변이보다 앞** |
| ⑥ 검증·테스트 | G1–G6 PASS · 출력을 **다시 읽음** · 부류 재스캔 |

**역할**: 오케스트레이터가 **PM**이다 — 단계 확인·WBS 소유·작업 분배·에이전트와 Grok 중재·결과 **재검증**. 구현/리뷰/검증은 서로 다른 주체가 맡고(자기 승인 금지), 실질 작업에는 **Grok 독립 레그**를 준다. 어느 에이전트의 결과도 액면가로 받지 않는다.

전체 절차·WBS 규약·기각 체크리스트·게이트: **[작업 프로세스](docs/governance/process.md)**.

### 이 저장소에서의 구체 진입점

1. **언어 디렉터리에서 작업한다.** `java/`·`python/`·`node/`·`go/`·`dotnet/`·`php/`·`rust/`·`ruby/`·`kotlin/` 중 하나에 들어가면 `.claude/rules/<lang>.md`가 자동 로드된다(`paths:` 프론트매터). **그 파일이 그 언어의 빌드 명령·제약·게차의 진실 원천이다** — 이 파일에 다시 적지 않는다.
2. **바꾸기 전에 테스트를 돌린다.** 아래 툴체인 표의 진입 명령. 통합 테스트는 Docker가 필요하다.
3. **문서·매니페스트를 건드렸으면** `node scripts/check-docs.mjs . --strict --min-facts=74 --min-anchors=22 --min-anchor-links=24 --min-blob-refs=4`.
4. **PR로 올린다.** `main` 직접 push 불가(룰셋 `PRIMARY`). required 체크는 `doc-facts`·`shell-exec-bits` 둘뿐이고 **언어 CI를 required에 넣으면 저장소가 잠긴다**(`paths:` 필터라 체크가 생성조차 안 된다).

### 하지 말 것

- **리포 파일 편집은 Edit 툴.** 왕복 해석기(`node -e`·heredoc·`perl`…)가 백슬래시·`$`를 조용히 먹는다.
- **외부 도구·레지스트리의 동작을 실측 없이 서술하지 않는다.** 붙일 출력이 없으면 그 문장을 쓰지 않는다. 자매 생태계가 같게 동작한다고 가정하지 않는다.
- **자기 행위("PR을 만들었다"·"복원했다")를 명령 출력 없이 주장하지 않는다** — 저장소에 흔적이 남지 않아 어떤 가드도 못 잡는다.
- **로컬 게이트가 볼 수 없는 것을 비가역 행위 전에 열거한다** — 계정 상태·토큰 종류·이메일 인증·2FA. `release-readiness.sh`의 초록은 게시 승인이 아니다.

(파괴적 명령 전 커밋 · 재스캔 없이 "전부" 금지 · 커밋 규약은 [작업 프로세스](docs/governance/process.md) ⑤⑥·§6이 소유한다.)

## 툴체인 (빌드 명령)

언어별 전체 명령(빌드·테스트·린트·배포·단일 테스트)은 `.claude/rules/<lang>.md`에 있다(그 경로에서 자동 로드). 아래는 진입 명령 하나씩만 남긴 표다.

**새 머신에서 시작한다면**: `node scripts/doctor.mjs [<lang>…]`이 각 언어의 빌드 파일에서 최소 런타임 선언을 읽어 이 PC에 무엇이 없는지 알려준다. 설치·환경변수 규약(`KCSDK_TOOLS`·`KCSDK_JDK21`·`KCSDK_PY`)은 [docs/guides/development-setup.md](docs/guides/development-setup.md). 툴체인 경로는 `.claude/rules/*.md`에 머신 기본값을 둔 채 이 변수들로 덮어쓸 수 있다(리포지토리에 특정 PC 경로를 못박지 않는다).

| 언어 | 핵심 진입 명령 | 상세 |
|---|---|---|
| Java | `mvn -f java/pom.xml verify` | `.claude/rules/java.md` |
| Python | `cd python && "${KCSDK_PY:-.venv/Scripts/python.exe}" -m pytest -m "not integration" --cov=keycloak_sdk` | `.claude/rules/python.md` |
| Node | `cd node && npm test` | `.claude/rules/node.md` |
| Go | `go -C go test ./...` | `.claude/rules/go.md` |
| C#/.NET | `cd dotnet && dotnet test --filter "Category!=Integration"` | `.claude/rules/dotnet.md` |
| PHP | `cd php && vendor/bin/phpunit --testsuite unit` | `.claude/rules/php.md` |
| Rust | `cd rust && cargo test` | `.claude/rules/rust.md` |
| Ruby | `cd ruby && bundle exec rspec` | `.claude/rules/ruby.md` |
| Kotlin | `cd kotlin && ./gradlew test` | `.claude/rules/kotlin.md` |

## 아키텍처 계약

폴리글랏 모노레포 — 언어당 디렉터리 하나, 각각 독립 빌드.

### 모듈 구조 (9개 언어 공통)

```
config · errors/masking · tokens · oidc(엔드포인트 조립, 네트워크 없음)
token_provider(캐시·single-flight) · jwks(DoS-safe) · jwt(자체 강화 검증)
auth(하위 OIDC 라이브러리 래핑) · admin/(users·clients·realms·roles·groups + raw 탈출구) · client(진입점)
```

`client`가 `auth`를 즉시 조립하고 `admin`은 지연 생성한다(**Rust만 즉시**). close/dispose는 실제 생성된 것만 정리한다.

물리 배치가 공통과 다른 넷: **Java** 6개 Maven 모듈 · **Python** `src/` 레이아웃 + `aio/` 비동기 미러 · **Go** 전체가 단일 `package keycloak`(admin을 서브패키지로 두면 import 순환) · **Kotlin** 단일 Gradle 모듈, 네트워크 메서드 전부 `suspend`.

### §4 언어 중립 계약

**하위 라이브러리 타입은 파사드 뒤에 숨는다.** 개념·계층은 9개 언어 동형이고 표기만 갈린다(`TokenSet`·`ValidatedToken`·`IntrospectionResult`·`Client.auth/admin`). **하위 오류는 항상 경계에서 SDK 타입으로 변환**되어 공개 API로 새지 않는다. Go/Rust는 error 값(센티넬 `errors.Is` / `Result<T, KeycloakError>`), 나머지는 예외(Kotlin은 sealed class).

**`admin`은 `auth`에 의존하지 않는다.** 독립을 이루는 방법이 둘로 갈린다 — Node·Rust·Ruby·.NET·Go는 `TokenProvider`가 유일한 접착제이고, **Java·Kotlin·PHP·Python은 admin이 토큰을 자체 소유**해 소비자가 토큰 소스를 주입할 수 없다.

⚠️ **Node는 SDK provider를 `registerTokenProvider`로 배선한다**(`kc.auth()`를 호출하지 않는다) — admin-client 내장 TokenManager는 만료 시 refresh만 시도해 client_credentials에서 영구 실패한다.

### §4(b) 문서화된 은닉성 예외

완전 은닉이 아니다. 세 자리가 하위 타입을 노출한다 — **(a)** admin 파사드의 representation 타입(Java/Kotlin `org.keycloak.representations.idm.*` · Node `defs/*` · Go `gocloak.*` · C# `*Representation` · PHP `Fschmtt\…\Representation\*` · Rust `keycloak::types` — Python·Ruby는 plain dict/Hash라 노출 없음), **(b)** `raw()` 탈출구가 돌려주는 하위 클라이언트, **(c)** Rust 저수준 주입 생성자가 받는 `reqwest::Client`(`AdminClient`·`AuthClient`·`ClientCredentialsTokenProvider`·`JwksStore`의 `new`). ⚠️ **「정상 소비 경로는 노출하지 않는다」고 쓰지 말 것 — (a)가 곧 admin 파사드이고 그것이 정상 경로다.** 참인 진술은 **이 셋 밖에는 없다**이고, Node 만 기계 검증한다(`node scripts/check-node-public-surface.mjs` → 누출 0).

⚠️ Rust는 `keycloak_sdk::types`로 미러 재노출한다 — 없으면 소비자가 `keycloak` crate를 직접 의존해야 해서 게시된 퀵스타트가 컴파일되지 않는다.

9개 언어 전체 `raw` 표와 admin capability matrix: [admin-capability.md](docs/reference/admin-capability.md).

## 교차언어 제약

언어별 제약은 **전부 `.claude/rules/<lang>.md`에 있다**(그 경로에서 자동 로드). 여기에는 경로와 무관하게 걸리는 것만 둔다.

- ⚠️ **JWT 검증은 자체 강화 구현이다** — 알고리즘 핀닝(`none` 거부)·`iss` 정확일치·`aud` 포함검사·`exp` 필수·클록 스큐 제한·JWKS 재조회 rate-limit. 라이브러리 기본값은 9개 언어 어디서도 안전하지 않다.
- ⚠️ **JWKS 재조회 최소 간격과 `clockSkew`는 9개 언어 전부 30초다 — 하나만 바꾸지 말 것.** 상세: `.claude/rules/security.md` · 가드: `scripts/test/test-security-defaults.sh`.
- ⚠️ **보안 기본선**: 토큰/시크릿 로깅 금지 · 완전 마스킹(`***`, 접두 노출 없음) · TLS 검증 기본 on · 인메모리 토큰저장.
- ⚠️ **시크릿 메모리 위생은 end-to-end 보장이 아니다 — 과대광고 금지.** 상세: `.claude/rules/security.md`.
- ⚠️ **admin-client와 Keycloak 서버는 독립 버전 트랙이다** — 서버 라인과 같은 번호의 admin-client는 없다. `representation` 필드는 실서버로 검증한다.
- ⚠️ **Maven Central은 Central Portal 경로만**(구 OSSRH 종료). 워크플로 초록 ≠ 게시 — Publish 후에도 전파 지연이 있으니 **404로 실패를 결론내지 않는다**(Java·Kotlin 공통).
- ⚠️ **배포 시크릿 미설정은 스킵이 아니라 실패다** — 아무것도 게시하지 않고 green으로 끝난 실행은 성공한 실행과 구분되지 않는다.
<!-- doc-guard: kind=ignores source=.github/dependabot.yml min=8 -->
- ⚠️ **dependabot이 올려서는 안 되는 핀 네 종류** — 값이 **다른 결정**을 뜻하는 것들: ref가 브랜치인 액션(`rust-toolchain`·`gh-action-pypi-publish`)·소비자에게 보이는 하한(`kotlin-stdlib`·`@types/node`)·CI 매트릭스 하한(`parallel`)·**대상 서버 라인**(rust `keycloak`). ⚠️ **분할이 아니다** — `vitest`·`@vitest/coverage-v8`은 종류가 아니라 **일시적 이관 보류**다. 근거·해제 조건·명령은 `.github/dependabot.yml`의 `ignore` 주석이 소유한다.

## 확정 의존성 (BOM으로 고정)

<!-- doc-guard: kind=dep source=java/pom.xml min=5 -->
| 의존성 | 좌표 | 버전 |
|---|---|---|
| Keycloak admin-client | `org.keycloak:keycloak-admin-client` | 26.0.12 |
| OAuth2/OIDC SDK | `com.nimbusds:oauth2-oidc-sdk` | 11.38.2 |
| JOSE/JWT | `com.nimbusds:nimbus-jose-jwt` | 10.9.1 |
| 통합 테스트 | `com.github.dasniko:testcontainers-keycloak` | 4.3.1 |
| Testcontainers | `org.testcontainers:testcontainers` (+ `-junit-jupiter`) | 2.0.5 |
| 단위 테스트 | JUnit 6.1.3 · Mockito 5.23.0 | — |

**Python 확정 의존성(pyproject.toml, major 상한 고정)**:

<!-- doc-guard: kind=dep source=python/pyproject.toml min=2 -->
| 의존성 | 배포명 | 버전 |
|---|---|---|
| Admin + 인증 | `python-keycloak` | `>=7.1,<8` |
| JWT(강화 검증) | `joserfc` | `>=1.7,<2` |

dev(비앵커): `pytest`·`pytest-asyncio`·`pytest-cov`·`mypy`(strict)·`ruff`(보안 S/bandit 포함)·`testcontainers[keycloak]`. ⚠️ 버전 상수를 매니페스트와 중복하지 말 것 — `__version__`은 `importlib.metadata` 파생이다(경위: `.claude/rules/python.md`).

**Node 확정 의존성(package.json으로 고정)**:

<!-- doc-guard: kind=dep source=node/package.json min=3 -->
| 의존성 | 패키지 | 버전 |
|---|---|---|
| Admin | `@keycloak/keycloak-admin-client` | `~26.7.0` |
| 인증(OIDC/OAuth2) | `openid-client` | `^6` |
| JWT(강화 검증) | `jose` | `^6` |

dev(`devDependencies` — **앵커 있음**):

<!-- doc-guard: kind=dep source=node/package.json min=8 -->
| 의존성 | 좌표 | 버전 |
|---|---|---|
| 타입 | `typescript` | ^6 |
| 테스트 | `vitest` | ^3 |
| 커버리지 | `@vitest/coverage-v8` | ^3 |
| 통합 테스트 | `testcontainers` | ^12 |
| 린트 | `eslint` | ^10 |
| 린트(TS) | `typescript-eslint` | ^8 |
| 포맷 | `prettier` | ^3 |
| Node 타입 | `@types/node` | ^22 |

⚠️ vitest는 v4를 보류한다(`vi.mock` 시맨틱 변경). `@types/node`는 "최신 Node"가 아니라 `engines` 하한을 따라가므로 dependabot이 메이저를 못 올린다. 런타임 deps는 audit clean, devDeps 일부 moderate(`files:["dist"]`라 소비자에게 배포되지 않는다).

**Go 확정 의존성(go.mod, major 핀)**:

<!-- doc-guard: kind=dep source=go/go.mod min=5 -->
| 의존성 | 모듈 | 버전 |
|---|---|---|
| Admin | `github.com/Nerzal/gocloak/v13` | `v13.9.0` |
| 인증(OAuth2 흐름) | `golang.org/x/oauth2` | `v0.36.0` |
| JWT(강화 검증) | `github.com/go-jose/go-jose/v4` | `v4.1.4` |
| single-flight | `golang.org/x/sync` | `v0.22.0` |
| 통합 테스트 | `github.com/testcontainers/testcontainers-go` | `v0.44.0` |

전부 Apache-2.0/BSD-3/MIT(호환).

⚠️ **Go에는 dev-dependency 개념이 없다** — `// indirect`는 우리가 고른 것이 아니다(근거·실측: `.claude/rules/go.md`).

**C#/.NET 확정 의존성(csproj, major 핀)**:

<!-- doc-guard: kind=dep source=dotnet/src/Xzawed.Keycloak.Sdk/Xzawed.Keycloak.Sdk.csproj min=5 -->
| 의존성 | 좌표 | 버전 |
|---|---|---|
| 인증(OIDC/OAuth2) | `Duende.IdentityModel` | 8.1.0 |
| JWT(강화 검증) | `Microsoft.IdentityModel.JsonWebTokens` | 8.22.0 |
| JWT(JWKS/디스커버리) | `Microsoft.IdentityModel.Protocols.OpenIdConnect` | 8.22.0 |
| Admin | `Keycloak.AuthServices.Sdk` | 2.7.0 |
| DI 추상화 | `Microsoft.Extensions.DependencyInjection.Abstractions` | 9.0.19 |

dev(테스트 csproj — **앵커 있음**):

<!-- doc-guard: kind=dep source=dotnet/tests/Xzawed.Keycloak.Sdk.Tests/Xzawed.Keycloak.Sdk.Tests.csproj min=6 -->
| 의존성 | 좌표 | 버전 |
|---|---|---|
| 테스트 호스트 | `Microsoft.NET.Test.Sdk` | 18.9.0 |
| 단위 테스트 | `xunit` | 2.9.3 |
| 테스트 어댑터 | `xunit.runner.visualstudio` | 4.0.0 |
| 커버리지 수집 | `coverlet.collector` | 10.0.1 |
| HTTP 목 | `WireMock.Net` | 2.15.0 |
| 통합 테스트 | `Testcontainers.Keycloak` | 4.14.0 |

전부 Apache-2.0/MIT(호환).

**PHP 확정 의존성(composer.json, 정확 핀/범위 지정)**:

<!-- doc-guard: kind=dep source=php/composer.json min=6 -->
| 의존성 | 좌표 | 버전 |
|---|---|---|
| Admin | `fschmtt/keycloak-rest-api-client-php` | **0.42.0** |
| 인증(OAuth2) | `league/oauth2-client` | `^2.8` |
| 인증(OAuth2, Keycloak 프로바이더) | `stevenmaguire/oauth2-keycloak` | `^6.1` |
| JWT(강화 검증) | `firebase/php-jwt` | `^7.1` |
| HTTP(PSR-18) | `guzzlehttp/guzzle` | `^7.9` |
| HTTP(PSR-17) | `guzzlehttp/psr7` | `^2.7` |

| 의존성 | 좌표 | 버전 |
|---|---|---|
| 단위 테스트 | `phpunit/phpunit` 12 · `phpstan/phpstan` 2.2(+ strict-rules·phpunit 확장) · `friendsofphp/php-cs-fixer` 3.95 | — |
| 통합 테스트 | (docker CLI 셸아웃 — `testcontainers/testcontainers` ^1.0은 dev 의존이나 Windows native PHP 미지원으로 실사용 안 함) | — |

전부 MIT/BSD-3(Apache-2.0 호환).

**Rust 확정 의존성(Cargo.toml, 정확 핀 없음 — 크레이트별로 캐럿/틸드 + 커밋된 `Cargo.lock`)**:

<!-- doc-guard: kind=dep source=rust/Cargo.toml min=5 -->
| 의존성 | 크레이트 | 버전 |
|---|---|---|
| Admin | `keycloak`(`default-features = false`, features: `tags-all`·`resource-builder`·`reqwest12`) | `~26.6.2` |
| 인증(OIDC/OAuth2) | `openidconnect`(`default-features = false`, feature: `reqwest`) | `4.0.1` |
| JWT(강화 검증) | `jsonwebtoken`(`default-features = false`, features: `rust_crypto`·`use_pem`) | `11.0.0` |
| HTTP | `reqwest`(`default-features = false`, features: `json`·`rustls-tls`) | `0.12` |
| 비동기 런타임 | `tokio`(features: `rt-multi-thread`·`macros`·`time`·`sync`) | `1.52` |

<!-- doc-guard: kind=dep source=rust/Cargo.toml min=1 -->
| 의존성 | 크레이트 | 버전 |
|---|---|---|
| 오류/직렬화 | thiserror 2.0 · async-trait 0.1 · serde+serde_json 1 · url 2 | — |
| 단위 테스트 | wiremock 0.6(HTTP 목) · rsa 0.9+rand 0.8+base64 0.23(JWKS 공격 프로브 픽스처 생성) | — |
| 통합 테스트 | `testcontainers` — pre-1.0, base `GenericImage`(언어별 편의 모듈 없음) | `0.28.0` |

전부 Apache-2.0/MIT(호환). ⚠️ **셋 다 정확 핀(`=`)이 아니다** — `openidconnect`/`jsonwebtoken`은 캐럿, `keycloak`은 틸드 `~26.6.2`(버전이 semver가 아니라 Keycloak 서버 라인을 추종). 라이브러리에서 정확 핀이 왜 소비자 빌드를 하드 실패시키는지, 커밋된 `Cargo.lock`이 소비자에게 왜 닿지 않는지는 `.claude/rules/rust.md`.

**Ruby 확정 의존성(gemspec, 범위 지정)**:

<!-- doc-guard: kind=dep source=ruby/keycloak-sdk.gemspec min=3 -->
| 의존성 | gem | 버전 |
|---|---|---|
| 인증(OAuth2/OIDC) | `rack-oauth2`(nov) | `~> 2.3` |
| Admin | (성숙한 gem 부재 — faraday로 Admin REST 직접 래핑) | — |
| HTTP | `faraday` | `~> 2.0` |
| JWT(강화 검증) | `jwt`(ruby-jwt) | `~> 3.2` |
| 단위 테스트 | rspec 3 · webmock · simplecov · rubocop(+ rubocop-rspec) | — |
| 통합 테스트 | (docker CLI 셸아웃 — Windows native Ruby가 testcontainers-ruby 소켓 트랜스포트 미지원, PHP와 동일 패턴) | — |
| 의존성 감사 | bundler-audit | — |

전부 MIT(Apache-2.0 호환). ⚠️ admin gem 후보 3종(`looorent/keycloak-admin` 등)은 **공유 `TokenProvider` 주입 미지원**(§4 캐시 불변식 위반)으로 기각했다 — 그래서 `faraday` 직접 래핑이다(상세: `.claude/rules/ruby.md`).

**Kotlin 확정 의존성(build.gradle.kts, JVM 자매 Java SDK 스택 재사용 + 코루틴 경계 신규)**:

<!-- doc-guard: kind=dep source=kotlin/build.gradle.kts min=6 -->
| 의존성 | 좌표 | 버전 |
|---|---|---|
| Admin(재사용, api) | `org.keycloak:keycloak-admin-client` | 26.0.12 |
| 인증(재사용) | `com.nimbusds:oauth2-oidc-sdk` | 11.38.2 |
| JWT(재사용, 강화 검증) | `com.nimbusds:nimbus-jose-jwt` | 10.9.1 |
| 코루틴(신규, 공개 suspend 노출 → api) | `org.jetbrains.kotlinx:kotlinx-coroutines-core` | 1.11.0 |
| 통합 테스트 | `com.github.dasniko:testcontainers-keycloak` | 4.3.1 |
| Testcontainers | `org.testcontainers:testcontainers` (+ `-junit-jupiter`) | 2.0.5 |

| 의존성 | 좌표 | 버전 |
|---|---|---|
| 단위 테스트 | JUnit 6.1.3 · MockK 1.14.11 · WireMock 3.13.2 · `kotlinx-coroutines-test` 1.11.0 · `kotlin-test-junit5` 2.4.10 | — |
| 빌드/배포 플러그인 | Kotlin 2.4.10 · vanniktech `maven.publish` 0.37.0(Central Portal) · Kover 0.9.9 · ktlint gradle 14.2.0 · Dokka 2.2.0 | — |

전부 Apache-2.0/EPL-2.0(호환). Admin·인증·JWT 3좌표는 Java SDK가 실 Keycloak으로 이미 검증한 것과 동일해 **신규 라이브러리 리스크 0** — 차이는 코루틴 래핑뿐이다.

⚠️ 위 표의 `Kotlin 2.4.10`은 **빌드 툴체인(KGP) 버전**이지 소비자 하한이 아니다 — 게시 jar의 메타데이터는 `languageVersion`/`apiVersion`(=`KOTLIN_2_2`)이 정하므로 **소비자 하한은 2.2+**다(전이 `kotlin-stdlib`까지 함께 내려야 하는 이유는 `.claude/rules/kotlin.md`).

## 현재 상태

9개 언어 SDK 모두 `main` 병합 완료. **9개 언어 전부 정식 `1.0.0`이 공개 레지스트리에 게시됐다**(아래 표). ⚠️ **정렬은 우연이다 — 다시 갈리므로 함대 번호로 말하지 말 것**(근거: 1.0 기준(`git show d4e8958:docs/superpowers/plans/release-1.0.md`)). 배포는 전부 사람 승인 게이트다(사람이 태그를 민다).

⚠️ **Maven Central은 "워크플로 초록"과 "게시" 사이에 사람 클릭과 전파 지연이 둘 다 있다.** `release.yml`이 끝나도 Portal **스테이징**일 뿐이고, Publish 후에도 시차가 있다(실측: 첫 확인 404 → 3분 뒤 200, 검색 색인은 한참 뒤). **404로 "실패"를 결론내지 말 것** — 판정은 Portal 상태로 하고 repo1은 폴링한다. Kotlin도 같다.

| 언어 | 배포명 | 태그 접두 | 배포 |
|---|---|---|---|
| Java | `io.github.xzawed:keycloak-sdk` (Maven Central) | `v*` | 게시됨(`1.0.0`) |
| Python | `keycloak-sdk` (PyPI) | `py-v*` | 게시됨(`1.0.0`) |
| Node | `@xzawed/keycloak-sdk` (npm) | `node-v*` | 게시됨(`1.0.0`) |
| Go | `github.com/xzawed/KeyCloakSDK/go` (proxy.golang.org) | `go/v*` | 게시됨(`1.0.0`) |
| C#/.NET | `Xzawed.Keycloak.Sdk` (NuGet) | `dotnet-v*` | 게시됨(`1.0.0`) |
| PHP | `xzawed/keycloak-sdk` (Packagist) | `php-v*` | 게시됨(`1.0.0`) |
| Rust | `keycloak-sdk` (crates.io) | `rust-v*` | 게시됨(`1.0.0`) |
| Ruby | `keycloak-sdk` (RubyGems) | `ruby-v*` | 게시됨(`1.0.0`) |
| Kotlin | `io.github.xzawed:keycloak-sdk-kotlin` (Maven Central) | `kotlin-v*` | 게시됨(`1.0.0` · 하한 2.2+) |

**릴리스-레디니스 감사**(`main` 병합, PR #104)로 릴리스 워크플로 불변식(태그↔매니페스트 가드·시크릿 미설정 시 fail-closed·발행 전 E2E 게이트·액션 SHA 핀·`permissions` 최소화)과 패키징 표면(LICENSE·영문 README·레지스트리 메타데이터, Rust 캐럿 전환 + `Cargo.lock` 커밋 + `keycloak::types` 재노출)을 갖췄다. PHP 선행작업(미러·`PHP_SPLIT_TOKEN`·Packagist 등록)도 끝났다.

구현 경위: [CHANGELOG.md](CHANGELOG.md) · 배포 절차: [DEPLOY.md](DEPLOY.md) · **`docs/` 전체 지도(각 문서에만 있는 것까지): [docs/README.md](docs/README.md)**

## 문서 규칙

**문서는 워크플로우와 프로세스 기준으로 쓴다** — "지금 이 코드에서 무엇을 어떤 순서로 하는가". 사고 이력·설계 경위는 문서의 축이 아니다(그렇게 쓰면 규칙 하나마다 문단이 하나씩 늘어난다). 그 위에 **어디에 무엇을 적는가**가 온다.

| 무엇 | 어디 | 형태 |
|---|---|---|
| 언어별 명령·제약·게차 | `.claude/rules/<lang>.md` | 그 언어 경로에서 자동 로드 |
| 교차언어 계약·제약 | 이 파일 | 경로와 무관하게 상주 |
| 단계·WBS·역할·게이트·기각 체크리스트 | [작업 프로세스](docs/governance/process.md) | 절차 |
| 소비자용 사용법 | [`docs/guides/`](docs/guides/) · 각 언어 README | **영문** |
| 왜 그렇게 됐는가 | git log · [CHANGELOG.md](CHANGELOG.md) | **문서로 옮기지 않는다** |

⚠️ **규칙은 한 줄로 쓴다.** 근거가 필요하면 한 절까지고, 재현 로그·PR 번호·측정표는 커밋 메시지에 남긴다 — 문서에 쌓으면 규칙 하나마다 문단 하나씩 늘어난다.

⚠️ **같은 사실을 두 곳에 적지 않는다.** 버전·좌표의 SSOT는 매니페스트와 `scripts/lib/deploy-facts.sh`이고, 문서는 거기서 파생하거나 `<!-- doc-guard: ... -->` 앵커로 대조된다. 앵커·표를 늘리면 `.github/workflows/repo-hygiene.yml`의 `--min-facts`/`--min-anchors`도 함께 올린다.

⚠️ **`doc-budget` 래칫이 올라가는 경우는 둘뿐이다** — (1) 증가분이 **검증 가능성**을 사 올 때(기계 검증, 또는 그 주장을 **다시 재는 명령**), (2) **사람이 이 문서의 역할을 바꿀 때**. 판정을 앵커 주석에 `옛값 → 새값` 으로 적고, (1)은 **같은 커밋이 거짓 문장을 지워야** 한다(추가가 아니라 교환). **+300B 초과는 사람 판정** — `check-docs.mjs` 검사 8b 가 `main` 과 대조해 강제한다. 목표 바이트 수는 없다. 그 밖의 산문 추가는 교환이 아니므로 줄이거나 블록 주석으로 남긴다(주입되지 않아 계상되지 않는다).

⚠️ **압축이 판정 방법을 지우면 그건 교환이 아니라 손실이다 — 그때는 줄이지 말고 (2)로 올린다.** 예산이 0인 문서에서 정확성 수정을 밀어 넣으려다 문장을 깎으면, 남는 것은 결론뿐이고 **그 결론에 이르는 명령이 사라진다**(실례: `sonar.tests` 되살릴 조건이 「487 상수 아님」만 남아 무엇을 어떻게 재는지가 지워졌다). 압축 전에 묻는다 — **다음 세션이 이 문장만 읽고 판정을 재현할 수 있는가.**

### 언어

- **README는 루트만 영한 미러**([`README.md`](README.md) ↔ [`README.ko.md`](README.ko.md), 동일 구조). 언어별 `<lang>/README.md`는 영문 단일이다.
- **소비자 문서는 영문**([`docs/guides/`](docs/guides/)·[`CONTRIBUTING.md`](CONTRIBUTING.md)·[`DEPLOY.md`](DEPLOY.md)·`harness/`), **내부 문서는 한글**([`docs/governance/`](docs/governance/)·이 파일).
- ⚠️ **`.claude/rules/*.md`만 예외로 영문**(2026-08-18 판정) — 청중이 둘이다. 에이전트가 경로로 자동로드하고, 영문 문서 둘이 **인간 기여자**를 그리로 보낸다. 한글이면 빌드 명령을 영문 쪽에 복제할 수밖에 없다(실측 4곳·드리프트 3건).
- 9개 중 9개가 정식 게시(번호는 언어별로 갈린다)이나 **라이브 레지스트리 배지는 여전히 금지** — 배지는 아홉 레지스트리를 실시간으로 물어 문서가 SSOT를 우회하게 만든다(버전 문자열의 SSOT는 `deploy-facts.sh`다).
- ⚠️ 영문 문서 헤딩을 바꾸면 `#anchor`가 바뀐다. `getting-started.md`의 `## C# / .NET`(앵커 `#c--net`)은 양쪽 README가 링크한다.
