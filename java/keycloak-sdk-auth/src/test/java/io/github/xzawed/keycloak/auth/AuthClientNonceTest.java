package io.github.xzawed.keycloak.auth;
import static org.junit.jupiter.api.Assertions.*;
import com.nimbusds.jose.JWSAlgorithm;
import com.nimbusds.jose.JWSHeader;
import com.nimbusds.jose.crypto.RSASSASigner;
import com.nimbusds.jose.jwk.JWKSet;
import com.nimbusds.jose.jwk.RSAKey;
import com.nimbusds.jose.jwk.gen.RSAKeyGenerator;
import com.nimbusds.jwt.JWTClaimsSet;
import com.nimbusds.jwt.SignedJWT;
import com.nimbusds.oauth2.sdk.token.BearerAccessToken;
import com.nimbusds.oauth2.sdk.token.RefreshToken;
import com.nimbusds.oauth2.sdk.token.Tokens;
import com.nimbusds.openid.connect.sdk.token.OIDCTokens;
import io.github.xzawed.keycloak.core.KeycloakConfig;
import io.github.xzawed.keycloak.core.TokenSet;
import io.github.xzawed.keycloak.core.exception.KeycloakAuthException;
import io.github.xzawed.keycloak.core.exception.TokenValidationException;
import com.sun.net.httpserver.HttpServer;
import java.io.OutputStream;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.Date;
import java.util.List;
import java.util.Set;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;

// OIDC nonce 재생 방지 회귀 테스트: exchangeCode가 id_token을 보존하고(현재는 null 폐기),
// expectedNonce가 주어지면 응답 id_token을 강화 JwtValidator로 서명검증한 뒤 nonce를 대조하는지
// 검증한다. 검증기는 정적 JWKS를 주입(테스트 시임)해 실 RSA 서명 id_token으로 검증한다.
// ⚠️ 「토큰 엔드포인트 send()는 브라우저 로그인이 필요해 단위로 못 간다」는 틀렸다 — code 를
// 검사하는 것은 서버이므로, 토큰 엔드포인트만 JDK 내장 HttpServer 로 세우면 exchangeCode 전체가
// 돈다(아래 exchangeCode_* 셋). 헬퍼만 시험하던 동안 exchangeCode 안의 requireValidNonce 호출을
// 지워도 이 파일 전부가 통과했다(변이 실측 2026-09-25).
class AuthClientNonceTest {
  private static final String ISSUER = "https://kc.example.com/realms/r";
  // Nimbus CodeVerifier 는 43~128 자를 요구한다(RFC 7636 §4.1). 서버(목)는 이 값을 검사하지 않는다.
  private static final String VERIFIER = "v".repeat(43);
  private HttpServer server;

  @AfterEach void stopServer() {
    if (server != null) server.stop(0);
  }

  // id_token 캡처: OIDCTokens가 담은 id_token이 TokenSet.getIdToken()으로 노출돼야 한다.
  @Test void toTokenSet_capturesIdToken_fromOidcTokens() throws Exception {
    RSAKey key = new RSAKeyGenerator(2048).keyID("k1").generate();
    String idToken = signIdToken(key, ISSUER, "app", "n1");
    OIDCTokens tokens =
        new OIDCTokens(idToken, new BearerAccessToken("AT", 300, null), new RefreshToken("RT"));
    TokenSet ts = AuthClient.toTokenSet(tokens, System.currentTimeMillis() / 1000);
    assertEquals(idToken, ts.getIdToken());
    assertEquals("AT", ts.getAccessToken());
  }

  // 비-OIDC 그랜트(client-credentials/refresh)의 플레인 Tokens는 id_token이 없어야 한다(회귀).
  @Test void toTokenSet_plainTokens_hasNullIdToken() {
    Tokens tokens = new Tokens(new BearerAccessToken("AT", 300, null), new RefreshToken("RT"));
    assertNull(AuthClient.toTokenSet(tokens, System.currentTimeMillis() / 1000).getIdToken());
  }

  @Test void requireValidNonce_acceptsMatchingNonce() throws Exception {
    RSAKey key = new RSAKeyGenerator(2048).keyID("k1").generate();
    AuthClient client = clientWithValidator(key);
    String idToken = signIdToken(key, ISSUER, "app", "server-nonce");
    assertDoesNotThrow(() -> client.requireValidNonce(idToken, "server-nonce"));
  }

