package io.github.xzawed.keycloak;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.junit.jupiter.api.Assertions.fail;

import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;
import io.github.xzawed.keycloak.auth.ClientCredentialsTokenProvider;
import io.github.xzawed.keycloak.core.KeycloakConfig;
import io.github.xzawed.keycloak.core.exception.KeycloakAuthException;
import java.io.IOException;
import java.io.OutputStream;
import java.io.PrintWriter;
import java.io.StringWriter;
import java.lang.reflect.Field;
import java.lang.reflect.Modifier;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.URLDecoder;
import java.nio.charset.StandardCharsets;
import java.time.Clock;
import java.time.Duration;
import java.util.ArrayList;
import java.util.Base64;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.function.Function;
import java.util.function.UnaryOperator;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

/**
 * The OAuth {@code error} code an SDK error carries is a code, never a value the request sent (registry
 * {@code token-error-code-secret-echo} · {@code oauth-error-field-echo-unmasked}).
 *
 * <p>The IdP's {@code error} is response body too. An endpoint (or a proxy) that echoes what the request sent puts the
 * client secret, the refresh token or the introspected token there — and {@code getError()} carried any value in the RFC
 * 6749 grammar Nimbus accepts, a Keycloak-style secret and a JWT included (measured on main a7d0fdf3). One rule now
 * ({@code OAuthErrorCode}): {@code [a-z_]{1,64}} and overlapping no non-empty secret the request sent — neither contains
 * the other, so a truncated or extended echo is withheld too. The price is pinned below: a secret that is a piece of a
 * registered code ({@code client}) withholds that code. The admin facade's own grant takes the same rule — at an error
 * status it carried no code at all before (registry {@code oauth-error-code-surface-divergent}).
 */
class OAuthErrorCodeEchoTest {
  private static final String REALM = "r";
  private static final String OIDC = "/realms/" + REALM + "/protocol/openid-connect";
  // Code-shaped on purpose (the shape alone cannot withhold them), and no two share a piece — an echo of one value must be
  // withheld by comparing against THAT value, not a sibling's prefix.
  private static final String SECRET = "zebrasecretjk";
  private static final String REFRESH = "yakrefreshvq";
  private static final String TOKEN = "walrustokenpx";
  private static final String CODE = "vulturecodeby";
  private static final String VERIFIER = "ocelotverifier".repeat(3) + "xx";

