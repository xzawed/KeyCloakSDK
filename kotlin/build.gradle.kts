// gradle/wrapper: 9.5.0
// kgp-gradle-band: kgp=2.4.10 gradle=7.6.3-9.5.0
//   ⚠️ 이 줄은 주석이 아니라 **검사되는 선언**이다(scripts/check-versions.mjs). kotlinlang.org의
//   KGP↔Gradle 완전지원 밴드를 그 KGP 버전과 **묶어서** 기록한다 — `kgp=`가 아래 `kotlin("jvm")`과
//   어긋나면 가드가 실패하므로, KGP를 올리는 사람은 밴드를 반드시 다시 확인하게 된다(밴드 값은
//   외부 데이터라 CI가 가져올 수 없고, 하드코딩한 상수는 KGP에 묶이지 않으면 조용히 낡는다).
//   근거·되살릴 조건: .claude/rules/kotlin.md
// settings.gradle.kts: plugins { id("org.gradle.toolchains.foojay-resolver-convention") version "1.0.0" }

plugins {
    kotlin("jvm") version "2.4.10"
    `java-library`
    id("org.jetbrains.dokka") version "2.2.0"
    id("com.vanniktech.maven.publish") version "0.37.0"
    id("org.jetbrains.kotlinx.kover") version "0.9.9"
    id("org.jlleitschuh.gradle.ktlint") version "14.2.0"
}

group = "io.github.xzawed"
version = "0.1.0-RC1"

repositories {
    mavenCentral()
}

kotlin {
    jvmToolchain(21)
    explicitApi() // JDK21 + public API 엄격

    // ⚠️ 소비자 Kotlin 하한선 — 게시 아티팩트의 바이너리 메타데이터 버전을 결정한다.
    // KGP 2.4.10로 그냥 빌드하면 @Metadata(mv=[2,4,…])가 박혀 **Kotlin 2.4 미만 소비자는
    // "compiled with an incompatible version of Kotlin"으로 컴파일 자체가 불가능**하다
    // (하네스 install 소비자앱이 2.2.20이라 7일 연속 CI RED였던 실제 원인).
    // languageVersion/apiVersion을 내리면 그만큼 낮은 mv가 방출돼 더 넓은 소비자가 쓸 수 있다
    // (컨테이너 실측: 미설정 → mv=[2,4], KOTLIN_2_0 → mv=[2,0], 둘 다 test+ktlintCheck BUILD SUCCESSFUL).
    // 2.0이 아니라 2.2를 고른 이유: KGP 2.4.10이 "Language version 2.0 is deprecated ... Update the
    // version to 2.2"를 경고한다 — 신규 라이브러리를 폐기예정 버전에 묶으면 다음 KGP 상향에서 빌드가 깨진다.
    // 2.2는 경고 없이 지원되며 하네스 install 소비자앱(2.2.20)도 충족한다.
    // ⚠️ 이 하한을 올리면 그만큼 소비자를 잘라내는 것이므로 릴리스 노트에 반드시 명시할 것.
    compilerOptions {
        languageVersion.set(org.jetbrains.kotlin.gradle.dsl.KotlinVersion.KOTLIN_2_2)
        apiVersion.set(org.jetbrains.kotlin.gradle.dsl.KotlinVersion.KOTLIN_2_2)
    }
}

