---
paths:
  - "kotlin/**"
  - "harness/apps/kotlin/**"
  - "harness/install/consume/kotlin*"
  - "harness/install/consume/kotlin-app/**"
  - ".github/workflows/kotlin-*.yml"
---

# Kotlin 규칙

## 툴체인 (빌드 명령)

Kotlin은 JDK 21(Eclipse Temurin `jdk-21.0.8.9-hotspot`) + 포터블 Gradle `9.6.1`(로컬 실행용)을 사용한다(래퍼도 동일하게 `9.6.1` — `kotlin/gradle/wrapper/gradle-wrapper.properties`). 프리픽스를 인라인 지정하고 명령은 `gradle -p kotlin <task>`(또는 `kotlin/`에서 `./gradlew`)로 실행한다:
```bash
export JAVA_HOME="${KCSDK_JDK21:-/c/Program Files/Eclipse Adoptium/jdk-21.0.8.9-hotspot}" PATH="${KCSDK_TOOLS:-$HOME/tools}/gradle-9.6.1/bin:$PATH" GRADLE_USER_HOME="${GRADLE_USER_HOME:-$HOME/.gradle}"
gradle -p kotlin build              # 빌드
gradle -p kotlin test               # 단위테스트 100개. Docker 불필요
gradle -p kotlin integrationTest    # 통합 E2E 1개(Docker 필요 — Testcontainers/dasniko, 실제 Keycloak 26.6)
gradle -p kotlin koverVerify        # 커버리지 게이트(로직 모듈 라인≥90%/브랜치≥85%, 네트워크 경계 omit)
gradle -p kotlin ktlintCheck        # 린트(무경고; 수정은 ktlintFormat)
```
> 다른 PC에서는 `KCSDK_TOOLS`(포터블 툴 상위 디렉터리, 기본 `$HOME/tools`)·`KCSDK_JDK21`(JDK 21+ 경로)를 덮어쓰거나, 이미 PATH에 있으면 프리픽스를 생략한다. 설치·진단은 [development-setup.md](../../docs/guides/development-setup.md)(`node scripts/doctor.mjs kotlin`).
- 단일 테스트: `gradle -p kotlin test --tests "*<ClassName>"`
- 커버리지 게이트(Kover, 네트워크 경계 omit): `gradle -p kotlin koverVerify` — **실측 라인 99.24%/브랜치 85.71%**(omit 대상 `AuthClient*`/`admin.*`/`KeycloakClient*` — 통합 E2E로 검증). 상세는 [verification-log-kotlin.md](../../docs/governance/verification-log-kotlin.md) 참고
- 로컬 배포 빌드 검증(업로드 없이): `gradle -p kotlin publishToMavenLocal` → 로컬 `~/.m2`에 `keycloak-sdk-kotlin-0.1.0.jar`(+`-sources.jar`/`-javadoc.jar`, Dokka) 생성 확인
- 실제 Maven Central 배포는 로컬에서 실행하지 않는다 — `kotlin-v*` 태그 push 시 `.github/workflows/kotlin-release.yml`에서 vanniktech maven.publish로 `publishToMavenCentral`(Central Portal 스테이징) 실행(`ORG_GRADLE_PROJECT_` 접두 in-memory GPG 시크릿) 후, 사람이 Portal 콘솔에서 수동 release하는 2단계 승인 게이트(human-gated, 미실행). `publish` 잡은 `verify`+별도 `integration` 잡(FullFlowIT)을 `needs:`로 요구하고, 첫 스텝에서 태그↔`build.gradle.kts` `version` 정합성을 검사하며(추출 실패도 실패), **4개 시크릿(`MAVEN_CENTRAL_USERNAME`/`_PASSWORD`·`SIGNING_IN_MEMORY_KEY`/`_PASSWORD`) 중 하나라도 없으면 건너뛰지 않고 실패한다**(아래 게차)
- 좌표 `io.github.xzawed:keycloak-sdk-kotlin`. 빌드 KGP 2.4.10 · JDK 21 타깃(`jvmToolchain(21)`) · **`compilerOptions.languageVersion`/`apiVersion` = `KOTLIN_2_2`(소비자 Kotlin 하한 2.2+ — 아래 게차)** · `explicitApi()`로 public API 가시성 엄격 강제 — 소비자 측 코틀린 API 문서화 요구가 컴파일 타임에 강제됨
- ⚠️ **`gradle --stop`을 빌드 인플라이트 중 실행 금지** — `--no-daemon`도 jvmargs 때문에 단일-사용 데몬을 fork하므로 진행 중 빌드를 죽인다(동일 프로젝트에 gradle 2개 동시 실행도 락 경합으로 금지). kill 후 stale 빌드 상태는 `gradle -p kotlin clean`으로 복구
- ⚠️ ktlint의 소문자 다중선언 파일명(`errors.kt`/`masking.kt`/`tokens.kt`/`client.kt` 등, 모노레포 공통 관용) 규칙은 `kotlin/.editorconfig`의 `ktlint_standard_filename = disabled`로 비활성 — 커밋 전 `ktlintFormat`으로 나머지 포매팅 자동정렬

