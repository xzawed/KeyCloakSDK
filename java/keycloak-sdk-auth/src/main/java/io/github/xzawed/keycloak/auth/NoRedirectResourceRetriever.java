package io.github.xzawed.keycloak.auth;
import com.nimbusds.jose.util.DefaultResourceRetriever;
import java.io.IOException;
import java.net.HttpURLConnection;
import java.net.URL;
import java.net.URLConnection;

/**
 * JWKS 조회 전용 {@link DefaultResourceRetriever} — 3xx를 따라가지 않는다.
 *
 * <p>Nimbus의 기본 리트리버는 {@code HttpURLConnection}의 기본 동작(리다이렉트 추종)을 그대로
 * 쓴다. 즉 JWKS 엔드포인트가 예상 밖 3xx를 반환하면 SDK가 공격자가 고른 URL을 가져와 **그 응답을
 * 서명 검증용 키 집합으로 사용한다**. 타임아웃만 주입하고 이 플래그를 두면 SSRF 표면이 남는다.
 *
 * <p>{@code openConnection}은 Nimbus가 실제로 쓰는 유일한 확장점이라 여기서 한 번만 막으면
 * 모든 조회 경로가 덮인다. 리다이렉트를 만나면 추종 대신 3xx가 그대로 표면화되고, 상위
 * {@code JWKSourceBuilder}가 그것을 조회 실패로 처리한다 — 조용히 엉뚱한 키를 쓰는 것보다 낫다.
 *
 * <p>⚠️ 이것은 SDK가 스스로 보내는 요청에 대한 것이다. OIDC authorization-code의
 * {@code redirect_uri}는 브라우저 front-channel 개념이라 무관하다.
 * Kotlin 자매 SDK도 같은 지점을 같은 방식으로 막는다.
 */
final class NoRedirectResourceRetriever extends DefaultResourceRetriever {
  NoRedirectResourceRetriever(int connectTimeoutMs, int readTimeoutMs) {
    super(connectTimeoutMs, readTimeoutMs);
  }

  @Override
  protected HttpURLConnection openConnection(URL url) throws IOException {
    URLConnection raw = url.openConnection();
    if (!(raw instanceof HttpURLConnection con)) {
      throw new IOException("JWKS URL must be HTTP(S): " + url.getProtocol());
    }
    con.setInstanceFollowRedirects(false); // SSRF 하드닝 — 인스턴스 단위로만 끈다(전역 상태 불변)
    return con;
  }
}
