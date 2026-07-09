// 설치 검증용 소비자 Gradle 프로젝트(Kotlin 참조 구현) — kotlin/(SDK 소스 트리) 접근 없이,
// nginx(compose 서비스 mvn-repo-kotlin)가 정적 서빙하는 staged .m2에서 저장소 해석으로 설치한
// `io.github.xzawed:keycloak-sdk-kotlin:0.1.0`(게시된 릴리스 패키지)을 소비한다. harness/apps/kotlin/src의
// Application.kt(무변경)를 boot 앱으로 그대로 재사용하고, Quickstart.kt는 설치 스모크용 별도 main이다.
//
// ⚠️ 이 build.gradle.kts는 harness/apps/kotlin/build.gradle.kts와 딱 한 가지만 다르다: SDK 의존성 소스가
// mavenLocal(소스에서 publishToMavenLocal한 것)이 아니라 mvn-repo-kotlin 레지스트리(게시된 패키지)다 —
// 그 외 Ktor·application 플러그인·app 소스는 동일하다("최대 재사용·단일 변수" 하네스 원칙).
plugins {
    kotlin("jvm") version "2.2.20"
    application
}

repositories {
    // 게시된 SDK 패키지는 로컬 Maven 레지스트리(nginx)에서 해석한다. 평문 HTTP라 allowInsecureProtocol 필요.
    maven {
        url = uri("http://mvn-repo-kotlin/")
        isAllowInsecureProtocol = true
    }
    // 전이 의존성(coroutines·keycloak-admin-client·nimbus·Ktor 등)은 Central에서 해석(install-net 실인터넷).
    mavenCentral()
}

val ktorVersion = "3.1.3"

dependencies {
    // ← 유일한 차이점: 소스 빌드(mavenLocal)가 아니라 레지스트리에서 설치된 게시 패키지.
    implementation("io.github.xzawed:keycloak-sdk-kotlin:0.1.0")
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

// 설치 스모크(quickstart) — 설치된 SDK 패키지로 실 Keycloak에 client-credentials 토큰을 받아 검증한다.
tasks.register<JavaExec>("runQuickstart") {
    group = "verification"
    mainClass.set("io.github.xzawed.harness.QuickstartKt")
    classpath = sourceSets["main"].runtimeClasspath
}
