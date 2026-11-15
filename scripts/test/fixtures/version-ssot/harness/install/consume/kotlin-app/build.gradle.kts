repositories {
    // ⚠️ 미끼(실제 파일에 있는 모양) — 산문이 같은 좌표를 **다른 버전으로** 언급한다.
    // consume/kotlin-run.sh 가 컨테이너 안에서 io.github.xzawed:keycloak-sdk-kotlin:0.0.9 처럼 이 줄을 치환한다.
    maven { url = uri("http://java-registry/maven") }
}

dependencies {
    implementation("io.github.xzawed:keycloak-sdk-kotlin:0.1.0")
}
