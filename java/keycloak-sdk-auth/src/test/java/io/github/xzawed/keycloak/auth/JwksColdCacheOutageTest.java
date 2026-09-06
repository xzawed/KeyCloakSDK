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
import java.time.Duration;
import java.util.Date;
import java.util.Set;
import java.util.concurrent.atomic.AtomicInteger;
import org.junit.jupiter.api.Test;

/**
 * 콜드 캐시 + IdP 장애에서 JWKS 조회가 유계인가.
 *
 * <p>⚠️ 이 축은 <b>워밍 캐시 rate-limit 테스트가 볼 수 없는 자리</b>다. 30초 게이트는 캐시가 찬 뒤
 * 미해결 kid 폭주를 막는 것이고, 캐시가 <b>빈 채 fetch 가 계속 실패</b>하면 그 게이트에 닿기 전이다.
 * 나머지 일곱 언어는 정확히 거기서 무유계였다(20 검증 → IdP 요청 20).
 *
 * <p>실측 2026-09-06: Java 는 <b>이미 유계</b>다 — Nimbus 의 {@code RateLimitedJWKSetSource} 가
 * 실패한 조회에도 창을 적용해 20회 검증이 요청 2건에 그친다(그 「2」는 창을 열 때 한 건이 이미
 * 크레딧되는 Nimbus 관용으로, 워밍 경로의 상한과 같은 값이다). <b>고칠 것이 없다.</b>
 *
 * <p>⚠️ 이 테스트의 무게는 상한 단언이 아니라 <b>대조군</b>에 있다. rate-limit 을 0 으로 풀면 같은
 * 프로브가 20 을 본다 — 그것이 없으면 「2」가 게이트 덕인지 프로브가 애초에 못 재는 것인지 갈리지
 * 않는다.
 *
 * <p>⚠️ <b>상한 단언만으로는 하드닝 삭제를 못 잡는다 — 변이로 실측했다.</b>
 * {@code forRealm} 에서 {@code .rateLimited(cfg.getJwksMinRefetch()...)} 를 지우면
 * {@code JWKSourceBuilder} 의 <b>기본</b> rate-limit(30초)이 대신 걸려 상한은 그대로 2다.
 * 그때 무너지는 것은 <b>대조군</b>이다 — interval 0 이 20 → 2 로 떨어져 「설정 노브가 죽었다」를
 * 가리킨다(실측: 변이 → 1 failed · 복원 → 0 failed · {@code git diff} 빈 출력).
 * <b>대조군 레그를 지우면 이 테스트는 하드닝 삭제에 침묵한다.</b>
 */
class JwksColdCacheOutageTest {

  /** 창당 상한. Nimbus 는 창을 열 때 한 건을 이미 크레딧한다 — `.claude/rules/security.md`. */
  private static final int WINDOW_CEILING = 2;

  private static final int ATTEMPTS = 20;

  @Test
  void coldCacheDuringIdpOutage_isBounded() throws Exception {
    RSAKey signing = new RSAKeyGenerator(2048).keyID("k1").generate();

    AtomicInteger down = new AtomicInteger();
    com.sun.net.httpserver.HttpServer failing = server(down, -1, null);
    int coldFailing;
    try {
      coldFailing = run(failing, down, signing, ATTEMPTS, null);
    } finally {
      failing.stop(0);
    }

    AtomicInteger okHits = new AtomicInteger();
    byte[] body = new JWKSet(signing.toPublicJWK()).toString()
        .getBytes(java.nio.charset.StandardCharsets.UTF_8);
    com.sun.net.httpserver.HttpServer healthy = server(okHits, 200, body);
    int warmOk;
    try {
      warmOk = run(healthy, okHits, signing, ATTEMPTS, null);
    } finally {
      healthy.stop(0);
    }

    // 대조군(알려진 양성) — 게이트를 풀면 같은 프로브가 폭주를 본다.
    AtomicInteger ungated = new AtomicInteger();
    com.sun.net.httpserver.HttpServer failing2 = server(ungated, -1, null);
    int coldUngated;
    try {
      coldUngated = run(failing2, ungated, signing, ATTEMPTS, Duration.ZERO);
    } finally {
      failing2.stop(0);
    }

    assertTrue(coldUngated >= ATTEMPTS / 2,
        "대조군이 폭주를 못 보면 이 테스트는 공허하다 — rate-limit 0 에서 실제=" + coldUngated);
    assertTrue(coldFailing <= WINDOW_CEILING,
        "콜드 캐시 + IdP 503 에서 " + ATTEMPTS + "회 검증이 요청 " + WINDOW_CEILING
            + "건을 넘으면 안 된다 — 실제=" + coldFailing);
    assertTrue(warmOk <= WINDOW_CEILING,
        "정상 IdP + 미해결 kid 폭주도 같은 상한이다 — 실제=" + warmOk);
  }

  /** code<0 이면 503. hits 는 모든 요청을 센다. */
  private static com.sun.net.httpserver.HttpServer server(AtomicInteger hits, int code, byte[] body)
      throws Exception {
    com.sun.net.httpserver.HttpServer s =
        com.sun.net.httpserver.HttpServer.create(new java.net.InetSocketAddress("127.0.0.1", 0), 0);
    s.createContext("/realms/r/protocol/openid-connect/certs", ex -> {
      hits.incrementAndGet();
      if (code < 0) {
        ex.sendResponseHeaders(503, -1);
        ex.close();
        return;
      }
      ex.getResponseHeaders().add("Content-Type", "application/json");
      ex.sendResponseHeaders(code, body.length);
      try (java.io.OutputStream os = ex.getResponseBody()) {
        os.write(body);
      }
    });
    s.start();
    return s;
  }

  /** 콜드 캐시에서 시작해 attempts 회 검증하고, 그동안의 JWKS 요청 수를 돌려준다. */
  private static int run(com.sun.net.httpserver.HttpServer s, AtomicInteger hits, RSAKey signing,
      int attempts, Duration minRefetch) throws Exception {
    io.github.xzawed.keycloak.core.KeycloakConfig.Builder b =
        io.github.xzawed.keycloak.core.KeycloakConfig.builder()
            .serverUrl("http://127.0.0.1:" + s.getAddress().getPort())
            .realm("r").clientId("app");
    if (minRefetch != null) b = b.jwksMinRefetch(minRefetch);
    io.github.xzawed.keycloak.core.KeycloakConfig cfg = b.build();
    OidcMetadata md = OidcMetadata.forRealm(cfg);
    JwtValidator v = JwtValidator.forRealm(md, cfg, Set.of(JWSAlgorithm.RS256), "app");
    hits.set(0);
    for (int i = 0; i < attempts; i++) {
      SignedJWT jwt = new SignedJWT(
          new JWSHeader.Builder(JWSAlgorithm.RS256).keyID("unknown-" + i).build(),
          new JWTClaimsSet.Builder().issuer(md.getIssuer()).audience("app")
              .expirationTime(new Date(System.currentTimeMillis() + 60_000)).build());
      jwt.sign(new RSASSASigner(signing));
      final String serialized = jwt.serialize();
      assertThrows(io.github.xzawed.keycloak.core.exception.TokenValidationException.class,
          () -> v.validate(serialized), "미해결 kid 토큰은 항상 거부되어야 한다");
    }
    return hits.get();
  }
}
