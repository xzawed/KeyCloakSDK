// gradle/wrapper: 9.5.0
// settings.gradle.kts: plugins { id("org.gradle.toolchains.foojay-resolver-convention") version "1.0.0" }

plugins {
    kotlin("jvm") version "2.2.20"
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
    implementation("com.nimbusds:oauth2-oidc-sdk:11.37.2")
    implementation("com.nimbusds:nimbus-jose-jwt:10.9.1")

    testImplementation(kotlin("test"))
    testImplementation(platform("org.junit:junit-bom:6.1.1"))
    testImplementation("org.junit.jupiter:junit-jupiter")
    testRuntimeOnly("org.junit.platform:junit-platform-launcher")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.11.0")
    testImplementation("io.mockk:mockk:1.14.4")
    testImplementation("org.wiremock:wiremock:3.13.2")
    testImplementation("org.testcontainers:testcontainers:2.0.5")
    testImplementation("org.testcontainers:testcontainers-junit-jupiter:2.0.5")
    testImplementation("com.github.dasniko:testcontainers-keycloak:4.2.1")
}

tasks.test {
    useJUnitPlatform()
}

// Kover 0.9.x DSL — 네트워크 경계(AuthClient/admin.*/KeycloakClient) omit, 라인90%/브랜치85% 게이트.
kover {
    reports {
        filters {
            excludes {
                classes(
                    "io.github.xzawed.keycloak.AuthClient",
                    "io.github.xzawed.keycloak.admin.*",
                    "io.github.xzawed.keycloak.KeycloakClient",
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
mavenPublishing {
    publishToMavenCentral()
    signAllPublications()

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
