package io.github.xzawed.keycloak.auth;
import static org.junit.jupiter.api.Assertions.*;
import com.nimbusds.oauth2.sdk.http.HTTPRequest;
import io.github.xzawed.keycloak.core.KeycloakConfig;
import java.net.URI;
import org.junit.jupiter.api.Test;

// exchangeCode()의 wire format(send() 없이)을 검증 (I.2): buildLogoutRequest/
// buildIntrospectionRequest와 동일 패턴 — 실제 네트워크 없이 Nimbus TokenRequest가
// grant_type=authorization_code / code / code_verifier / 토큰 엔드포인트를 올바르게
// 구성하는지 확인한다. 실제 HTTP 성공/실패 경로는 브라우저 로그인이 필요해 자동 IT
// 범위 밖이다(6.2에서 다루지 않음).
class AuthClientExchangeCodeTest {
  // RFC 7636 code_verifier는 43~128자여야 한다(Nimbus CodeVerifier가 강제).
  private static final String VERIFIER = "verifier-value-that-is-at-least-43-characters-long";

  private AuthClient confidentialClient() {
    KeycloakConfig c = KeycloakConfig.builder()
        .serverUrl("https://kc.example.com").realm("r").clientId("app")
        .clientSecret("s3cr3t".toCharArray()).build();
    return new AuthClient(c, OidcMetadata.forRealm(c));
  }
  private AuthClient publicClient() {
    KeycloakConfig c = KeycloakConfig.builder()
        .serverUrl("https://kc.example.com").realm("r").clientId("public-app").build();
    return new AuthClient(c, OidcMetadata.forRealm(c));
  }

  @Test void buildExchangeCodeRequest_isPostToTokenEndpoint() {
    HTTPRequest req = confidentialClient()
        .buildExchangeCodeRequest("auth-code", URI.create("https://app/cb"), VERIFIER);
    assertEquals(HTTPRequest.Method.POST, req.getMethod());
    assertEquals("https://kc.example.com/realms/r/protocol/openid-connect/token",
        req.getURI().toString());
  }

  @Test void buildExchangeCodeRequest_bodyContainsGrantTypeCodeAndVerifier() {
    HTTPRequest req = confidentialClient()
        .buildExchangeCodeRequest("auth-code", URI.create("https://app/cb"), VERIFIER);
    String body = req.getBody();
    assertTrue(body.contains("grant_type=authorization_code"), body);
    assertTrue(body.contains("code=auth-code"), body);
    assertTrue(body.contains("code_verifier=" + VERIFIER), body);
    assertTrue(body.contains("redirect_uri="), body);
  }

  @Test void buildExchangeCodeRequest_confidentialClient_usesBasicAuth() {
    HTTPRequest req = confidentialClient()
        .buildExchangeCodeRequest("auth-code", URI.create("https://app/cb"), VERIFIER);
    assertNotNull(req.getAuthorization());
    assertTrue(req.getAuthorization().startsWith("Basic "));
    // 기밀 클라이언트는 client_id를 별도로 본문에 넣지 않는다 (Basic 헤더로 인증).
    assertFalse(req.getBody().contains("client_id="));
  }

  @Test void buildExchangeCodeRequest_publicClient_includesClientIdInBody_noAuthHeader() {
    HTTPRequest req = publicClient()
        .buildExchangeCodeRequest("auth-code", URI.create("https://app/cb"), VERIFIER);
    assertNull(req.getAuthorization());
    assertTrue(req.getBody().contains("client_id=public-app"), req.getBody());
    assertTrue(req.getBody().contains("grant_type=authorization_code"));
    assertTrue(req.getBody().contains("code_verifier=" + VERIFIER));
  }
}
