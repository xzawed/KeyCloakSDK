package io.github.xzawed.keycloak;

import static org.junit.jupiter.api.Assertions.*;

import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;
import io.github.xzawed.keycloak.auth.ClientCredentialsTokenProvider;
import io.github.xzawed.keycloak.core.KeycloakConfig;
import io.github.xzawed.keycloak.core.exception.KeycloakAuthException;
import io.github.xzawed.keycloak.core.exception.KeycloakNotFoundException;
import io.github.xzawed.keycloak.core.exception.KeycloakTransportException;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.OutputStream;
import java.io.PrintWriter;
import java.io.StringWriter;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.ServerSocket;
import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.time.Clock;
import java.time.Duration;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Deque;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

/**
 * 토큰·introspection 응답의 오류 계급(등록부 token-response-class-divergent) — <b>끝까지 온</b> 응답을 쓸 수 없으면 SDK 의
 * {@link KeycloakAuthException}, 끝까지 오지 <b>않은</b> 응답(네트워크 실패 · 타임아웃 · 1,048,576 바이트 상한 초과 · 깨진 틀)은
 * {@link KeycloakTransportException} 이다. 공개 API 만 쓴다.
 *
 * <p>칸: S1 = {@code auth().clientCredentialsToken()} · S2 = {@link ClientCredentialsTokenProvider}(S1 을 지난다) · IN =
 * {@code auth().introspect()} · S5 = admin 파사드의 자기 토큰 그랜트(keycloak-admin-client 의 TokenManager — RESTEasy 의
 * {@code BearerAuthFilter} 안). 수정 전 실측(main 219a4667): S1·S2·IN 은 JSON 문자열 안의 잘못된 UTF-8(0xFF 0xFE)을 U+FFFD 로
 * 바꿔 <b>받아들였고</b>, 설명 없는 오류 응답(JSON 이 아닌 503·400)은 「… failed: null」 이었고, S5 는 끝까지 온 실패 응답 전부를
 * 전송 오류로 냈다(토큰 엔드포인트의 404 도).
 *
 * <p>대조(바뀌지 않는다): 좋은 그랜트 · {@code application/json} 의 모르는 charset(RFC 8259 §11 — 효과 없음) · 유효한 비 ASCII ·
 * 오류 본문의 잘못된 UTF-8(판정은 상태가 한다) · logout · 상한 초과 · 연결 거부 · 타임아웃 · 좋은 그랜트 뒤 admin REST 404 ·
 * 갱신 400 뒤 다시 부여(TokenManager 의 복구 경로).
 *
 * <p>⚠️ S5 의 오류 본문은 그 요청의 클라이언트 시크릿을 되울린다 — 메시지는 상태만 싣고, 원인 사슬은 걸러진다(어느 표현에도 시크릿이
 * 찍히면 안 된다).
 */
class TokenResponseClassTest {
  private static final String REALM = "r";
  private static final String OIDC = "/realms/" + REALM + "/protocol/openid-connect";
  private static final String ADMIN_USER = "/admin/realms/" + REALM + "/users/x";
  private static final String SECRET = "ZclsSECRET-0123456789abcdef";
  private static final String RT_CANARY = "ZclsRT-0123456789abcdef";
  private static final URI CB = URI.create("https://app.example/cb");
  private static final String VERIFIER = "ZclsVERIFIER-0123456789abcdefghijklmnopqrstuvwxyz";
  /** 상한 — SDK 상수를 빌리지 않는다(빌리면 그 값이 바뀌어도 시험이 따라 움직인다). */
  private static final int CAP = 1_048_576;
  /** JSON 문자열 안의 잘못된 UTF-8 — 0xFF 0xFE 는 UTF-8 의 어느 자리에도 올 수 없다. */
  private static final byte[] INVALID = {(byte) 0xFF, (byte) 0xFE};
  private static final String UNKNOWN_CHARSET = "application/json; charset=x-unknown-kc";

  /** 응답 하나 — {@code type} 이 null 이면 Content-Type 을 달지 않고 {@code body} 가 null 이면 본문이 없다. */
  private static final class Reply {
    final int status;
    final String type;
    final byte[] body;
    final int delayMs;