  @Test void requireValidNonce_rejectsMismatch() throws Exception {
    RSAKey key = new RSAKeyGenerator(2048).keyID("k1").generate();
    AuthClient client = clientWithValidator(key);
    String idToken = signIdToken(key, ISSUER, "app", "server-nonce");
    assertThrows(KeycloakAuthException.class,
        () -> client.requireValidNonce(idToken, "attacker-nonce"));
  }

  @Test void requireValidNonce_rejectsNullIdToken() throws Exception {
    RSAKey key = new RSAKeyGenerator(2048).keyID("k1").generate();
    AuthClient client = clientWithValidator(key);
    assertThrows(KeycloakAuthException.class,
        () -> client.requireValidNonce(null, "server-nonce"));
  }

  // 위조 서명(신뢰하지 않는 키로 서명된) id_token은 nonce가 맞아도 거부돼야 한다.
  @Test void requireValidNonce_rejectsUntrustedIdToken() throws Exception {
    RSAKey trusted = new RSAKeyGenerator(2048).keyID("k1").generate();
    RSAKey attacker = new RSAKeyGenerator(2048).keyID("k1").generate();
    AuthClient client = clientWithValidator(trusted);
    String forged = signIdToken(attacker, ISSUER, "app", "server-nonce");
    assertThrows(KeycloakAuthException.class,
        () -> client.requireValidNonce(forged, "server-nonce"));
  }

  // config의 서명 알고리즘(문자열)이 Nimbus JWSAlgorithm 집합으로 변환돼 검증기에 전달되는지 검증한다
  // (기존 RS256 하드코딩 → 설정 가능). ES256/PS256 realm 지원의 핵심 배선.
  @Test void allowedAlgorithms_mapsConfiguredStringsToNimbusAlgorithms() {
    KeycloakConfig cfg = KeycloakConfig.builder()
        .serverUrl("https://kc.example.com").realm("r").clientId("app")
        .signatureAlgorithms("ES256", "RS256").build();
    AuthClient client = new AuthClient(cfg, OidcMetadata.forRealm(cfg));
    assertEquals(Set.of(JWSAlgorithm.ES256, JWSAlgorithm.RS256), client.allowedAlgorithms());
  }

  @Test void allowedAlgorithms_defaultsToRs256() {
    KeycloakConfig cfg = KeycloakConfig.builder()
        .serverUrl("https://kc.example.com").realm("r").clientId("app").build();
    AuthClient client = new AuthClient(cfg, OidcMetadata.forRealm(cfg));
    assertEquals(Set.of(JWSAlgorithm.RS256), client.allowedAlgorithms());
  }

  // ── exchangeCode 전체 경로 ── 거부 둘은 **메시지까지** 본다: 다른 인증 실패가 초록을 대신 채우지
  // 못하게. 양성 대조(일치 → 성공)가 같은 파이프라인이 통과함을 보여, 거부의 원인이 nonce 뿐임을 고정한다.
  @Test void exchangeCode_rejectsMismatchedNonce_endToEnd() throws Exception {
    RSAKey key = new RSAKeyGenerator(2048).keyID("k1").generate();
    AuthClient client = clientServingToken(key, signIdToken(key, ISSUER, "app", "attacker-nonce"));
    KeycloakAuthException e = assertThrows(KeycloakAuthException.class,
        () -> client.exchangeCode("c", URI.create("http://localhost/cb"), VERIFIER, "expected-nonce"));
    assertTrue(e.getMessage().contains("unexpected nonce"), e.getMessage());
  }

  @Test void exchangeCode_rejectsMissingIdToken_whenNonceExpected() throws Exception {
    RSAKey key = new RSAKeyGenerator(2048).keyID("k1").generate();
    AuthClient client = clientServingToken(key, null);
    KeycloakAuthException e = assertThrows(KeycloakAuthException.class,
        () -> client.exchangeCode("c", URI.create("http://localhost/cb"), VERIFIER, "expected-nonce"));
    assertTrue(e.getMessage().contains("missing id_token"), e.getMessage());
  }

  // 서명은 유효하지만 nonce 클레임이 **없는** id_token — 「있고 다를 때만 거부」로 약해지면 통과한다
  // (독립 레그 지목). OIDC Core §3.1.3.7 은 요청에 nonce 를 보냈으면 클레임이 있어야 한다고 요구한다.
  @Test void exchangeCode_rejectsIdTokenWithoutNonceClaim() throws Exception {
    RSAKey key = new RSAKeyGenerator(2048).keyID("k1").generate();
    AuthClient client = clientServingToken(key, signIdToken(key, ISSUER, "app", null));
    KeycloakAuthException e = assertThrows(KeycloakAuthException.class,
        () -> client.exchangeCode("c", URI.create("http://localhost/cb"), VERIFIER, "expected-nonce"));
    assertTrue(e.getMessage().contains("unexpected nonce"), e.getMessage());
  }

