repositories {
    // ⚠️ 미끼(실제 파일에 있는 모양) — 산문이 같은 좌표를 **다른 버전으로** 언급한다.
    // 가드가 선언이 아니라 이 주석을 읽으면 엉뚱한 값을 SSOT와 대조하게 된다.
    // Kotlin SDK(io.github.xzawed:keycloak-sdk-kotlin:0.0.9)는 Dockerfile이 publishToMavenLocal로
    // 설치한 것을 mavenLocal로 해석한다.
    mavenLocal()
}

val ktorVersion = "3.1.3"

dependencies {
    implementation("io.github.xzawed:keycloak-sdk-kotlin:0.1.0")
    implementation("io.ktor:ktor-server-core:$ktorVersion")
}
