package io.github.xzawed.keycloak.auth;

import static org.junit.jupiter.api.Assertions.*;

import com.nimbusds.jose.JWSAlgorithm;
import com.nimbusds.jose.JWSHeader;
import com.nimbusds.jose.crypto.MACSigner;
import com.nimbusds.jose.crypto.RSASSASigner;
import com.nimbusds.jose.jwk.JWKSet;
import com.nimbusds.jose.jwk.RSAKey;
import com.nimbusds.jose.jwk.gen.RSAKeyGenerator;
import com.nimbusds.jose.jwk.source.JWKSource;
import com.nimbusds.jose.proc.SecurityContext;
import com.nimbusds.jose.util.Base64URL;
import com.nimbusds.jwt.JWTClaimsSet;
import com.nimbusds.jwt.SignedJWT;
import io.github.xzawed.keycloak.core.KeycloakConfig;
import io.github.xzawed.keycloak.core.exception.TokenValidationException;
import java.nio.charset.StandardCharsets;
import java.security.SecureRandom;
import java.time.Duration;
import java.util.Base64;
import java.util.Date;
import java.util.List;
import java.util.Set;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.stream.Stream;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.Arguments;
import org.junit.jupiter.params.provider.MethodSource;
import org.junit.jupiter.params.provider.ValueSource;

/**
 * ⚠️ JWKS 의 대칭({@code oct}) 키는 검증 키가 아니다 — JWKS 는 공개 문서라 그 안의 대칭 키는 비밀이 아니다. HS256 을 허용한
 * 설정에서 그 키로 서명한 위조 토큰이 통과했다 — Nimbus 의 {@code JWSVerificationKeySelector} 는 HS 에 {@code OctetSequenceKey}
 * 를 고르고, kid 가 없는 토큰도 그렇다(등록부 jwks-oct-key-usable-with-hs · 아홉 언어 실측은 PR 본문). Keycloak 은 oct 를 내지
 * 않는다. Kotlin 자매 시험과 같은 모양이다.
 */
class JwksOctKeyTest {
  private static final SecureRandom RANDOM = new SecureRandom();

  static Stream<Arguments> octShapes() {
    return Stream.of(
        Arguments.of("kid · alg", "\"kid\":\"hk\",\"alg\":\"HS256\",\"use\":\"sig\"", "hk"),
        Arguments.of("alg 없음", "\"kid\":\"hk\"", "hk"),
        Arguments.of("kid 없음", "\"alg\":\"HS256\",\"use\":\"sig\"", null));
  }

  @ParameterizedTest(name = "{0}")
  @MethodSource("octShapes")
  void octKey_isNeverAVerificationKey(String name, String members, String kid) throws Exception {
    byte[] secret = new byte[32];
    RANDOM.nextBytes(secret);
    RSAKey k1 = new RSAKeyGenerator(2048).keyID("k1").generate();
    String oct = "{\"kty\":\"oct\",\"k\":\"" + Base64URL.encode(secret) + "\"," + members + "}";
    String set = "{\"keys\":[" + oct + "," + k1.toPublicJWK().toJSONString() + "]}";
    com.sun.net.httpserver.HttpServer s = serve(set);
    try {
      KeycloakConfig cfg = config(s);
      OidcMetadata md = OidcMetadata.forRealm(cfg);
      JwtValidator v = JwtValidator.forRealm(md, cfg, Set.of(JWSAlgorithm.RS256, JWSAlgorithm.HS256), "app");

      assertThrows(TokenValidationException.class, () -> v.validate(hsToken(md, secret, kid)),
          name + ": JWKS 의 oct 키로 서명한 위조 토큰이 통과했다");
      // 대조 — 같은 키셋의 RSA 토큰은 통과한다(oct 를 버리는 것이 키셋 전체를 버리지 않는다).
      assertEquals("user-1", v.validate(rsToken(md, k1)).getSubject());
    } finally {
      s.stop(0);
    }
  }

  /** oct 만 있는 키셋은 쓸 수 있는 키가 없는 키셋이다 — 빈 키셋처럼 조회 실패로 닫는다(Nimbus 에 빈 집합을 넘기지 않는다). */
  @Test
  void onlyAnOctKey_hasNoUsableKeys() {
    com.nimbusds.jose.util.Resource res = new com.nimbusds.jose.util.Resource(
        "{\"keys\":[{\"kty\":\"oct\",\"kid\":\"k1\",\"k\":\"c2VjcmV0LXNlY3JldC1zZWNyZXQtc2VjcmV0LXNlY3JldA\"}]}",
        "application/json");
    java.io.IOException e =
        assertThrows(java.io.IOException.class, () -> NoRedirectResourceRetriever.usableKeysOnly(res));
    assertTrue(e.getMessage().contains("no usable keys (1 skipped)"), e.getMessage());
  }

  /**
   * 고정 — HS 를 허용해도 RSA 공개키 바이트를 HMAC 비밀로 쓴 RS→HS 혼동은 거부된다. 이제 검증기가 키 조회 전에 HS 를 거부해
   * (등록부 hs-refusal-rests-on-libraries) 이 칸은 Nimbus 의 키 선택(HS 에 oct 키만 고른다)까지 가지 않는다 — 라이브러리 갱신과 무관하다.
   */
  @Test
  void rsaPublicKeyBytesAsHmacSecret_areRejectedEvenWithHsAllowed() throws Exception {
    RSAKey k1 = new RSAKeyGenerator(2048).keyID("k1").generate();
    com.sun.net.httpserver.HttpServer s = serve("{\"keys\":[" + k1.toPublicJWK().toJSONString() + "]}");
    try {
      KeycloakConfig cfg = config(s);
      OidcMetadata md = OidcMetadata.forRealm(cfg);
      JwtValidator v = JwtValidator.forRealm(md, cfg, Set.of(JWSAlgorithm.RS256, JWSAlgorithm.HS256), "app");
      byte[] der = k1.toRSAPublicKey().getEncoded();
      byte[] pem = ("-----BEGIN PUBLIC KEY-----\n" + Base64.getMimeEncoder(64, "\n".getBytes(StandardCharsets.US_ASCII))
          .encodeToString(der) + "\n-----END PUBLIC KEY-----\n").getBytes(StandardCharsets.US_ASCII);
      for (byte[] secret : new byte[][] {der, pem}) {
        assertThrows(TokenValidationException.class, () -> v.validate(hsToken(md, secret, "k1")));
      }
    } finally {
      s.stop(0);
    }
  }