    Reply(int status, String type, byte[] body, int delayMs) {
      this.status = status;
      this.type = type;
      this.body = body;
      this.delayMs = delayMs;
    }

    @Override public String toString() {
      return status + " " + type + " (" + (body == null ? "no body" : body.length + " bytes") + ")";
    }
  }

  private static byte[] utf8(String s) {
    return s.getBytes(StandardCharsets.UTF_8);
  }

  private static byte[] concat(byte[]... parts) {
    ByteArrayOutputStream out = new ByteArrayOutputStream();
    for (byte[] p : parts) out.write(p, 0, p.length);
    return out.toByteArray();
  }

  private static Reply json(int status, String body) {
    return new Reply(status, "application/json", utf8(body), 0);
  }

  private static Reply typed(int status, String type, byte[] body) {
    return new Reply(status, type, body, 0);
  }

  private static String token(String accessToken) {
    return "{\"access_token\":\"" + accessToken + "\",\"token_type\":\"Bearer\",\"expires_in\":300,\"refresh_token\":\""
        + RT_CANARY + "\"}";
  }

  /** access_token 안에 잘못된 UTF-8 이 든 200 토큰 응답. */
  private static Reply tokenWithInvalidUtf8() {
    return tokenWith("ok", INVALID);
  }

  /** access_token 이 {@code head} 다음 {@code bad} 바이트를 품은 200 토큰 응답. */
  private static Reply tokenWith(String head, byte[] bad) {
    return typed(200, "application/json", concat(utf8("{\"access_token\":\"" + head), bad,
        utf8("vc\",\"token_type\":\"Bearer\",\"expires_in\":300,\"refresh_token\":\"" + RT_CANARY + "\"}")));
  }

  /**
   * 잘못된 UTF-8 의 두 꼴 더 — 겹침 꼴({@code C1 81} = 'A' 를 두 바이트로 — Jackson 의 바이트 파서는 받아들여 admin 이 {@code Bearer
   * goodA} 를 보냈다, 독립 레그 실측)과 디코더의 4 KiB 버퍼를 넘긴 뒤의 잘못된 바이트(첫 4096 글자만 재는 검사가 놓친다).
   */
  private static final Map<String, Reply> MORE_INVALID_UTF8 = Map.of(
      "겹침 꼴", tokenWith("good", new byte[] {(byte) 0xC1, (byte) 0x81}),
      "4096 글자 뒤", tokenWith("a".repeat(5_000), INVALID));

  /** username 안에 잘못된 UTF-8 이 든 200 introspection 응답. */
  private static Reply introspectionWithInvalidUtf8() {
    return typed(200, "application/json",
        concat(utf8("{\"active\":true,\"username\":\"s"), INVALID, utf8("vc\",\"client_id\":\"app\"}")));
  }

  /** 정확히 {@code size} 바이트 — {@code json} 뒤를 JSON 공백으로 채운다. */
  private static byte[] padTo(String json, int size) {
    byte[] out = new byte[size];
    Arrays.fill(out, (byte) ' ');
    byte[] head = utf8(json);
    System.arraycopy(head, 0, out, 0, head.length);
    return out;
  }

  /** 오류 본문 — error_description 이 그 요청의 클라이언트 시크릿을 되울린다. */
  private static Reply echoing(int status, String error) {
    return json(status, "{\"error\":\"" + error + "\",\"error_description\":\"rejected " + SECRET + "\"}");
  }

  private HttpServer server;
  private ExecutorService handlers;
  private final Deque<Reply> tokenReplies = new ArrayDeque<>();
  private Reply introspectReply = json(200, "{\"active\":true,\"username\":\"svc\",\"client_id\":\"app\"}");
  private Reply logoutReply = new Reply(204, null, null, 0);
  private Reply adminReply = json(200, "{\"id\":\"x\",\"username\":\"alice\"}");
  private final List<String> grants = new ArrayList<>();
  private int adminHits;

  @BeforeEach void start() throws IOException {
    server = HttpServer.create(new InetSocketAddress(InetAddress.getLoopbackAddress(), 0), 0);
    handlers = Executors.newCachedThreadPool();
    server.setExecutor(handlers);
    server.createContext("/", this::handle);
    server.start();
  }

  @AfterEach void stop() {
    server.stop(0);
    handlers.shutdownNow();
  }

