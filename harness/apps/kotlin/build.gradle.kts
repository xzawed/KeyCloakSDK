// Kotlin/Ktor 하네스 샘플 앱 — 공통 HTTP 계약을 Kotlin SDK로 구현(Java 앱 동형).
// fat jar는 shadow 플러그인의 gradle 버전 호환 리스크가 있어 gradle 내장 `application` 플러그인의
// installDist(bin/lib 배포)를 쓴다 — Dockerfile이 그 산출물을 실행한다.
plugins {
    kotlin("jvm") version "2.2.20"
    application
}

repositories {
    // Kotlin SDK(io.github.xzawed:keycloak-sdk-kotlin:0.1.0-RC1)는 Dockerfile이 SDK 소스에서
    // `publishToMavenLocal`로 설치한 것을 mavenLocal로 해석한다(다른 8개 앱의 소스-빌드 패턴과 동형).
    mavenLocal()
    mavenCentral()
}

val ktorVersion = "3.1.3"

dependencies {
    // ⚠️ 이 핀은 kotlin/build.gradle.kts 의 `version` 과 **문자열까지** 같아야 한다 —
    // Dockerfile이 SDK 소스를 publishToMavenLocal 한 것만 mavenLocal에 있기 때문이다.
    // `scripts/check-versions.mjs` 가 대조한다(범프를 두고 가면 야간 score-all만 조용히 빨개진다).
    implementation("io.github.xzawed:keycloak-sdk-kotlin:0.1.0-RC1")
    implementation("io.ktor:ktor-server-core:$ktorVersion")
    implementation("io.ktor:ktor-server-netty:$ktorVersion")
    implementation("io.ktor:ktor-server-content-negotiation:$ktorVersion")
    implementation("io.ktor:ktor-serialization-jackson:$ktorVersion")
    implementation("com.fasterxml.jackson.module:jackson-module-kotlin:2.18.2")
    runtimeOnly("ch.qos.logback:logback-classic:1.5.12")
}

kotlin {
    jvmToolchain(21)
}

application {
    mainClass.set("io.github.xzawed.harness.ApplicationKt")
    applicationName = "harness-app-kotlin"
}
