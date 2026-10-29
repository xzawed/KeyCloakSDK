package io.github.xzawed.keycloak.auth;

import static org.junit.jupiter.api.Assertions.*;

import com.nimbusds.jose.JWSAlgorithm;
import com.nimbusds.jose.JWSHeader;
import com.nimbusds.jose.KeySourceException;
import com.nimbusds.jose.crypto.RSASSASigner;
import com.nimbusds.jose.jwk.JWK;
import com.nimbusds.jose.jwk.JWKSelector;
import com.nimbusds.jose.jwk.JWKSet;
import com.nimbusds.jose.jwk.RSAKey;
import com.nimbusds.jose.jwk.gen.RSAKeyGenerator;
import com.nimbusds.jose.jwk.source.CachingJWKSetSource;
import com.nimbusds.jose.jwk.source.JWKSetBasedJWKSource;
import com.nimbusds.jose.jwk.source.JWKSetCacheRefreshEvaluator;
import com.nimbusds.jose.jwk.source.JWKSetSource;
import com.nimbusds.jose.jwk.source.JWKSetSourceWrapper;
import com.nimbusds.jose.jwk.source.JWKSource;
import com.nimbusds.jose.jwk.source.OutageTolerantJWKSetSource;
import com.nimbusds.jose.proc.SecurityContext;
import com.nimbusds.jwt.JWTClaimsSet;
import com.nimbusds.jwt.SignedJWT;
import io.github.xzawed.keycloak.core.KeycloakConfig;
import io.github.xzawed.keycloak.core.exception.TokenValidationException;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Date;
import java.util.List;
import java.util.Set;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicLong;
import java.util.concurrent.atomic.AtomicReference;
import org.junit.jupiter.api.Test;

/**
 * JWKS 키 집합의 수명 300초 — 지나면 콜드 캐시처럼 다시 가져오고, 낡은 집합으로 물러서지 않는다(등록부
 * jwks-cache-lifetime-divergent, 판정 2026-10-29 — 아홉 언어가 같은 규칙. Kotlin 자매는 같은 이름의 시험).
 *
 * <p><b>시계.</b> Nimbus 는 시각을 {@link JWKSetBasedJWKSource#get} 한 자리에서만 {@code System.currentTimeMillis()}
 * 로 읽어 체인 아래로 넘긴다 — 캐시 만료 · rate-limit 창 · refresh-ahead 가 모두 그 값을 쓴다. 그래서 {@code forRealm}
 * 이 만든 체인({@code jwkSource()})은 그대로 두고 맨 위 어댑터만 가짜 시계로 바꾼다. {@link FakeClockJwkSource} 는
 * {@code JWKSetBasedJWKSource.get} 을 줄 단위로 옮긴 것이다(시각을 읽는 자리만 다르다).
 *
 * <p>⚠️ 시각은 <b>리터럴</b>(299 · 301 · 350초)이다 — 상수에서 파생하면 상수를 바꾼 변이를 따라가 초록으로 남는다.
 *
 * <p>⚠️ <b>JVM 이 다른 둘</b>(규칙은 같다 — 300초가 지난 집합은 쓰지 않는다): (1) 실패 백오프(0.2→5초)가 없고 그 자리를
 * Nimbus rate-limit(창 jwksMinRefetch 30초 · 창당 2회)이 맡는다 — 그래서 T2 의 「창 안」은 30초이고 창 안 둘째 검증이
 * 크레딧된 한 번을 더 쓴다. (2) refresh-ahead(기본 켜짐)가 TTL 의 마지막 30초에 온 검증을 캐시로 통과시키고 백그라운드로
 * 한 번 미리 가져온다 — 그래서 T1 의 「조회 없음」은 그 창 밖(269초)에서 재고, 299초는 refreshAhead_* 둘이 잰다(실측:
 * 299초 「조회 없음」 단언은 expected 1 but was 2). 나이를 줄일 뿐 늘리지 않는다 — 장애면 301초에 거부된다.
 *
 * <p>⚠️ <b>잔여</b>: Nimbus 는 나이를 그 조회를 부른 검증이 <b>시작한</b> 시각부터, monotonic 이 아니라 벽시계로 센다
 * ({@code JWKSetBasedJWKSource.get} 의 {@code System.currentTimeMillis()} · {@code AbstractCachingJWKSetSource.cacheJWKSet}
 * 의 만료 = fetchTime + TTL). 앞의 것은 수명을 조회 시간만큼 줄이고, 벽시계를 뒤로 돌리면 그만큼 늘어난다 — 이 시험은
 * 시계를 바꿔 끼우므로 그 둘을 재지 못한다.
 */
