package io.github.xzawed.keycloak.core;
import static org.junit.jupiter.api.Assertions.*;
import io.github.xzawed.keycloak.core.exception.KeycloakConfigException;
import java.time.Duration;
import org.junit.jupiter.api.Test;

class KeycloakConfigTest {
  @Test void buildsWithDefaults() {
    KeycloakConfig c = KeycloakConfig.builder()
        .serverUrl("https://kc.example.com").realm("r").clientId("app").build();
    assertEquals("https://kc.example.com", c.getServerUrl());
    assertEquals(Duration.ofSeconds(30), c.getClockSkew());
    assertTrue(c.isTlsVerification());
  }
  @Test void missingRealm_throwsConfigException() {
    KeycloakConfig.Builder b = KeycloakConfig.builder().serverUrl("x").clientId("app");
    assertThrows(KeycloakConfigException.class, b::build);
  }
  @Test void missingServerUrl_throwsConfigException() {
    KeycloakConfig.Builder b = KeycloakConfig.builder().realm("r").clientId("app");
    assertThrows(KeycloakConfigException.class, b::build);
  }
  @Test void missingClientId_throwsConfigException() {
    KeycloakConfig.Builder b = KeycloakConfig.builder().serverUrl("x").realm("r");
    assertThrows(KeycloakConfigException.class, b::build);
  }
  @Test void clientSecret_isDefensivelyCopied() {
    char[] secret = "s3cr3t".toCharArray();
    KeycloakConfig c = KeycloakConfig.builder().serverUrl("x").realm("r").clientId("app")
        .clientSecret(secret).build();
    secret[0] = 'X';
    assertArrayEquals("s3cr3t".toCharArray(), c.getClientSecret());
  }
  @Test void clientSecret_defaultsToNull() {
    KeycloakConfig c = KeycloakConfig.builder().serverUrl("x").realm("r").clientId("app").build();
    assertNull(c.getClientSecret());
  }
  @Test void customValues_areReflectedInGetters() {
    KeycloakConfig c = KeycloakConfig.builder()
        .serverUrl("https://kc.example.com").realm("r").clientId("app")
        .scopes("openid", "profile")
        .connectTimeout(Duration.ofSeconds(5))
        .readTimeout(Duration.ofSeconds(15))
        .clockSkew(Duration.ofSeconds(60))
        .tlsVerification(false)
        .build();
    assertEquals("r", c.getRealm());
    assertEquals("app", c.getClientId());
    assertEquals(java.util.List.of("openid", "profile"), c.getScopes());
    assertEquals(Duration.ofSeconds(5), c.getConnectTimeout());
    assertEquals(Duration.ofSeconds(15), c.getReadTimeout());
    assertEquals(Duration.ofSeconds(60), c.getClockSkew());
    assertFalse(c.isTlsVerification());
  }
}
