---
paths:
  - "kotlin/**"
  - "harness/apps/kotlin/**"
  - "harness/install/consume/kotlin*"
  - "harness/install/consume/kotlin-app/**"
  - ".github/workflows/kotlin-*.yml"
---

# Kotlin 규칙

## 툴체인

JDK 21 + 포터블 Gradle `9.5.0`(래퍼도 동일). 명령은 `gradle -p kotlin <task>`.

```bash
export JAVA_HOME="${KCSDK_JDK21:-/c/Program Files/Eclipse Adoptium/jdk-21.0.11.10-hotspot}" \
       PATH="${KCSDK_TOOLS:-$HOME/tools}/gradle-9.5.0/bin:$PATH"
gradle -p kotlin build
gradle -p kotlin test                # 단위. Docker 불필요
gradle -p kotlin integrationTest     # 통합 E2E 1개. Docker 필요(Testcontainers, KC 26.6)
gradle -p kotlin koverVerify         # 커버리지 라인≥90/브랜치≥85, 네트워크 경계 omit
gradle -p kotlin ktlintCheck         # 수정은 ktlintFormat
gradle -p kotlin publishToMavenLocal # 배포 빌드 로컬 검증
```

- 단일 테스트: `gradle -p kotlin test --tests "*<ClassName>"`
- 좌표 `io.github.xzawed:keycloak-sdk-kotlin`. KGP 2.4.10 · `jvmToolchain(21)` · `languageVersion`/`apiVersion` = `KOTLIN_2_2`(소비자 하한) · `explicitApi()`.
- 배포는 `kotlin-v*` 태그 → `kotlin-release.yml`(Central Portal 스테이징) → 사람이 Portal에서 release. 핀은 루트 `CLAUDE.md` 의존성 표가 SSOT(doc-guard 앵커가 `build.gradle.kts`와 대조 — 여기 숫자를 쓰지 않는다).
- 커버리지 실측 라인 99.24%/브랜치 85.71%. ⚠️ `koverVerify`는 백분율을 출력하지 않아 CI 로그로 대조할 수 없다 — 확인하려면 `koverHtmlReport`.

## 빌드·테스트 제약

- ⚠️ **`gradle --stop`을 빌드 중에 실행하지 않는다.** `--no-daemon`도 데몬을 fork하므로 진행 중 빌드가 죽고 테스트 실패로 오인된다. 같은 프로젝트에 gradle 2개 동시 실행도 금지(락 경합). 복구는 `gradle -p kotlin clean`.
- ⚠️ **MockK로 JAX-RS 추상클래스(`Response`·`WebApplicationException`)를 모킹하면 JDK21에서 무기한 hang한다.** byte-buddy가 RESTEasy 클래스그래프를 계측하다 멈춘다. 실객체를 쓴다 — `WebApplicationException(msg, status)` · `Response.status(500).entity("body").build()` · 익명 서브클래스. **인터페이스**(`UsersResource` 등) 모킹은 안전하다.
- ⚠️ **코루틴 스택트레이스 복구는 예외 identity를 보존하지 않는다.** suspend 경계를 넘은 예외는 새 인스턴스다 — `assertSame` 대신 `assertIs<T>` + message 비교.
- ⚠️ **`= runBlocking { … }` 표현식 본문 `@Test`는 Jupiter가 발견하지 못한다.** 마지막 식이 non-Unit이면 메서드가 non-void가 된다 — `: Unit`을 명시한다.
- ⚠️ **`integrationTest`는 Gradle `jvm-test-suite`로 만든다.** 수동 `creating` 소스셋은 Kotlin 컴파일 출력이 `output.classesDirs`에 등록되지 않아 "no tests discovered"가 된다. 의존성은 `kotlin("test")`가 아니라 **`kotlin-test-junit5`**.
- ⚠️ **Kover 0.9.x 두 가지**: (1) 와일드카드 없는 정확 클래스명 exclude를 무시한다 — 네트워크 경계는 `AuthClient*`처럼 `*` 접미로 지정해야 top-level 함수 클래스(`…Kt`)까지 빠진다. (2) `integrationTest`를 자동 계측 대상에 넣어 Docker 없는 단위 CI를 파손한다 — `instrumentation.disabledForTestTasks.add("integrationTest")`와 `sources.excludedSourceSets.add("integrationTest")` **둘 다** 필요하다.
- ktlint의 다중선언 파일명 규칙은 이 모노레포의 소문자 관용(`errors.kt` 등)과 충돌해 `kotlin/.editorconfig`에서 `ktlint_standard_filename = disabled`.