  private void handle(HttpExchange ex) throws IOException {
    String path = ex.getRequestURI().getPath();
    String form = new String(ex.getRequestBody().readAllBytes(), StandardCharsets.UTF_8);
    Reply r;
    synchronized (this) {
      if (path.equals(OIDC + "/token")) {
        grants.add(form.contains("grant_type=refresh_token") ? "refresh_token"
            : form.contains("grant_type=client_credentials") ? "client_credentials" : "other");
        r = tokenReplies.size() > 1 ? tokenReplies.poll() : tokenReplies.peek();
      } else if (path.equals(OIDC + "/token/introspect")) {
        r = introspectReply;
      } else if (path.equals(OIDC + "/logout")) {
        r = logoutReply;
      } else if (path.equals(ADMIN_USER)) {
        adminHits++;
        r = adminReply;
      } else {
        r = json(404, "{\"error\":\"not found\"}");
      }
    }
    send(ex, r);
  }

  private static void send(HttpExchange ex, Reply r) {
    try {
      if (r.delayMs > 0) Thread.sleep(r.delayMs);
      if (r.type != null) ex.getResponseHeaders().add("Content-Type", r.type);
      if (r.body == null || r.body.length == 0) {
        ex.sendResponseHeaders(r.status, -1);
      } else {
        ex.sendResponseHeaders(r.status, r.body.length);
        try (OutputStream os = ex.getResponseBody()) {
          os.write(r.body);
        }
      }
    } catch (InterruptedException e) {
      Thread.currentThread().interrupt();
    } catch (IOException clientLeft) {
      // 클라이언트가 끊었다 — 상한에서, 또는 타임아웃 뒤
    } finally {
      ex.close();
    }
  }

  private synchronized void tokens(Reply... replies) {
    tokenReplies.clear();
    tokenReplies.addAll(List.of(replies));
    grants.clear();
    adminHits = 0;
  }

  private synchronized int adminHits() {
    return adminHits;
  }

  private synchronized List<String> grants() {
    return List.copyOf(grants);
  }

  private KeycloakConfig config(int port, Duration readTimeout) {
    return KeycloakConfig.builder().serverUrl("http://127.0.0.1:" + port).realm(REALM).clientId("app")
        .clientSecret(SECRET.toCharArray()).connectTimeout(Duration.ofSeconds(5)).readTimeout(readTimeout).build();
  }

  private KeycloakConfig config() {
    return config(server.getAddress().getPort(), Duration.ofSeconds(5));
  }

  @FunctionalInterface
  private interface Call {
    Object run(KeycloakClient kc);
  }

  private static final Call CC = kc -> kc.auth().clientCredentialsToken().getAccessToken();
  private static final Call PROV = kc ->
      new ClientCredentialsTokenProvider(kc.auth(), Clock.systemUTC(), Duration.ofSeconds(30)).getAccessToken();
  private static final Call RF = kc -> kc.auth().refresh("rt-1").getAccessToken();
  private static final Call EX = kc -> kc.auth().exchangeCode("code-1", CB, VERIFIER).getAccessToken();
  private static final Call IN = kc -> kc.auth().introspect("tok-1").getUsername().orElse(null);
  private static final Call ADMIN = kc -> kc.admin().users().get("x").orElseThrow().getUsername();

  /** 결과 — 돌려받은 값이나 던진 것. */
  private record Outcome(Object value, Throwable thrown) {
    @Override public String toString() {
      return thrown == null ? "성공(" + value + ")" : thrown.getClass().getSimpleName() + "(" + thrown.getMessage() + ")";
    }
  }

  private Outcome call(KeycloakConfig config, Call call) {
    try (KeycloakClient kc = KeycloakClient.create(config)) {
      return new Outcome(call.run(kc), null);
    } catch (RuntimeException e) {
      return new Outcome(null, e);
    }
  }

  private Outcome call(Call call) {
    return call(config(), call);
  }

  private static String trace(Throwable t) {
    StringWriter out = new StringWriter();
    t.printStackTrace(new PrintWriter(out, true));
    return out.toString();
  }

