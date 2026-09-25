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
import com.sun.net.httpserver.HttpServer;
import java.io.OutputStream;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.Date;
import java.util.Set;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;

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

  private KeycloakConfig config() {
    return KeycloakConfig.builder()
        .serverUrl("https://kc.example.com").realm("r").clientId("app").build();
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

  @Test void exchangeCode_acceptsMatchingNonce_endToEnd() throws Exception {
    RSAKey key = new RSAKeyGenerator(2048).keyID("k1").generate();
    String idToken = signIdToken(key, ISSUER, "app", "expected-nonce");
    AuthClient client = clientServingToken(key, idToken);
    TokenSet ts = client.exchangeCode("c", URI.create("http://localhost/cb"), VERIFIER, "expected-nonce");
    assertEquals(idToken, ts.getIdToken());
  }

  // 토큰 엔드포인트 하나만 서는 로컬 서버. idTokenOrNull 이 null 이면 응답에 id_token 이 없다.
  private AuthClient clientServingToken(RSAKey key, String idTokenOrNull) throws Exception {
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
        .build();
    JwtValidator v = JwtValidator.withStaticJwks(new JWKSet(key.toPublicJWK()), ISSUER, "app",
        Set.of(JWSAlgorithm.RS256), Duration.ofSeconds(30));
    return new AuthClient(cfg, OidcMetadata.forRealm(cfg), v);
  }

  private AuthClient clientWithValidator(RSAKey key) throws Exception {
    KeycloakConfig cfg = config();
    JwtValidator v = JwtValidator.withStaticJwks(new JWKSet(key.toPublicJWK()), ISSUER, "app",
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
