// Kotlin/Ktor 하네스 샘플 앱 — 공통 HTTP 계약을 Kotlin SDK로 구현(Java 앱 동형).
// fat jar는 shadow 플러그인의 gradle 버전 호환 리스크가 있어 gradle 내장 `application` 플러그인의
// installDist(bin/lib 배포)를 쓴다 — Dockerfile이 그 산출물을 실행한다.
// gradle/wrapper: 8.14
// ⚠️ **KGP 2.2.20 은 의도된 값이다 — 올리지 말 것.** 게시 jar 의 소비자 하한(languageVersion/
// apiVersion = KOTLIN_2_2)을 실제로 검증하는 자리라 여기를 SDK 의 KGP 2.4.10 으로 맞추면
// 그 검증이 사라진다(`.claude/rules/kotlin.md` 의 publishToMavenLocal 확인 절차).
// ⚠️ 그래서 **래퍼를 9.5.0 → 8.14 로 내렸다**: KGP 2.2.20 의 완전지원 밴드는 7.6.3-8.14 이고
// (kotlinlang.org 표의 `2.2.20–2.2.21` 행) 9.5.0 은 밖이었다. 밴드 안에 두는 것이 이 저장소
// 정책이다. 래퍼만 되올리면 다시 밴드를 벗어난다 — KGP 를 올릴 때만 함께 올린다.
plugins {
    kotlin("jvm") version "2.2.20"
    application
}

repositories {
    // Kotlin SDK(io.github.xzawed:keycloak-sdk-kotlin:0.1.0)는 Dockerfile이 SDK 소스에서
    // `publishToMavenLocal`로 설치한 것을 mavenLocal로 해석한다(다른 8개 앱의 소스-빌드 패턴과 동형).
    mavenLocal()
    mavenCentral()
}

val ktorVersion = "3.5.2"

dependencies {
    // ⚠️ 이 핀은 kotlin/build.gradle.kts 의 `version` 과 **문자열까지** 같아야 한다 —
    // Dockerfile이 SDK 소스를 publishToMavenLocal 한 것만 mavenLocal에 있기 때문이다.
    // `scripts/check-versions.mjs` 가 대조한다(범프를 두고 가면 야간 score-all만 조용히 빨개진다).
    implementation("io.github.xzawed:keycloak-sdk-kotlin:0.1.0")
    implementation("io.ktor:ktor-server-core:$ktorVersion")
    implementation("io.ktor:ktor-server-netty:$ktorVersion")
    implementation("io.ktor:ktor-server-content-negotiation:$ktorVersion")
    implementation("io.ktor:ktor-serialization-jackson:$ktorVersion")
    implementation("com.fasterxml.jackson.module:jackson-module-kotlin:2.18.2")
    runtimeOnly("ch.qos.logback:logback-classic:1.5.34")
    // ⚠️ **전이 의존을 여기서 끌어올린다.** ktor 3.5.2 가 netty 4.2.16 을 끌어오는데
    // GHSA-8c42-7qj2-3j46(CORS 캐시 오염·정보노출)이 4.2.17.Final 에서 고쳐졌다. ktor 쪽이
    // 따라올 때까지 BOM 으로 netty 전체를 함께 올린다(모듈 하나만 올리면 버전이 갈린다).
    // 이 줄이 필요 없어지는 조건: ktor 가 4.2.17 이상을 끌어오게 되면 지운다 —
    // `security-audit` 의 harness-kotlin 잡이 그때도 초록이면 지워도 안전하다.
    implementation(platform("io.netty:netty-bom:4.2.17.Final"))
}

kotlin {
    jvmToolchain(21)
}

application {
    mainClass.set("io.github.xzawed.harness.ApplicationKt")
    applicationName = "harness-app-kotlin"
}
