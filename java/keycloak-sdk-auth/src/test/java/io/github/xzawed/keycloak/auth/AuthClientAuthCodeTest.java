package io.github.xzawed.keycloak.auth;
import static org.junit.jupiter.api.Assertions.*;
import io.github.xzawed.keycloak.core.KeycloakConfig;
import java.net.URI;
import org.junit.jupiter.api.Test;

class AuthClientAuthCodeTest {
  private AuthClient newClient() {
    KeycloakConfig c = KeycloakConfig.builder()
        .serverUrl("https://kc.example.com").realm("r").clientId("app")
        .scopes("openid","profile").build();
    return new AuthClient(c, OidcMetadata.forRealm(c));
  }
  @Test void authorizationUrl_containsPkceAndState() {
    AuthorizationUrlRequest req = newClient().createAuthorizationRequest(URI.create("https://app/cb"));
    String url = req.getAuthorizationUrl().toString();
    assertTrue(url.startsWith("https://kc.example.com/realms/r/protocol/openid-connect/auth"));
    assertTrue(url.contains("code_challenge="));
    assertTrue(url.contains("code_challenge_method=S256"));
    assertTrue(url.contains("state=" ));
    assertTrue(url.contains("response_type=code"));
    assertNotNull(req.getCodeVerifier());
    assertNotNull(req.getState());
  }
}
