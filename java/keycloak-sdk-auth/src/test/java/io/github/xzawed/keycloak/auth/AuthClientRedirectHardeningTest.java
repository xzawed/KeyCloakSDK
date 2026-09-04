package io.github.xzawed.keycloak.auth;
import static org.junit.jupiter.api.Assertions.*;
import com.nimbusds.oauth2.sdk.http.HTTPRequest;
import io.github.xzawed.keycloak.core.KeycloakConfig;
import java.net.URI;
import org.junit.jupiter.api.Test;

/**
 * SSRF 하드닝 — SDK가 **스스로 보내는** back-channel 요청(token·refresh·introspect·logout)은
 * 3xx를 따라가면 안 된다. Nimbus {@code HTTPRequest}의 기본값은 추종이다.
 *
 * <p>왜 심각한가(실측): 이 SDK의 5개 {@code send()} 호출부가 전부 {@link AuthClient#applyTimeouts}를
 * 지나므로 한 곳이 뚫리면 전부 뚫린다. 그리고 이 클래스의 위험은 "엉뚱한 URL을 가져온다"에 그치지
 * 않는다 — <b>logout이 302를 따라가 무관한 200을 받으면 정상 반환</b>한다. 호출자는 세션이
 * 폐기됐다고 믿지만 실제로는 살아 있다. 예외보다 나쁜 실패 모드다.
 *
 * <p>⚠️ 이것은 SDK가 보내는 요청에 대한 것이다. OIDC authorization-code의 {@code redirect_uri}는
 * 브라우저 front-channel 개념이라 무관하다 — 이름이 비슷해 혼동하기 쉽다.
 *
 * <p>네트워크 불필요: {@code applyTimeouts}가 모든 전송의 단일 병목이므로 그 산출물의 플래그를
 * 직접 확인하는 것이 가장 좁고 확실한 계약이다. Kotlin 자매 SDK도 같은 지점을 같은 방식으로 막는다.
 */
class AuthClientRedirectHardeningTest {

  private static AuthClient client() {
    KeycloakConfig c = KeycloakConfig.builder()
        .serverUrl("https://kc.example.com").realm("r").clientId("app").build();
    return new AuthClient(c, OidcMetadata.forRealm(c));
  }

  @Test void applyTimeouts_disablesRedirectFollowing() throws Exception {
    HTTPRequest req = new HTTPRequest(HTTPRequest.Method.POST,
        URI.create("https://kc.example.com/realms/r/protocol/openid-connect/token").toURL());
    // 전제 확인: Nimbus 기본값은 추종이다. 이 단언이 깨지면 상류가 기본값을 바꿨다는 뜻이고,
    // 그때는 아래 하드닝이 불필요해졌는지 재검토해야 한다(무의미해진 코드를 남기지 않도록).
    assertTrue(req.getFollowRedirects(),
        "Nimbus HTTPRequest의 기본값이 더 이상 '추종'이 아니라면 이 하드닝의 전제를 재검토할 것");

    assertFalse(client().applyTimeouts(req).getFollowRedirects(),
        "SSRF 하드닝: back-channel 요청은 3xx를 따라가면 안 된다");
  }

  /**
   * JWKS 조회 경로도 3xx를 따라가면 안 된다 — 여기가 뚫리면 공격자가 고른 URL의 응답이
   * **서명 검증용 키 집합으로 쓰인다**. auth 경로보다 결과가 나쁘다.
   *
   * <p>행동 검증: 302를 주는 로컬 서버에 붙여 리다이렉트 대상이 실제로 조회되지 않는지 센다.
   * 대조군으로 Nimbus 기본 리트리버를 같은 서버에 붙여 **그쪽은 따라간다**는 것까지 확인한다 —
   * 대조군이 없으면 이 테스트는 "서버가 302를 주긴 했다"만 증명할 수도 있다.
   */
  @Test void jwksRetriever_doesNotFollowRedirects() throws Exception {
    java.util.concurrent.atomic.AtomicInteger internalHits = new java.util.concurrent.atomic.AtomicInteger();
    com.sun.net.httpserver.HttpServer server =
        com.sun.net.httpserver.HttpServer.create(new java.net.InetSocketAddress("127.0.0.1", 0), 0);
    byte[] keys = "{\"keys\":[]}".getBytes(java.nio.charset.StandardCharsets.UTF_8);
    server.createContext("/internal", ex -> {
      internalHits.incrementAndGet();
      ex.getResponseHeaders().add("Content-Type", "application/json");
      ex.sendResponseHeaders(200, keys.length);
      try (java.io.OutputStream os = ex.getResponseBody()) { os.write(keys); }
    });
    server.createContext("/certs", ex -> {
      ex.getResponseHeaders().add("Location", "/internal");
      ex.sendResponseHeaders(302, -1);
      ex.close();
    });
    server.start();
    try {
      java.net.URL certs = java.net.URI.create(
          "http://127.0.0.1:" + server.getAddress().getPort() + "/certs").toURL();

      // 대조군: Nimbus 기본 리트리버는 따라간다 — 이 단언이 깨지면 상류가 기본값을 바꿨다는 뜻이다.
      new com.nimbusds.jose.util.DefaultResourceRetriever(2000, 2000).retrieveResource(certs);
      assertTrue(internalHits.get() > 0, "대조군(기본 리트리버)은 리다이렉트를 따라가야 한다");

      internalHits.set(0);
      // 우리 리트리버: 따라가지 않으므로 조회가 실패해야 하고, /internal은 건드리지 않아야 한다.
      assertThrows(java.io.IOException.class,
          () -> new NoRedirectResourceRetriever(2000, 2000).retrieveResource(certs),
          "리다이렉트를 따라가지 않으므로 JWKS 조회는 실패로 표면화되어야 한다");
      assertEquals(0, internalHits.get(),
          "SSRF 하드닝: 리다이렉트 대상은 조회되면 안 된다 — 그 응답이 서명 검증 키가 된다");
    } finally {
      server.stop(0);
    }
  }

