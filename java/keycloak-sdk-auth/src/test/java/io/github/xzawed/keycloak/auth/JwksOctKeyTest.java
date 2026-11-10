package io.github.xzawed.keycloak.auth;

import static org.junit.jupiter.api.Assertions.*;

import com.nimbusds.jose.JWSAlgorithm;
import com.nimbusds.jose.JWSHeader;
import com.nimbusds.jose.crypto.MACSigner;
import com.nimbusds.jose.crypto.RSASSASigner;
import com.nimbusds.jose.jwk.RSAKey;
import com.nimbusds.jose.jwk.gen.RSAKeyGenerator;
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
import java.util.Set;
import java.util.stream.Stream;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.Arguments;
import org.junit.jupiter.params.provider.MethodSource;

/**
 * ⚠️ JWKS 의 대칭({@code oct}) 키는 검증 키가 아니다 — JWKS 는 공개 문서라 그 안의 대칭 키는 비밀이 아니다. HS256 을 허용한
 * 설정에서 그 키로 서명한 위조 토큰이 통과했다 — Nimbus 의 {@code JWSVerificationKeySelector} 는 HS 에 {@code OctetSequenceKey}
 * 를 고르고, kid 가 없는 토큰도 그렇다(등록부 jwks-oct-key-usable-with-hs · 아홉 언어 실측은 PR 본문). Keycloak 은 oct 를 내지
 * 않는다. Kotlin 자매 시험과 같은 모양이다.
 */
class JwksOctKeyTest {

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
    new SecureRandom().nextBytes(secret);
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
    assertTrue(e.getMessage().contains("no usable keys (1 unreadable)"), e.getMessage());
  }

  /**
   * 고정 — HS 를 허용해도 RSA 공개키 바이트를 HMAC 비밀로 쓴 RS→HS 혼동은 거부된다(Nimbus 는 HS 에 oct 키만 고른다). oct 를
   * 버리는 것만으로 충분하다는 판정의 근거라, 라이브러리 갱신이 이것을 바꾸면 여기서 운다.
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
    JWSHeader.Builder h = new JWSHeader.Builder(JWSAlgorithm.HS256);
    if (kid != null) {
      h.keyID(kid);
    }
    SignedJWT jwt = new SignedJWT(h.build(), claims(md, "attacker"));
    jwt.sign(new MACSigner(secret));
    return jwt.serialize();
  }
}