  // 서명만 틀린 RS256 id_token(같은 kid, nonce 일치) — 실서버는 만들 수 없는 토큰이라 통합(CodeExchangeIT)으로는 못 잰다.
  // requireValidNonce_rejectsUntrustedIdToken 은 헬퍼만 본다 — exchangeCode 가 헬퍼 대신 검증 없는 디코드로 nonce 를
  // 대조하도록 바뀌면 그 테스트와 위 exchangeCode_* 셋은 전부 초록이다. 이것이 그 경로를 끝까지 막는다.
  @Test void exchangeCode_rejectsForgedIdTokenWhoseNonceMatches() throws Exception {
    RSAKey trusted = new RSAKeyGenerator(2048).keyID("k1").generate();
    RSAKey attacker = new RSAKeyGenerator(2048).keyID("k1").generate();
    AuthClient client = clientServingToken(trusted, signIdToken(attacker, ISSUER, "app", "expected-nonce"));
    KeycloakAuthException e = assertThrows(KeycloakAuthException.class,
        () -> client.exchangeCode("c", URI.create("http://localhost/cb"), VERIFIER, "expected-nonce"));
    assertEquals("Authorization code exchange failed: invalid id_token", e.getMessage());
    assertInstanceOf(TokenValidationException.class, e.getCause());
  }

  @Test void exchangeCode_acceptsMatchingNonce_endToEnd() throws Exception {
    RSAKey key = new RSAKeyGenerator(2048).keyID("k1").generate();
    String idToken = signIdToken(key, ISSUER, "app", "expected-nonce");
    AuthClient client = clientServingToken(key, idToken);
    TokenSet ts = client.exchangeCode("c", URI.create("http://localhost/cb"), VERIFIER, "expected-nonce");
    assertEquals(idToken, ts.getIdToken());
  }

  // ── expectedAudience 재정의 아래의 교환 ── (등록부 `id-token-audience-follows-access-audience`, 판정 (a))
  // expectedAudience 는 **액세스 토큰**이 향하는 리소스 서버의 이름이다(RFC 9700 §2.3). id_token 의 aud 는 언제나
  // client id 를 담는다(OIDC Core §2·§3.1.3.7, MUST). 예전에는 교환이 id_token 을 validate() 의 검증기로 봐서, 재정의하면
  // 정상 id_token 이 「invalid id_token」으로 거부됐다(실서버 실측 2026-09-27). 주입 시임의 aud 는 **액세스 쪽** 값이고
  // (실코드의 forRealm(…, getExpectedAudience()) 자리), id 쪽은 거기서 clientId 로 파생된다. forRealm 경로와 JWKS 공유는
  // IdTokenAudienceJwksSharingTest 가 본다.
  private static final String OVERRIDE = "api";
  private static final String NONCE = "expected-nonce";

  @Test void exchangeCode_underAudienceOverride_acceptsAnIdTokenForTheClientId() throws Exception {
    RSAKey key = new RSAKeyGenerator(2048).keyID("k1").generate();
    String idToken = sign(key, JWSAlgorithm.RS256, idClaims("app").build());
    AuthClient client = clientServingToken(key, idToken, OVERRIDE);
    TokenSet ts = client.exchangeCode("c", URI.create("http://localhost/cb"), VERIFIER, NONCE);
    assertEquals(idToken, ts.getIdToken());
  }

  // 「Add to ID token」 audience 매퍼를 켠 Keycloak 은 [client_id, extra] 를 낸다(실측) — 포함 검사이지 완전 일치가 아니다.
  @Test void exchangeCode_underAudienceOverride_acceptsAMultiValuedAudienceThatNamesTheClient() throws Exception {
    RSAKey key = new RSAKeyGenerator(2048).keyID("k1").generate();
    String idToken = sign(key, JWSAlgorithm.RS256, idClaims("app", OVERRIDE).build());
    AuthClient client = clientServingToken(key, idToken, OVERRIDE);
    assertEquals(idToken,
        client.exchangeCode("c", URI.create("http://localhost/cb"), VERIFIER, NONCE).getIdToken());
  }

