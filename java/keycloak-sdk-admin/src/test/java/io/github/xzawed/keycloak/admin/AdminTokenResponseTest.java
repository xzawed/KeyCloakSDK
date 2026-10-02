package io.github.xzawed.keycloak.admin;

import static org.junit.jupiter.api.Assertions.*;

import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;
import io.github.xzawed.keycloak.core.KeycloakConfig;
import io.github.xzawed.keycloak.core.exception.KeycloakTransportException;
import java.io.IOException;
import java.io.OutputStream;
import java.io.PrintWriter;
import java.io.StringWriter;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Deque;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.keycloak.representations.idm.UserRepresentation;

/**
 * admin 레인의 토큰 응답 계약 — admin 은 토큰을 자체 소유하고(§4) keycloak-admin-client 내장 TokenManager 가 그 응답을
 * Jackson 으로 읽는다. 계약: 쓸 수 없는 {@code access_token}(누락·null·숫자·불리언·빈 문자열·객체·배열)이면 **admin API
 * 요청을 하나도 보내지 않고** {@link KeycloakTransportException} 으로 실패한다 — 오늘 null·객체·배열·누락이 이미 그렇게
 * 실패하던 타입이다. 쓸 수 있는 문자열 토큰은 그대로 동작하고, TokenManager 의 갱신(refresh_token 그랜트)도 같은 검사를
 * 받는다.
 *
 * <p>⚠️ 가짜 admin 엔드포인트는 <b>성공</b>(200 사용자)을 낸다 — 강제변환된 토큰으로 나간 요청이 404 로 우연히 실패해
 * 결함이 「실패했으니 됐다」로 가려지지 않게. 판정의 무게는 「admin 요청 0 건」이 진다(적대 행렬 W3a 와 같은 기준).
 * 네트워크는 로컬 루프백만 쓴다(Docker 불필요).
 */
class AdminTokenResponseTest {
  private static final String REALM = "r";
  private static final String TOKEN_PATH = "/realms/" + REALM + "/protocol/openid-connect/token";
  private static final String MISSING = "(missing)";

  private HttpServer server;
  /** 토큰 엔드포인트가 차례로 낼 응답 — 마지막 것은 계속 낸다. */
  private final Deque<Reply> tokenReplies = new ArrayDeque<>();
  private final List<String> grants = new ArrayList<>();
  /** admin 엔드포인트에 닿은 요청(메서드 경로 · Authorization). */
  private final List<String> adminHits = new ArrayList<>();

  private record Reply(int status, String body) {}

  @BeforeEach void start() throws IOException {
    server = HttpServer.create(new InetSocketAddress(InetAddress.getLoopbackAddress(), 0), 0);
    server.createContext("/", this::handle);
    server.start();
  }

  @AfterEach void stop() {
    server.stop(0);
  }

  private synchronized void handle(HttpExchange ex) throws IOException {
    String path = ex.getRequestURI().getPath();
    String body = new String(ex.getRequestBody().readAllBytes(), StandardCharsets.UTF_8);
    if (path.equals(TOKEN_PATH)) {
      grants.add(form(body).getOrDefault("grant_type", "?"));
      Reply r = tokenReplies.size() > 1 ? tokenReplies.poll() : tokenReplies.peek();
      send(ex, r.status(), r.body());
    } else if (path.startsWith("/admin/realms/" + REALM + "/users")) {
      adminHits.add(ex.getRequestMethod() + " " + path + " · " + ex.getRequestHeaders().getFirst("Authorization"));
      if (ex.getRequestMethod().equals("POST")) {
        ex.getResponseHeaders().add("Location", "http://127.0.0.1/admin/realms/" + REALM + "/users/new-id");
        send(ex, 201, null);
      } else {
        send(ex, 200, "{\"id\":\"x\",\"username\":\"alice\"}");
      }
    } else {
      send(ex, 404, "{\"error\":\"not found\"}");
    }
  }

  private static void send(HttpExchange ex, int status, String body) throws IOException {
    if (body == null) {
      ex.sendResponseHeaders(status, -1);
      ex.close();
      return;
    }
    byte[] bytes = body.getBytes(StandardCharsets.UTF_8);
    ex.getResponseHeaders().add("Content-Type", "application/json");
    ex.sendResponseHeaders(status, bytes.length);
    try (OutputStream os = ex.getResponseBody()) {
      os.write(bytes);
    }
  }