## 게시 제약

- ⚠️ **Gradle 래퍼는 KGP의 완전지원 밴드 안에 둔다**(KGP 2.4.10 → 7.6.3–9.5.0). 밴드 밖이 곧 고장은 아니지만 이 저장소의 정책이다. 래퍼만 올리지 말고 **KGP·`kgp-gradle-band` 기록·래퍼·`build.gradle.kts` 1행 미러 주석을 한 커밋에서 함께** 옮긴다 — `scripts/check-versions.mjs`가 넷의 정합을 강제한다. dependabot은 래퍼를 단독 PR로 올린다(`exclude-patterns`).
- ⚠️ **게시 jar의 바이너리 메타데이터 버전은 KGP가 아니라 `languageVersion`/`apiVersion`이 정한다.** 설정 없이 KGP 2.4.10으로 빌드하면 `mv=[2,4,0]`이 박혀 **Kotlin 2.4 미만 소비자가 라이브러리를 아예 쓸 수 없다.**
  - ⚠️ **전이 `kotlin-stdlib`도 함께 내려야 한다.** 클래스 메타데이터만 낮추면 소비자는 여전히 stdlib 2.4.10을 해석해 `Class 'kotlin.Unit' was compiled with an incompatible version of Kotlin`으로 실패한다. `gradle.properties`에 `kotlin.stdlib.default.dependency=false` + `api("org.jetbrains.kotlin:kotlin-stdlib:<하한>")` 명시. **`constraints`로는 낮출 수 없다**(제약은 하한이라 자동주입이 이긴다).
  - 확인: `publishToMavenLocal` 후 POM의 stdlib 버전을 보고, `harness/apps/kotlin`(Kotlin 2.2.20 + `mavenLocal()`)에서 `./gradlew classes`가 통과하는지 본다. 메타데이터 자체는 `javap -v`로 `kotlin/Metadata`의 `mv` 배열을 읽는다(상수 풀 grep은 중복 제거 때문에 판별 불가).
  - **하한을 올리면 그만큼 소비자를 잘라내는 것이므로 릴리스 노트에 명시한다.**
- ⚠️ **릴리스 시크릿 4개(`MAVEN_CENTRAL_USERNAME`/`_PASSWORD`·`SIGNING_IN_MEMORY_KEY`/`_PASSWORD`)는 하나라도 없으면 실패시킨다.** 스킵하면 서명 없는 아티팩트가 green 실행에서 Portal로 올라간다. job-level `if:`는 secrets를 읽지 못하므로 가드는 **스텝 안에서 env-매핑된 값**으로 한다.

## SDK 동작 (Java와 동형)

- `exchangeCode`는 id_token을 **nonce 비교 전에** 완전 검증한다(서명·iss·aud·exp).
- admin 파사드는 auth를 알지 못한다 — `KeycloakBuilder` 내장 client-credentials로 토큰을 자체 소유한다(§4).
- `fun interface` + `suspend`는 컴파일된다(KT-40978 해소) — `TokenProvider`가 SAM 변환 가능하다.
- ⚠️ **`jwksMinRefetch`는 Nimbus 캐시 TTL(기본 5분) 미만이어야 한다.** 넘으면 `JWKSourceBuilder.build()`가 던지고, 그 foreign 예외가 공개 API로 새면 §4 위반이다 — 경계에서 `KeycloakConfigException`으로 변환한다. ⚠️ **JWKS rate-limit 테스트에는 대조군(간격 0 또는 검증기 재생성)을 반드시 둔다** — 캐시만으로도 통과해 하드닝 한 줄을 지워도 초록이 된다.
- ⚠️ **`resteasyClient(...)` 주입은 admin-client의 `JacksonProvider` 등록을 우회한다** — `NON_NULL`과 `FAIL_ON_UNKNOWN_PROPERTIES=false`를 함께 잃어 버전 스큐에서 양방향으로 깨진다. `buildTimeoutClient`가 `JacksonProvider`와 `StreamMessageBodyReader`를 직접 등록한다. `ClientBuilder.newBuilder()`를 유지할 것(`createClientBuilder()`는 커넥션풀을 50→10으로 줄인다). **동작 계약**: NON_NULL이 켜지면 부분 업데이트에서 null로 필드를 비울 수 없다(공식 admin-client와 동일) — 비우려면 빈 문자열이나 전용 API를 쓴다.