  // 재정의 값만 담은 id_token — 액세스 검증기라면 통과시킬 aud 다. client id 가 없으니 거부한다.
  @Test void exchangeCode_underAudienceOverride_refusesAnIdTokenThatNamesOnlyTheOverride() throws Exception {
    RSAKey key = new RSAKeyGenerator(2048).keyID("k1").generate();
    assertRefusedAsInvalidIdToken(key, sign(key, JWSAlgorithm.RS256, idClaims(OVERRIDE).build()));
  }

  @Test void exchangeCode_underAudienceOverride_refusesAnIdTokenForAnotherClient() throws Exception {
    RSAKey key = new RSAKeyGenerator(2048).keyID("k1").generate();
    assertRefusedAsInvalidIdToken(key, sign(key, JWSAlgorithm.RS256, idClaims("other-client").build()));
  }

  // validate() 는 재정의를 계속 쓴다 — 액세스 토큰은 재정의 값으로 통과하고 client id 만으로는 거부된다.
  @Test void validate_underAudienceOverride_stillLooksForTheOverride() throws Exception {
    RSAKey key = new RSAKeyGenerator(2048).keyID("k1").generate();
    AuthClient client = clientWithValidator(key, OVERRIDE);
    String forApi = sign(key, JWSAlgorithm.RS256, accessClaims(OVERRIDE).build());
    String forClient = sign(key, JWSAlgorithm.RS256, accessClaims("app").build());
    assertTrue(client.validate(forApi).getAudience().contains(OVERRIDE));
    assertThrows(TokenValidationException.class, () -> client.validate(forClient));
  }

  // iss · alg 핀 · exp(필수)·skew · 서명은 재정의 아래에서도 그대로다 — aud 만 바뀐다. 양성 대조는 위 accepts 둘.
  // skew 는 양쪽에서 고정한다: -45s 는 30s 로는 거부이고 Nimbus 기본 60s 로는 통과(아래), -10s 는 30s 로 통과이고 0 으로는 거부.
  @ParameterizedTest
  @ValueSource(strings = {"wrong-issuer", "algorithm-outside-the-pin", "expired-beyond-the-skew", "no-exp",
      "forged-signature"})
  void exchangeCode_underAudienceOverride_keepsTheOtherIdTokenChecks(String variant) throws Exception {
    RSAKey key = new RSAKeyGenerator(2048).keyID("k1").generate();
    String idToken = switch (variant) {
      case "wrong-issuer" ->
          sign(key, JWSAlgorithm.RS256, idClaims("app").issuer("https://evil.example.com/realms/r").build());
      case "algorithm-outside-the-pin" -> sign(key, JWSAlgorithm.RS512, idClaims("app").build());
      case "expired-beyond-the-skew" ->
          sign(key, JWSAlgorithm.RS256, idClaims("app").expirationTime(secondsFromNow(-45)).build());
      case "no-exp" -> sign(key, JWSAlgorithm.RS256, idClaims("app").expirationTime(null).build());
      case "forged-signature" ->
          sign(new RSAKeyGenerator(2048).keyID("k1").generate(), JWSAlgorithm.RS256, idClaims("app").build());
      default -> throw new IllegalArgumentException(variant);
    };
    assertRefusedAsInvalidIdToken(key, idToken);
  }

  @Test void exchangeCode_underAudienceOverride_toleratesExpiryWithinTheSkew() throws Exception {
    RSAKey key = new RSAKeyGenerator(2048).keyID("k1").generate();
    String idToken = sign(key, JWSAlgorithm.RS256, idClaims("app").expirationTime(secondsFromNow(-10)).build());
    AuthClient client = clientServingToken(key, idToken, OVERRIDE);
    assertEquals(idToken,
        client.exchangeCode("c", URI.create("http://localhost/cb"), VERIFIER, NONCE).getIdToken());
  }

  // 메시지까지 본다 — 옛 동작(재정의 aud 로 검증)이면 여기서 nonce 가 아니라 「invalid id_token」이 난다.
  @Test void exchangeCode_underAudienceOverride_stillComparesTheNonce() throws Exception {
    RSAKey key = new RSAKeyGenerator(2048).keyID("k1").generate();
    AuthClient client = clientServingToken(key,
        sign(key, JWSAlgorithm.RS256, idClaims("app").claim("nonce", "attacker-nonce").build()), OVERRIDE);
    KeycloakAuthException e = assertThrows(KeycloakAuthException.class,
        () -> client.exchangeCode("c", URI.create("http://localhost/cb"), VERIFIER, NONCE));
    assertEquals("Authorization code exchange failed: unexpected nonce", e.getMessage());
  }