  private HttpServer server;
  private ExecutorService handlers;
  private final List<Map<String, String>> sent = new ArrayList<>();
  private Function<Map<String, String>, String> errorJson = s -> "\"invalid_request\"";
  private volatile int status = 400;
  /** When set, the whole answer body instead of {@code {"error": …}}. */
  private volatile String rawBody;
  /** When set, a {@code Location} header on the answer. */
  private volatile String location;
  /** Every request as {@code METHOD /path}, in order — the 3xx cells read which method reached {@link #REDIRECT_TARGET}. */
  private final List<String> requests = new ArrayList<>();
  /** Where the 3xx cells point {@code Location} (this server, same origin) — a client that follows it shows up here. */
  private static final String REDIRECT_TARGET = "/redirect-target";

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
    synchronized (this) {
      requests.add(ex.getRequestMethod() + " " + path);
    }
    Map<String, String> form = new HashMap<>();
    String body = new String(ex.getRequestBody().readAllBytes(), StandardCharsets.UTF_8);
    if (REDIRECT_TARGET.equals(path)) {
      byte[] reached = "{\"error\":\"redirect_target_reached\"}".getBytes(StandardCharsets.UTF_8);
      ex.getResponseHeaders().add("Content-Type", "application/json");
      ex.sendResponseHeaders(400, reached.length);
      try (OutputStream out = ex.getResponseBody()) {
        out.write(reached);
      }
      return;
    }
    for (String pair : body.split("&")) {
      if (pair.isEmpty()) continue;
      int eq = pair.indexOf('=');
      String name = URLDecoder.decode(eq < 0 ? pair : pair.substring(0, eq), StandardCharsets.UTF_8);
      form.put(name, eq < 0 ? "" : URLDecoder.decode(pair.substring(eq + 1), StandardCharsets.UTF_8));
    }
    String auth = ex.getRequestHeaders().getFirst("Authorization");
    if (auth != null && auth.startsWith("Basic ")) {
      String pair = new String(Base64.getDecoder().decode(auth.substring(6)), StandardCharsets.UTF_8);
      form.put("client_secret", URLDecoder.decode(pair.substring(pair.indexOf(':') + 1), StandardCharsets.UTF_8));
    }
    String json;
    synchronized (this) {
      sent.add(form);
      json = rawBody != null ? rawBody : "{\"error\":" + errorJson.apply(form) + "}";
    }
    byte[] bytes = json.getBytes(StandardCharsets.UTF_8);
    ex.getResponseHeaders().add("Content-Type", "application/json");
    if (location != null) ex.getResponseHeaders().add("Location", location);
    ex.sendResponseHeaders(status, bytes.length);
    try (OutputStream out = ex.getResponseBody()) {
      out.write(bytes);
    }
  }

  private static String quoted(String s) {
    return "\"" + s.replace("\\", "\\\\").replace("\"", "\\\"") + "\"";
  }

  private interface Call {
    void run(KeycloakClient kc) throws Exception;
  }

  /** surface → (secret form fields it sends besides the client secret, call). */
  private static final Map<String, Map.Entry<List<String>, Call>> SURFACES = new LinkedHashMap<>();

  static {
    SURFACES.put("clientCredentialsToken", Map.entry(List.of(), kc -> kc.auth().clientCredentialsToken()));
    SURFACES.put("provider", Map.entry(List.of(),
        kc -> new ClientCredentialsTokenProvider(kc.auth(), Clock.systemUTC(), Duration.ofSeconds(30)).getAccessToken()));
    SURFACES.put("refresh", Map.entry(List.of("refresh_token"), kc -> kc.auth().refresh(REFRESH)));
    SURFACES.put("exchangeCode", Map.entry(List.of("code", "code_verifier"),
        kc -> kc.auth().exchangeCode(CODE, java.net.URI.create("https://app.example/cb"), VERIFIER)));
    SURFACES.put("introspect", Map.entry(List.of("token"), kc -> kc.auth().introspect(TOKEN)));
    SURFACES.put("admin", Map.entry(List.of(), kc -> kc.admin().users().get("u1")));
  }

  private KeycloakAuthException failing(String surface, String secret) {
    synchronized (this) {
      sent.clear();
    }
    KeycloakConfig.Builder b = KeycloakConfig.builder().serverUrl("http://127.0.0.1:" + server.getAddress().getPort())
        .realm(REALM).clientId("app")
        .connectTimeout(Duration.ofSeconds(5)).readTimeout(Duration.ofSeconds(5));
    if (secret != null) b.clientSecret(secret.toCharArray());
    try (KeycloakClient kc = KeycloakClient.create(b.build())) {
      SURFACES.get(surface).getValue().run(kc);
    } catch (KeycloakAuthException e) {
      return e;
    } catch (Exception e) {
      fail(surface + ": " + e);
    }
    return fail(surface + " did not fail");
  }

  private synchronized Map<String, String> firstSent() {
    assertFalse(sent.isEmpty(), "no token request reached the IdP");
    return sent.get(0);
  }

  private static List<String> renderings(Throwable e) {
    List<String> out = new ArrayList<>();
    StringWriter trace = new StringWriter();
    e.printStackTrace(new PrintWriter(trace));
    out.add(trace.toString());
    for (Throwable x = e; x != null; x = x.getCause()) {
      out.add(String.valueOf(x));
      for (Class<?> c = x.getClass(); c != null && !c.getName().startsWith("java."); c = c.getSuperclass()) {
        for (Field f : c.getDeclaredFields()) {
          if (Modifier.isStatic(f.getModifiers())) continue;
          try {
            f.setAccessible(true);
            out.add(String.valueOf(f.get(x)));
          } catch (ReflectiveOperationException | RuntimeException ignored) {
            // an inaccessible field is not a rendering a logger reaches either
          }
        }
      }
    }
    return out;
  }

  private static void assertWithheld(String label, KeycloakAuthException e, String value) {
    assertNull(e.getError(), label);
    for (String text : renderings(e)) {
      assertFalse(text.contains(value), label + ": a rendering shows " + value + ": " + text);
    }
  }

  /** Every piece and every padding, so each direction of the overlap is pinned. */
  private static final Map<String, UnaryOperator<String>> ECHO_FORMS = Map.of(
      "whole", v -> v,
      "prefix", v -> v.substring(0, 11),
      "suffix", v -> v.substring(v.length() - 11),
      "middle", v -> v.substring(2, 11),
      "extended", v -> v + "_x",
      "prefixed", v -> "x_" + v,
      "wrapped", v -> "x_" + v + "_x");

  /** Keycloak answers a bad client with 401, not 400 — an error status other than 400 takes the same rule. */
  @Test void anEchoOnA401IsNeverCarried() {
    status = 401;
    for (Map.Entry<String, Map.Entry<List<String>, Call>> s : SURFACES.entrySet()) {
      List<String> params = new ArrayList<>(List.of("client_secret"));
      params.addAll(s.getValue().getKey());
      for (String param : params) {
        errorJson = sentForm -> quoted(sentForm.getOrDefault(param, ""));
        KeycloakAuthException e = failing(s.getKey(), SECRET);
        assertWithheld(s.getKey() + " · 401 · " + param, e, firstSent().get(param));
      }
    }
  }

  @Test void anEchoedClientSecretIsNeverCarried() {
    for (String surface : SURFACES.keySet()) {
      for (Map.Entry<String, UnaryOperator<String>> form : ECHO_FORMS.entrySet()) {
        errorJson = s -> quoted(form.getValue().apply(s.getOrDefault("client_secret", "")));
        KeycloakAuthException e = failing(surface, SECRET);
        assertEquals(SECRET, firstSent().get("client_secret"), surface);
        assertWithheld(surface + " · " + form.getKey(), e, form.getValue().apply(SECRET));
      }
    }
  }

  /** An IdP or proxy that echoes the secret lowercased — the overlap ignores ASCII case. */
  @Test void aLowercasedEchoOfTheClientSecretIsNeverCarried() {
    String mixed = "EchoMixedCase";
    errorJson = s -> quoted(s.getOrDefault("client_secret", "").toLowerCase(Locale.ROOT));
    for (String surface : SURFACES.keySet()) {
      KeycloakAuthException e = failing(surface, mixed);
      assertEquals(mixed, firstSent().get("client_secret"), surface);
      assertWithheld(surface + " · lowercased", e, "echomixedcase");
    }
  }

  @Test void anEchoedGrantValueIsNeverCarried() {
    for (Map.Entry<String, Map.Entry<List<String>, Call>> s : SURFACES.entrySet()) {
      for (String param : s.getValue().getKey()) {
        for (Map.Entry<String, UnaryOperator<String>> form : ECHO_FORMS.entrySet()) {
          errorJson = sentForm -> quoted(form.getValue().apply(sentForm.getOrDefault(param, "")));
          KeycloakAuthException e = failing(s.getKey(), SECRET);
          assertWithheld(s.getKey() + " · " + param + " · " + form.getKey(), e,
              form.getValue().apply(firstSent().get(param)));
        }
      }
    }
  }

  @Test void aPublicClientWithholdsItsEchoedRefreshTokenAndStillGetsACode() {
    errorJson = s -> quoted(s.getOrDefault("refresh_token", ""));
    assertWithheld("public · echo", failing("refresh", null), REFRESH);
    String sentSecret = firstSent().get("client_secret");
    assertTrue(sentSecret == null || sentSecret.isEmpty(), "a public client sent a client secret");
    errorJson = s -> quoted("invalid_grant");
    assertEquals("invalid_grant", failing("refresh", null).getError());
  }

  @Test void aValueThatIsNotACodeIsNeverCarried() {
    List<String> values = List.of("Kx7mQ2vT9pLr4WzN8bYc3FhJ6sDa1gE5",
        "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ4In0.c2lnbmF0dXJlLXZhbHVl", "Invalid_client", "invalid client",
        "invalid_client2", "a".repeat(65));
    for (String surface : SURFACES.keySet()) {
      for (String value : values) {
        errorJson = s -> quoted(value);
        assertWithheld(surface + " · " + value, failing(surface, SECRET), value);
      }
    }
  }

  @Test void aCodeThatOverlapsNothingSentIsCarried() {
    for (String surface : SURFACES.keySet()) {
      for (String code : List.of("invalid_client", "invalid_grant", "slow_down", "a".repeat(64))) {
        errorJson = s -> quoted(code);
        assertEquals(code, failing(surface, SECRET).getError(), surface);
      }
    }
  }

  @Test void thePriceASecretThatIsAPieceOfTheCodeWithholdsIt() {
    errorJson = s -> quoted("invalid_client");
    for (String surface : List.of("clientCredentialsToken", "provider", "admin")) {
      assertNull(failing(surface, "client").getError(), surface);
    }
  }

  /**
   * The two error statuses the nine languages were measured with (registry {@code oauth-error-code-surface-divergent}): A is
   * 400 {@code {"error":"invalid_grant"}}, B is 401 {@code {"error":"invalid_client"}}. Every surface carries the code in
   * {@code getError()}, as every one does at 200 (#1184). Before: the admin facade's own grant left it null for both.
   */
  @Test void anErrorStatusCarriesTheCodeOnEverySurface() {
    List<String> wrong = new ArrayList<>();
    for (Object[] cell : new Object[][] {{"A", 400, "invalid_grant"}, {"B", 401, "invalid_client"}}) {
      status = (Integer) cell[1];
      String code = (String) cell[2];
      errorJson = s -> quoted(code);
      for (String surface : SURFACES.keySet()) {
        String got = failing(surface, SECRET).getError();
        if (!code.equals(got)) wrong.add(cell[0] + " · " + surface + ": getError() " + got + " (want " + code + ")");
      }
    }
    assertTrue(wrong.isEmpty(), () -> wrong.size() + " cells:\n" + String.join("\n", wrong));
  }

  // The OAuth `error` at a 3xx and a 5xx (registry node-5xx-oauth-error-code-empty). The contract puts it in the code field
  // "at any status"; that was measured at 400 · 401 (#1199) and the other 2xx (#1207) only. Pinned as the contract reads at
  // 500 · 503 and at 302 (Location on this server — a 3xx is an error status too), which is never followed.
  private static final String B5 = "{\"error\":\"temporarily_unavailable\",\"error_description\":\"down\"}";
  private static final String NO_ERROR = "{\"message\":\"down\"}";

  /** One surface's outcome: {@code getError()} (null when not an auth error), one line, and every request seen. */
  private record Cell(String code, String line, List<String> requests) {}

  private Cell errorStatusCell(String surface, int cellStatus, String body, String cellLocation) {
    synchronized (this) {
      sent.clear();
      requests.clear();
    }
    status = cellStatus;
    rawBody = body;
    location = cellLocation;
    KeycloakConfig cfg = KeycloakConfig.builder().serverUrl("http://127.0.0.1:" + server.getAddress().getPort())
        .realm(REALM).clientId("app").clientSecret(SECRET.toCharArray())
        .connectTimeout(Duration.ofSeconds(5)).readTimeout(Duration.ofSeconds(5)).build();
    String code = null;
    String outcome;
    try (KeycloakClient kc = KeycloakClient.create(cfg)) {
      SURFACES.get(surface).getValue().run(kc);
      outcome = "success";
    } catch (KeycloakAuthException e) {
      code = e.getError();
      outcome = e.getClass().getSimpleName() + "(" + e.getMessage() + ") code=" + code;
    } catch (Exception e) {
      outcome = e.getClass().getSimpleName() + "(" + e.getMessage() + ") code=-";
    }
    List<String> seen;
    synchronized (this) {
      seen = List.copyOf(requests);
    }
    return new Cell(code, cellStatus + " " + surface + " → " + outcome + " requests=" + seen, seen);
  }

  @Test void aServerErrorStatusCarriesTheOAuthErrorOnEverySurface() {
    List<String> table = new ArrayList<>();
    List<String> wrong = new ArrayList<>();
    for (int s : new int[] {500, 503}) {
      for (String surface : SURFACES.keySet()) {
        Cell c = errorStatusCell(surface, s, B5, null);
        table.add(c.line());
        if (!"temporarily_unavailable".equals(c.code())) wrong.add(c.line());
      }
    }
    System.out.println(String.join("\n", table));
    assertTrue(wrong.isEmpty(), () -> wrong.size() + " cells:\n" + String.join("\n", wrong));
  }

  /** Controls: the same body at 400 carries it; a 503 whose body names no {@code error} carries none. */
  @Test void theErrorStatusControlsCarryItAt400AndNoneWithoutOne() {
    List<String> table = new ArrayList<>();
    List<String> wrong = new ArrayList<>();
    for (String surface : SURFACES.keySet()) {
      Cell at400 = errorStatusCell(surface, 400, B5, null);
      Cell none = errorStatusCell(surface, 503, NO_ERROR, null);
      table.add(at400.line());
      table.add(none.line());
      if (!"temporarily_unavailable".equals(at400.code())) wrong.add(at400.line());
      if (none.code() != null) wrong.add(none.line());
    }
    System.out.println(String.join("\n", table));
    assertTrue(wrong.isEmpty(), () -> wrong.size() + " cells:\n" + String.join("\n", wrong));
  }

  @Test void aRedirectErrorStatusCarriesTheOAuthErrorAndIsNeverFollowed() {
    List<String> table = new ArrayList<>();
    List<String> wrong = new ArrayList<>();
    for (String surface : SURFACES.keySet()) {
      Cell c = errorStatusCell(surface, 302, B5, "http://127.0.0.1:" + server.getAddress().getPort() + REDIRECT_TARGET);
      table.add(c.line());
      boolean followed = c.requests().stream().anyMatch(r -> r.endsWith(" " + REDIRECT_TARGET));
      if (followed || !"temporarily_unavailable".equals(c.code())) wrong.add(c.line());
    }
    System.out.println(String.join("\n", table));
    assertTrue(wrong.isEmpty(), () -> wrong.size() + " cells:\n" + String.join("\n", wrong));
  }
}
