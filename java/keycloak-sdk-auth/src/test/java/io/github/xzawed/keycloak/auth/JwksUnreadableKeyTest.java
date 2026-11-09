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
import io.github.xzawed.keycloak.core.KeycloakConfig;
import io.github.xzawed.keycloak.core.exception.TokenValidationException;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.Date;
import java.util.Set;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicReference;
import java.util.stream.Stream;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.Arguments;
import org.junit.jupiter.params.provider.MethodSource;

/**
 * 못 읽는 원소 하나가 JWKS 전체를 버리면 안 된다(RFC 7517 §5 — 이해 못 하는 kty · 빠진 필수 멤버 · 범위 밖 값의 키는
 * 무시한다).
 *
 * <p>Nimbus 의 {@code JWKSet.parse} 는 모르는 kty 만 건너뛰고, 그 밖의 못 읽는 원소 하나(지원 밖 곡선 P-192 · {@code n} 이 빠진
 * RSA · JWK 가 아닌 원소)로 키셋 전체를 {@code ParseException} 으로 거부한다 — 같은 키셋의 정상 키로 서명한 토큰까지
 * 거부됐다(등록부 jwks-unsupported-key-rejects-set · 아홉 언어 실측은 PR 본문). 못 읽는 원소를 <b>앞</b>에 둔다.
 */
class JwksUnreadableKeyTest {

  static Stream<Arguments> unreadable() {
    return Stream.of(
        Arguments.of("EC P-192", "{\"kty\":\"EC\",\"crv\":\"P-192\",\"x\":\"AAECAwQFBgcICQoLDA0ODxAREhMUFRYX\","
            + "\"y\":\"GBkaGxwdHh8gISIjJCUmJygpKissLS4v\",\"kid\":\"p192\",\"use\":\"sig\"}"),
        Arguments.of("RSA without n", "{\"kty\":\"RSA\",\"e\":\"AQAB\",\"kid\":\"missingn\",\"use\":\"sig\"}"),
        Arguments.of("not a JWK", "\"not-a-jwk\""),
        // JWK.parse 가 ParseException 이 아니라 NPE 를 던지는 원소(OtherPrimesInfo 의 requireNonNull) — RuntimeException 을
        // 잡지 않으면 그 NPE 가 리트리버 밖으로 샌다(main 이 그랬다 · PR #1001 레그).
        Arguments.of("RSA with an empty oth entry",
            "{\"kty\":\"RSA\",\"n\":\"AQAB\",\"e\":\"AQAB\",\"kid\":\"oth\",\"oth\":[{}]}"));
  }

  @ParameterizedTest(name = "{0}")
  @MethodSource("unreadable")
  void keyItCannotRead_isSkippedNotTheWholeSet(String name, String bad) throws Exception {
    RSAKey k1 = new RSAKeyGenerator(2048).keyID("k1").generate();
    String set = "{\"keys\":[" + bad + "," + k1.toPublicJWK().toJSONString() + "]}";
    // 전제 — Nimbus 자신은 이 키셋을 통째로 읽지 못한다(아니면 이 칸은 아무것도 재지 않는다). 던지는 것은 대개
    // ParseException 이지만 oth 칸은 NPE 다.
    assertThrows(Exception.class, () -> JWKSet.parse(set), name + " 가 든 키셋을 Nimbus 가 읽는다");

    AtomicReference<byte[]> body = new AtomicReference<>(set.getBytes(StandardCharsets.UTF_8));
    com.sun.net.httpserver.HttpServer s = serve(body, new AtomicInteger());
    try {
      KeycloakConfig cfg = config(s);
      OidcMetadata md = OidcMetadata.forRealm(cfg);
      JwtValidator v = JwtValidator.forRealm(md, cfg, Set.of(JWSAlgorithm.RS256), "app");

      assertEquals("user-1", v.validate(token(md, k1, "user-1")).getSubject(),
          name + " 하나가 키셋 전체를 버렸다 — 정상 키로 서명한 토큰이 거부된다");
    } finally {
      s.stop(0);
    }
  }

  static Stream<Arguments> unusableOnly() {
    return Stream.of(
        Arguments.of("Nimbus 도 못 읽는 원소만", unreadable().map(a -> (String) a.get()[1])
            .reduce((a, b) -> a + "," + b).map(keys -> "{\"keys\":[" + keys + "]}").orElseThrow()),
        // ⚠️ Nimbus 가 **스스로 건너뛰는** 원소만 — 그대로 넘기면 Nimbus 는 빈 집합을 파싱해 좋은 캐시를 덮는다. 위 칸만으로는
        // 「조회 실패로 던짐」과 「응답을 Nimbus 에 돌려줌」을 가르지 못했다(PR #1001 레그의 변이가 둘 다 통과했다).
        Arguments.of("모르는 kty 만", "{\"keys\":[{\"kty\":\"XYZ\",\"kid\":\"future\"}]}"));
  }

