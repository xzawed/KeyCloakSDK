// gradle/wrapper: 9.5.0
// kgp-gradle-band: kgp=2.4.10 gradle=7.6.3-9.5.0
plugins {
    kotlin("jvm") version "2.4.10"
}
version = "0.1.0"

// 소비자 하한 — 이 셋은 함께 움직인다(guard: check-versions.mjs).
kotlin {
    jvmToolchain(21)
    compilerOptions {
        languageVersion.set(org.jetbrains.kotlin.gradle.dsl.KotlinVersion.KOTLIN_2_2)
        apiVersion.set(org.jetbrains.kotlin.gradle.dsl.KotlinVersion.KOTLIN_2_2)
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}
dependencies {
    api("org.jetbrains.kotlin:kotlin-stdlib:2.2.21")
}
// POM `<description>` 의 하한 문구 — 위 KOTLIN_2_2 · JVM_17 과 대조된다(guard: check-versions.mjs).
mavenPublishing {
    pom {
        description.set(
            "Keycloak SDK for Kotlin (fixture). " +
                "Requires Kotlin 2.2+ / JDK 17+. Fixture only.",
        )
    }
}
