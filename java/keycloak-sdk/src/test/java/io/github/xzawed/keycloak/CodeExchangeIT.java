package io.github.xzawed.keycloak;

import static org.junit.jupiter.api.Assertions.*;

import dasniko.testcontainers.keycloak.KeycloakContainer;
import io.github.xzawed.keycloak.auth.AuthClient;
import io.github.xzawed.keycloak.auth.AuthorizationUrlRequest;
import io.github.xzawed.keycloak.auth.IntrospectionResult;
import io.github.xzawed.keycloak.core.KeycloakConfig;
import io.github.xzawed.keycloak.core.TokenSet;
import io.github.xzawed.keycloak.core.exception.KeycloakAuthException;
import io.github.xzawed.keycloak.core.exception.TokenValidationException;
import java.io.ByteArrayOutputStream;
import java.io.PrintStream;
import java.io.PrintWriter;
import java.io.StringWriter;
import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Base64;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.keycloak.representations.idm.UserRepresentation;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;

/**
 * 인가 코드 교환 E2E — 실제 Keycloak 이 발급한 코드·id_token 으로.
 *
 * <p>{@code exchangeCode} 의 nonce 대조와 id_token 서명 검증은 지금까지 목 토큰으로만 돌았다
 * ({@code AuthClientNonceTest}). 여기서는 {@link BrowserLogin} 으로 실제 로그인해 받은 코드를 교환하고,
 * <b>서버가 서명한</b> 토큰에 대고 거부 경로까지 돈다. python {@code test_code_exchange_it.py} 의 이식이다.
 *
 * <p>realm 의 {@code it-web}(RS256 · PKCE S256 강제 · aud 매퍼)·{@code it-web-hs256}(id_token 을 HS256 서명)과 짝.
 * ⚠️ {@code it-web} 의 audience 매퍼는 introspect 용이다 — {@code aud} 가 없는 접근 토큰을 Keycloak 26.6 은 발급한
 * 그 클라이언트가 물어도 {@code active: false} 로 답한다(python 파일럿 실측).
 */
@Testcontainers
class CodeExchangeIT {

  @Container
  static KeycloakContainer KC =
      new KeycloakContainer("quay.io/keycloak/keycloak:26.6").withRealmImportFile("/it-realm-realm.json");

  static final URI REDIRECT_URI = URI.create("http://localhost/it-callback");
  static final String USERNAME = "alice";
  static final String PASSWORD = "alice-password";
  static final Map<String, String> WEB_CLIENT_SECRETS =
      Map.of("it-web", "it-web-secret", "it-web-hs256", "it-web-hs256-secret");
  static final String UNEXPECTED_NONCE = "Authorization code exchange failed: unexpected nonce";

  /** {@code alice} 의 사용자 id — 토큰의 {@code sub} 와 대조할 <b>독립 원천</b>(admin API)에서 읽는다. */
  static String aliceId;

  @BeforeAll
  static void readAliceId() {
    KeycloakConfig admin = KeycloakConfig.builder()
        .serverUrl(KC.getAuthServerUrl()).realm("it-realm")
        .clientId("it-client").clientSecret("it-secret".toCharArray())
        .build();
    try (KeycloakClient kc = KeycloakClient.create(admin)) {
      List<UserRepresentation> alice = new ArrayList<>();
      for (UserRepresentation u : kc.admin().users().search(USERNAME, 0, 10)) {
        if (USERNAME.equals(u.getUsername())) {
          alice.add(u);
        }
      }
      assertEquals(1, alice.size(), "exactly one alice in it-realm");
      aliceId = alice.get(0).getId();
    }
  }

  static KeycloakConfig webConfig(String clientId, String... algorithms) {
    return KeycloakConfig.builder()
        .serverUrl(KC.getAuthServerUrl()).realm("it-realm")
        .clientId(clientId).clientSecret(WEB_CLIENT_SECRETS.get(clientId).toCharArray())
        .signatureAlgorithms(algorithms.length == 0 ? new String[] {"RS256"} : algorithms)
        .build();
  }