// 🔒 Jackson 보안 핀 — java/pom.xml의 dependencyManagement와 동일한 불변식을 Kotlin에도 건다.
// keycloak-admin-client 26.0.11은 Jackson 2.21.2를 끌어오는데, Java SDK는 CVE 대응으로 그 계열을
// 2.22.1로 올려두었다(CVE-2026-54512~54518 6건 + CVE-2026-54515 — 취약범위 <2.21.5). Kotlin은 같은
// admin-client를 재사용하면서 이 핀만 미러링하지 않아, runtimeClasspath가 취약한 2.21.2로 해석되고
// 있었다(kotlin-ci.yml의 OSV `dependency-audit` 잡이 실측으로 검출). 전이 의존성이라 `implementation`
// 선언이 아니라 constraints로 하한을 걸어야 admin-client의 관리값을 이긴다.
// ⚠️ java/pom.xml의 Jackson 버전을 올릴 때는 여기도 함께 올린다 — 두 JVM SDK가 같은 트리를 쓴다.
dependencies {
    constraints {
        implementation("com.fasterxml.jackson.core:jackson-core:2.22.1")
        implementation("com.fasterxml.jackson.core:jackson-databind:2.22.1")
        implementation("com.fasterxml.jackson.core:jackson-annotations:2.22") // 별도 버전 트랙
        implementation("com.fasterxml.jackson.datatype:jackson-datatype-jdk8:2.22.1")
        implementation("com.fasterxml.jackson.datatype:jackson-datatype-jsr310:2.22.1")
        implementation("com.fasterxml.jackson.jakarta.rs:jackson-jakarta-rs-base:2.22.1")
        implementation("com.fasterxml.jackson.module:jackson-module-jakarta-xmlbind-annotations:2.22.1")
    }

    // stdlib는 KGP 자동주입을 끄고(gradle.properties `kotlin.stdlib.default.dependency=false`)
    // 소비자 하한(= compilerOptions의 languageVersion/apiVersion)에 맞춰 직접 선언한다.
    // ⚠️ 이 버전은 위 KOTLIN_2_2와 함께 움직여야 한다 — 하나만 올리면 소비자 하한이 조용히 갈라진다.
    api("org.jetbrains.kotlin:kotlin-stdlib:2.2.21")
    api("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.11.0") // 공개 suspend → api
    api("org.keycloak:keycloak-admin-client:26.0.12") // representation 노출 → api
    implementation("com.nimbusds:oauth2-oidc-sdk:11.38.2")
    implementation("com.nimbusds:nimbus-jose-jwt:10.9.1")

    testImplementation(kotlin("test"))
    testImplementation(platform("org.junit:junit-bom:6.1.3"))
    testImplementation("org.junit.jupiter:junit-jupiter")
    testRuntimeOnly("org.junit.platform:junit-platform-launcher")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.11.0")
    testImplementation("io.mockk:mockk:1.14.11")
    testImplementation("org.wiremock:wiremock:3.13.2")
    testImplementation("org.testcontainers:testcontainers:2.0.5")
    testImplementation("org.testcontainers:testcontainers-junit-jupiter:2.0.5")
    testImplementation("com.github.dasniko:testcontainers-keycloak:4.3.1")
}

tasks.test {
    useJUnitPlatform()
}

// Apache-2.0 §4(a): 배포되는 아카이브가 라이선스 전문을 담아야 한다. `kotlin/LICENSE`는 이미 저장소에
// 있다(루트 LICENSE와 동일 blob, 다른 8개 언어 디렉터리와 같은 관용)이므로 새 사본을 만들지 않는다.
// Central에 올라가는 아카이브는 main jar 하나가 아니라 `-sources`·`-javadoc`까지 셋이므로 `tasks.jar`
// 하나만 거는 것으로는 부족하다.
//
// ⚠️ 타입을 `org.gradle.jvm.tasks.Jar`로 **명시**해야 한다 — Kotlin DSL에서 그냥 `withType<Jar>()`라고
// 쓰면 기본 import인 `org.gradle.api.tasks.bundling.Jar`로 해석되는데, 이것은 `jvm.tasks.Jar`의
// **하위** 클래스다. vanniktech가 등록하는 `dokkaJavadocJar`(타입
// `com.vanniktech.maven.publish.tasks.JavadocJar`)는 상위 클래스인 `jvm.tasks.Jar`만 상속하므로
// 좁은 쪽으로 걸면 javadoc jar만 조용히 빠진다(실측: 좁은 타입 → main·sources에는 들어가고 javadoc은
// 누락, 넓은 타입 → 셋 다 포함). 실패가 눈에 띄지 않는 종류라 회귀 시 알아채기 어렵다.
//
// 참고: Java SDK의 `-javadoc.jar`에는 LICENSE가 없다(maven-javadoc-plugin이 리소스를 포함하지 않음).
// 두 JVM SDK가 여기서만 어긋나는데, 덜 담는 쪽에 맞추기보다 더 담는 쪽이 §4(a)에 부합해 이대로 둔다.
tasks.withType<org.gradle.jvm.tasks.Jar>().configureEach {
    from(layout.projectDirectory.file("LICENSE")) {
        into("META-INF")
    }
}

