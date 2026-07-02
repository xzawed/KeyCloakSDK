package io.github.xzawed.keycloak;

import static org.junit.jupiter.api.Assertions.*;

import com.nimbusds.jwt.JWTClaimsSet;
import dasniko.testcontainers.keycloak.KeycloakContainer;
import io.github.xzawed.keycloak.auth.AuthClient;
import io.github.xzawed.keycloak.auth.IntrospectionResult;
import io.github.xzawed.keycloak.auth.OidcMetadata;
import io.github.xzawed.keycloak.core.KeycloakConfig;
import io.github.xzawed.keycloak.core.TokenSet;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;

/**
 * Auth flow E2E against a real Keycloak container (WBS 6.2): client-credentials
 * token acquisition, JWT validation (JWKS/issuer/audience), and RFC 7662
 * introspection.
 */
@Testcontainers
class AuthFlowIT {

  @Container
  static KeycloakContainer KC =
      new KeycloakContainer("quay.io/keycloak/keycloak:26.6").withRealmImportFile("/it-realm-realm.json");

  static AuthClient auth;

  @BeforeAll
  static void setUp() {
    KeycloakConfig config =
        KeycloakConfig.builder()
            .serverUrl(KC.getAuthServerUrl())
            .realm("it-realm")
            .clientId("it-client")
            .clientSecret("it-secret".toCharArray())
            .scopes("openid")
            .build();
    auth = new AuthClient(config, OidcMetadata.forRealm(config));
  }

  @Test
  void clientCredentialsToken_returnsNonBlankAccessToken() {
    TokenSet tokens = auth.clientCredentialsToken();
    assertNotNull(tokens.getAccessToken());
    assertFalse(tokens.getAccessToken().isBlank());
  }

  @Test
  void validate_acceptsClientCredentialsToken_withExpectedIssuer() {
    TokenSet tokens = auth.clientCredentialsToken();
    JWTClaimsSet claims = auth.validate(tokens.getAccessToken());
    assertNotNull(claims);
    assertTrue(claims.getIssuer().endsWith("/realms/it-realm"), "unexpected issuer: " + claims.getIssuer());
  }

  @Test
  void introspect_reportsActiveTrue() {
    TokenSet tokens = auth.clientCredentialsToken();
    IntrospectionResult result = auth.introspect(tokens.getAccessToken());
    assertTrue(result.isActive());
  }
}
