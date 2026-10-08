package io.github.xzawed.keycloak.auth;

import static org.junit.jupiter.api.Assertions.*;

import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;
import io.github.xzawed.keycloak.core.KeycloakConfig;
import io.github.xzawed.keycloak.core.exception.KeycloakAuthException;
import java.io.IOException;
import java.io.OutputStream;
import java.io.PrintWriter;
import java.io.StringWriter;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.URI;
import java.net.URLDecoder;
import java.net.URLEncoder;
import java.nio.charset.Charset;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.ArrayList;
import java.util.Base64;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

/**
 * 되울린 값의 <b>인코딩된 꼴</b> — IdP·프록시가 이 요청이 보낸 값(클라이언트 시크릿 · Basic 자격 · 본문의 비밀 파라미터)을
 * error_description 에 되울릴 때, 그 값이 어느 꼴로 오든 SDK 오류(메시지 · toString · printStackTrace · 원인 메시지)에 남지
 * 않는다. 꼴: 그대로(Nimbus 가 RFC 6749 §5.2 밖의 글자를 지운 뒤) · 폼 인코딩(Basic 의 비밀번호 칸이 이 꼴이다 — RFC 6749
 * §2.3.1) · RFC 3986 퍼센트 인코딩(공백 {@code %20}, {@code ~} 그대로) · 두 인코딩의 소문자 16진 · Grok 레그가 낸 실제 인코더와
 * 변형(그대로 두는 글자·문자 집합이 다른 것 — Go {@code url.QueryEscape} · Python {@code quote} · JS {@code encodeURI}·{@code escape} ·
 * ISO-8859-1 폼, 공백과 {@code +} 가 뒤섞인 것, 한 겹 더 인코딩된 것, {@code %uXXXX}) · Basic 자격(base64) · 그것을 푼 userinfo
 * ({@code c:<폼 인코딩된 시크릿>})와 그것을 한 번 더 인코딩한 꼴.
 *
 * <p>⚠️ 메시지를 <b>통째로</b> 대조한다 — 꼴마다 「그 문자열이 없다」만 보면 첫 낱말만 남은 부분 누출({@code Bad credentials: sec
 * ***} — 연속 규칙이 {@code ret/+=~0005} 만 잡았다)이 통과한다. 사유 문구({@code Bad credentials:})가 남는 것도 같은 대조가 본다.
 * 인코더는 이 시험이 따로 만든다(SDK 의 것을 빌리면 같은 실수를 함께 한다). 네트워크는 루프백만.
 */
class AuthEchoedSecretFormsTest {
  private static final String CLIENT_ID = "c";
  private static final String SECRET = "sec ret/+=~0005é";
  private static final String REFRESH = "rt ref/+=~0007é";
  private static final String TOKEN = "at tok/+=~0008é";
  private static final String CODE = "cd code/+=~0009é";
  /** RFC 7636 §4.1 — 43–128 자, [A-Za-z0-9-._~]. {@code ~} 는 폼 인코딩만 바꾼다. */
  private static final String VERIFIER = "vVERIF~0123456789abcdefghijklmnopqrstuvwxyzAB";
  private static final String BASIC = "BASIC";

