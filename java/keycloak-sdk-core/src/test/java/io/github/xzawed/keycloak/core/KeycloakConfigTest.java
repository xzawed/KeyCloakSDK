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
    assertEquals(Duration.ofSeconds(30), c.getJwksMinRefetch());
  }
  @Test void jwksMinRefetchCustomValueReflected() {
    KeycloakConfig c = KeycloakConfig.builder()
        .serverUrl("x").realm("r").clientId("app").jwksMinRefetch(Duration.ofSeconds(120)).build();
    assertEquals(Duration.ofSeconds(120), c.getJwksMinRefetch());
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
  @Test void blankServerUrl_throwsConfigException() {
    // null 분기뿐 아니라 isBlank() 분기(공백만 있는 값)도 커버한다.
    KeycloakConfig.Builder b = KeycloakConfig.builder().serverUrl("   ").realm("r").clientId("app");
    assertThrows(KeycloakConfigException.class, b::build);
  }
  @Test void blankClientId_throwsConfigException() {
    KeycloakConfig.Builder b = KeycloakConfig.builder().serverUrl("x").realm("r").clientId("   ");
    assertThrows(KeycloakConfigException.class, b::build);
  }
  @Test void clientSecret_isDefensivelyCopied() {
    char[] secret = "s3cr3t".toCharArray();
    KeycloakConfig c = KeycloakConfig.builder().serverUrl("x").realm("r").clientId("app")
        .clientSecret(secret).build();
    secret[0] = 'X';
    assertArrayEquals("s3cr3t".toCharArray(), c.getClientSecret());
  }
  @Test void getClientSecret_returnedArrayMutation_doesNotAffectInternalCopy() {
    // getClientSecret()이 매번 방어적 복사본을 반환하는지 검증: 반환값을 변조해도 내부 상태는 불변.
    KeycloakConfig c = KeycloakConfig.builder().serverUrl("x").realm("r").clientId("app")
        .clientSecret("s3cr3t".toCharArray()).build();
    char[] returned = c.getClientSecret();
    returned[0] = 'X';
    assertArrayEquals("s3cr3t".toCharArray(), c.getClientSecret());
  }
  @Test void clientSecret_defaultsToNull() {
    KeycloakConfig c = KeycloakConfig.builder().serverUrl("x").realm("r").clientId("app").build();
    assertNull(c.getClientSecret());
  }
  @Test void signatureAlgorithms_defaultsToRs256() {
    KeycloakConfig c = KeycloakConfig.builder().serverUrl("x").realm("r").clientId("app").build();
    assertEquals(java.util.List.of("RS256"), c.getSignatureAlgorithms());
  }
  @Test void signatureAlgorithms_customValuesReflected() {
    KeycloakConfig c = KeycloakConfig.builder().serverUrl("x").realm("r").clientId("app")
        .signatureAlgorithms("ES256", "RS256").build();
    assertEquals(java.util.List.of("ES256", "RS256"), c.getSignatureAlgorithms());
  }
  @Test void emptySignatureAlgorithms_throwsConfigException() {
    // 빈 집합은 알고리즘 핀을 무력화한다(핀 없이는 alg 혼동에 노출) — 거부한다.
    KeycloakConfig.Builder b = KeycloakConfig.builder().serverUrl("x").realm("r").clientId("app")
        .signatureAlgorithms();
    assertThrows(KeycloakConfigException.class, b::build);
  }
  @Test void customValues_areReflectedInGetters() {
    KeycloakConfig c = KeycloakConfig.builder()
        .serverUrl("https://kc.example.com").realm("r").clientId("app")
        .scopes("openid", "profile")
        .connectTimeout(Duration.ofSeconds(5))
        .readTimeout(Duration.ofSeconds(15))
        .clockSkew(Duration.ofSeconds(60))
        .build();
    assertEquals("r", c.getRealm());
    assertEquals("app", c.getClientId());
    assertEquals(java.util.List.of("openid", "profile"), c.getScopes());
    assertEquals(Duration.ofSeconds(5), c.getConnectTimeout());
    assertEquals(Duration.ofSeconds(15), c.getReadTimeout());
    assertEquals(Duration.ofSeconds(60), c.getClockSkew());
  }
}
