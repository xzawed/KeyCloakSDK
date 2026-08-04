package io.github.xzawed.keycloak.admin;

import static org.junit.jupiter.api.Assertions.*;

import com.sun.net.httpserver.HttpServer;
import io.github.xzawed.keycloak.core.KeycloakConfig;
import jakarta.ws.rs.client.Client;
import jakarta.ws.rs.core.Response;
import java.net.InetSocketAddress;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.util.concurrent.ConcurrentLinkedQueue;
import org.junit.jupiter.api.Test;

/**
 * SSRF 고정(pinning) — admin의 JAX-RS/RESTEasy 클라이언트는 3xx를 따라가면 안 된다.
 *
 * <p>왜 이 형태인가: 자매 언어들과 달리 <strong>여기서는 우리가 끌 노브가 없다.</strong> 다른 SDK는
 * 리다이렉트 플래그를 우리가 직접 끈다(예: Nimbus {@code HTTPRequest.followRedirects = false},
 * reqwest {@code redirect::Policy::none()}, Faraday의 follow_redirects 미장착). 하지만 JAX-RS
 * {@code ClientBuilder}에는 리다이렉트 정책 API가 아예 없다 — 안전한 것은 RESTEasy의
 * <em>기본 동작</em> 덕분이고 그 기본값은 우리가 통제하지 않는다.
 *
 * <p>즉 이 테스트가 유일한 방어수단이다. {@code keycloak-admin-client}나 RESTEasy 상향에서 이
 * 기본값이 바뀌면 예상 밖 3xx가 공격자가 고른 내부 URL을 가리켜도 admin 호출이 그것을 따라가게
 * 되는데, 다른 어떤 게이트도 그 변화를 알려주지 않는다.
 *
 * <p>⚠️ 하드닝이 라이브러리 기본값이라 <strong>변이검증(방어를 지우고 실패를 확인)이
 * 불가능</strong>하다 — 지울 줄이 없다. 그래서 대조군을 함께 둔다: 추종하도록 설정한 JDK
 * {@link HttpClient}는 같은 서버에서 실제로 {@code /internal}에 도달한다. 그게 실패하면
 * 프로브(경로 기록)가 고장난 것이고 위 단언의 통과는 무의미해진다. 자매 Node SDK의
 * jose/openid-client 핀닝 테스트와 같은 구조다.
 *
 * <p>네트워크는 로컬 루프백만 쓴다(Docker 불필요). 전송 계층은 패키지 전용 시임
 * {@link AdminClient#buildTimeoutClient}로 조립한다({@link AdminJacksonProviderTest}와 동일
 * 관용 — 가시성을 넓히지 않는다).
 */
class AdminRedirectHardeningTest {

  @Test
  void resteasyClient_doesNotFollowRedirects() throws Exception {
    ConcurrentLinkedQueue<String> paths = new ConcurrentLinkedQueue<>();
    HttpServer server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
    int port = server.getAddress().getPort();
    server.createContext(
        "/",
        exchange -> {
          paths.add(exchange.getRequestURI().getPath());
          if ("/start".equals(exchange.getRequestURI().getPath())) {
            exchange.getResponseHeaders().add("Location", "http://127.0.0.1:" + port + "/internal");
            exchange.sendResponseHeaders(302, -1);
          } else {
            // 따라갔다면 여기 도달한다 — 200을 내줘서 "3xx를 삼키고 성공을 반환"하는
            // 최악의 시나리오를 그대로 재현한다.
            byte[] body = "followed".getBytes();
            exchange.sendResponseHeaders(200, body.length);
            exchange.getResponseBody().write(body);
          }
          exchange.close();
        });
    server.start();

    KeycloakConfig config =
        KeycloakConfig.builder()
            .serverUrl("http://127.0.0.1:" + port)
            .realm("r")
            .clientId("app")
            .build();

    Client client = AdminClient.buildTimeoutClient(config);
    try {
      try (Response response = client.target("http://127.0.0.1:" + port + "/start").request().get()) {
        assertEquals(
            302,
            response.getStatus(),
            "admin 전송 계층이 3xx를 호출자에게 표면화해야 한다 — 따라가면 안 된다");
      }
      assertFalse(
          paths.contains("/internal"),
          "리다이렉트 대상에 요청 자체가 가면 안 된다. 실제 경로: " + paths);

      // ⚠️ 대조군을 지우지 말 것 — 위 단언이 프로브 고장으로 인한 공허한 통과가 아님을
      // 증명하는 유일한 수단이다(하드닝이 라이브러리 기본값이라 변이검증을 쓸 수 없다).
      paths.clear();
      try (HttpClient follower =
          HttpClient.newBuilder().followRedirects(HttpClient.Redirect.ALWAYS).build()) {
        follower.send(
            HttpRequest.newBuilder(URI.create("http://127.0.0.1:" + port + "/start")).GET().build(),
            HttpResponse.BodyHandlers.ofString());
      }
      assertTrue(
          paths.contains("/internal"),
          "추종하는 클라이언트는 /internal에 도달해야 한다 — 도달하지 않았다면 프로브가 고장난 것이다");
    } finally {
      client.close();
      server.stop(0);
    }
  }
}
