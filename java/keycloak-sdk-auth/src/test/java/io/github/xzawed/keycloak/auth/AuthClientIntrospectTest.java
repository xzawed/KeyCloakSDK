package io.github.xzawed.keycloak.auth;
import static org.junit.jupiter.api.Assertions.*;
import com.nimbusds.common.contenttype.ContentType;
import com.nimbusds.oauth2.sdk.TokenIntrospectionSuccessResponse;
import com.nimbusds.oauth2.sdk.http.HTTPRequest;
import io.github.xzawed.keycloak.core.KeycloakConfig;
import java.util.Optional;
import net.minidev.json.JSONObject;
import org.junit.jupiter.api.Test;

// TokenIntrospectionRequest 조립(send() 없이)을 검증: 요청 URL·client 인증이
// metadata.getIntrospectionEndpoint()를 향하는지 확인 (WBS 3.7). 실제 HTTP는 6.2에서 검증.
class AuthClientIntrospectTest {
  private AuthClient newClient() {
    KeycloakConfig c = KeycloakConfig.builder()
        .serverUrl("https://kc.example.com").realm("r").clientId("app")
        .clientSecret("s3cr3t".toCharArray()).build();
    return new AuthClient(c, OidcMetadata.forRealm(c));
  }

  @Test void buildIntrospectionRequest_isPostToIntrospectionEndpoint() {
    HTTPRequest req = newClient().buildIntrospectionRequest("some-access-token");
    assertEquals(HTTPRequest.Method.POST, req.getMethod());
    assertEquals("https://kc.example.com/realms/r/protocol/openid-connect/token/introspect",
        req.getURI().toString());
  }

  @Test void buildIntrospectionRequest_usesFormUrlEncodedContentType() {
    HTTPRequest req = newClient().buildIntrospectionRequest("some-access-token");
    assertEquals(ContentType.APPLICATION_URLENCODED, req.getEntityContentType());
  }

  @Test void buildIntrospectionRequest_bodyContainsToken() {
    HTTPRequest req = newClient().buildIntrospectionRequest("some-access-token");
    assertTrue(req.getBody().contains("token=some-access-token"));
  }

  @Test void buildIntrospectionRequest_setsBasicAuthorizationHeader() {
    HTTPRequest req = newClient().buildIntrospectionRequest("some-access-token");
    assertNotNull(req.getAuthorization());
    assertTrue(req.getAuthorization().startsWith("Basic "));
  }

  @Test void introspect_rejectsNullToken() {
    AuthClient a = newClient();
    assertThrows(IllegalArgumentException.class, () -> a.introspect(null));
  }

  @Test void mapsActiveResponseToIntrospectionResult() {
    JSONObject json = new JSONObject();
    json.put("active", true);
    json.put("username", "bob");
    json.put("client_id", "app");
    TokenIntrospectionSuccessResponse success = new TokenIntrospectionSuccessResponse(json);
    IntrospectionResult result = AuthClient.toIntrospectionResult(success);
    assertTrue(result.isActive());
    assertEquals(Optional.of("bob"), result.getUsername());
    assertEquals(Optional.of("app"), result.getClientId());
  }

  @Test void mapsInactiveResponseWithoutOptionalFields() {
    JSONObject json = new JSONObject();
    json.put("active", false);
    TokenIntrospectionSuccessResponse success = new TokenIntrospectionSuccessResponse(json);
    IntrospectionResult result = AuthClient.toIntrospectionResult(success);
    assertFalse(result.isActive());
    assertTrue(result.getUsername().isEmpty());
    assertTrue(result.getClientId().isEmpty());
  }
}