  private static Map<String, String> form(String body) {
    Map<String, String> out = new LinkedHashMap<>();
    for (String kv : body.split("&")) {
      int eq = kv.indexOf('=');
      if (eq > 0) out.put(kv.substring(0, eq), kv.substring(eq + 1));
    }
    return out;
  }

  private AdminClient admin() {
    return new AdminClient(KeycloakConfig.builder().serverUrl("http://127.0.0.1:" + server.getAddress().getPort())
        .realm(REALM).clientId("app").clientSecret("s3cr3t".toCharArray())
        .connectTimeout(Duration.ofSeconds(5)).readTimeout(Duration.ofSeconds(5)).build());
  }

  private static String tokenBody(String rawAccessToken, String extra) {
    String at = rawAccessToken.equals(MISSING) ? "" : "\"access_token\":" + rawAccessToken + ",";
    return "{" + at + "\"token_type\":\"Bearer\",\"expires_in\":300" + extra + "}";
  }

  private synchronized void reset(Reply... replies) {
    tokenReplies.clear();
    tokenReplies.addAll(List.of(replies));
    grants.clear();
    adminHits.clear();
  }

  private synchronized List<String> adminHits() {
    return List.copyOf(adminHits);
  }

  private synchronized List<String> grants() {
    return List.copyOf(grants);
  }

  /** 같은 응답에 실린 refresh_token — 거부 오류의 어느 표현에도 찍히면 안 된다. */
  private static final String RT_CANARY = "ZadminRT-0123456789abcdef";

  @Test void unusableAccessToken_sendsNoAdminRequest_andFailsAsTransport() {
    List<String> table = new ArrayList<>();
    List<String> wrong = new ArrayList<>();
    // 마지막 행은 중복 키 — 결합은 마지막 값(숫자)을 쓴다(첫 값만 보는 검사는 여기서 Bearer 12345 로 나아간다).
    for (String raw : List.of("12345", "true", "\"\"", "null", "{\"v\":\"x\"}", "[\"x\"]", MISSING,
        "\"AT\",\"access_token\":12345")) {
      reset(new Reply(200, tokenBody(raw, ",\"refresh_token\":\"" + RT_CANARY + "\"")));
      Throwable thrown;
      try (AdminClient admin = admin()) {
        admin.users().get("x");
        thrown = null;
      } catch (Throwable t) {
        thrown = t;
      }
      List<String> hits = adminHits();
      table.add(String.format("access_token %-12s → %s · grants %s · admin %s", raw,
          thrown == null ? "성공" : thrown.getClass().getSimpleName() + "(" + thrown.getMessage() + ")", grants(), hits));
      if (!(thrown instanceof KeycloakTransportException) || !"admin transport failure".equals(thrown.getMessage())) {
        wrong.add(raw + ": KeycloakTransportException(admin transport failure) 가 아니다 — "
            + (thrown == null ? "성공" : thrown.getClass().getName()));
      }
      if (!hits.isEmpty()) wrong.add(raw + ": 쓸 수 없는 토큰으로 admin 요청이 나갔다 — " + hits);
      if (grants().size() != 1) wrong.add(raw + ": 토큰 요청이 정확히 한 번이 아니다 — " + grants());
      if (thrown == null) continue;
      // §4 — 원인 사슬에 하위 라이브러리 인스턴스가 없고(파서 사슬은 타입 이름만 남긴 사본이다), 응답을 인용하지 않는다.
      for (Throwable c = thrown.getCause(); c != null; c = c.getCause()) {
        if (!c.getClass().getName().startsWith("java.")) wrong.add(raw + ": 원인 사슬에 하위 타입이 샜다 — " + c.getClass());
      }
      StringWriter trace = new StringWriter();
      thrown.printStackTrace(new PrintWriter(trace, true));
      if (trace.toString().contains(RT_CANARY.substring(0, 10))) wrong.add(raw + ": 오류가 응답의 refresh_token 을 찍었다");
    }
    System.out.println("[AdminTokenResponseTest]\n  " + String.join("\n  ", table));
    assertTrue(wrong.isEmpty(), () -> wrong.size() + " 건:\n" + String.join("\n", wrong));
  }

