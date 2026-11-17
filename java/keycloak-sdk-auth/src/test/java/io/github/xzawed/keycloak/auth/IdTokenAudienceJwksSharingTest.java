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
import com.sun.net.httpserver.HttpServer;
import io.github.xzawed.keycloak.core.KeycloakConfig;
import io.github.xzawed.keycloak.core.TokenSet;
import io.github.xzawed.keycloak.core.exception.KeycloakAuthException;
import io.github.xzawed.keycloak.core.exception.TokenValidationException;
import java.io.OutputStream;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.Date;
import java.util.List;
import java.util.Set;
import java.util.concurrent.atomic.AtomicInteger;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;

/**
 * 교환의 id_token 과 {@code validate()} 의 액세스 토큰은 요구 {@code aud} 만 다르고 <b>키 원천 하나</b>를 나눈다 —
 * JWKS 캐시·재조회 제한·콜드 캐시 창이 하나다.
 *
 * <p>등록부 {@code id-token-audience-follows-access-audience}(판정 (a))의 수용 기준 A5. id_token 을 clientId 로
 * 따로 검증하게 되면서 생긴 위험은 「검증기를 하나 더 만든다 = 키 저장소를 하나 더 만든다」이다 — 그러면 교환 뒤 첫
 * {@code validate()} 가 JWKS 를 다시 받고, IdP 장애 때 창당 상한이 두 배가 된다. 주입 시임을 쓰지 않는다 — 실코드의
 * {@code forRealm} 경로(공개 생성자)를 지나야 저장소가 몇 개 생기는지가 보인다. 같은 이유로 A3(액세스 검증은 재정의를
 * 쓴다)도 여기서 한 번 더 본다: 시임을 쓰는 {@code AuthClientNonceTest} 는 {@code forRealm} 에 넘기는 audience 를 못 본다.
 *
 * <p>⚠️ 무게는 <b>대조군</b>에 있다({@code .claude/rules/java.md}). 같은 서버·같은 토큰으로 저장소를 둘 만든 대조군이
 * 정상일 때 2, 장애일 때 상한 초과를 보지 못하면, 1 과 「≤ 2」 는 공유 덕인지 프로브가 애초에 못 재는 것인지 갈리지 않는다.
 * 창당 상한이 1 이 아니라 2 인 이유는 {@code .claude/rules/security.md}(Nimbus 는 창을 열 때 한 건을 이미 크레딧한다).
 */
class IdTokenAudienceJwksSharingTest {

  private static final int WINDOW_CEILING = 2;
  private static final int ROUNDS = 10;
  private static final String CLIENT_ID = "app";
  private static final String OVERRIDE = "api";
  private static final String NONCE = "expected-nonce";
  private static final String VERIFIER = "v".repeat(43);
  private static final URI CALLBACK = URI.create("http://localhost/cb");

  private final AtomicInteger certsHits = new AtomicInteger();
  private HttpServer server;
  private String issuer;
  private String idToken;
  private String accessToken;

  @AfterEach
  void stopServer() {
    if (server != null) server.stop(0);
  }

  @Test
  void exchangeThenValidate_underAudienceOverride_fetchesTheJwksOnce() throws Exception {
    start(200);
    KeycloakConfig cfg = config(null);
    OidcMetadata md = OidcMetadata.forRealm(cfg);
    AuthClient client = new AuthClient(cfg, md);

    certsHits.set(0);
    TokenSet ts = client.exchangeCode("c", CALLBACK, VERIFIER, NONCE);
    assertEquals(idToken, ts.getIdToken());
    // A3 — forRealm 경로에서도 validate() 는 재정의를 찾는다: 액세스(aud=api)는 통과, id_token(aud=app)은 거부. 거부는 aud
    // 검사의 것이다(이 토큰은 typ "ID" 지만 typ 은 aud 검사 뒤에야 본다 — 「not an access token」이 이 자리를 대신 채우지
    // 못하게 메시지까지 본다).
    assertTrue(client.validate(ts.getAccessToken()).getAudience().contains(OVERRIDE));
    assertEquals("JWT validation failed",
        assertThrows(TokenValidationException.class, () -> client.validate(ts.getIdToken())).getMessage());
    int shared = certsHits.get();

    // 대조군: 저장소 둘 — 같은 서버·같은 두 토큰을 각자의 forRealm 검증기로. id_token(typ "ID")은 id_token 검증기로 본다 — 액세스
    // 검증기는 typ "ID" 를 거부한다.
    certsHits.set(0);
    JwtValidator.forRealm(md, cfg, Set.of(JWSAlgorithm.RS256), OVERRIDE).withAudience(CLIENT_ID).validate(idToken);
    JwtValidator.forRealm(md, cfg, Set.of(JWSAlgorithm.RS256), OVERRIDE).validate(accessToken);
    int separate = certsHits.get();

    assertEquals(2, separate, "대조군이 저장소 둘을 못 세면 이 테스트는 공허하다 — 실제=" + separate);
    assertEquals(1, shared,
        "교환 뒤 validate() 가 JWKS 를 다시 받았다 — id_token 검증기가 제 키 저장소를 가졌다. 실제=" + shared);
  }

