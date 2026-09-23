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
import io.github.xzawed.keycloak.core.exception.TokenValidationException;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.Date;
import java.util.Set;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicReference;
import org.junit.jupiter.api.Test;

/**
 * 200 + {@code {"keys":[]}} 가 이미 올라간 좋은 JWKS 캐시를 덮으면 안 된다(#520 의 JVM 절반).
 *
 * <p>실측 2026-09-24(수정 전): 빈 200 뒤 같은 k1 토큰도, 새로 서명한 k1 토큰도 {@code no matching
 * key(s)} 로 거부됐다 — Nimbus 의 캐시는 파싱에 성공한 집합이면 빈 집합도 그대로 올린다.
 *
 * <p>⚠️ <b>재조회 단언이 이 테스트의 전제다.</b> 두 번째 요청이 없으면 빈 응답을 한 번도 안 본
 * 것이므로 k1 이 통과해도 아무것도 증명하지 않는다 — 그래서 rate-limit 을 0 으로 풀고 요청 수를
 * 먼저 단언한다(판정 행렬의 「판정 불가」를 테스트 실패로 바꾼다).
 */
class JwksEmptyKeysetTest {

  @Test
  void empty200_doesNotPoisonGoodCache() throws Exception {
    RSAKey k1 = new RSAKeyGenerator(2048).keyID("k1").generate();
    RSAKey k2 = new RSAKeyGenerator(2048).keyID("k2").generate();
    AtomicInteger hits = new AtomicInteger();
    AtomicReference<byte[]> body = new AtomicReference<>(
        new JWKSet(k1.toPublicJWK()).toString().getBytes(StandardCharsets.UTF_8));

    com.sun.net.httpserver.HttpServer s =
        com.sun.net.httpserver.HttpServer.create(new java.net.InetSocketAddress("127.0.0.1", 0), 0);
    s.createContext("/realms/r/protocol/openid-connect/certs", ex -> {
      hits.incrementAndGet();
      byte[] b = body.get();
      ex.getResponseHeaders().add("Content-Type", "application/json");
      ex.sendResponseHeaders(200, b.length);
      try (java.io.OutputStream os = ex.getResponseBody()) {
        os.write(b);
      }
    });
    s.start();
    try {
      io.github.xzawed.keycloak.core.KeycloakConfig cfg =
          io.github.xzawed.keycloak.core.KeycloakConfig.builder()
              .serverUrl("http://127.0.0.1:" + s.getAddress().getPort())
              .realm("r").clientId("app")
              .jwksMinRefetch(Duration.ZERO)
              .build();
      OidcMetadata md = OidcMetadata.forRealm(cfg);
      JwtValidator v = JwtValidator.forRealm(md, cfg, Set.of(JWSAlgorithm.RS256), "app");

      String good = token(md, k1, "user-1");
      v.validate(good);
      int before = hits.get();

      body.set("{\"keys\":[]}".getBytes(StandardCharsets.UTF_8));
      String unknownKid = token(md, k2, "user-1");
      assertThrows(TokenValidationException.class, () -> v.validate(unknownKid));
      assertTrue(hits.get() > before,
          "미해결 kid 가 재조회를 일으키지 않으면 빈 응답을 본 적이 없다 — 이 테스트는 공허하다");

      assertEquals("user-1", v.validate(good).getSubject(),
          "빈 200 이 좋은 캐시를 덮었다 — 방금 검증되던 토큰이 거부된다");
      assertEquals("user-2", v.validate(token(md, k1, "user-2")).getSubject(),
          "빈 200 뒤 같은 키로 새로 서명한 토큰도 통과해야 한다");
    } finally {
      s.stop(0);
    }
  }

  private static String token(OidcMetadata md, RSAKey key, String sub) throws Exception {
    SignedJWT jwt = new SignedJWT(
        new JWSHeader.Builder(JWSAlgorithm.RS256).keyID(key.getKeyID()).build(),
        new JWTClaimsSet.Builder().issuer(md.getIssuer()).audience("app").subject(sub)
            .expirationTime(new Date(System.currentTimeMillis() + 60_000)).build());
    jwt.sign(new RSASSASigner(key));
    return jwt.serialize();
  }
}
