package io.github.xzawed.keycloak.auth;

import static org.junit.jupiter.api.Assertions.assertEquals;

import io.github.xzawed.keycloak.core.KeycloakConfig;
import org.junit.jupiter.api.Test;

/**
 * `serverUrl`의 후행 슬래시 정규화를 고정한다.
 *
 * <p>왜 지금 쓰는가: 이 동작은 지금까지 **테스트가 없었다**(`OidcMetadata`를 직접 겨눈 테스트 파일이
 * 없었고, `AuthClient*Test`들은 `forRealm`을 호출만 한다). 구현을 정규식
 * {@code replaceAll("/+$", "")}에서 선형 트림으로 바꾸기 전에 먼저 현행 동작을 고정해, 변경이
 * 동작을 보존하는지 확인할 수 있게 한다.
 *
 * <p>⚠️ **슬래시 여러 개 케이스가 핵심이다.** 정규식 {@code /+$}는 후행 슬래시를 **전부** 지운다 —
 * 하나만 지우는 구현으로 바꾸면 조용히 달라진다. 단일 슬래시만 검사하면 그 차이를 못 잡는다.
 */
class OidcMetadataTest {

  private static KeycloakConfig config(String serverUrl) {
    return KeycloakConfig.builder().serverUrl(serverUrl).realm("demo").clientId("app").build();
  }

  @Test
  void forRealm_noTrailingSlash_isUnchanged() {
    OidcMetadata m = OidcMetadata.forRealm(config("https://kc.example.com"));
    assertEquals("https://kc.example.com/realms/demo", m.getIssuer());
  }

  @Test
  void forRealm_singleTrailingSlash_isStripped() {
    OidcMetadata m = OidcMetadata.forRealm(config("https://kc.example.com/"));
    assertEquals("https://kc.example.com/realms/demo", m.getIssuer());
  }

  @Test
  void forRealm_multipleTrailingSlashes_areAllStripped() {
    OidcMetadata m = OidcMetadata.forRealm(config("https://kc.example.com////"));
    assertEquals("https://kc.example.com/realms/demo", m.getIssuer());
  }

  @Test
  void forRealm_interiorSlashesSurvive_onlyTheTailIsTrimmed() {
    // 경로가 있는 배포(리버스 프록시 뒤 /auth 서브패스)에서 내부 슬래시를 건드리면 안 된다.
    OidcMetadata m = OidcMetadata.forRealm(config("https://kc.example.com/auth//"));
    assertEquals("https://kc.example.com/auth/realms/demo", m.getIssuer());
  }

  @Test
  void forRealm_derivedEndpoints_hangOffTheNormalizedIssuer() {
    OidcMetadata m = OidcMetadata.forRealm(config("https://kc.example.com//"));
    String oc = "https://kc.example.com/realms/demo/protocol/openid-connect";
    assertEquals(oc + "/auth", m.getAuthorizationEndpoint().toString());
    assertEquals(oc + "/token", m.getTokenEndpoint().toString());
    assertEquals(oc + "/token/introspect", m.getIntrospectionEndpoint().toString());
    assertEquals(oc + "/logout", m.getEndSessionEndpoint().toString());
    assertEquals(oc + "/certs", m.getJwksUri().toString());
  }
}