  /** {@code o} 가 정확히 그 타입·메시지의 실패이고, 어느 표현도 시크릿·응답의 refresh_token 을 찍지 않는다. */
  private static void expect(String label, Outcome o, Class<? extends RuntimeException> type, String message,
                             List<String> wrong) {
    if (!type.isInstance(o.thrown()) || !message.equals(o.thrown().getMessage())) {
      wrong.add(label + ": " + type.getSimpleName() + "(" + message + ") 가 아니다 — " + o);
      return;
    }
    for (String printed : List.of(o.thrown().toString(), trace(o.thrown()))) {
      if (printed.contains(SECRET.substring(0, 10))) wrong.add(label + ": 클라이언트 시크릿이 찍혔다");
      if (printed.contains(RT_CANARY.substring(0, 10))) wrong.add(label + ": 응답의 refresh_token 이 찍혔다");
    }
  }

  private static void assertNone(List<String> wrong) {
    assertTrue(wrong.isEmpty(), () -> wrong.size() + " 건:\n" + String.join("\n", wrong));
  }

  // ───────────── auth 레인 — S1 · S2 · introspection ─────────────

  /**
   * 2xx 본문의 잘못된 UTF-8 은 끝까지 온 응답을 쓸 수 없다는 것이다 — 그 레인의 인증 오류(r9). 수정 전에는 U+FFFD 로 바꿔 받아들여
   * IdP 가 내지 않은 토큰(ok · U+FFFD 둘 · vc)·바뀐 클레임이 성공으로 나갔다. 세 그랜트가 같은 송신을 지난다.
   */
  @Test void anInvalidUtf8SuccessBody_isAnAuthFailure() {
    List<String> wrong = new ArrayList<>();
    String notUtf8 = "token response is not valid UTF-8";
    for (Object[] row : new Object[][] {
        {"S1", CC, "Client credentials failed: " + notUtf8},
        {"S2", PROV, "Client credentials failed: " + notUtf8},
        {"refresh", RF, "Token refresh failed: " + notUtf8},
        {"code exchange", EX, "Authorization code exchange failed: " + notUtf8}}) {
      tokens(tokenWithInvalidUtf8());
      expect((String) row[0] + " 200 잘못된 UTF-8", call((Call) row[1]), KeycloakAuthException.class, (String) row[2], wrong);
      for (Map.Entry<String, Reply> more : MORE_INVALID_UTF8.entrySet()) {
        tokens(more.getValue());
        expect(row[0] + " 200 " + more.getKey(), call((Call) row[1]), KeycloakAuthException.class, (String) row[2], wrong);
      }
    }
    introspectReply = introspectionWithInvalidUtf8();
    expect("IN 200 잘못된 UTF-8", call(IN), KeycloakAuthException.class,
        "Introspection failed: introspection response is not valid UTF-8", wrong);
    assertNone(wrong);
  }

  /**
   * 설명 없는 오류 응답(JSON 이 아닌 본문 · {@code error} 만 있는 본문)의 메시지는 HTTP 상태를 말한다 — Nimbus {@code ErrorObject} 는
   * 그 본문에 설명을 두지 않아 「… failed: null」 이었다. 오류를 만드는 auth 메서드 넷 모두.
   */
  @Test void anErrorWithoutADescription_namesTheStatus() {
    List<String> wrong = new ArrayList<>();
    for (int status : new int[] {503, 400}) {
      Reply html = typed(status, "text/html", utf8("<html><body>" + status + "</body></html>"));
      for (Object[] row : new Object[][] {
          {"S1", CC, "Client credentials failed: HTTP " + status},
          {"S2", PROV, "Client credentials failed: HTTP " + status},
          {"refresh", RF, "Token refresh failed: HTTP " + status},
          {"code exchange", EX, "Authorization code exchange failed: HTTP " + status}}) {
        tokens(html);
        expect(row[0] + " " + status + " HTML", call((Call) row[1]), KeycloakAuthException.class, (String) row[2], wrong);
      }
      introspectReply = html;
      expect("IN " + status + " HTML", call(IN), KeycloakAuthException.class, "Introspection failed: HTTP " + status, wrong);
    }
    // error 만 · 빈 설명 · 공백뿐인 설명 — 셋 다 「… failed: 」 가 아니라 상태다(빈 설명은 「Token refresh failed: 」 였다)
    for (String body : new String[] {"{\"error\":\"invalid_grant\"}",
        "{\"error\":\"invalid_grant\",\"error_description\":\"\"}",
        "{\"error\":\"invalid_grant\",\"error_description\":\"  \"}"}) {
      tokens(json(400, body));
      Outcome codeOnly = call(RF);
      expect("refresh 400 " + body, codeOnly, KeycloakAuthException.class, "Token refresh failed: HTTP 400", wrong);
      if (codeOnly.thrown() instanceof KeycloakAuthException e && !"invalid_grant".equals(e.getError())) {
        wrong.add("refresh 400 " + body + ": OAuth 오류 코드를 잃었다 — " + e.getError());
      }
    }
    assertNone(wrong);
  }