  /**
   * HS(대칭) 서명은 설정이 허용해도 키를 찾기 전에 거부한다(등록부 hs-refusal-rests-on-libraries) — 검증 키는 JWKS(공개 문서)
   * 에서만 오므로 HMAC 비밀이 될 수 있는 것은 공개된 값뿐이다. 그 거부가 oct 를 버리는 키 저장소와 Nimbus 의 키·alg 결합에만
   * 기대지 않는다는 증거가 키 조회 0 이다. kid 는 원천에 있는 RSA 키를 가리킨다. 코드 교환의 id_token 경로(withAudience —
   * AuthClient.requireValidNonce)도 같은 거부다.
   */
  @ParameterizedTest
  @ValueSource(strings = {"HS256", "HS384", "HS512"})
  void hsSignature_isRefusedBeforeAnyKeyLookup_evenWhenAllowed(String name) throws Exception {
    JWSAlgorithm hs = JWSAlgorithm.parse(name);
    RSAKey k1 = new RSAKeyGenerator(2048).keyID("k1").generate();
    JWKSet set = new JWKSet(k1.toPublicJWK());
    AtomicInteger lookups = new AtomicInteger();
    JWKSource<SecurityContext> counting = (selector, ctx) -> {
      lookups.incrementAndGet();
      return selector.select(set);
    };
    OidcMetadata md = OidcMetadata.forRealm(
        KeycloakConfig.builder().serverUrl("https://kc.example.com").realm("r").clientId("app").build());
    JwtValidator v = JwtValidator.withJwkSource(counting, md.getIssuer(), "app",
        Set.of(JWSAlgorithm.RS256, hs), Duration.ofSeconds(30));
    byte[] secret = new byte[64];
    RANDOM.nextBytes(secret);
    String forged = hsToken(md, hs, secret, "k1");

    for (JwtValidator path : List.of(v, v.withAudience("app"))) {
      TokenValidationException e = assertThrows(TokenValidationException.class, () -> path.validate(forged));
      assertAll(
          () -> assertEquals("algorithm not allowed: " + name + " (a JWKS holds public keys only)", e.getMessage()),
          () -> assertNull(e.getCause(), "원인이 달렸다 — 라이브러리의 거부를 감싼 것이다"),
          () -> assertEquals(0, lookups.get(), "HS 토큰이 키를 찾았다"));
    }
    // 대조 — 같은 검증기의 RS256 토큰은 통과하고, 계수기는 그 조회를 본다(위의 0 이 죽은 계수기의 0 이 아니다).
    assertEquals("user-1", v.validate(rsToken(md, k1)).getSubject());
    assertTrue(lookups.get() > 0, "계수기가 키 조회를 보지 못한다");
  }

  private static com.sun.net.httpserver.HttpServer serve(String set) throws java.io.IOException {
    byte[] b = set.getBytes(StandardCharsets.UTF_8);
    com.sun.net.httpserver.HttpServer s =
        com.sun.net.httpserver.HttpServer.create(new java.net.InetSocketAddress("127.0.0.1", 0), 0);
    s.createContext("/realms/r/protocol/openid-connect/certs", ex -> {
      ex.getResponseHeaders().add("Content-Type", "application/json");
      ex.sendResponseHeaders(200, b.length);
      try (java.io.OutputStream os = ex.getResponseBody()) {
        os.write(b);
      }
    });
    s.start();
    return s;
  }

  private static KeycloakConfig config(com.sun.net.httpserver.HttpServer s) {
    return KeycloakConfig.builder()
        .serverUrl("http://127.0.0.1:" + s.getAddress().getPort())
        .realm("r").clientId("app")
        .jwksMinRefetch(Duration.ZERO)
        .build();
  }

  private static JWTClaimsSet claims(OidcMetadata md, String sub) {
    return new JWTClaimsSet.Builder().issuer(md.getIssuer()).audience("app").subject(sub)
        .expirationTime(new Date(System.currentTimeMillis() + 60_000)).build();
  }

  private static String rsToken(OidcMetadata md, RSAKey key) throws Exception {
    SignedJWT jwt = new SignedJWT(new JWSHeader.Builder(JWSAlgorithm.RS256).keyID(key.getKeyID()).build(),
        claims(md, "user-1"));
    jwt.sign(new RSASSASigner(key));
    return jwt.serialize();
  }

  private static String hsToken(OidcMetadata md, byte[] secret, String kid) throws Exception {
    return hsToken(md, JWSAlgorithm.HS256, secret, kid);
  }

  private static String hsToken(OidcMetadata md, JWSAlgorithm alg, byte[] secret, String kid) throws Exception {
    JWSHeader.Builder h = new JWSHeader.Builder(alg);
    if (kid != null) {
      h.keyID(kid);
    }
    SignedJWT jwt = new SignedJWT(h.build(), claims(md, "attacker"));
    jwt.sign(new MACSigner(secret));
    return jwt.serialize();
  }
}