class JwksMaxAgeTest {

  private static final String CERTS = "/realms/r/protocol/openid-connect/certs";
  private static final long S = 1_000L;

  @Test
  void t1_keySetIsReusedWithoutAFetch_andFetchedExactlyOnceAfter300s() throws Exception {
    RSAKey k1 = key("k1");
    try (Idp idp = new Idp(k1)) {
      AtomicLong now = new AtomicLong(System.currentTimeMillis());
      Rig rig = rig(idp, now);
      String token = rig.token(k1);
      assertEquals("k1", rig.validator.validate(token).getSubject());
      assertEquals(1, idp.hits.get());

      now.addAndGet(269 * S); // refresh-ahead 창(마지막 30초) 바로 앞
      assertEquals("k1", rig.validator.validate(token).getSubject());
      assertEquals(1, settle(idp.hits), "269초 된 집합은 조회 없이 써야 한다");

      now.addAndGet(32 * S); // t0 + 301
      assertEquals("k1", rig.validator.validate(token).getSubject());
      assertEquals(2, settle(idp.hits), "300초가 지나면 다음 검증이 정확히 한 번 조회한다");
    }
  }

  /** T1 의 299초 — refresh-ahead: 캐시로 통과하고 백그라운드로 한 번 가져온다. 그 집합이 나이를 다시 센다. */
  @Test
  void refreshAhead_aValidationAt299s_isServedFromCache_andRefreshesOnceInTheBackground() throws Exception {
    RSAKey k1 = key("k1");
    try (Idp idp = new Idp(k1)) {
      AtomicLong now = new AtomicLong(System.currentTimeMillis());
      Rig rig = rig(idp, now);
      String token = rig.token(k1);
      rig.validator.validate(token);

      now.addAndGet(299 * S);
      assertEquals("k1", rig.validator.validate(token).getSubject());
      assertEquals(2, settle(idp.hits), "마지막 30초의 검증은 백그라운드로 정확히 한 번 미리 가져온다");

      now.addAndGet(2 * S); // t0 + 301 — 299초에 받은 집합으로는 2초다
      assertEquals("k1", rig.validator.validate(token).getSubject());
      assertEquals(2, settle(idp.hits));
    }
  }

  /** refresh-ahead 는 장애 중에 나이를 늘리지 않는다 — 299초의 백그라운드 조회가 503 이면 301초의 검증은 거부된다. */
  @Test
  void refreshAhead_duringAnOutage_doesNotExtendTheAge() throws Exception {
    RSAKey k1 = key("k1");
    try (Idp idp = new Idp(k1)) {
      AtomicLong now = new AtomicLong(System.currentTimeMillis());
      Rig rig = rig(idp, now);
      String token = rig.token(k1);
      rig.validator.validate(token);
      idp.status = 503;

      now.addAndGet(299 * S);
      assertEquals("k1", rig.validator.validate(token).getSubject(), "299초 — 아직 나이 안이다");
      assertEquals(2, settle(idp.hits), "백그라운드 조회 한 번(실패)");

      now.addAndGet(2 * S); // t0 + 301
      assertThrows(TokenValidationException.class, () -> rig.validator.validate(token),
          "300초가 지난 집합으로 물러서면 안 된다");
      assertEquals(3, idp.hits.get(), "299초가 연 창의 크레딧 한 번");
    }
  }

  @Test
  void t2_afterExpiry_anOutageRejects_isBoundedByTheWindow_andRecovers() throws Exception {
    RSAKey k1 = key("k1");
    try (Idp idp = new Idp(k1)) {
      AtomicLong now = new AtomicLong(System.currentTimeMillis());
      Rig rig = rig(idp, now);
      String token = rig.token(k1);
      rig.validator.validate(token);
      idp.status = 503;

      now.addAndGet(301 * S);
      assertThrows(TokenValidationException.class, () -> rig.validator.validate(token));
      assertEquals(2, idp.hits.get(), "정확히 한 번 시도하고, 낡은 키로 물러서지 않는다");
      for (int i = 0; i < 5; i++) {
        assertThrows(TokenValidationException.class, () -> rig.validator.validate(token));
      }
      // 창(jwksMinRefetch 30초) 안: Nimbus 는 창을 열 때 한 번을 크레딧해 창당 두 번이다(.claude/rules/security.md).
      assertEquals(3, idp.hits.get(), "창 안의 추가 검증은 크레딧된 한 번 말고는 IdP 로 나가지 않는다");

      idp.status = 200;
      now.addAndGet(31 * S);
      assertEquals("k1", rig.validator.validate(token).getSubject());
      assertEquals(4, idp.hits.get(), "창이 지나면 한 번 가져와 성공한다");
    }
  }

