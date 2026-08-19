// gradle/wrapper: 9.5.0
// kgp-gradle-band: kgp=2.4.10 gradle=7.6.3-9.5.0
plugins {
    kotlin("jvm") version "2.4.10"
}
version = "0.1.0"

// 소비자 하한 — 이 셋은 함께 움직인다(guard: check-versions.mjs).
kotlin {
    compilerOptions {
        languageVersion.set(org.jetbrains.kotlin.gradle.dsl.KotlinVersion.KOTLIN_2_2)
        apiVersion.set(org.jetbrains.kotlin.gradle.dsl.KotlinVersion.KOTLIN_2_2)
    }
}
dependencies {
    api("org.jetbrains.kotlin:kotlin-stdlib:2.2.21")
}