## 게차

- ⚠️ **(Kotlin) `fun interface`+`suspend`는 컴파일된다(KT-40978 해소)** — 2.2.20에서 실증, 2.4.10에서도 유효. `TokenProvider`를 SAM 변환가능 함수형 인터페이스로 선언.
- ⚠️ **(Kotlin) ktlint filename 규칙(다중선언 파일 PascalCase)은 이 모노레포와 충돌** — 소문자 공통파일(`errors.kt` 등) 자동수정 불가 → `ktlint_standard_filename = disabled`로 비활성. 나머지는 `ktlintFormat`(커밋전)+`ktlintCheck` 게이트. 근거: `kotlin/.editorconfig`.
- ⚠️ **(Kotlin) `gradle --stop`을 빌드 인플라이트 중 실행 금지** — `--no-daemon`도 jvmargs로 단일사용 데몬 fork해 `--stop`이 죽임(테스트실패로 오인). 동일 프로젝트 gradle 2개 동시실행도 금지(락 경합). kill 후 stale은 `gradle -p kotlin clean`으로 복구.
- ⚠️ **(Kotlin) MockK로 JAX-RS 추상클래스(`Response`·`WebApplicationException`)를 모킹하면 JDK21에서 무기한 hang한다** — byte-buddy가 RESTEasy 구현 클래스그래프를 계측하다 멈춤(단일테스트도 2.5분 타임아웃 실측, "non-final이라 안전"은 오판). `AdminBoundaryTest`는 실객체로 재작성: `WebApplicationException(msg,status)`·`Response.status(500).entity("body").build()`·익명서브클래스(`getResponse()=null`). **인터페이스**(`UsersResource` 등)는 MockK 프록시가 가벼워 안전.
- ⚠️ **(Kotlin) 코루틴 스택트레이스 복구는 예외 identity를 보존 안 함** — suspend 경계를 넘는 예외는 새 인스턴스로 복사되므로 `assertSame` 대신 `assertIs<T>`+message 비교.
- ⚠️ **(Kotlin) Kover 0.9.x는 와일드카드 없는 정확 클래스명 exclude를 무시한다** — `"AuthClient"` 정확명은 무시되고 브랜치집계에 섞임 → 네트워크경계 클래스는 전부 `*` 접미(`AuthClient*` 등)로 지정해야 top-level 함수클래스(`…Kt`)까지 제외.
- ⚠️ **(Kotlin) jvm-test-suite 없이 수동 `creating` 소스셋으로 `integrationTest`를 만들면 "no tests discovered"** — Kotlin 컴파일출력이 `output.classesDirs`에 미등록. Gradle 표준 `jvm-test-suite`로 전환 필요, `dependencies`엔 `kotlin("test")` 대신 **`kotlin-test-junit5`** 명시(plain은 assertions만).
- ⚠️ **(Kotlin) `= runBlocking {…}` 표현식-본문 `@Test`는 Jupiter가 발견 못 함** — 블록 마지막식이 non-Unit이면 메서드가 non-void가 됨 → `: Unit` 반환타입 명시 필요.
- ⚠️ **(Kotlin) Kover 0.9.x는 jvm-test-suite `integrationTest`를 자동 계측대상에 포함** — `FullFlowIT` 미실행 시 0%로 총계 붕괴 + `koverVerify`가 Docker없는 단위CI를 파손 → `instrumentation.disabledForTestTasks.add("integrationTest")`+`sources.excludedSourceSets.add("integrationTest")` 둘 다 필요.
- ⚠️ **(Kotlin) exchangeCode는 id_token을 nonce 비교 전에 완전 서명검증한다(Java보다 강함)** — `JwtValidator`로 서명검증 먼저, nonce는 그 다음(Java는 nonce 파스온리였음).
- ⚠️ **(Kotlin) admin 파사드는 auth를 직접 알지 못한다(§4·Java 동형)** — `AdminClient`가 `KeycloakBuilder` 내장 client-credentials로 토큰 자체소유(TokenManager 자동 획득/갱신) — Java가 RESTEasy 필터충돌로 내린 결정을 상속.
- ⚠️ **(Kotlin) 로컬 포터블 Gradle과 CI 래퍼 버전을 일치시켜 둔다(현재 둘다 9.6.1)** — 어긋나면 로컬에서 재현 안 되는 CI실패 발생. KGP 상향 시 Gradle 지원밴드 확인(현재 KGP 2.4.10).
- ⚠️ **(Kotlin) 신규 라이브러리 리스크 0** — Java SDK가 실Keycloak으로 이미 검증한 3개(admin-client 26.0.11·oauth2-oidc-sdk 11.38.2·nimbus-jose-jwt 10.9.1)를 그대로 재사용, Java의 게차를 코루틴 경계만 다르게 상속.
- ⚠️ **(Kotlin) 게시 아티팩트의 바이너리 메타데이터 버전(`@Metadata(mv=…)`)은 KGP 버전이 아니라 `languageVersion`/`apiVersion`이 정한다** — 설정 없이 KGP 2.4.10으로 빌드하면 jar에 `mv=[2,4,0]`이 박히고, **Kotlin 2.4 미만 컴파일러는 그 클래스를 "compiled with an incompatible version of Kotlin"으로 거부해 소비자가 라이브러리를 아예 쓸 수 없다**(하네스 install 잡의 소비자앱이 Kotlin 2.2.20이라 7일 연속 RED였던 실제 원인). `kotlin { compilerOptions { languageVersion/apiVersion = KotlinVersion.KOTLIN_2_2 } }`를 넣으면 `mv=[2,2,0]`이 방출된다(`KOTLIN_2_0`도 `mv=[2,0,0]`으로 동작하나 KGP 2.4.10이 "Language version 2.0 is deprecated"를 경고하므로 2.2를 선택 — 이 설정으로 `test`+`ktlintCheck` BUILD SUCCESSFUL 확인). **하한을 올리면 그만큼 소비자를 잘라내는 것이므로 릴리스 노트에 명시할 것.**
  - **측정 방법**: jar를 풀고(`unzip`) 클래스 하나를 `javap -v`로 덤프해 `kotlin/Metadata` 애노테이션의 `mv` 배열을 읽는다. ⚠️ **상수 풀(raw constant pool)만 grep하는 것으로는 판별할 수 없다** — 풀 엔트리가 중복 제거되어 `[2,2,0]`과 `[2,0,0]`이 동일하게 보인다. 반드시 애노테이션의 element 참조를 읽어야 한다.
- ⚠️ **(Kotlin) 릴리스 시크릿 4개는 전부 있어야 하고, 하나라도 없으면 업로드를 건너뛰는 게 아니라 실패해야 한다** — 이전에는 `MAVEN_CENTRAL_USERNAME` 하나만 검사하고 `exit 0`으로 스킵해서, **서명키(`SIGNING_IN_MEMORY_KEY`) 없이도 green 실행에서 서명 없는 아티팩트가 Central Portal로 올라갈 수 있었다**. 지금은 누락된 이름을 전부 나열하고 `::error::`+`exit 1`. ⚠️ job-level `if:`는 secrets 컨텍스트를 읽지 못하므로(github/needs/vars/inputs만) 가드는 스텝 안에서 env-매핑된 값으로 해야 한다.
