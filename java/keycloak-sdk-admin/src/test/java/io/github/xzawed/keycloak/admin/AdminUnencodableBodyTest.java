package io.github.xzawed.keycloak.admin;

import static java.nio.charset.StandardCharsets.UTF_8;
import static org.junit.jupiter.api.Assertions.*;

import com.fasterxml.jackson.databind.node.JsonNodeFactory;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.sun.net.httpserver.HttpServer;
import io.github.xzawed.keycloak.core.KeycloakConfig;
import io.github.xzawed.keycloak.core.exception.KeycloakTransportException;
import java.io.IOException;
import java.math.BigDecimal;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.time.Duration;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.function.Consumer;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.keycloak.representations.idm.ClientPolicyExecutorRepresentation;
import org.keycloak.representations.idm.ClientProfileRepresentation;
import org.keycloak.representations.idm.ClientProfilesRepresentation;
import org.keycloak.representations.idm.GroupRepresentation;
import org.keycloak.representations.idm.RealmRepresentation;
import org.keycloak.representations.idm.UserProfileAttributeMetadata;
import org.keycloak.representations.idm.UserProfileMetadata;
import org.keycloak.representations.idm.UserRepresentation;

/**
 * admin 쓰기 본문이 JSON 으로 그대로 실리지 못하면 요청 전에 {@link KeycloakTransportException} 이고 문구는 아홉 언어 공통이다(등록부
 * {@code admin-unencodable-body-residuals}). admin-client 의 Jackson 은 자유 형식 칸(Map&lt;String, Object&gt; · JsonNode)의 NaN ·
 * ±Infinity 를 던지지 않고 <b>문자열</b> {@code "NaN"} · {@code "Infinity"} 로 써(QUOTE_NON_NUMERIC_NUMBERS) 호출자가 보내지 않은 값이
 * 나갔다. 수가 아닌 값으로 바뀐 것이다. 다섯 표현에 double · float 필드는 없고(javap) 수를 쥘 수 있는 칸은 자유 형식 칸이다 — 사용자
 * 프로필 메타데이터의 annotations · validators(realm 의 users 로도 닿는다)와 realm 의 client profile · policy(JsonNode).
 *
 * <p>쓸 수 없는 표현(순환)도 같은 계약이다 — 전에는 토큰을 받은 뒤 본문을 쓰다 「admin transport failure」였다. 짝 없는 서로게이트는
 * Jackson 이 {@code \uD800} 이스케이프로 그대로 싣는다 — 받는다(대조군).
 *
 * <p>서버는 JDK HttpServer 로 받은 토큰 요청 · admin 요청(메서드 · 경로 · 본문)을 적는다. admin 클라이언트는 토큰을 첫 요청에서 받으므로
 * 새 클라이언트의 거부된 쓰기는 요청이 0 이다.
 */
class AdminUnencodableBodyTest {
  private static final String UNENCODABLE = "admin request failed: the request body could not be encoded as JSON";
  private static final String REALM = "r";
  private static final byte[] TOKEN =
      "{\"access_token\":\"good\",\"token_type\":\"Bearer\",\"expires_in\":300}".getBytes(UTF_8);

  private HttpServer server;
  private final List<String> tokenRequests = new CopyOnWriteArrayList<>();
  /** 받은 admin 요청 — 「메서드 경로 본문」. */
  private final List<String> adminRequests = new CopyOnWriteArrayList<>();

  @BeforeEach
  void start() throws IOException {
    server = HttpServer.create(new InetSocketAddress(InetAddress.getLoopbackAddress(), 0), 0);
    server.createContext("/", exchange -> {
      String body = new String(exchange.getRequestBody().readAllBytes(), UTF_8);
      String path = exchange.getRequestURI().getPath();
      if (path.endsWith("/protocol/openid-connect/token")) {
        tokenRequests.add(path);
        exchange.getResponseHeaders().add("Content-Type", "application/json");
        exchange.sendResponseHeaders(200, TOKEN.length);
        exchange.getResponseBody().write(TOKEN);
      } else {
        adminRequests.add(exchange.getRequestMethod() + " " + path + " " + body);
        if ("POST".equals(exchange.getRequestMethod())) {
          exchange.getResponseHeaders().add("Location", "http://127.0.0.1" + path + "/new-id");
          exchange.sendResponseHeaders(201, -1);
        } else {
          exchange.sendResponseHeaders(204, -1);
        }
      }
      exchange.close();
    });
    server.start();
  }

  @AfterEach
  void stop() {
    server.stop(0);
  }

  private AdminClient admin() {
    return new AdminClient(KeycloakConfig.builder().serverUrl("http://127.0.0.1:" + server.getAddress().getPort())
        .realm(REALM).clientId("app").clientSecret("s3cr3t".toCharArray())
        .connectTimeout(Duration.ofSeconds(5)).readTimeout(Duration.ofSeconds(5)).build());
  }

  /** 사용자 프로필 메타데이터 하나 — annotations 와 validators 둘 다 자유 형식 칸이다. */
  private static UserRepresentation userWith(Map<String, Object> annotations, Map<String, Map<String, Object>> validators) {
    UserRepresentation user = new UserRepresentation();
    user.setUsername("alice");
    user.setUserProfileMetadata(new UserProfileMetadata(List.of(
        new UserProfileAttributeMetadata("a", "A", false, false, null, annotations, validators, false, null)), List.of()));
    return user;
  }