  @Test
  void t3_aKeyTheIdpRemoved_isRejectedAfter300s() throws Exception {
    RSAKey k1 = key("k1");
    RSAKey k2 = key("k2");
    try (Idp idp = new Idp(k1, k2)) {
      AtomicLong now = new AtomicLong(System.currentTimeMillis());
      Rig rig = rig(idp, now);
      rig.validator.validate(rig.token(k1));
      idp.serve(k2);

      now.addAndGet(301 * S);
      assertThrows(TokenValidationException.class, () -> rig.validator.validate(rig.token(k1)));
      // 나이로 다시 가져온 것 하나 + 미해결 kid 의 재조회 하나(같은 창의 크레딧).
      assertEquals(3, idp.hits.get());
      assertEquals("k2", rig.validator.validate(rig.token(k2)).getSubject());
      assertEquals(3, idp.hits.get());
    }
  }

  @Test
  void t4_aForcedRefetch_restartsTheAge() throws Exception {
    RSAKey k1 = key("k1");
    RSAKey k2 = key("k2");
    try (Idp idp = new Idp(k1)) {
      AtomicLong now = new AtomicLong(System.currentTimeMillis());
      Rig rig = rig(idp, now);
      rig.validator.validate(rig.token(k1));
      idp.serve(k1, k2);

      now.addAndGet(100 * S);
      assertEquals("k2", rig.validator.validate(rig.token(k2)).getSubject()); // 미해결 kid → 재조회
      assertEquals(2, idp.hits.get());

      now.addAndGet(250 * S); // t0 + 350 — 재조회로부터는 250초
      assertEquals("k1", rig.validator.validate(rig.token(k1)).getSubject());
      assertEquals(2, settle(idp.hits), "재조회가 300초를 다시 세야 한다");
    }
  }

  /** 체인의 모양 — 캐시 TTL 300초 · outage tolerance(장애 중 낡은 집합) 가 어디에도 없다. T2 가 행동으로 같은 것을 잰다. */
  @Test
  void theChainCachesFor300s_andHasNoOutageFallback() {
    KeycloakConfig cfg = KeycloakConfig.builder().serverUrl("https://kc.example.com").realm("r").clientId("app").build();
    JWKSource<SecurityContext> src =
        JwtValidator.forRealm(OidcMetadata.forRealm(cfg), cfg, Set.of(JWSAlgorithm.RS256), "app").jwkSource();
    JWKSetSource<?> top = assertInstanceOf(JWKSetBasedJWKSource.class, src).getJWKSetSource();
    long ttl = assertInstanceOf(CachingJWKSetSource.class, top).getTimeToLive();
    assertEquals(300_000L, ttl);
    // ⚠️ Nimbus 기본값도 300초라 `.cache(...)` 를 지워도 위 단언은 초록이다 — 상수가 실제로 배선됐는지는 이 줄이 본다.
    assertEquals(JwtValidator.JWKS_MAX_AGE_SECONDS * 1000L, ttl, "캐시 TTL 이 JWKS_MAX_AGE_SECONDS 에서 오지 않는다");
    int depth = 0;
    for (JWKSetSource<?> s = top; s instanceof JWKSetSourceWrapper<?> w; s = w.getSource()) {
      assertFalse(s instanceof OutageTolerantJWKSetSource, "outage tolerance 가 체인에 있다 — 장애 중 낡은 집합을 돌려준다");
      depth++;
    }
    assertTrue(depth >= 2, "체인을 걷지 못했다(refresh-ahead 캐시 → rate-limit) — 이 단언은 공허하다");
  }

  // ── 도구 ──