// integrationTest = 별도 스위트·태스크(T10) — 단위 `test`는 Docker-free로 유지하고, 실 Keycloak
// Testcontainers E2E(FullFlowIT)만 이 스위트로 분리한다. `check`(→koverVerify)에는 의존시키지 않는다 —
// integrationTest는 Docker가 필요해 로컬/CI의 매 빌드마다 강제로 돌리면 부적합하다(Kotlin WBS Task 11의
// 별도 CI 잡에서 명시 실행). Kover는 `test` 태스크만 계측하므로(기본 동작) integrationTest는 커버리지
// 집계에 섞이지 않는다.
//
// ⚠️ 수동 `creating` 소스셋 + `compileClasspath +=`/`runtimeClasspath +=` 오버라이드는 Kotlin 컴파일
// 출력을 소스셋 `output.classesDirs`에 등록하지 못해 Test 태스크가 "no tests discovered"로 실패한다
// (실측: FullFlowIT.class는 build/classes/kotlin/integrationTest에 컴파일되나 testClassesDirs에 안 잡힘).
// jvm-test-suite는 소스셋·Kotlin 컴파일·Test 태스크·JUnit Platform·resources를 Gradle이 정합 배선한다.
@Suppress("UnstableApiUsage")
testing {
    suites {
        val integrationTest by registering(JvmTestSuite::class) {
            useJUnitJupiter("6.1.1")
            dependencies {
                implementation(project())
                // 스위트 dependencies 블록엔 kotlin("test") 헬퍼가 없어 좌표를 명시한다(플러그인 kotlin 버전과 일치).
                // `kotlin.test.Test` typealias(→org.junit.jupiter.api.Test)는 plain kotlin-test가 아니라
                // kotlin-test-junit5 변형이 제공한다 — 단위 test는 Kotlin 플러그인의 variant-aware 해석이 이를
                // 자동 선택하나 jvm-test-suite 구성엔 그 해석이 없어 junit5 변형을 직접 지정한다(assertions 포함).
                implementation("org.jetbrains.kotlin:kotlin-test-junit5:2.4.10")
                implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.11.0")
                implementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.11.0")
                implementation("org.testcontainers:testcontainers:2.0.5")
                implementation("org.testcontainers:testcontainers-junit-jupiter:2.0.5")
                implementation("com.github.dasniko:testcontainers-keycloak:4.3.1")
            }
            targets {
                all {
                    testTask.configure {
                        description = "Runs integration tests (Testcontainers, real Keycloak)."
                        shouldRunAfter(tasks.test)
                    }
                }
            }
        }
    }
}

// Kover 0.9.x DSL — 네트워크 경계(AuthClient/admin.*/KeycloakClient) omit, 라인90%/브랜치85% 게이트.
kover {
    // ⚠️ jvm-test-suite로 등록된 integrationTest는 Kover 0.9.x가 자동으로 계측 대상 테스트 태스크에 포함한다
    // → 테스트 클래스 FullFlowIT가 커버리지 subject로 집계되고(브랜치 하락), koverVerify가 integrationTest를
    // 태스크 그래프로 끌어들여 Docker 없는 단위 CI 게이트가 깨진다. disabledForTestTasks는 이 태스크의 계측을
    // 끄고(리포트 미집계) Kover 리포트 생성이 이 태스크를 트리거하는 것도 방지한다(0.9.x 문서 명시). 이전
    // 수동 소스셋은 Kover가 몰라 이 조정이 불필요했다.
    currentProject {
        instrumentation {
            // koverVerify 태스크 그래프가 integrationTest(Docker)를 끌어들이지 않게 계측 자체를 끈다.
            disabledForTestTasks.add("integrationTest")
        }
        sources {
            // ⚠️ disabledForTestTasks만으로는 부족하다 — jvm-test-suite가 integrationTest 소스셋 출력을
            // 커버리지 subject 집합에 넣어 FullFlowIT 클래스가 측정 대상이 되고, 태스크 미실행 시 0% covered로
            // 집계돼 총계를 붕괴시킨다(실측: 라인 51%/브랜치 69%). 소스셋 자체를 subject에서 제외해야 한다.
            excludedSourceSets.add("integrationTest")
        }
    }
    reports {
        filters {
            excludes {
                // ⚠️ Kover 0.9.x는 와일드카드 없는 정확 클래스명 exclude를 적용하지 않는다(실측: "AuthClient"
                // 정확명은 무시돼 브랜치 집계됨·"admin.*"만 제외됨) → 네트워크 경계 클래스는 전부 `*` 접미로
                // 지정한다. `AuthClient*`/`KeycloakClient*`는 클래스 본체 + 파일-레벨 top-level 함수 클래스(…Kt)까지 포함.
                classes(
                    "io.github.xzawed.keycloak.AuthClient*",
                    "io.github.xzawed.keycloak.admin.*",
                    "io.github.xzawed.keycloak.KeycloakClient*",
                )
            }
        }
        verify {
            rule {
                bound {
                    minValue = 90
                    coverageUnits = kotlinx.kover.gradle.plugin.dsl.CoverageUnit.LINE
                }
            }
            rule {
                bound {
                    minValue = 85
                    coverageUnits = kotlinx.kover.gradle.plugin.dsl.CoverageUnit.BRANCH
                }
            }
        }
    }
}

tasks.named("check") {
    dependsOn("koverVerify")
}