  @Test
  void exchangeCode_bindsTokensToTheNonceAndUser() {
    try (KeycloakClient kc = KeycloakClient.create(webConfig("it-web"))) {
      AuthClient auth = kc.auth();
      AuthorizationUrlRequest request = auth.createAuthorizationRequest(REDIRECT_URI);
      String code = BrowserLogin.login(request, REDIRECT_URI, USERNAME, PASSWORD);

      TokenSet tokens = auth.exchangeCode(code, REDIRECT_URI, request.getCodeVerifier(), request.getNonce());
      assertNotBlank(tokens.getAccessToken());
      assertNotBlank(tokens.getRefreshToken());
      assertNotBlank(tokens.getIdToken());
      Map<String, Object> idClaims = auth.validate(tokens.getIdToken()).getClaims();
      assertEquals(request.getNonce(), idClaims.get("nonce"));
      assertEquals(aliceId, idClaims.get("sub"));
      // 교환이 돌려준 접근 토큰 자체도 서버가 alice 에게 발급한 활성 토큰이다 — 대리값이면 여기서 걸린다(Grok 1:
      // 이 두 줄이 없을 때 exchangeCode 가 접근 토큰만 가짜로 바꿔 내도 이 파일 전부가 초록이었다).
      assertEquals(aliceId, auth.validate(tokens.getAccessToken()).getSubject());
      IntrospectionResult exchanged = auth.introspect(tokens.getAccessToken());
      assertTrue(exchanged.isActive());
      assertEquals(Optional.of(USERNAME), exchanged.getUsername());

      // refresh: 새 접근 토큰을 준다 — 같은 사용자의 활성 토큰이다.
      TokenSet refreshed = auth.refresh(tokens.getRefreshToken());
      assertNotBlank(refreshed.getAccessToken());
      assertNotEquals(tokens.getAccessToken(), refreshed.getAccessToken());
      assertNotBlank(refreshed.getRefreshToken());
      IntrospectionResult active = auth.introspect(refreshed.getAccessToken());
      assertTrue(active.isActive());
      assertEquals(Optional.of(USERNAME), active.getUsername());

      // logout: 세션을 끝낸다 — 그 refresh token 은 더는 갱신되지 않고 접근 토큰은 비활성이 된다.
      auth.logout(refreshed.getRefreshToken());
      KeycloakAuthException ended =
          assertThrows(KeycloakAuthException.class, () -> auth.refresh(refreshed.getRefreshToken()));
      assertEquals("invalid_grant", ended.getError());
      assertFalse(auth.introspect(refreshed.getAccessToken()).isActive());
    }
  }

  /**
   * logout 은 자기가 받은 세션만 끝낸다 — 같은 클라이언트로 연 두 번째 세션은 살아 있다. (Grok 2·3: 이 테스트 전에는
   * refresh·logout·introspect 가 인자 대신 이 인스턴스가 마지막에 본 토큰을 써도 초록이었다 — 세션이 하나뿐이라서.)
   */
  @Test
  void logout_endsOnlyTheSessionItNames() {
    try (KeycloakClient kc = KeycloakClient.create(webConfig("it-web"))) {
      AuthClient auth = kc.auth();
      TokenSet first = loginAndExchange(auth);
      TokenSet second = loginAndExchange(auth);

      auth.logout(first.getRefreshToken());
      assertFalse(auth.introspect(first.getAccessToken()).isActive());
      assertTrue(auth.introspect(second.getAccessToken()).isActive());
      KeycloakAuthException ended =
          assertThrows(KeycloakAuthException.class, () -> auth.refresh(first.getRefreshToken()));
      assertEquals("invalid_grant", ended.getError());
      assertNotBlank(auth.refresh(second.getRefreshToken()).getAccessToken());
    }
  }

  @Test
  void exchangeCode_refusesANonceTheServerDidNotSign() {
    try (KeycloakClient kc = KeycloakClient.create(webConfig("it-web"))) {
      AuthClient auth = kc.auth();
      AuthorizationUrlRequest request = auth.createAuthorizationRequest(REDIRECT_URI);
      String code = BrowserLogin.login(request, REDIRECT_URI, USERNAME, PASSWORD);

      KeycloakAuthException refused = assertThrows(KeycloakAuthException.class,
          () -> auth.exchangeCode(code, REDIRECT_URI, request.getCodeVerifier(), "x" + request.getNonce()));
      assertEquals(UNEXPECTED_NONCE, refused.getMessage());
      assertNull(refused.getError(), "the SDK refused it, not the server");
      assertLeaksNothing(refused, "", sent("it-web", code, request));
    }
  }