  /** forRealm 이 만든 검증기 그대로 — 키 원천의 맨 위 어댑터만 가짜 시계로 바꾼다. */
  private static Rig rig(Idp idp, AtomicLong now) {
    KeycloakConfig cfg = KeycloakConfig.builder().serverUrl(idp.baseUrl()).realm("r").clientId("app").build();
    OidcMetadata md = OidcMetadata.forRealm(cfg);
    JwtValidator production = JwtValidator.forRealm(md, cfg, Set.of(JWSAlgorithm.RS256), "app");
    JwtValidator clocked = JwtValidator.withJwkSource(new FakeClockJwkSource(production.jwkSource(), now),
        md.getIssuer(), "app", Set.of(JWSAlgorithm.RS256), cfg.getClockSkew());
    return new Rig(clocked, md.getIssuer());
  }

  private record Rig(JwtValidator validator, String issuer) {
    String token(RSAKey key) throws Exception {
      SignedJWT jwt = new SignedJWT(new JWSHeader.Builder(JWSAlgorithm.RS256).keyID(key.getKeyID()).build(),
          new JWTClaimsSet.Builder().issuer(issuer).audience("app").subject(key.getKeyID())
              .expirationTime(new Date(System.currentTimeMillis() + 600_000)).build());
      jwt.sign(new RSASSASigner(key));
      return jwt.serialize();
    }
  }

  /** {@link JWKSetBasedJWKSource#get} 를 줄 단위로 옮겼다 — 시각만 {@code now} 에서 읽는다. */
  private static final class FakeClockJwkSource implements JWKSource<SecurityContext> {
    private final JWKSetSource<SecurityContext> chain;
    private final AtomicLong now;

    @SuppressWarnings("unchecked")
    FakeClockJwkSource(JWKSource<SecurityContext> production, AtomicLong now) {
      this.chain = assertInstanceOf(JWKSetBasedJWKSource.class, production,
          "forRealm 의 키 원천이 JWKSetBasedJWKSource 가 아니다 — 이 어댑터가 옮긴 get() 이 더는 운영 경로가 아니다")
          .getJWKSetSource();
      this.now = now;
    }

    @Override
    public List<JWK> get(JWKSelector jwkSelector, SecurityContext context) throws KeySourceException {
      long currentTime = now.get();
      JWKSet jwkSet = chain.getJWKSet(JWKSetCacheRefreshEvaluator.noRefresh(), currentTime, context);
      List<JWK> select = jwkSelector.select(jwkSet);
      if (select.isEmpty()) {
        JWKSet recentJwkSet =
            chain.getJWKSet(JWKSetCacheRefreshEvaluator.referenceComparison(jwkSet), currentTime, context);
        select = jwkSelector.select(recentJwkSet);
      }
      return select;
    }
  }

  /** 백그라운드(refresh-ahead) 조회가 끝날 틈을 준다 — 그동안 hits 가 늘면 그것까지 센다. */
  private static int settle(AtomicInteger hits) throws InterruptedException {
    int seen;
    do {
      seen = hits.get();
      Thread.sleep(300);
    } while (hits.get() != seen);
    return seen;
  }

  private static RSAKey key(String kid) throws Exception {
    return new RSAKeyGenerator(2048).keyID(kid).generate();
  }

  /** /certs 하나를 내는 IdP. status·본문은 시험 도중 바꾼다. hits 는 모든 요청을 센다. */
  private static final class Idp implements AutoCloseable {
    final AtomicInteger hits = new AtomicInteger();
    volatile int status = 200;
    private final AtomicReference<byte[]> body = new AtomicReference<>();
    private final com.sun.net.httpserver.HttpServer server;

    Idp(RSAKey... keys) throws Exception {
      serve(keys);
      server = com.sun.net.httpserver.HttpServer.create(new java.net.InetSocketAddress("127.0.0.1", 0), 0);
      server.createContext(CERTS, ex -> {
        hits.incrementAndGet();
        if (status != 200) {
          ex.sendResponseHeaders(status, -1);
          ex.close();
          return;
        }
        byte[] b = body.get();
        ex.getResponseHeaders().add("Content-Type", "application/json");
        ex.sendResponseHeaders(200, b.length);
        try (java.io.OutputStream os = ex.getResponseBody()) {
          os.write(b);
        }
      });
      server.start();
    }

    void serve(RSAKey... keys) {
      List<JWK> pub = new ArrayList<>();
      for (RSAKey k : keys) pub.add(k.toPublicJWK());
      body.set(new JWKSet(pub).toString().getBytes(StandardCharsets.UTF_8));
    }

    String baseUrl() {
      return "http://127.0.0.1:" + server.getAddress().getPort();
    }

    @Override
    public void close() {
      server.stop(0);
    }
  }
}
