package io.github.xzawed.keycloak

import com.nimbusds.jose.util.DefaultResourceRetriever
import java.net.HttpURLConnection
import java.net.URL

/**
 * JWKS 조회 전용 [DefaultResourceRetriever] — 3xx를 따라가지 않는다.
 *
 * Nimbus의 기본 리트리버는 `HttpURLConnection`의 기본 동작(리다이렉트 추종)을 그대로 쓴다.
 * 즉 JWKS 엔드포인트가 예상 밖 3xx를 반환하면 SDK가 공격자가 고른 URL을 가져와 **그 응답을
 * 서명 검증용 키 집합으로 사용한다**. 타임아웃만 주입하고 이 플래그를 두면 SSRF 표면이 남는다.
 *
 * `openConnection`은 Nimbus가 실제로 쓰는 유일한 확장점이라 여기서 한 번만 막으면 모든 조회
 * 경로가 덮인다. 리다이렉트를 만나면 3xx가 그대로 표면화되고 상위 `JWKSourceBuilder`가 조회
 * 실패로 처리한다 — 조용히 엉뚱한 키를 쓰는 것보다 낫다. Java 자매 SDK와 동형.
 *
 * ⚠️ SDK가 스스로 보내는 요청에 대한 것이다. authorization-code의 `redirect_uri`는 브라우저
 * front-channel 개념이라 무관하다.
 */
internal class NoRedirectResourceRetriever(
    connectTimeoutMs: Int,
    readTimeoutMs: Int,
) : DefaultResourceRetriever(connectTimeoutMs, readTimeoutMs) {
    // ⚠️ Nimbus는 이 훅을 deprecated로 표시했지만 **여전히 실제로 호출되는 유일한 확장점**이다
    // (10.9.1에서 실측 확인). 대체 훅이 생기면 그쪽으로 옮기되, 옮기기 전에 이 파일의 행동
    // 테스트(대조군 포함)가 그대로 통과하는지부터 확인할 것 — 훅이 바뀌면 하드닝이 조용히 사라진다.
    @Suppress("OVERRIDE_DEPRECATION")
    // ⚠️ 캐스트가 안전한 이유: 이 메서드의 반환 타입 자체가 HttpURLConnection이라 Nimbus는
    // HTTP(S) URL에 대해서만 이것을 호출한다(비-HTTP는 retrieveResource가 여기 오기 전에 처리한다 —
    // file: URL로 실측). 방어적 분기를 두면 어떤 테스트로도 도달할 수 없는 죽은 가지가 되어
    // 커버리지 게이트만 떨어뜨린다. 상위 클래스와 같은 계약을 그대로 따른다.
    override fun openConnection(url: URL): HttpURLConnection {
        val con = url.openConnection() as HttpURLConnection
        con.instanceFollowRedirects = false // SSRF 하드닝 — 인스턴스 단위로만 끈다(전역 상태 불변)
        return con
    }
}