  /** JSON 의 여섯 글자 이스케이프 — 소스의 유니코드 이스케이프 전처리를 피해 이어 붙인다. */
  private static String esc(int unit) {
    return "\\" + "u" + String.format("%04x", unit);
  }

  /** 쓸 수 있는 멤버 뒤에 붙이는 자리 — 짝 없는 서로게이트 이스케이프가 그 안 어딘가에 있다. */
  private static final Map<String, String> UNPAIRED = Map.of(
      "확장 멤버 값", "\"x_ext\":\"" + esc(0xD800) + "\"",
      "멤버 이름", "\"" + esc(0xD800) + "\":1",
      "여럿 중 하나인 배열 원소", "\"x_ext\":[\"ok\",\"" + esc(0xD800) + "\"]",
      "중첩 객체의 이름", "\"x_ext\":{\"a\":1,\"" + esc(0xDC00) + "\":2}",
      "읽는 멤버의 낮은 서로게이트", "\"scope\":\"ab" + esc(0xDC00) + "cd\"",
      "대문자 16진", "\"x_ext\":\"" + esc(0xD800).toUpperCase().replace("\\U", "\\u") + "\"",
      "높은 서로게이트 뒤 다른 이스케이프", "\"x_ext\":\"" + esc(0xD800) + esc(0x41) + "\"");

  /**
   * 짝 없는 UTF-16 서로게이트 이스케이프(RFC 8259 §8.2 의 문법은 싣지만 I-JSON §2.1 은 금한다)가 2xx 토큰 · introspection 본문 어디에
   * 있든 끝까지 온 응답을 쓸 수 없다 — 그 레인의 인증 오류(등록부 token-response-class-residue 판정 Q2, 2026-11-11). 수정 전에는 그
   * 값을 그대로 돌려줬고, 돌려받은 refresh token 을 다시 보내면 {@code %3F}({@code ?})로 바뀌어 나갔다(실측).
   */
  @Test void anUnpairedSurrogateEscapeAnywhere_isAnAuthFailure() {
    List<String> wrong = new ArrayList<>();
    String holds = "token response holds an unpaired surrogate escape";
    Map<String, String> places = new java.util.LinkedHashMap<>(UNPAIRED);
    places.put("access_token 값", "\"access_token\":\"" + esc(0xD800) + "\"");
    for (Map.Entry<String, String> place : places.entrySet()) {
      for (Object[] row : new Object[][] {
          {"S1", CC, "Client credentials failed: " + holds},
          {"S2", PROV, "Client credentials failed: " + holds},
          {"refresh", RF, "Token refresh failed: " + holds},
          {"code exchange", EX, "Authorization code exchange failed: " + holds}}) {
        tokens(json(200, "{\"access_token\":\"good\",\"token_type\":\"Bearer\",\"expires_in\":300," + place.getValue() + "}"));
        expect(row[0] + " 200 " + place.getKey(), call((Call) row[1]), KeycloakAuthException.class, (String) row[2], wrong);
      }
      introspectReply = json(200, "{\"active\":true,\"username\":\"svc\"," + place.getValue() + "}");
      expect("IN 200 " + place.getKey(), call(IN), KeycloakAuthException.class,
          "Introspection failed: introspection response holds an unpaired surrogate escape", wrong);
    }
    // 대조 — 짝을 이룬 이스케이프와 이스케이프된 역슬래시 뒤의 「u」(이스케이프가 아니다)는 그대로다
    String pair = "a" + esc(0xD83D) + esc(0xDE00) + "b";
    tokens(json(200, "{\"access_token\":\"good\",\"token_type\":\"Bearer\",\"expires_in\":300,\"scope\":\"" + pair
        + "\",\"x_ext\":\"\\\\" + "ud800\"}"));
    Outcome control = call(CC);
    if (!"good".equals(control.value())) wrong.add("S1 짝 · 이스케이프된 역슬래시: 받아들여야 한다 — " + control);
    introspectReply = json(200, "{\"active\":true,\"username\":\"" + pair + "\"}");
    Outcome introspected = call(IN);
    if (!new String(Character.toChars(0x1F600)).equals(((String) introspected.value()).substring(1, 3))) {
      wrong.add("IN 짝: 받아들여야 한다 — " + introspected);
    }
    assertNone(wrong);
  }