  private static Map<String, Object> one(String key, Object value) {
    Map<String, Object> map = new HashMap<>();
    map.put(key, value);
    return map;
  }

  /** realm 의 client profile 하나 — 실행기 설정은 JsonNode 다(setParsedClientProfiles 가 convertValue 로 JsonNode 를 만든다). */
  private static ClientProfilesRepresentation profilesWith(Object value) {
    ObjectNode configuration = JsonNodeFactory.instance.objectNode();
    if (value instanceof Float f) {
      configuration.put("n", f);
    } else {
      configuration.put("n", (Double) value);
    }
    ClientPolicyExecutorRepresentation executor = new ClientPolicyExecutorRepresentation();
    executor.setExecutorProviderId("x");
    executor.setConfiguration(configuration);
    ClientProfileRepresentation profile = new ClientProfileRepresentation();
    profile.setName("p");
    profile.setExecutors(List.of(executor));
    ClientProfilesRepresentation profiles = new ClientProfilesRepresentation();
    profiles.setProfiles(List.of(profile));
    return profiles;
  }

  /** 수를 쥐는 쓰기 다섯 — 자리가 서로 다르다(annotations · validators 안 · 목록 안 · realm 의 사용자 안 · JsonNode 안). */
  private static List<Map.Entry<String, Consumer<AdminClient>>> writes(Object value) {
    return List.of(
        Map.entry("users.create annotations", a -> a.users().create(userWith(one("n", value), Map.of()))),
        Map.entry("users.update validators", a -> a.users().update("x", userWith(Map.of(), Map.of("length", one("max", value))))),
        Map.entry("realms.create users[].annotations list", a -> {
          RealmRepresentation realm = new RealmRepresentation();
          realm.setRealm("r2");
          realm.setUsers(List.of(userWith(one("n", new ArrayList<>(List.of(1, value))), Map.of())));
          a.realms().create(realm);
        }),
        Map.entry("realms.update users[].validators", a -> {
          RealmRepresentation realm = new RealmRepresentation();
          realm.setUsers(List.of(userWith(Map.of(), Map.of("length", one("min", value)))));
          a.realms().update("r2", realm);
        }),
        Map.entry("realms.update clientProfiles JsonNode", a -> {
          RealmRepresentation realm = new RealmRepresentation();
          realm.setParsedClientProfiles(profilesWith(value));
          a.realms().update("r2", realm);
        }));
  }

  @Test
  void aNonFiniteNumber_isRefusedBeforeAnyRequest() {
    List<String> wrong = new ArrayList<>();
    for (Object value : List.of(Double.NaN, Double.POSITIVE_INFINITY, Double.NEGATIVE_INFINITY, Float.NaN,
        Float.NEGATIVE_INFINITY)) {
      for (Map.Entry<String, Consumer<AdminClient>> write : writes(value)) {
        tokenRequests.clear();
        adminRequests.clear();
        Throwable thrown;
        try (AdminClient admin = admin()) {
          write.getValue().accept(admin);
          thrown = null;
        } catch (Throwable t) {
          thrown = t;
        }
        if (!(thrown instanceof KeycloakTransportException) || !UNENCODABLE.equals(thrown.getMessage())
            || !adminRequests.isEmpty() || !tokenRequests.isEmpty()) {
          wrong.add(write.getKey() + " " + value + " → " + (thrown == null ? "returned" : thrown.getClass().getSimpleName()
              + ": " + thrown.getMessage()) + " · token requests " + tokenRequests.size() + " · admin requests " + adminRequests);
        }
      }
    }
    assertEquals(List.of(), wrong, () -> String.join("\n", wrong));
  }

  /** 순환 — Jackson 이 쓸 수 없는 표현도 같은 계약이다(토큰 · admin 요청 0). */
  @Test
  void aBodyJacksonCannotWrite_isRefusedBeforeAnyRequest() {
    GroupRepresentation group = new GroupRepresentation();
    group.setName("g");
    group.setSubGroups(List.of(group));
    try (AdminClient admin = admin()) {
      Throwable thrown = assertThrows(Throwable.class, () -> admin.groups().create(group));
      assertEquals(KeycloakTransportException.class.getName() + ": " + UNENCODABLE,
          thrown.getClass().getName() + ": " + thrown.getMessage());
      assertEquals(List.of(), adminRequests);
      assertEquals(List.of(), tokenRequests);
    }
  }

  /**
   * 대조군 — 그대로 실리는 값은 그대로 나간다: 유한한 수 · double 을 넘는 BigDecimal(JSON 수로 그대로 — 거부하지 않는다) · 짝 없는
   * 서로게이트(Jackson 이 {@code \uD800} 로 이스케이프한다).
   */
  @Test
  void whatJsonCarriesFaithfully_goesOut() {
    UserRepresentation user = userWith(one("n", new ArrayList<>(List.of(1.5, Double.MAX_VALUE, new BigDecimal("1e400")))), Map.of());
    user.setUsername("x\ud800");
    try (AdminClient admin = admin()) {
      admin.users().update("x", user);
    }
    assertEquals(1, adminRequests.size(), adminRequests::toString);
    String sent = adminRequests.get(0);
    assertTrue(sent.startsWith("PUT /admin/realms/r/users/x "), sent);
    assertTrue(sent.contains("\"username\":\"x\\uD800\""), sent);
    assertTrue(sent.contains("\"annotations\":{\"n\":[1.5,1.7976931348623157E308,1E+400]}"), sent);
  }
}
