package io.github.xzawed.keycloak.auth;
import static org.junit.jupiter.api.Assertions.*;
import com.nimbusds.oauth2.sdk.ParseException;
import com.sun.net.httpserver.HttpServer;
import io.github.xzawed.keycloak.core.KeycloakConfig;
import io.github.xzawed.keycloak.core.exception.KeycloakAuthException;
import java.io.OutputStream;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.util.List;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;

// 토큰 응답의 access_token 이 비어 있지 않은 문자열이 아니면 거절하는 것은 **우리 코드가 아니라 Nimbus
// `TokenResponse.parse`** 다. 교차언어 가드는 그 호출의 존재만 봤다 — 라이브러리가 관용해지면(.NET 의
// Duende 가 실제로 강제변환했다) 쓸 수 없는 토큰이 성공으로 나가도 아무도 모른다. 그 행동을 여기서 고정한다.
class AuthClientTokenTypeTest {
  private HttpServer server;

  @AfterEach void stopServer() {
    if (server != null) server.stop(0);
  }

  @Test void clientCredentialsToken_rejectsNonStringOrEmptyAccessToken() throws Exception {
    for (String raw : List.of("12345", "{\"a\":1}", "[]", "true", "null", "\"\"")) {
      AuthClient client = clientServingToken("{\"access_token\":" + raw
          + ",\"token_type\":\"Bearer\",\"expires_in\":300}");
      KeycloakAuthException e = assertThrows(KeycloakAuthException.class,
          client::clientCredentialsToken, "access_token " + raw);
      assertEquals("Client credentials request error", e.getMessage(), "access_token " + raw);
      // 원인은 Nimbus 파서 예외의 **사본**이다 — 타입 이름은 남고 메시지(응답을 인용할 수 있다)는 보류된다.
      assertFalse(e.getCause() instanceof ParseException, "access_token " + raw);
      assertTrue(e.getCause().getMessage().startsWith(ParseException.class.getName() + " (message withheld"),
          "access_token " + raw + ": " + e.getCause().getMessage());
      server.stop(0);
    }
  }

  // 대조군 — 같은 경로에서 문자열 access_token 은 통과한다(위 거절이 다른 원인이 아님을 보인다).
  @Test void clientCredentialsToken_acceptsStringAccessToken() throws Exception {
    AuthClient client = clientServingToken(
        "{\"access_token\":\"AT\",\"token_type\":\"Bearer\",\"expires_in\":300}");
    assertEquals("AT", client.clientCredentialsToken().getAccessToken());
  }

  private AuthClient clientServingToken(String body) throws Exception {
    byte[] bytes = body.getBytes(StandardCharsets.UTF_8);
    server = HttpServer.create(new InetSocketAddress(InetAddress.getLoopbackAddress(), 0), 0);
    server.createContext("/realms/r/protocol/openid-connect/token", ex -> {
      ex.getResponseHeaders().add("Content-Type", "application/json");
      ex.sendResponseHeaders(200, bytes.length);
      try (OutputStream os = ex.getResponseBody()) {
        os.write(bytes);
      }
    });
    server.start();
    KeycloakConfig cfg = KeycloakConfig.builder()
        .serverUrl("http://127.0.0.1:" + server.getAddress().getPort()).realm("r").clientId("app")
        .clientSecret("secret".toCharArray()).build();
    return new AuthClient(cfg, OidcMetadata.forRealm(cfg));
  }
}