  /** nonce 를 빼고 인가받은 코드 — 서버는 nonce 없는 id_token 을 낸다. 부재도 거부다. */
  @Test
  void exchangeCode_refusesAnIdTokenThatCarriesNoNonce() {
    try (KeycloakClient kc = KeycloakClient.create(webConfig("it-web"))) {
      AuthClient auth = kc.auth();
      AuthorizationUrlRequest request = auth.createAuthorizationRequest(REDIRECT_URI);
      URI withoutNonce = BrowserLogin.withoutQueryParameter(request.getAuthorizationUrl(), "nonce");
      assertTrue(BrowserLogin.parseQuery(request.getAuthorizationUrl().getRawQuery()).containsKey("nonce"));
      assertFalse(BrowserLogin.parseQuery(withoutNonce.getRawQuery()).containsKey("nonce"));

      // 전제: 서버가 정말 nonce 없이 서명한다(아니면 아래는 부재가 아니라 불일치를 잰다).
      String first = BrowserLogin.login(withoutNonce, request.getState(), REDIRECT_URI, USERNAME, PASSWORD);
      TokenSet unchecked = auth.exchangeCode(first, REDIRECT_URI, request.getCodeVerifier());
      assertNotBlank(unchecked.getIdToken());
      assertFalse(auth.validate(unchecked.getIdToken()).getClaims().containsKey("nonce"));

      String second = BrowserLogin.login(withoutNonce, request.getState(), REDIRECT_URI, USERNAME, PASSWORD);
      KeycloakAuthException refused = assertThrows(KeycloakAuthException.class,
          () -> auth.exchangeCode(second, REDIRECT_URI, request.getCodeVerifier(), request.getNonce()));
      assertEquals(UNEXPECTED_NONCE, refused.getMessage());
      assertLeaksNothing(refused, "", sent("it-web", second, request));
    }
  }

  @Test
  void reusedCode_isRefusedWithoutLeakingIt() {
    try (KeycloakClient kc = KeycloakClient.create(webConfig("it-web"))) {
      AuthClient auth = kc.auth();
      AuthorizationUrlRequest request = auth.createAuthorizationRequest(REDIRECT_URI);
      String code = BrowserLogin.login(request, REDIRECT_URI, USERNAME, PASSWORD);

      // 로그인 자체(콜백 URL 에 코드가 실린다)는 SDK 의 누출이 아니다 — 여기서부터 stdout·stderr 를 잰다.
      // ⚠️ java.util.logging 은 재지 않는다: 소비자가 FINE 을 켜면 JDK 의 HttpURLConnection 이 요청 헤더를 찍고, 거기에
      // `Authorization: Basic <client_id:secret>` 이 원문으로 있다(실측 2026-09-27, 코드·verifier·토큰은 없음). SDK 가 쓰는
      // 전송 계층의 동작이라 여기서 초록/빨강으로 가를 대상이 아니다 — 커밋 메시지와 보고가 소유한다.
      TokenSet tokens;
      KeycloakAuthException reused;
      PrintStream out = System.out;
      PrintStream err = System.err;
      ByteArrayOutputStream captured = new ByteArrayOutputStream();
      try (PrintStream capture = new PrintStream(captured, true, StandardCharsets.UTF_8)) {
        System.setOut(capture);
        System.setErr(capture);
        tokens = auth.exchangeCode(code, REDIRECT_URI, request.getCodeVerifier(), request.getNonce());
        reused = assertThrows(KeycloakAuthException.class,
            () -> auth.exchangeCode(code, REDIRECT_URI, request.getCodeVerifier(), request.getNonce()));
      } finally {
        System.setOut(out);
        System.setErr(err);
      }
      assertEquals("invalid_grant", reused.getError());

      List<String> hidden = new ArrayList<>(sent("it-web", code, request));
      hidden.addAll(List.of(tokens.getAccessToken(), tokens.getRefreshToken(), tokens.getIdToken()));
      assertLeaksNothing(reused, captured.toString(StandardCharsets.UTF_8), hidden);
    }
  }

  /**
   * {@code it-web-hs256} 의 id_token 은 realm 의 HMAC 키로 서명된다 — 대칭키는 JWKS 에 없다. 알고리즘 핀(RS256)이
   * 먼저 거부하고, 핀을 열어도(RS256·HS256) 그 키를 JWKS 에서 찾지 못해 거부한다. ⚠️ python 과 달리 Java SDK 는
   * 두 사유를 다른 공개 타입으로 가르지 않는다 — 둘 다 {@link TokenValidationException} 이다(Nimbus 가 두 경우를
   * 같은 {@code BadJOSEException} "Another algorithm expected, or no matching key(s) found" 로 낸다, 실측). 그래서 두 번째
   * 변형은 「핀을 열어도 거부된다」만 보이고, 핀이 정말 열렸는지는 이 층에서 안 보인다 — 설정 → 알고리즘 집합 배선은 단위
   * {@code AuthClientNonceTest.allowedAlgorithms_mapsConfiguredStringsToNimbusAlgorithms} 가 잡는다(Grok 4, 변이 실측).
   */
  @ParameterizedTest
  @ValueSource(strings = {"RS256", "RS256,HS256"})
  void idTokenSignedByAKeyOutsideTheJwks_isRefused(String algorithms) {
    try (KeycloakClient kc = KeycloakClient.create(webConfig("it-web-hs256", algorithms.split(",")))) {
      AuthClient auth = kc.auth();
      AuthorizationUrlRequest request = auth.createAuthorizationRequest(REDIRECT_URI);
      String code = BrowserLogin.login(request, REDIRECT_URI, USERNAME, PASSWORD);

      KeycloakAuthException refused = assertThrows(KeycloakAuthException.class,
          () -> auth.exchangeCode(code, REDIRECT_URI, request.getCodeVerifier(), request.getNonce()));
      assertEquals("Authorization code exchange failed: invalid id_token", refused.getMessage());
      assertInstanceOf(TokenValidationException.class, refused.getCause());
      assertLeaksNothing(refused, "", sent("it-web-hs256", code, request));
    }
  }

