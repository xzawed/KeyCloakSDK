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
    // ⚠️ 억제가 아니라 어서션이다(SonarCloud javabugs:S2259). `getClientSecret()`은 **정말로**
    // null을 반환할 수 있다 — 퍼블릭/PKCE 클라이언트에는 시크릿이 없다(이 저장소의 알려진 게차:
    // 그 null을 무조건 문자열화하던 코드가 맨 NPE를 냈다). 여기서는 시크릿을 준 설정이므로
    // non-null이 계약이고, 그 계약을 명시하면 정적분석의 지적이 사라지면서 테스트 의도도 분명해진다.
    assertNotNull(returned, "시크릿을 준 설정은 방어복사본을 반환해야 한다");
    returned[0] = 'X';
    assertArrayEquals("s3cr3t".toCharArray(), c.getClientSecret());
  }
  @Test void clientSecret_defaultsToNull() {
    KeycloakConfig c = KeycloakConfig.builder().serverUrl("x").realm("r").clientId("app").build();
    assertNull(c.getClientSecret());
  }
  @Test void expectedAudience_defaultsToClientId() {
    // 미설정이면 기존 동작 그대로 — 기대 audience는 clientId다(하위 호환).
    KeycloakConfig c = KeycloakConfig.builder().serverUrl("x").realm("r").clientId("app").build();
    assertEquals("app", c.getExpectedAudience());
  }
  @Test void expectedAudience_customValueOverridesClientId() {
    // 기본 realm은 client-credentials 토큰의 aud에 client id를 넣지 않는다 — 리소스 서버 이름 등
    // 실제 발급되는 audience로 재정의할 수 있어야 한다.
    KeycloakConfig c = KeycloakConfig.builder().serverUrl("x").realm("r").clientId("app")
        .expectedAudience("my-api").build();
    assertEquals("my-api", c.getExpectedAudience());
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