  /** 대조 — 같은 경로에서 문자열 토큰은 GET·POST 둘 다 admin 에 닿는다(위 실패가 다른 원인이 아님을 보인다). */
  @Test void stringAccessToken_reachesAdmin_forReadsAndWrites() {
    reset(new Reply(200, tokenBody("\"AT-1\"", "")));
    try (AdminClient admin = admin()) {
      assertEquals("alice", admin.users().get("x").orElseThrow().getUsername());
      UserRepresentation u = new UserRepresentation();
      u.setUsername("bob");
      assertEquals("new-id", admin.users().create(u));
    }
    assertEquals(List.of("client_credentials"), grants(), "토큰은 캐시되어 한 번만 부여돼야 한다");
    assertEquals(List.of("GET /admin/realms/r/users/x · Bearer AT-1", "POST /admin/realms/r/users · Bearer AT-1"),
        adminHits());
  }

  /** TokenManager 의 갱신(refresh_token 그랜트) 응답도 같은 검사를 받는다 — 쓸 수 있으면 새 토큰으로 나아간다. */
  @Test void refreshedStringAccessToken_isUsed() {
    String first = tokenBody("\"AT-1\"", ",\"refresh_token\":\"RT-1\",\"refresh_expires_in\":300")
        .replace("\"expires_in\":300", "\"expires_in\":1");
    reset(new Reply(200, first), new Reply(200, tokenBody("\"AT-2\"", "")));
    try (AdminClient admin = admin()) {
      admin.users().get("x");
      admin.users().get("x"); // expires_in 1 < TokenManager 최소 유효기간(30s) — 갱신한다
    }
    assertEquals(List.of("client_credentials", "refresh_token"), grants());
    assertEquals(List.of("GET /admin/realms/r/users/x · Bearer AT-1", "GET /admin/realms/r/users/x · Bearer AT-2"),
        adminHits());
  }

  @Test void refreshedUnusableAccessToken_sendsNoAdminRequest() {
    String first = tokenBody("\"AT-1\"", ",\"refresh_token\":\"RT-1\",\"refresh_expires_in\":300")
        .replace("\"expires_in\":300", "\"expires_in\":1");
    reset(new Reply(200, first), new Reply(200, tokenBody("12345", "")));
    try (AdminClient admin = admin()) {
      admin.users().get("x");
      KeycloakTransportException e = assertThrows(KeycloakTransportException.class, () -> admin.users().get("x"));
      assertEquals("admin transport failure", e.getMessage());
    }
    assertEquals(List.of("client_credentials", "refresh_token"), grants());
    assertEquals(List.of("GET /admin/realms/r/users/x · Bearer AT-1"), adminHits(), "갱신된 숫자 토큰으로 나아갔다");
  }

  /**
   * 오류 상태의 토큰 응답은 검사하지 않고 TokenManager 에 그대로 넘긴다 — 갱신이 400 이면 TokenManager 가
   * {@code BadRequestException} 을 받아 client_credentials 로 다시 부여한다(admin-client 의 복구 경로). 검사가 오류 본문
   * (access_token 없음)까지 거부하면 그 예외가 바뀌어 복구가 끊긴다.
   */
  @Test void tokenErrorStatus_isLeftToTokenManager() {
    String first = tokenBody("\"AT-1\"", ",\"refresh_token\":\"RT-1\",\"refresh_expires_in\":300")
        .replace("\"expires_in\":300", "\"expires_in\":1");
    reset(new Reply(200, first), new Reply(400, "{\"error\":\"invalid_grant\"}"), new Reply(200, tokenBody("\"AT-3\"", "")));
    try (AdminClient admin = admin()) {
      admin.users().get("x");
      admin.users().get("x");
    }
    assertEquals(List.of("client_credentials", "refresh_token", "client_credentials"), grants());
    assertEquals(List.of("GET /admin/realms/r/users/x · Bearer AT-1", "GET /admin/realms/r/users/x · Bearer AT-3"),
        adminHits());
  }
}
