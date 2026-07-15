// gradle/wrapper: 9.5.0
// settings.gradle.kts: plugins { id("org.gradle.toolchains.foojay-resolver-convention") version "1.0.0" }

plugins {
    kotlin("jvm") version "2.4.10"
    `java-library`
    id("org.jetbrains.dokka") version "2.2.0"
    id("com.vanniktech.maven.publish") version "0.37.0"
    id("org.jetbrains.kotlinx.kover") version "0.9.8"
    id("org.jlleitschuh.gradle.ktlint") version "14.2.0"
}

group = "io.github.xzawed"
version = "0.1.0"

repositories {
    mavenCentral()
}

kotlin {
    jvmToolchain(21)
    explicitApi() // JDK21 + public API 엄격
}

dependencies {
    api("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.11.0") // 공개 suspend → api
    api("org.keycloak:keycloak-admin-client:26.0.10") // representation 노출 → api
    implementation("com.nimbusds:oauth2-oidc-sdk:11.38.1")
    implementation("com.nimbusds:nimbus-jose-jwt:10.9.1")

    testImplementation(kotlin("test"))
    testImplementation(platform("org.junit:junit-bom:6.1.2"))
    testImplementation("org.junit.jupiter:junit-jupiter")
    testRuntimeOnly("org.junit.platform:junit-platform-launcher")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.11.0")
    testImplementation("io.mockk:mockk:1.14.11")
    testImplementation("org.wiremock:wiremock:3.13.2")
    testImplementation("org.testcontainers:testcontainers:2.0.5")
    testImplementation("org.testcontainers:testcontainers-junit-jupiter:2.0.5")
    testImplementation("com.github.dasniko:testcontainers-keycloak:4.3.0")
}

tasks.test {
    useJUnitPlatform()
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
                implementation("com.github.dasniko:testcontainers-keycloak:4.3.0")
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
    publishToMavenCentral()
    if (signingKeyPresent) {
        signAllPublications()
    }

    coordinates("io.github.xzawed", "keycloak-sdk-kotlin", version.toString())

    pom {
        name.set("Keycloak SDK (Kotlin)")
        description.set("Multi-language Keycloak SDK — Kotlin implementation")
        inceptionYear.set("2026")
        url.set("https://github.com/xzawed/KeyCloakSDK")
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