  // 공개 id_token 검증(validateIdToken — 교환을 거치지 않는 소비자의 길)도 validate() 와 키 원천 하나를 쓴다. 순서를 둘 다 친다:
  // 어느 쪽이 먼저 적재하든 다른 쪽은 그 캐시를 쓴다. 대조군은 위 시험과 같다 — 저장소 둘이면 조회도 둘이다.
  @Test
  void validateIdTokenAndValidate_underAudienceOverride_fetchTheJwksOnce() throws Exception {
    start(200);
    KeycloakConfig cfg = config(null);
    OidcMetadata md = OidcMetadata.forRealm(cfg);

    AuthClient idFirst = new AuthClient(cfg, md);
    certsHits.set(0);
    assertEquals(List.of(CLIENT_ID), idFirst.validateIdToken(idToken).getAudience());
    assertTrue(idFirst.validate(accessToken).getAudience().contains(OVERRIDE));
    int sharedIdFirst = certsHits.get();

    AuthClient accessFirst = new AuthClient(cfg, md);
    certsHits.set(0);
    assertTrue(accessFirst.validate(accessToken).getAudience().contains(OVERRIDE));
    assertEquals(List.of(CLIENT_ID), accessFirst.validateIdToken(idToken).getAudience());
    int sharedAccessFirst = certsHits.get();

    // 대조군: 저장소 둘 — 같은 서버·같은 두 토큰을 클라이언트 둘에 나눠서.
    certsHits.set(0);
    new AuthClient(cfg, md).validateIdToken(idToken);
    new AuthClient(cfg, md).validate(accessToken);
    int separate = certsHits.get();

    assertEquals(2, separate, "대조군이 저장소 둘을 못 세면 이 테스트는 공허하다 — 실제=" + separate);
    assertEquals(1, sharedIdFirst,
        "validateIdToken 뒤 validate() 가 JWKS 를 다시 받았다 — 공개 id_token 검증이 제 키 저장소를 가졌다. 실제=" + sharedIdFirst);
    assertEquals(1, sharedAccessFirst,
        "validate() 뒤 validateIdToken 이 JWKS 를 다시 받았다 — 공개 id_token 검증이 제 키 저장소를 가졌다. 실제="
            + sharedAccessFirst);
  }

  @Test
  void coldCacheOutage_exchangesAndValidations_shareOneRateLimitWindow() throws Exception {
    start(-1);

    int shared = flood(config(null));
    // 공개 id_token 검증과 validate() 를 번갈아도 창 하나다 — 교환 대신 공개 메서드로 같은 프로브.
    int sharedPublic = floodPublic(config(null));
    // 대조군 1: 창을 풀면(interval 0) 같은 프로브가 폭주를 본다 — 「≤ 2」 가 게이트 덕임을 고정한다.
    int ungated = flood(config(Duration.ZERO));
    int ungatedPublic = floodPublic(config(Duration.ZERO));
    // 대조군 2: 저장소 둘 — 창도 둘이라 상한을 넘는다. 이것이 공유의 삭제를 보는 눈이다.
    int separate = floodTwoStores(config(null));

    assertTrue(ungated >= ROUNDS, "rate-limit 0 에서 폭주를 못 보면 이 프로브는 공허하다 — 실제=" + ungated);
    assertTrue(ungatedPublic >= ROUNDS, "rate-limit 0 에서 공개 메서드 프로브가 폭주를 못 본다 — 실제=" + ungatedPublic);
    assertTrue(separate > WINDOW_CEILING,
        "저장소 둘이 창 하나의 상한 안에 들면 이 프로브는 공유를 못 가른다 — 실제=" + separate);
    assertTrue(shared <= WINDOW_CEILING, "콜드 캐시 + IdP 503 에서 교환 " + ROUNDS + " + validate " + ROUNDS
        + " 회가 창 하나(" + WINDOW_CEILING + ")를 넘었다 — 실제=" + shared);
    assertTrue(sharedPublic <= WINDOW_CEILING, "콜드 캐시 + IdP 503 에서 validateIdToken " + ROUNDS + " + validate "
        + ROUNDS + " 회가 창 하나(" + WINDOW_CEILING + ")를 넘었다 — 실제=" + sharedPublic);
  }

  /** 공개 생성자(실코드 경로)로 교환과 validate 를 번갈아 부르고 그동안의 JWKS 요청 수를 돌려준다. */
  private int flood(KeycloakConfig cfg) {
    AuthClient client = new AuthClient(cfg, OidcMetadata.forRealm(cfg));
    certsHits.set(0);
    for (int i = 0; i < ROUNDS; i++) {
      KeycloakAuthException e = assertThrows(KeycloakAuthException.class,
          () -> client.exchangeCode("c", CALLBACK, VERIFIER, NONCE));
      assertEquals("Authorization code exchange failed: invalid id_token", e.getMessage());
      assertThrows(TokenValidationException.class, () -> client.validate(accessToken));
    }
    return certsHits.get();
  }