  private void assertRefusedAsInvalidIdToken(RSAKey key, String idToken) throws Exception {
    AuthClient client = clientServingToken(key, idToken, OVERRIDE);
    KeycloakAuthException e = assertThrows(KeycloakAuthException.class,
        () -> client.exchangeCode("c", URI.create("http://localhost/cb"), VERIFIER, NONCE));
    assertEquals("Authorization code exchange failed: invalid id_token", e.getMessage());
    assertInstanceOf(TokenValidationException.class, e.getCause());
  }

  private static JWTClaimsSet.Builder idClaims(String... audience) {
    return accessClaims(audience).claim("nonce", NONCE);
  }

  private static JWTClaimsSet.Builder accessClaims(String... audience) {
    return new JWTClaimsSet.Builder().issuer(ISSUER).audience(List.of(audience)).expirationTime(secondsFromNow(60));
  }

  private static Date secondsFromNow(int seconds) {
    return new Date(System.currentTimeMillis() + seconds * 1000L);
  }

  private static String sign(RSAKey key, JWSAlgorithm alg, JWTClaimsSet claims) throws Exception {
    SignedJWT jwt = new SignedJWT(new JWSHeader.Builder(alg).keyID("k1").build(), claims);
    jwt.sign(new RSASSASigner(key));
    return jwt.serialize();
  }

  // 토큰 엔드포인트 하나만 서는 로컬 서버. idTokenOrNull 이 null 이면 응답에 id_token 이 없다.
  private AuthClient clientServingToken(RSAKey key, String idTokenOrNull) throws Exception {
    return clientServingToken(key, idTokenOrNull, null);
  }

  // expectedAudienceOrNull 이 주어지면 config 와 주입 검증기(액세스 쪽) 둘 다 그 값을 기대한다.
  private AuthClient clientServingToken(RSAKey key, String idTokenOrNull, String expectedAudienceOrNull)
      throws Exception {
    String body = "{\"access_token\":\"AT\",\"token_type\":\"Bearer\",\"expires_in\":300"
        + (idTokenOrNull == null ? "" : ",\"id_token\":\"" + idTokenOrNull + "\"") + "}";
    byte[] bytes = body.getBytes(StandardCharsets.UTF_8);
    server = HttpServer.create(new InetSocketAddress(InetAddress.getLoopbackAddress(), 0), 0);
    server.createContext("/realms/r/protocol/openid-connect/token", ex -> {
      ex.getResponseHeaders().add("Content-Type", "application/json");
      ex.sendResponseHeaders(200, bytes.length);
      try (OutputStream os = ex.getResponseBody()) {
        os.write(bytes);
      }
    });
    server.start();
    KeycloakConfig cfg = KeycloakConfig.builder()
        .serverUrl("http://127.0.0.1:" + server.getAddress().getPort()).realm("r").clientId("app")
        .expectedAudience(expectedAudienceOrNull)
        .build();
    JwtValidator v = JwtValidator.withStaticJwks(new JWKSet(key.toPublicJWK()), ISSUER, cfg.getExpectedAudience(),
        Set.of(JWSAlgorithm.RS256), Duration.ofSeconds(30));
    return new AuthClient(cfg, OidcMetadata.forRealm(cfg), v);
  }

  private AuthClient clientWithValidator(RSAKey key) throws Exception {
    return clientWithValidator(key, null);
  }

  private AuthClient clientWithValidator(RSAKey key, String expectedAudienceOrNull) throws Exception {
    KeycloakConfig cfg = KeycloakConfig.builder()
        .serverUrl("https://kc.example.com").realm("r").clientId("app")
        .expectedAudience(expectedAudienceOrNull).build();
    JwtValidator v = JwtValidator.withStaticJwks(new JWKSet(key.toPublicJWK()), ISSUER, cfg.getExpectedAudience(),
        Set.of(JWSAlgorithm.RS256), Duration.ofSeconds(30));
    return new AuthClient(cfg, OidcMetadata.forRealm(cfg), v);
  }

  private static String signIdToken(RSAKey key, String issuer, String audience, String nonce)
      throws Exception {
    SignedJWT jwt = new SignedJWT(
        new JWSHeader.Builder(JWSAlgorithm.RS256).keyID("k1").build(),
        new JWTClaimsSet.Builder().issuer(issuer).audience(audience).claim("nonce", nonce)
            .expirationTime(new Date(System.currentTimeMillis() + 60_000)).build());
    jwt.sign(new RSASSASigner(key));
    return jwt.serialize();
  }
}
