package io.github.xzawed.keycloak.admin;

import static org.junit.jupiter.api.Assertions.*;

import com.fasterxml.jackson.databind.ObjectMapper;
import io.github.xzawed.keycloak.core.KeycloakConfig;
import jakarta.ws.rs.client.Client;
import jakarta.ws.rs.core.MediaType;
import org.junit.jupiter.api.Test;
import org.keycloak.admin.client.JacksonProvider;
import org.keycloak.representations.idm.UserRepresentation;

/**
 * admin-client의 {@link JacksonProvider}가 우리가 만든 JAX-RS 클라이언트에 실제로 등록되는지,
 * 그리고 그 프로바이더가 실제로 null 필드를 생략하는지 잠근다.
 *
 * <p>배경: admin-client는 이 프로바이더를 <em>자기가 만든</em> 클라이언트에만 등록한다. 타임아웃
 * 주입을 위해 우리 클라이언트를 {@code resteasyClient(...)}로 넘기면 등록이 통째로 유실되고,
 * {@code NON_NULL} 직렬화와 {@code FAIL_ON_UNKNOWN_PROPERTIES=false} 역직렬화를 함께 잃는다.
 * 그 상태에서는 admin-client가 서버보다 앞선 필드를 갖는 순간(클라이언트/서버 버전 스큐) 우리가
 * {@code null}을 실어 보내 서버가 <em>Unrecognized field</em>로 400을 낸다 —
 * 26.0.11의 {@code UserRepresentation.verifiableCredentials}에서 실제로 발생했다.
 *
 * <p>두 테스트가 함께 있어야 의미가 있다. 등록 검사만으로는 프로바이더가 무엇을 하는지 증명하지
 * 못하고, 직렬화 검사만으로는 우리가 그것을 배선했는지 증명하지 못한다.
 */
class AdminJacksonProviderTest {

  private static KeycloakConfig config() {
    return KeycloakConfig.builder()
        .serverUrl("https://kc.example.com")
        .realm("r")
        .clientId("app")
        .clientSecret("s3cr3t".toCharArray())
        .build();
  }

  /** 배선: 타임아웃 클라이언트에 상류 프로바이더가 등록되어 있어야 한다. */
  @Test void timeoutClient_registersUpstreamJacksonProvider() {
    try (Client client = AdminClient.buildTimeoutClient(config())) {
      assertTrue(
          client.getConfiguration().isRegistered(JacksonProvider.class),
          "admin-client의 JacksonProvider가 등록되지 않았다 — resteasyClient(...) 주입이 상류 등록을 "
              + "우회하므로 buildTimeoutClient가 직접 등록해야 한다");
    }
  }

  /** 동작: 그 프로바이더의 매퍼는 설정되지 않은(null) 필드를 아예 내보내지 않아야 한다. */
  @Test void providerMapper_omitsNullFields_soVersionSkewCannotBreakWrites() throws Exception {
    ObjectMapper mapper =
        new JacksonProvider().locateMapper(UserRepresentation.class, MediaType.APPLICATION_JSON_TYPE);

    UserRepresentation sparse = new UserRepresentation();
    sparse.setUsername("alice");
    sparse.setEnabled(true);

    String json = mapper.writeValueAsString(sparse);

    assertFalse(json.contains("null"), "직렬화 결과에 null 값이 실렸다: " + json);
    assertTrue(json.contains("\"username\":\"alice\""), json);
    assertTrue(json.contains("\"enabled\":true"), json);
    // 설정하지 않은 필드는 키 자체가 없어야 한다 — 이것이 클라이언트/서버 스큐를 견디게 하는 성질이다.
    assertFalse(json.contains("\"email\""), json);
    assertFalse(json.contains("\"firstName\""), json);
  }

  /** 역방향: 서버가 우리 모델에 없는 필드를 반환해도 역직렬화가 깨지지 않아야 한다. */
  @Test void providerMapper_ignoresUnknownServerFields() throws Exception {
    ObjectMapper mapper =
        new JacksonProvider().locateMapper(UserRepresentation.class, MediaType.APPLICATION_JSON_TYPE);

    // 우리 representation에 존재하지 않는 필드를 서버가 보냈다고 가정한다(서버가 클라이언트보다 앞선 경우).
    String fromNewerServer = "{\"username\":\"bob\",\"someFieldFromAFutureKeycloak\":123}";

    UserRepresentation parsed =
        assertDoesNotThrow(() -> mapper.readValue(fromNewerServer, UserRepresentation.class));
    assertEquals("bob", parsed.getUsername());
  }
}
