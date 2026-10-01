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
    // A3 — forRealm 경로에서도 validate() 는 재정의를 찾는다: 액세스(aud=api)는 통과, id_token(aud=app)은 거부.
    assertTrue(client.validate(ts.getAccessToken()).getAudience().contains(OVERRIDE));
    assertThrows(TokenValidationException.class, () -> client.validate(ts.getIdToken()));
    int shared = certsHits.get();

    // 대조군: 저장소 둘 — 같은 서버·같은 두 토큰을 각자의 forRealm 검증기로.
    certsHits.set(0);
    JwtValidator.forRealm(md, cfg, Set.of(JWSAlgorithm.RS256), CLIENT_ID).validate(idToken);
    JwtValidator.forRealm(md, cfg, Set.of(JWSAlgorithm.RS256), OVERRIDE).validate(accessToken);
    int separate = certsHits.get();

    assertEquals(2, separate, "대조군이 저장소 둘을 못 세면 이 테스트는 공허하다 — 실제=" + separate);
    assertEquals(1, shared,
        "교환 뒤 validate() 가 JWKS 를 다시 받았다 — id_token 검증기가 제 키 저장소를 가졌다. 실제=" + shared);
  }

  @Test
  void coldCacheOutage_exchangesAndValidations_shareOneRateLimitWindow() throws Exception {
    start(-1);

    int shared = flood(config(null));
    // 대조군 1: 창을 풀면(interval 0) 같은 프로브가 폭주를 본다 — 「≤ 2」 가 게이트 덕임을 고정한다.
    int ungated = flood(config(Duration.ZERO));
    // 대조군 2: 저장소 둘 — 창도 둘이라 상한을 넘는다. 이것이 공유의 삭제를 보는 눈이다.
    int separate = floodTwoStores(config(null));

    assertTrue(ungated >= ROUNDS, "rate-limit 0 에서 폭주를 못 보면 이 프로브는 공허하다 — 실제=" + ungated);
    assertTrue(separate > WINDOW_CEILING,
        "저장소 둘이 창 하나의 상한 안에 들면 이 프로브는 공유를 못 가른다 — 실제=" + separate);
    assertTrue(shared <= WINDOW_CEILING, "콜드 캐시 + IdP 503 에서 교환 " + ROUNDS + " + validate " + ROUNDS
        + " 회가 창 하나(" + WINDOW_CEILING + ")를 넘었다 — 실제=" + shared);
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
    idToken = sign(signing, new JWTClaimsSet.Builder().audience(CLIENT_ID).claim("nonce", NONCE));
    accessToken = sign(signing, new JWTClaimsSet.Builder().audience(OVERRIDE));
  }

  private String sign(RSAKey key, JWTClaimsSet.Builder claims) throws Exception {
    SignedJWT jwt = new SignedJWT(new JWSHeader.Builder(JWSAlgorithm.RS256).keyID("k1").build(),
        claims.issuer(issuer).expirationTime(new Date(System.currentTimeMillis() + 60_000)).build());
    jwt.sign(new RSASSASigner(key));
    return jwt.serialize();
  }
}