  /** 인코더 — 알파벳·숫자와 {@code safe} 는 그대로, 공백은 {@code +} 또는 {@code %20}, 나머지 바이트(그 문자 집합)는 %XX. */
  private record Encoder(String safe, boolean spacePlus, boolean lower, Charset charset) {
    String apply(String v) {
      StringBuilder out = new StringBuilder();
      for (byte b : v.getBytes(charset)) {
        int c = b & 0xFF;
        if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || safe.indexOf(c) >= 0) {
          out.append((char) c);
        } else if (c == ' ' && spacePlus) {
          out.append('+');
        } else {
          out.append(String.format(lower ? "%%%02x" : "%%%02X", c));
        }
      }
      return out.toString();
    }
  }

  private static final Charset UTF8 = StandardCharsets.UTF_8;
  /** 공백·{@code %} 를 뺀 ASCII 출력 글자 — {@code nonascii-only} 가 그대로 두는 것. */
  private static final String PRINTABLE_ASCII = "!\"#$&'()*+,-./:;<=>?@[\\]^_`{|}~";
  /**
   * 꼴 이름 → 인코더. 앞의 넷은 SDK 가 꼴로 늘어놓는 것이고, 나머지는 Grok 레그가 낸 실제 인코더·변형이다(레그 1: 그대로 두는 글자·
   * 문자 집합이 다른 것, 레그 2: 공백과 {@code +} 가 뒤섞이거나 한 겹 더 인코딩되거나 {@code %uXXXX} 인 것).
   */
  private static final Map<String, java.util.function.UnaryOperator<String>> ENCODERS = new LinkedHashMap<>();

  static {
    Encoder form = new Encoder("*-._", true, false, UTF8);
    Encoder pct = new Encoder("-._~", false, false, UTF8);
    Encoder query = new Encoder("-._~", true, false, UTF8);
    ENCODERS.put("form", form::apply);                                                     // Java URLEncoder · WHATWG
    ENCODERS.put("form-lower", new Encoder("*-._", true, true, UTF8)::apply);              // .NET HttpUtility.UrlEncode
    ENCODERS.put("pct", pct::apply);                                                       // RFC 3986 · Uri.EscapeDataString
    ENCODERS.put("pct-lower", new Encoder("-._~", false, true, UTF8)::apply);
    ENCODERS.put("query", query::apply);                                                   // Go url.QueryEscape · quote_plus
    ENCODERS.put("path", new Encoder("-._~/", false, false, UTF8)::apply);                 // Python quote (safe='/')
    ENCODERS.put("uri", new Encoder("-._~!*'();/?:@&=+$,#", false, false, UTF8)::apply);   // JS encodeURI
    ENCODERS.put("latin1-form", new Encoder("*-._", true, false, StandardCharsets.ISO_8859_1)::apply); // URLEncoder ISO-8859-1
    ENCODERS.put("js-escape", AuthEchoedSecretFormsTest::jsEscape);                        // JS escape — %E9 · %uXXXX
    ENCODERS.put("unicode-escape", AuthEchoedSecretFormsTest::unicodeEscape);              // .NET UrlEncodeUnicode 류 %uXXXX
    ENCODERS.put("nonascii-only", new Encoder(PRINTABLE_ASCII, true, false, UTF8)::apply); // 비 ASCII 만, 공백은 +
    ENCODERS.put("space-as-2B", v -> form.apply(v).replace("+", "%2B"));                   // 폼 뒤 + 를 %2B 로 바꾼 게이트웨이
    ENCODERS.put("requoted", v -> pct.apply(query.apply(v)));                              // quote_plus 된 값을 다시 인코딩
    ENCODERS.put("mojibake", v -> form.apply(new String(v.getBytes(UTF8), StandardCharsets.ISO_8859_1))); // UTF-8 을 ISO-8859-1 로 읽고 폼
    ENCODERS.put("json-escape-url", v -> form.apply(nonAscii(v, "\\u%04x")));             // JSON \\u00e9 뒤 폼
    ENCODERS.put("entity-url", v -> form.apply(nonAscii(v, "&#%d;")));                     // &#233; 뒤 폼
    ENCODERS.put("html-entity", AuthEchoedSecretFormsTest::htmlEntities);                  // 알파벳·숫자 밖을 전부 &#NN;
    ENCODERS.put("xmlcharref", v -> nonAscii(v, "&#%d;"));                                 // Python encode('ascii','xmlcharrefreplace')
  }

  /** 비 ASCII 글자만 {@code format}(그 코드 단위)으로. */
  private static String nonAscii(String v, String format) {
    StringBuilder out = new StringBuilder();
    for (char c : v.toCharArray()) out.append(c < 0x80 ? String.valueOf(c) : String.format(format, (int) c));
    return out.toString();
  }

  /** 알파벳·숫자 밖의 글자를 전부 10진 HTML 숫자 참조로. */
  private static String htmlEntities(String v) {
    StringBuilder out = new StringBuilder();
    v.codePoints().forEach(cp -> out.append(Character.isLetterOrDigit(cp) && cp < 0x80
        ? new String(Character.toChars(cp)) : "&#" + cp + ";"));
    return out.toString();
  }

  /** JS {@code escape} — 알파벳·숫자와 {@code @*_+-./} 는 그대로, U+00FF 까지는 %XX, 그 위는 %uXXXX. */
  private static String jsEscape(String v) {
    StringBuilder out = new StringBuilder();
    for (char c : v.toCharArray()) {
      if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || "@*_+-./".indexOf(c) >= 0) {
        out.append(c);
      } else {
        out.append(c <= 0xFF ? String.format("%%%02X", (int) c) : String.format("%%u%04X", (int) c));
      }
    }
    return out.toString();
  }

  /** 모든 글자를 %uXXXX 로. */
  private static String unicodeEscape(String v) {
    StringBuilder out = new StringBuilder();
    for (char c : v.toCharArray()) out.append(String.format("%%u%04X", (int) c));
    return out.toString();
  }

  private static final List<String> VARIANTS = new ArrayList<>(List.of("raw"));

  static {
    VARIANTS.addAll(ENCODERS.keySet());
  }

  private static final List<String> BASIC_ONLY = List.of("b64", "userinfo", "userinfo-pct");

  private HttpServer server;
  private volatile String target = BASIC;
  private volatile String variant = "raw";
  /** 마지막으로 되울린 문자열(서버가 실제로 쓴 꼴). */
  private volatile String echoed = "";

  @BeforeEach void start() throws IOException {
    server = HttpServer.create(new InetSocketAddress(InetAddress.getLoopbackAddress(), 0), 0);
    server.createContext("/", this::answer);
    server.start();
  }

  @AfterEach void stop() {
    server.stop(0);
  }

  /** 받은 값을 고른 꼴로 되울리는 IdP — 토큰·introspection·logout 엔드포인트 모두 401 invalid_client. */
  private void answer(HttpExchange ex) throws IOException {
    Map<String, String> form = new LinkedHashMap<>();
    for (String kv : new String(ex.getRequestBody().readAllBytes(), UTF8).split("&")) {
      int eq = kv.indexOf('=');
      if (eq > 0) form.put(kv.substring(0, eq), URLDecoder.decode(kv.substring(eq + 1), UTF8));
    }
    String auth = ex.getRequestHeaders().getFirst("Authorization");
    String credential = auth == null ? "" : auth.substring(auth.indexOf(' ') + 1);
    String userinfo = new String(Base64.getDecoder().decode(credential), UTF8);
    String value = target.equals(BASIC)
        ? URLDecoder.decode(userinfo.substring(userinfo.indexOf(':') + 1), UTF8)
        : form.getOrDefault(target, "");
    String text = switch (variant) {
      case "raw" -> value;
      case "b64" -> credential;
      case "userinfo" -> userinfo;
      case "userinfo-pct" -> ENCODERS.get("pct").apply(userinfo); // 받은 userinfo 를 그대로 한 번 더 인코딩
      default -> ENCODERS.get(variant).apply(value);
    };
    echoed = text;
    byte[] body = ("{\"error\":\"invalid_client\",\"error_description\":\"Bad credentials: " + text + "\"}").getBytes(UTF8);
    ex.getResponseHeaders().add("Content-Type", "application/json");
    ex.sendResponseHeaders(401, body.length);
    try (OutputStream os = ex.getResponseBody()) {
      os.write(body);
    }
  }

  /** RFC 6749 §5.2 — error_description 에 허용되는 글자(%x20-21 / %x23-5B / %x5D-7E). */
  private static String legal(String s) {
    StringBuilder out = new StringBuilder();
    for (char c : s.toCharArray()) {
      if ((c >= 0x20 && c <= 0x21) || (c >= 0x23 && c <= 0x5b) || (c >= 0x5d && c <= 0x7e)) out.append(c);
    }
    return out.toString();
  }

  /** 보낸 값이 오류에 실릴 수 있는 꼴 전부 — 이 중 어느 것도 오류의 어느 표현에도 없어야 한다. */
  private static Set<String> forms(String sent) {
    String received = new String(sent.getBytes(UTF8), UTF8);
    Set<String> out = new LinkedHashSet<>();
    for (String v : List.of(sent, received)) {
      out.add(v);
      out.add(legal(v));
      for (java.util.function.UnaryOperator<String> e : ENCODERS.values()) out.add(e.apply(v));
    }
    out.removeIf(f -> f.length() < 8);
    return out;
  }

  private static Set<String> basicForms(String secret) {
    String credential = credentialOf(secret);
    String userinfo = new String(Base64.getDecoder().decode(credential), UTF8);
    Set<String> out = new LinkedHashSet<>(forms(secret));
    out.add(credential);
    out.add(userinfo);
    out.add(ENCODERS.get("pct").apply(userinfo));
    return out;
  }

  /** Nimbus {@code ClientSecretBasic} 이 싣는 자격 — client id 와 시크릿을 각각 폼 인코딩해 잇고 base64(RFC 6749 §2.3.1). */
  private static String credentialOf(String secret) {
    String pair = URLEncoder.encode(CLIENT_ID, UTF8) + ":" + URLEncoder.encode(secret, UTF8);
    return Base64.getEncoder().encodeToString(pair.getBytes(UTF8));
  }

  /** 꼴마다 메시지에 남아야 할 꼬리 — 시크릿이 있던 자리만 {@code ***} 다(client id 와 인코딩된 {@code :} 는 비밀이 아니다). */
  private static String masked(String v) {
    return switch (v) {
      case "userinfo" -> CLIENT_ID + ":***";
      case "userinfo-pct" -> CLIENT_ID + "%3A***";
      default -> "***";
    };
  }

  private AuthClient auth(String secret) {
    KeycloakConfig c = KeycloakConfig.builder().serverUrl("http://127.0.0.1:" + server.getAddress().getPort())
        .realm("r").clientId(CLIENT_ID).clientSecret(secret.toCharArray()).readTimeout(Duration.ofSeconds(10)).build();
    return new AuthClient(c, OidcMetadata.forRealm(c));
  }

  private interface Call {
    void run(AuthClient a) throws Exception;
  }

  private static Throwable failureOf(AuthClient a, Call call) {
    try {
      call.run(a);
      return null;
    } catch (Throwable t) {
      return t;
    }
  }

  /** 오류 하나 — 메시지를 통째로 대조하고, 로거가 찍는 표현 전부에서 보낸 값의 꼴을 찾는다. */
  private void check(String label, Throwable thrown, String expected, Set<String> forms, List<String> wrong,
      List<String> table) {
    table.add(String.format("%-46s echoed=%-48s → %s", label, echoed,
        thrown == null ? "성공" : thrown.getClass().getSimpleName() + ": " + thrown.getMessage()));
    if (!(thrown instanceof KeycloakAuthException e)) {
      wrong.add(label + ": KeycloakAuthException 이 아니다 — " + thrown);
      return;
    }
    if (!expected.equals(e.getMessage())) wrong.add(label + ": 메시지 「" + e.getMessage() + "」 ≠ 「" + expected + "」");
    StringWriter trace = new StringWriter();
    e.printStackTrace(new PrintWriter(trace, true));
    StringBuilder all = new StringBuilder(e.toString()).append('\n').append(trace).append('\n').append(e.getError());
    for (Throwable c = e.getCause(); c != null; c = c.getCause()) all.append('\n').append(c.getMessage());
    for (String f : forms) {
      if (all.indexOf(f) >= 0) wrong.add(label + ": 오류가 보낸 값의 꼴 「" + f + "」 을 찍었다");
    }
  }

  private static final URI CB = URI.create("https://app/cb");

  /** 시크릿은 기밀 클라이언트의 모든 레인에서 Basic 으로 나간다 — 꼴마다 · 레인마다 같은 결과여야 한다. */
  @Test void echoedClientSecret_isMaskedInEveryForm_onEveryLane() {
    Map<String, Call> lanes = new LinkedHashMap<>();
    lanes.put("Client credentials failed", AuthClient::clientCredentialsToken);
    lanes.put("Token refresh failed", a -> a.refresh(REFRESH));
    lanes.put("Introspection failed", a -> a.introspect(TOKEN));
    lanes.put("Authorization code exchange failed", a -> a.exchangeCode(CODE, CB, VERIFIER));
    lanes.put("Logout failed", a -> a.logout(REFRESH));
    Set<String> forms = basicForms(SECRET);
    List<String> wrong = new ArrayList<>();
    List<String> table = new ArrayList<>();
    target = BASIC;
    List<String> variants = new ArrayList<>(VARIANTS);
    variants.addAll(BASIC_ONLY);
    for (Map.Entry<String, Call> lane : lanes.entrySet()) {
      for (String v : variants) {
        variant = v;
        String expected = lane.getKey().equals("Logout failed") ? "Logout failed (HTTP 401)"
            : lane.getKey() + ": Bad credentials: " + masked(v);
        check(lane.getKey() + " · secret " + v, failureOf(auth(SECRET), lane.getValue()), expected, forms, wrong, table);
      }
    }
    System.out.println("[AuthEchoedSecretFormsTest 시크릿]\n  " + String.join("\n  ", table));
    assertTrue(wrong.isEmpty(), () -> wrong.size() + " 건:\n" + String.join("\n", wrong));
  }

  /** 본문의 비밀 파라미터(호출자의 refresh·introspect 토큰 · 인가 코드 · verifier)도 같은 꼴로 되울린다. */
  @Test void echoedGrantValue_isMaskedInEveryForm() {
    record Case(String label, String param, String value, String prefix, Call call) {}
    List<Case> cases = List.of(
        new Case("refresh · refresh_token", "refresh_token", REFRESH, "Token refresh failed", a -> a.refresh(REFRESH)),
        new Case("introspect · token", "token", TOKEN, "Introspection failed", a -> a.introspect(TOKEN)),
        new Case("exchangeCode · code", "code", CODE, "Authorization code exchange failed",
            a -> a.exchangeCode(CODE, CB, VERIFIER)),
        new Case("exchangeCode · code_verifier", "code_verifier", VERIFIER, "Authorization code exchange failed",
            a -> a.exchangeCode(CODE, CB, VERIFIER)),
        new Case("logout · refresh_token", "refresh_token", REFRESH, "Logout failed", a -> a.logout(REFRESH)));
    List<String> wrong = new ArrayList<>();
    List<String> table = new ArrayList<>();
    for (Case c : cases) {
      target = c.param();
      for (String v : VARIANTS) {
        variant = v;
        String expected = c.prefix().equals("Logout failed") ? "Logout failed (HTTP 401)" : c.prefix() + ": Bad credentials: ***";
        check(c.label() + " " + v, failureOf(auth(SECRET), c.call()), expected, forms(c.value()), wrong, table);
      }
    }
    System.out.println("[AuthEchoedSecretFormsTest 본문 값]\n  " + String.join("\n  ", table));
    assertTrue(wrong.isEmpty(), () -> wrong.size() + " 건:\n" + String.join("\n", wrong));
  }

  /** 짝 없는 서로게이트 — UTF-8 이 그 자리에 {@code ?} 를 실어 보내므로 IdP 는 그 꼴을 되울린다(받은 꼴). */
  @Test void echoedSecret_inItsReceivedForm_isMasked() {
    String surrogate = "sur ab\uD800cd/+=~0006";
    target = BASIC;
    List<String> wrong = new ArrayList<>();
    List<String> table = new ArrayList<>();
    for (String v : VARIANTS) {
      variant = v;
      check("cc · surrogate secret " + v, failureOf(auth(surrogate), AuthClient::clientCredentialsToken),
          "Client credentials failed: Bad credentials: ***", basicForms(surrogate), wrong, table);
    }
    System.out.println("[AuthEchoedSecretFormsTest 받은 꼴]\n  " + String.join("\n  ", table));
    assertTrue(wrong.isEmpty(), () -> wrong.size() + " 건:\n" + String.join("\n", wrong));
  }
}