  /** 대조 — 규칙이 바꾸지 않는 auth 레인의 칸. */
  @Test void theAuthLaneControls_doNotChange() throws IOException {
    List<String> wrong = new ArrayList<>();
    // 모르는 charset 은 효과가 없다(RFC 8259 §11) — 본문은 UTF-8 로 읽는다
    tokens(typed(200, UNKNOWN_CHARSET, utf8(token("AT-charset"))));
    Outcome charset = call(CC);
    if (!"AT-charset".equals(charset.value())) wrong.add("S1 모르는 charset: 받아들여야 한다 — " + charset);
    introspectReply = typed(200, UNKNOWN_CHARSET, utf8("{\"active\":true,\"username\":\"sévc\",\"client_id\":\"app\"}"));
    Outcome valid = call(IN);
    if (!"sévc".equals(valid.value())) wrong.add("IN 모르는 charset · 유효한 비 ASCII: 그대로여야 한다 — " + valid);
    // 오류 본문의 잘못된 UTF-8 — 판정은 상태가 한다(인증 오류 · OAuth 코드 그대로)
    tokens(typed(400, "application/json",
        concat(utf8("{\"error\":\"invalid_grant\",\"error_description\":\"bad "), INVALID, utf8("\"}"))));
    Outcome errorBody = call(CC);
    if (!(errorBody.thrown() instanceof KeycloakAuthException e) || !"invalid_grant".equals(e.getError())) {
      wrong.add("S1 400 오류 본문의 잘못된 UTF-8: invalid_grant 인증 오류여야 한다 — " + errorBody);
    }
    // logout 의 성공은 204 뿐이다 — 그 밖의 상태(다른 2xx · 3xx · 4xx · 5xx)는 본문이 무엇이든 상태를 실은 auth 실패다(등록부
    // logout-2xx-html-false-success, 2026-11-12 판정 — 전에는 2xx 를 모두 받아 가로챈 200 로그인 페이지도 성공이었다). 본문은 판정에
    // 쓰지 않는다. 205 · 206 · 404 · 5xx 칸과 정확한 문구는 실행 레그가 살린 편집(205 수용 · 5xx 를 transport 로 · 문구에서 상태 빼기)을 잡는다.
    tokens(json(200, token("AT")));
    List<Reply> notLogouts = new ArrayList<>(List.of(
        typed(200, "application/json", concat(utf8("{\"x\":\""), INVALID, utf8("\"}"))),
        typed(200, "text/html", utf8("<html><body><form action=\"/login\"></form></body></html>")),
        new Reply(200, null, null, 0)));
    for (int status : new int[] {201, 202, 205, 206, 302, 400, 401, 404, 500, 502, 503, 504}) {
      notLogouts.add(new Reply(status, null, null, 0));
    }
    for (Reply reply : notLogouts) {
      logoutReply = reply;
      Outcome logout = call(kc -> {
        kc.auth().logout("rt-1");
        return "logged out";
      });
      String want = "Logout failed (HTTP " + reply.status + ")";
      if (!(logout.thrown() instanceof KeycloakAuthException e) || !want.equals(e.getMessage())) {
        wrong.add("logout " + reply + ": auth 실패(" + want + ")여야 한다 — " + logout);
      }
    }
    logoutReply = new Reply(204, null, null, 0);
    Outcome logout = call(kc -> {
      kc.auth().logout("rt-1");
      return "logged out";
    });
    if (!"logged out".equals(logout.value())) wrong.add("logout 204: 성공해야 한다 — " + logout);
    // 다 오지 않은 응답 — 전송 오류
    tokens(typed(200, "application/json", padTo(token("AT-big"), CAP + 1)));
    expect("S1 상한+1", call(CC), KeycloakTransportException.class,
        "Client credentials failed: token response exceeds 1048576 bytes", wrong);
    int closed;
    try (ServerSocket s = new ServerSocket(0, 1, InetAddress.getLoopbackAddress())) {
      closed = s.getLocalPort();
    }
    expect("S1 연결 거부", call(config(closed, Duration.ofSeconds(5)), CC), KeycloakTransportException.class,
        "Client credentials transport failure", wrong);
    assertNone(wrong);
  }