// Central Portal 배포(vanniktech maven.publish) — CI 시크릿(ORG_GRADLE_PROJECT_ 접두):
// mavenCentralUsername / mavenCentralPassword / signingInMemoryKey / signingInMemoryKeyPassword
// ⚠️ signAllPublications()는 in-memory 서명 키가 주입됐을 때만 호출한다 — 키 없이 호출하면
// publication에 .asc 서명 아티팩트가 포함되어 `publishToMavenLocal`(로컬 검증·하네스 소스빌드)이
// "no configured signatory"로 실패한다. CI 릴리스(kotlin-release.yml)는 ORG_GRADLE_PROJECT_signingInMemoryKey를
// 주입하므로 서명이 켜지고, 로컬/하네스는 무서명으로 mavenLocal에 게시된다(vanniktech 표준 관용).
val signingKeyPresent: Boolean =
    providers.gradleProperty("signingInMemoryKey").isPresent ||
        providers.environmentVariable("ORG_GRADLE_PROJECT_signingInMemoryKey").isPresent
mavenPublishing {
    // ⚠️ `automaticRelease = false`를 명시한다. Maven Central은 게시 후 철회 수단이 전혀 없고,
    // 이 SDK가 가진 유일한 회복 수단은 Central Portal의 사람 스테이징 하나다 — staging에 머무는
    // 동안에는 무비용 폐기가 가능하고 Publish를 누르면 영구다. 인자 없는 `publishToMavenCentral()`의
    // 기본값도 수동 릴리스라 지금도 안전하지만, 그 안전이 **플러그인 기본값 상속**에 의존하고 있었다
    // (Java 쪽 `<autoPublish>false</autoPublish>`와 같은 이유로 명시한다).
    // ⚠️ 릴리스 워크플로가 `publishAndReleaseToMavenCentral`(사람 게이트를 건너뛴다)이 아니라
    // `publishToMavenCentral` 태스크를 부르는지도 함께 유지할 것 — kotlin-release.yml.
    publishToMavenCentral(automaticRelease = false)
    if (signingKeyPresent) {
        signAllPublications()
    }

    coordinates("io.github.xzawed", "keycloak-sdk-kotlin", version.toString())

    pom {
        name.set("Keycloak SDK (Kotlin)")
        // ⚠️ Maven Central은 README를 렌더링하지 않는다 — 이 한 줄과 위 `name`이 아티팩트 페이지의
        // **전부**다. 소비자가 좌표만 보고 판단할 수 있도록 (1) 무엇을 덮는지(auth+admin+JWT),
        // (2) 어떤 관용인지(suspend), (3) 무엇을 감싸는지, (4) 소비자 하한(Kotlin 2.2+/JDK 21+)까지 담는다.
        // 하한을 여기 적어두는 이유: 잘못 맞추면 "compiled with an incompatible version of Kotlin"으로
        // 컴파일 자체가 실패하는데, 그 사실을 알려줄 다른 지면이 Central에는 없다(게차 참고).
        // ⚠️ POM `<description>`으로 나가므로 반드시 한 줄로 유지할 것.
        description.set(
            "Keycloak SDK for Kotlin — coroutine-first (suspend) OIDC/OAuth2 authentication with " +
                "hardened JWT validation, plus the Admin REST API, behind one facade. Wraps the same JVM " +
                "stack as the sibling Java SDK (keycloak-admin-client, oauth2-oidc-sdk, nimbus-jose-jwt). " +
                "Requires Kotlin 2.2+ / JDK 21+. The Kotlin implementation of a nine-language polyglot " +
                "Keycloak SDK (Java, Python, Node, Go, C#, PHP, Rust, Ruby, Kotlin).",
        )
        inceptionYear.set("2026")
        // POM `<url>`은 "The project's home page"(표시용)이지 VCS URL이 아니다 — 아래 <scm>이 VCS다.
        // kotlin/을 가리켜 Central에서 링크를 누른 소비자가 kotlin/README.md에 닿게 한다.
        // (Java SDK의 java/pom.xml과 같은 결정. 단 Kotlin은 단일 모듈이라 Maven의 URL 상속
        //  artifactId 자동 덧붙임 문제는 애초에 발생하지 않는다.)
        url.set("https://github.com/xzawed/KeyCloakSDK/tree/main/kotlin")
        licenses {
            license {
                name.set("Apache-2.0")
                url.set("https://www.apache.org/licenses/LICENSE-2.0.txt")
            }
        }
        developers {
            developer {
                id.set("xzawed")
                name.set("xzawed")
                email.set("xzawed31@gmail.com")
            }
        }
        scm {
            url.set("https://github.com/xzawed/KeyCloakSDK")
            connection.set("scm:git:https://github.com/xzawed/KeyCloakSDK.git")
            developerConnection.set("scm:git:https://github.com/xzawed/KeyCloakSDK.git")
        }
    }
}
