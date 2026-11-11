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
 * registered code ({@code client}) withholds that code. The admin facade's own grant never carried a code — unchanged.
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
    Map<String, String> form = new HashMap<>();
    String body = new String(ex.getRequestBody().readAllBytes(), StandardCharsets.UTF_8);
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
      json = "{\"error\":" + errorJson.apply(form) + "}";
    }
    byte[] bytes = json.getBytes(StandardCharsets.UTF_8);
    ex.getResponseHeaders().add("Content-Type", "application/json");
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
    for (String surface : List.of("clientCredentialsToken", "provider")) {
      assertNull(failing(surface, "client").getError(), surface);
    }
  }
}