  /** 공개 생성자로 validateIdToken 과 validate 를 번갈아 부르고 그동안의 JWKS 요청 수를 돌려준다(교환 없이). */
  private int floodPublic(KeycloakConfig cfg) {
    AuthClient client = new AuthClient(cfg, OidcMetadata.forRealm(cfg));
    certsHits.set(0);
    for (int i = 0; i < ROUNDS; i++) {
      assertThrows(TokenValidationException.class, () -> client.validateIdToken(idToken));
      assertThrows(TokenValidationException.class, () -> client.validate(accessToken));
    }
    return certsHits.get();
  }

  private int floodTwoStores(KeycloakConfig cfg) {
    OidcMetadata md = OidcMetadata.forRealm(cfg);
    JwtValidator forId = JwtValidator.forRealm(md, cfg, Set.of(JWSAlgorithm.RS256), CLIENT_ID);
    JwtValidator forAccess = JwtValidator.forRealm(md, cfg, Set.of(JWSAlgorithm.RS256), OVERRIDE);
    certsHits.set(0);
    for (int i = 0; i < ROUNDS; i++) {
      assertThrows(TokenValidationException.class, () -> forId.validate(idToken));
      assertThrows(TokenValidationException.class, () -> forAccess.validate(accessToken));
    }
    return certsHits.get();
  }

  private KeycloakConfig config(Duration minRefetchOrNull) {
    KeycloakConfig.Builder b = KeycloakConfig.builder()
        .serverUrl("http://127.0.0.1:" + server.getAddress().getPort()).realm("r")
        .clientId(CLIENT_ID).expectedAudience(OVERRIDE);
    if (minRefetchOrNull != null) b = b.jwksMinRefetch(minRefetchOrNull);
    return b.build();
  }

  /**
   * 토큰 엔드포인트(액세스 aud=api · id_token aud=app, 둘 다 kid k1)와 JWKS 엔드포인트(요청을 센다)를 세운다.
   * certsStatus 가 음수면 JWKS 는 503 이다.
   */
  private void start(int certsStatus) throws Exception {
    RSAKey signing = new RSAKeyGenerator(2048).keyID("k1").generate();
    byte[] jwks = new JWKSet(signing.toPublicJWK()).toString().getBytes(StandardCharsets.UTF_8);
    server = HttpServer.create(new InetSocketAddress(InetAddress.getLoopbackAddress(), 0), 0);
    server.createContext("/realms/r/protocol/openid-connect/certs", ex -> {
      certsHits.incrementAndGet();
      if (certsStatus < 0) {
        ex.sendResponseHeaders(503, -1);
        ex.close();
        return;
      }
      ex.getResponseHeaders().add("Content-Type", "application/json");
      ex.sendResponseHeaders(200, jwks.length);
      try (OutputStream os = ex.getResponseBody()) {
        os.write(jwks);
      }
    });
    server.createContext("/realms/r/protocol/openid-connect/token", ex -> {
      byte[] body = ("{\"access_token\":\"" + accessToken + "\",\"token_type\":\"Bearer\",\"expires_in\":300,"
          + "\"id_token\":\"" + idToken + "\"}").getBytes(StandardCharsets.UTF_8);
      ex.getResponseHeaders().add("Content-Type", "application/json");
      ex.sendResponseHeaders(200, body.length);
      try (OutputStream os = ex.getResponseBody()) {
        os.write(body);
      }
    });
    server.start();
    issuer = "http://127.0.0.1:" + server.getAddress().getPort() + "/realms/r";
    // id_token 은 Keycloak 처럼 typ "ID" 를 싣는다 — id_token 검증기는 그 밖의 typ 을 거부한다.
    idToken = sign(signing, new JWTClaimsSet.Builder().audience(CLIENT_ID).claim("nonce", NONCE).claim("typ", "ID"));
    // 액세스 토큰은 Keycloak 처럼 typ "Bearer" 다 — 액세스 검증기는 Bearer · DPoP 만 받는다.
    accessToken = sign(signing, new JWTClaimsSet.Builder().audience(OVERRIDE).claim("typ", "Bearer"));
  }

  private String sign(RSAKey key, JWTClaimsSet.Builder claims) throws Exception {
    SignedJWT jwt = new SignedJWT(new JWSHeader.Builder(JWSAlgorithm.RS256).keyID("k1").build(),
        claims.issuer(issuer).expirationTime(new Date(System.currentTimeMillis() + 60_000)).build());
    jwt.sign(new RSASSASigner(key));
    return jwt.serialize();
  }
}
