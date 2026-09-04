package io.github.xzawed.keycloak.auth;
import com.nimbusds.jose.jwk.source.JWKSourceBuilder;
import com.nimbusds.jose.util.DefaultResourceRetriever;
import java.io.IOException;
import java.net.HttpURLConnection;
import java.net.URL;

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
 *
 * <p>⚠️ <b>응답 크기 상한(3번째 인자)을 반드시 넘긴다.</b> 이것을 빼면
 * {@code DefaultResourceRetriever(int,int)}가 sizeLimit을 <b>0(무제한)</b>으로 넣는다(바이트코드
 * 실측: 2-arg 생성자가 {@code iconst_0}을 밀어 3-arg를 호출한다). 그런데 우리가 리트리버를
 * 주입하지 않았다면 {@code JWKSourceBuilder}는 자기 리트리버를 {@code (500, 500, 51200)}으로
 * 만든다 — 즉 <b>하드닝을 주입하는 행위 자체가 Nimbus의 51200바이트 상한을 지운다</b>. 그
 * 상태에서는 JWKS 엔드포인트(또는 그 자리를 차지한 무엇)가 무제한 응답을 흘려 메모리를 채울 수
 * 있다. 상한은 {@code BoundedInputStream}으로 집행된다.
 *
 * <p>값은 하드코딩하지 않고 {@link JWKSourceBuilder#DEFAULT_HTTP_SIZE_LIMIT}을 참조한다 — 우리가
 * 잃은 바로 그 값이고, 두 번째 정의 자리를 만들지 않는다.
 */
final class NoRedirectResourceRetriever extends DefaultResourceRetriever {
  NoRedirectResourceRetriever(int connectTimeoutMs, int readTimeoutMs) {
    super(connectTimeoutMs, readTimeoutMs, JWKSourceBuilder.DEFAULT_HTTP_SIZE_LIMIT);
  }

  // ⚠️ 캐스트가 안전한 이유: 이 메서드의 반환 타입 자체가 HttpURLConnection이라 Nimbus는 HTTP(S)
  // URL에 대해서만 이것을 호출한다(비-HTTP는 retrieveResource가 여기 오기 전에 처리한다 — file:
  // URL로 실측). 방어적 instanceof 분기를 두면 어떤 테스트로도 도달할 수 없는 죽은 가지가 되어
  // 커버리지 게이트만 떨어뜨린다. 상위 클래스와 같은 계약을 그대로 따른다.
  @Override
  protected HttpURLConnection openConnection(URL url) throws IOException {
    HttpURLConnection con = (HttpURLConnection) url.openConnection();
    con.setInstanceFollowRedirects(false); // SSRF 하드닝 — 인스턴스 단위로만 끈다(전역 상태 불변)
    return con;
  }
}