  /**
   * 대조 — 쓸 수 있는 원소가 하나도 없는 키셋은 빈 키셋처럼 조회 실패이고 좋은 캐시를 덮지 않는다. 건너뛰기가 「다 건너뛰고 빈
   * 키셋을 올림」이나 「Nimbus 에 그대로 넘김」으로 새면 마지막 두 단언이 운다. ⚠️ 재조회 단언이 전제다(JwksEmptyKeysetTest 와
   * 같은 이유).
   */
  @ParameterizedTest(name = "{0}")
  @MethodSource("unusableOnly")
  void onlyUnreadableKeys_isRefusedAndDoesNotPoisonGoodCache(String name, String unusable) throws Exception {
    RSAKey k1 = new RSAKeyGenerator(2048).keyID("k1").generate();
    RSAKey k2 = new RSAKeyGenerator(2048).keyID("k2").generate();
    AtomicInteger hits = new AtomicInteger();
    AtomicReference<byte[]> body = new AtomicReference<>(
        new JWKSet(k1.toPublicJWK()).toString().getBytes(StandardCharsets.UTF_8));
    com.sun.net.httpserver.HttpServer s = serve(body, hits);
    try {
      KeycloakConfig cfg = config(s);
      OidcMetadata md = OidcMetadata.forRealm(cfg);
      JwtValidator v = JwtValidator.forRealm(md, cfg, Set.of(JWSAlgorithm.RS256), "app");

      String good = token(md, k1, "user-1");
      v.validate(good);
      int before = hits.get();

      body.set(unusable.getBytes(StandardCharsets.UTF_8));
      assertThrows(TokenValidationException.class, () -> v.validate(token(md, k2, "user-1")));
      assertTrue(hits.get() > before,
          "미해결 kid 가 재조회를 일으키지 않으면 못 읽는 키셋을 본 적이 없다 — 이 테스트는 공허하다");

      assertEquals("user-1", v.validate(good).getSubject(), name + " 200 이 좋은 캐시를 덮었다");
      assertEquals("user-2", v.validate(token(md, k1, "user-2")).getSubject(),
          name + " 200 뒤 같은 키로 새로 서명한 토큰도 통과해야 한다");
    } finally {
      s.stop(0);
    }
  }

  /** 전부 읽히면 응답을 그대로 넘긴다(재직렬화하지 않는다) · 하나라도 빠지면 읽힌 키만 담은 새 응답이다. */
  @Test
  void usableKeysOnly_passesAFullyReadableResponseThroughUntouched() throws Exception {
    RSAKey k1 = new RSAKeyGenerator(2048).keyID("k1").generate();
    String good = k1.toPublicJWK().toJSONString();
    com.nimbusds.jose.util.Resource all =
        new com.nimbusds.jose.util.Resource("{\"keys\":[" + good + "]}", "application/json");
    assertSame(all, NoRedirectResourceRetriever.usableKeysOnly(all), "전부 읽히는 응답을 새로 만들었다");

    com.nimbusds.jose.util.Resource mixed =
        new com.nimbusds.jose.util.Resource("{\"keys\":[\"not-a-jwk\"," + good + "]}", "application/json");
    com.nimbusds.jose.util.Resource filtered = NoRedirectResourceRetriever.usableKeysOnly(mixed);
    assertNotSame(mixed, filtered);
    assertEquals(java.util.List.of("k1"),
        JWKSet.parse(filtered.getContent()).getKeys().stream().map(k -> k.getKeyID()).toList());
    assertEquals("application/json", filtered.getContentType());
  }

  /** 기형 문서는 지금처럼 Nimbus 가 판정한다 — 본문 {@code null} 도(전에는 NPE 가 리트리버 밖으로 샜다). */
  @ParameterizedTest
  @org.junit.jupiter.params.provider.ValueSource(strings = {"null", "not json", "{}", "{\"keys\":{}}", "[]"})
  void usableKeysOnly_leavesAMalformedDocumentToNimbus(String body) throws Exception {
    com.nimbusds.jose.util.Resource res = new com.nimbusds.jose.util.Resource(body, "application/json");
    assertSame(res, NoRedirectResourceRetriever.usableKeysOnly(res));
  }

  private static com.sun.net.httpserver.HttpServer serve(AtomicReference<byte[]> body, AtomicInteger hits)
      throws java.io.IOException {
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
    return s;
  }

  private static KeycloakConfig config(com.sun.net.httpserver.HttpServer s) {
    return KeycloakConfig.builder()
        .serverUrl("http://127.0.0.1:" + s.getAddress().getPort())
        .realm("r").clientId("app")
        .jwksMinRefetch(Duration.ZERO)
        .build();
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