  // ───────────── S5 — admin 의 자기 토큰 그랜트 ─────────────

  private static String adminAuth(int status) {
    return "admin token request failed: HTTP " + status + (status / 100 == 2 ? " (unusable token response)" : "");
  }

  /**
   * 그랜트가 끝까지 온 응답으로 실패하면 상태와 무관하게 인증 오류다 — 메시지는 상태만 싣고(본문은 시크릿을 되울릴 수 있다) admin
   * 요청은 하나도 나가지 않는다. 수정 전에는 전부 {@code KeycloakTransportException("admin transport failure")} 였다.
   */
  @Test void anAdminGrantThatGotAResponse_isAnAuthFailure() {
    List<String> wrong = new ArrayList<>();
    List<Object[]> cells = List.of(
        new Object[] {"503 HTML", typed(503, "text/html", utf8("<html>503 " + SECRET + "</html>")), 503},
        new Object[] {"200 HTML", typed(200, "text/html", utf8("<html>ok " + RT_CANARY + "</html>")), 200},
        new Object[] {"200 JSON access_token 없음",
            json(200, "{\"token_type\":\"Bearer\",\"expires_in\":300,\"refresh_token\":\"" + RT_CANARY + "\"}"), 200},
        new Object[] {"400 HTML", typed(400, "text/html", utf8("<html>400 " + SECRET + "</html>")), 400},
        new Object[] {"200 잘못된 UTF-8", tokenWithInvalidUtf8(), 200},
        new Object[] {"200 겹침 꼴", MORE_INVALID_UTF8.get("겹침 꼴"), 200},
        new Object[] {"200 4096 글자 뒤 잘못된 UTF-8", MORE_INVALID_UTF8.get("4096 글자 뒤"), 200},
        new Object[] {"200 JSON expires_in 숫자 아님",
            json(200, "{\"access_token\":\"good\",\"token_type\":\"Bearer\",\"expires_in\":\"soon\",\"refresh_token\":\""
                + RT_CANARY + "\"}"), 200},
        // 따라가지 않는 리다이렉트도 끝까지 온 응답이다(RESTEasy 의 RedirectionException — HTTP 오류의 하나)
        new Object[] {"302 HTML", typed(302, "text/html", utf8("<html>moved " + SECRET + "</html>")), 302},
        new Object[] {"401 JSON", echoing(401, "unauthorized_client"), 401},
        new Object[] {"403 JSON", echoing(403, "access_denied"), 403},
        new Object[] {"404 JSON", echoing(404, "not_found"), 404},
        new Object[] {"409 JSON", echoing(409, "conflict"), 409},
        // 결합이 아예 읽지 않는 2xx — RESTEasy 의 ResponseProcessingException(200)이 전송 실패로 나갔다(2026-11-11 실측)
        new Object[] {"200 Content-Type 없음", new Reply(200, null, utf8(token("good")), 0), 200},
        // 모든 바이트가 UTF-8 인 UTF-16 — Jackson 의 바이트 파서가 인코딩을 짐작해 받아들였다(auth 레인은 거부한다)
        new Object[] {"200 BOM 없는 UTF-16", typed(200, "application/json", token("good").getBytes(StandardCharsets.UTF_16LE)), 200});
    cells = new ArrayList<>(cells);
    for (Map.Entry<String, String> place : UNPAIRED.entrySet()) {
      cells.add(new Object[] {"200 짝 없는 서로게이트 — " + place.getKey(), json(200,
          "{\"access_token\":\"good\",\"token_type\":\"Bearer\",\"expires_in\":300," + place.getValue() + "}"), 200});
    }
    List<String> table = new ArrayList<>();
    for (Object[] cell : cells) {
      String label = "S5 " + cell[0];
      tokens((Reply) cell[1]);
      Outcome o = call(ADMIN);
      table.add(label + " → " + o + " · grants " + grants() + " · admin " + adminHits());
      expect(label, o, KeycloakAuthException.class, adminAuth((int) cell[2]), wrong);
      if (adminHits() != 0) wrong.add(label + ": admin 요청이 나갔다 — " + adminHits());
      if (grants().isEmpty()) wrong.add(label + ": 토큰 엔드포인트에 닿지 않았다");
    }
    System.out.println("[TokenResponseClassTest S5]\n  " + String.join("\n  ", table));
    assertNone(wrong);
  }

