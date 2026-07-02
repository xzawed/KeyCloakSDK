package io.github.xzawed.keycloak.auth;
import static org.junit.jupiter.api.Assertions.*;
import com.nimbusds.common.contenttype.ContentType;
import com.nimbusds.oauth2.sdk.http.HTTPRequest;
import io.github.xzawed.keycloak.core.KeycloakConfig;
import org.junit.jupiter.api.Test;

// buildLogoutRequest()의 wire format(send() 없이)을 검증: AuthClient.logout()은 Nimbus의
// 백업 클래스 없이 직접 조립되므로 가장 깨지기 쉬운 경로 (3a Important fix).
class AuthClientLogoutTest {
  private AuthClient newClient() {
    KeycloakConfig c = KeycloakConfig.builder()
        .serverUrl("https://kc.example.com").realm("r").clientId("app")
        .clientSecret("s3cr3t".toCharArray()).build();
    return new AuthClient(c, OidcMetadata.forRealm(c));
  }

  @Test void buildLogoutRequest_isPostToEndSessionEndpoint() {
    HTTPRequest req = newClient().buildLogoutRequest("some-refresh-token");
    assertEquals(HTTPRequest.Method.POST, req.getMethod());
    assertEquals("https://kc.example.com/realms/r/protocol/openid-connect/logout",
        req.getURI().toString());
  }

  @Test void buildLogoutRequest_usesFormUrlEncodedContentType() {
    HTTPRequest req = newClient().buildLogoutRequest("some-refresh-token");
    assertEquals(ContentType.APPLICATION_URLENCODED, req.getEntityContentType());
  }

  @Test void buildLogoutRequest_bodyContainsRefreshToken() {
    HTTPRequest req = newClient().buildLogoutRequest("some-refresh-token");
    assertEquals("refresh_token=some-refresh-token", req.getBody());
  }

  @Test void buildLogoutRequest_setsBasicAuthorizationHeader() {
    HTTPRequest req = newClient().buildLogoutRequest("some-refresh-token");
    assertNotNull(req.getAuthorization());
    assertTrue(req.getAuthorization().startsWith("Basic "));
  }
}