  /**
   * JWKS 응답 크기에 상한이 있어야 한다 — 없으면 무제한 응답이 그대로 힙에 들어온다.
   *
   * <p>왜 이 테스트가 필요한가: 리트리버를 <b>주입하는 행위 자체가</b> Nimbus의 상한을 지운다.
   * {@code JWKSourceBuilder}는 리트리버를 안 주면 자기 것을 {@code (500, 500, 51200)}으로 만드는데,
   * 우리가 SSRF 하드닝을 위해 리트리버를 주입하면 그 51200이 사라진다. 즉 <b>보안 하드닝 하나가
   * 다른 보안 속성을 조용히 없앤 자리</b>다.
   *
   * <p>⚠️ 대조군을 지우지 말 것 — sizeLimit 0(무제한)인 리트리버는 <b>같은 서버에서 같은 응답을
   * 성공적으로 받는다</b>. 그게 없으면 이 테스트는 "서버가 뭔가 잘못됐다"로도 통과한다.
   */
  @Test void jwksRetriever_boundsResponseSize() throws Exception {
    int limit = com.nimbusds.jose.jwk.source.JWKSourceBuilder.DEFAULT_HTTP_SIZE_LIMIT;
    // 상한보다 확실히 큰 JWKS. 파싱 가능한 형태일 필요는 없다 — 상한은 파싱 전에 걸린다.
    StringBuilder sb = new StringBuilder("{\"keys\":[],\"pad\":\"");
    while (sb.length() < limit * 2) sb.append('A');
    sb.append("\"}");
    byte[] huge = sb.toString().getBytes(java.nio.charset.StandardCharsets.UTF_8);
    assertTrue(huge.length > limit, "픽스처가 상한보다 커야 의미가 있다");

    com.sun.net.httpserver.HttpServer server =
        com.sun.net.httpserver.HttpServer.create(new java.net.InetSocketAddress("127.0.0.1", 0), 0);
    server.createContext("/certs", ex -> {
      ex.getResponseHeaders().add("Content-Type", "application/json");
      ex.sendResponseHeaders(200, huge.length);
      try (java.io.OutputStream os = ex.getResponseBody()) { os.write(huge); }
    });
    server.start();
    try {
      java.net.URL certs = java.net.URI.create(
          "http://127.0.0.1:" + server.getAddress().getPort() + "/certs").toURL();

      // 대조군: 상한 없는(2-arg → sizeLimit 0) 리트리버는 같은 응답을 통째로 받아낸다.
      // 이 단언이 이 테스트가 공허하지 않음을 보장한다.
      assertEquals(0, new com.nimbusds.jose.util.DefaultResourceRetriever(2000, 2000).getSizeLimit(),
          "2-arg 생성자는 sizeLimit을 0(무제한)으로 둔다 — 이 전제가 깨지면 상류가 바뀐 것이다");
      assertTrue(
          new com.nimbusds.jose.util.DefaultResourceRetriever(2000, 2000)
              .retrieveResource(certs).getContent().length() > limit,
          "대조군: 상한이 없으면 상한보다 큰 응답이 그대로 들어온다");

      // 우리 리트리버: 상한을 넘기면 실패로 표면화된다.
      assertEquals(limit, new NoRedirectResourceRetriever(2000, 2000).getSizeLimit(),
          "JWKS 리트리버는 Nimbus의 기본 상한을 그대로 이어받아야 한다");
      assertThrows(java.io.IOException.class,
          () -> new NoRedirectResourceRetriever(2000, 2000).retrieveResource(certs),
          "상한을 넘는 JWKS 응답은 조회 실패로 표면화되어야 한다 — 무제한으로 힙에 들이면 안 된다");
    } finally {
      server.stop(0);
    }
  }

}