  /**
   * {@code expectedAudience} 를 정하면 {@code validate} 는 client id 가 아니라 그 값을 {@code aud} 에서 찾는다. 대조군은 같은
   * 토큰이 기본 설정(aud=client id)으로는 통과하는 것 — 거부의 원인이 audience 뿐임을 고정한다. (Grok 8: 이 테스트 전에는
   * {@code AuthClient.validate} 가 {@code expectedAudience} 대신 client id 를 넘겨도 단위 전부·통합 전부가 초록이었다.)
   */
  @Test
  void validate_looksForTheConfiguredAudience_notTheClientId() {
    KeycloakConfig resourceServer = KeycloakConfig.builder()
        .serverUrl(KC.getAuthServerUrl()).realm("it-realm")
        .clientId("it-web").clientSecret(WEB_CLIENT_SECRETS.get("it-web").toCharArray())
        .expectedAudience("it-client")
        .build();
    try (KeycloakClient kc = KeycloakClient.create(webConfig("it-web"));
        KeycloakClient api = KeycloakClient.create(resourceServer)) {
      AuthorizationUrlRequest request = kc.auth().createAuthorizationRequest(REDIRECT_URI);
      String code = BrowserLogin.login(request, REDIRECT_URI, USERNAME, PASSWORD);
      String accessToken =
          kc.auth().exchangeCode(code, REDIRECT_URI, request.getCodeVerifier(), request.getNonce()).getAccessToken();

      assertTrue(kc.auth().validate(accessToken).getAudience().contains("it-web"));
      assertFalse(kc.auth().validate(accessToken).getAudience().contains("it-client"));
      assertThrows(TokenValidationException.class, () -> api.auth().validate(accessToken));
    }
  }

  private static TokenSet loginAndExchange(AuthClient auth) {
    AuthorizationUrlRequest request = auth.createAuthorizationRequest(REDIRECT_URI);
    String code = BrowserLogin.login(request, REDIRECT_URI, USERNAME, PASSWORD);
    return auth.exchangeCode(code, REDIRECT_URI, request.getCodeVerifier(), request.getNonce());
  }

  /** 교환 요청이 실어 보낸 비밀 — 코드·verifier·클라이언트 시크릿·그 Basic 자격. */
  private static List<String> sent(String clientId, String code, AuthorizationUrlRequest request) {
    String secret = WEB_CLIENT_SECRETS.get(clientId);
    String basic = Base64.getEncoder().encodeToString((clientId + ":" + secret).getBytes(StandardCharsets.UTF_8));
    return List.of(code, request.getCodeVerifier(), secret, basic);
  }

  /**
   * 비밀이 메시지·toString·원인 사슬·printStackTrace(원인·suppressed 까지 — 로거가 찍는 형태)·{@code extra} 어디에도 없고,
   * JWT 조각({@code eyJ} — base64url 로 쓴 {@code {"})도 없다. 거부 경로에서는 id_token 값을 모르므로 모양으로 잰다
   * (Grok 7: 이 검사 전에는 nonce 거부가 id_token 을 원인에 실어도 초록이었다).
   */
  private static void assertLeaksNothing(Throwable e, String extra, List<String> secrets) {
    StringWriter trace = new StringWriter();
    e.printStackTrace(new PrintWriter(trace));
    String printed = trace + extra;
    assertFalse(printed.contains("eyJ"), "a JWT fragment is printed:\n" + printed);
    for (String secret : secrets) {
      assertNotBlank(secret);
      assertFalse(e.getMessage().contains(secret), "message leaks a secret: " + e.getMessage());
      assertFalse(e.toString().contains(secret), "toString leaks a secret");
      for (Throwable t = e.getCause(); t != null; t = t.getCause()) {
        assertFalse(String.valueOf(t).contains(secret), "cause leaks a secret: " + t.getClass().getName());
      }
      assertFalse(printed.contains(secret), "stack trace or stdout/stderr leaks a secret");
    }
  }

  private static void assertNotBlank(String value) {
    assertNotNull(value);
    assertFalse(value.isBlank());
  }
}