  /** 대조 — 다 오지 않은 응답은 전송 오류 · 좋은 그랜트는 그대로 · 그랜트 뒤의 admin REST 오류는 제 계급 · 갱신 400 의 복구 경로. */
  @Test void theAdminControls_doNotChange() throws IOException {
    List<String> wrong = new ArrayList<>();
    tokens(json(200, token("good")));
    Outcome good = call(ADMIN);
    if (!"alice".equals(good.value()) || adminHits() != 1) wrong.add("S5 좋은 그랜트: " + good + " · admin " + adminHits());
    tokens(typed(200, UNKNOWN_CHARSET, utf8(token("good"))));
    Outcome charset = call(ADMIN);
    if (!"alice".equals(charset.value())) wrong.add("S5 모르는 charset: 받아들여야 한다 — " + charset);

    tokens(typed(200, "application/json", padTo(token("good"), CAP + 1)));
    expect("S5 2xx 상한+1", call(ADMIN), KeycloakTransportException.class, "admin transport failure", wrong);
    tokens(typed(400, "application/json", padTo("{\"error\":\"invalid_grant\"}", CAP + 1)));
    expect("S5 400 상한+1", call(ADMIN), KeycloakTransportException.class, "admin transport failure", wrong);
    int closed;
    try (ServerSocket s = new ServerSocket(0, 1, InetAddress.getLoopbackAddress())) {
      closed = s.getLocalPort();
    }
    expect("S5 연결 거부", call(config(closed, Duration.ofSeconds(5)), ADMIN), KeycloakTransportException.class,
        "admin transport failure", wrong);
    tokens(new Reply(200, "application/json", utf8(token("good")), 3_000));
    expect("S5 타임아웃", call(config(server.getAddress().getPort(), Duration.ofMillis(500)), ADMIN),
        KeycloakTransportException.class, "admin transport failure", wrong);

    tokens(json(200, token("good")));
    adminReply = json(404, "{\"error\":\"User not found\"}");
    Outcome rest404 = call(ADMIN);
    if (!(rest404.thrown() instanceof KeycloakNotFoundException)) wrong.add("S5 좋은 그랜트 뒤 REST 404: " + rest404);
    adminReply = json(200, "{\"id\":\"x\",\"username\":\"alice\"}");

    // 갱신 400 → TokenManager 가 BadRequestException 을 받아 client_credentials 로 다시 부여한다
    String first = "{\"access_token\":\"AT-1\",\"token_type\":\"Bearer\",\"expires_in\":1,\"refresh_token\":\"RT-1\","
        + "\"refresh_expires_in\":300}";
    tokens(json(200, first), json(400, "{\"error\":\"invalid_grant\"}"), json(200, token("AT-3")));
    List<Outcome> twice = new ArrayList<>();
    try (KeycloakClient kc = KeycloakClient.create(config())) {
      for (int i = 0; i < 2; i++) {
        try {
          twice.add(new Outcome(ADMIN.run(kc), null));
        } catch (RuntimeException e) {
          twice.add(new Outcome(null, e));
        }
      }
    }
    if (twice.stream().anyMatch(o -> o.thrown() != null) || adminHits() != 2
        || !grants().equals(List.of("client_credentials", "refresh_token", "client_credentials"))) {
      wrong.add("S5 갱신 400 의 복구 경로: " + twice + " · grants " + grants() + " · admin " + adminHits());
    }
    assertNone(wrong);
  }
}
