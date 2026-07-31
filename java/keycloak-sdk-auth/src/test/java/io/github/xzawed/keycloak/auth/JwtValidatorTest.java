package io.github.xzawed.keycloak.auth;
import static org.junit.jupiter.api.Assertions.*;
import com.nimbusds.jose.*; import com.nimbusds.jose.crypto.*;
import com.nimbusds.jose.jwk.*; import com.nimbusds.jose.jwk.gen.RSAKeyGenerator;
import com.nimbusds.jwt.*;
import java.util.*;
import org.junit.jupiter.api.Test;

class JwtValidatorTest {
  // Keycloak 서버 베이스 URL(realm 경로 제외) — KeycloakConfig 조립에만 쓴다.
  private static final String SERVER_URL = "https://kc.example.com";
  // clientId("app")가 아닌 리소스 서버 audience — expectedAudience 재정의 경로를 exercise한다.
  private static final String API_AUDIENCE = "my-api";

  @Test void validSignedToken_passes() throws Exception {
    RSAKey key = new RSAKeyGenerator(2048).keyID("k1").generate();
    String issuer = "https://kc.example.com/realms/r";
    SignedJWT jwt = new SignedJWT(
        new JWSHeader.Builder(JWSAlgorithm.RS256).keyID("k1").build(),
        new JWTClaimsSet.Builder().issuer(issuer).audience("app")
            .expirationTime(new Date(System.currentTimeMillis()+60000)).build());
    jwt.sign(new RSASSASigner(key));
    JwtValidator v = JwtValidator.withStaticJwks(
        new JWKSet(key.toPublicJWK()), issuer, "app",
        Set.of(JWSAlgorithm.RS256), java.time.Duration.ofSeconds(30));
    assertEquals(issuer, v.validate(jwt.serialize()).getIssuer());
  }
  @Test void forRealmBuildsRemoteValidatorWithConfiguredJwksRefetch() {
    // JWKSourceBuilder는 지연(lazy) — 구성만으로 네트워크 I/O가 없다. forRealm 전체 경로
    // (retriever + rateLimited(jwksMinRefetch) 배선 + JwtValidator 생성)를 네트워크 없이 커버한다.
    io.github.xzawed.keycloak.core.KeycloakConfig cfg =
        io.github.xzawed.keycloak.core.KeycloakConfig.builder()
            .serverUrl(SERVER_URL).realm("r").clientId("app")
            .jwksMinRefetch(java.time.Duration.ofSeconds(45)).build();
    OidcMetadata md = OidcMetadata.forRealm(cfg);
    JwtValidator v = JwtValidator.forRealm(md, cfg, Set.of(JWSAlgorithm.RS256), "app");
    assertNotNull(v);
  }
  @Test void noneAlg_rejected() {
    JwtValidator v = JwtValidator.withStaticJwks(new JWKSet(), "iss", "app",
        Set.of(JWSAlgorithm.RS256), java.time.Duration.ofSeconds(30));
    // alg=none 토큰: 헤더 {"alg":"none"} — base64url + "." + payload + "."
    String noneJwt = "eyJhbGciOiJub25lIn0.eyJpc3MiOiJpc3MifQ.";
    assertThrows(io.github.xzawed.keycloak.core.exception.TokenValidationException.class,
        () -> v.validate(noneJwt));
  }

  // 실증 검증(non-vacuous): 서명이 없다는 이유만으로 거부되는지 확인하기 위해,
  // claim 검증(issuer/audience/exp)은 모두 통과할 유효한 PlainJWT(alg=none)를 만들어 시도한다.
  // 이 토큰이 만약 수락된다면 그것이 바로 취약점이다 — 반드시 거부되어야 한다.
  @Test void plainJwt_withValidClaims_isRejected_forBeingUnsigned() throws Exception {
    String issuer = "https://kc.example.com/realms/r";
    JwtValidator v = JwtValidator.withStaticJwks(new JWKSet(), issuer, "app",
        Set.of(JWSAlgorithm.RS256), java.time.Duration.ofSeconds(30));

    PlainJWT plain = new PlainJWT(new JWTClaimsSet.Builder()
        .issuer(issuer)
        .audience("app")
        .expirationTime(new Date(System.currentTimeMillis() + 60_000))
        .build());
    String serialized = plain.serialize();

    assertThrows(io.github.xzawed.keycloak.core.exception.TokenValidationException.class,
        () -> v.validate(serialized));
  }

  // RS256/HS256 alg-confusion 회귀 테스트: 검증기는 RS256만 허용하도록 고정되어 있는데,
  // 공격자가 검증기가 신뢰하는 RSA 공개키 바이트를 그대로 HMAC 비밀키로 재사용해 HS256으로
  // 서명한 토큰을 제시하는 "고전적" 알고리즘 혼동 공격을 시뮬레이션한다(naive verifier가
  // RSA 공개키를 HMAC 키로 재사용하는 경우를 노린 공격). claim은 모두 유효하지만 alg가
  // 허용 집합(RS256)에 없으므로 반드시 거부되어야 한다.
  @Test void hs256TokenSignedWithRsaPublicKeyBytes_rejected_whenValidatorPinnedToRs256() throws Exception {
    RSAKey rsaKey = new RSAKeyGenerator(2048).keyID("k1").generate();
    String issuer = "https://kc.example.com/realms/r";
    JwtValidator v = JwtValidator.withStaticJwks(
        new JWKSet(rsaKey.toPublicJWK()), issuer, "app",
        Set.of(JWSAlgorithm.RS256), java.time.Duration.ofSeconds(30));

    // 공격자가 검증기에 배포된 RSA 공개키(X.509 인코딩)를 그대로 HMAC 비밀키로 사용한다.
    // 2048비트 RSA 공개키 인코딩은 256비트(32바이트)를 훨씬 상회하므로 HS256에 유효한 키다.
    byte[] secret = rsaKey.toRSAPublicKey().getEncoded();

    SignedJWT hs256Jwt = new SignedJWT(
        new JWSHeader.Builder(JWSAlgorithm.HS256).build(),
        new JWTClaimsSet.Builder().issuer(issuer).audience("app")
            .expirationTime(new Date(System.currentTimeMillis() + 60_000)).build());
    hs256Jwt.sign(new MACSigner(secret));

    assertThrows(io.github.xzawed.keycloak.core.exception.TokenValidationException.class,
        () -> v.validate(hs256Jwt.serialize()));
  }

  // 회귀 테스트: 실제 Keycloak client-credentials 액세스 토큰은 aud가 다중값이다
  // (예: ["it-client", "realm-management"]). 검증기가 exactMatchClaims에 audience를
  // 넣어 완전일치를 요구하면, 기대 audience를 "포함"하지만 다른 값도 함께 있는 정상
  // 토큰이 오탐 거부된다(BadJWTException: JWT aud claim value rejected). 수정 전에는
  // 이 테스트가 실패한다.
  @Test void validate_acceptsMultiValuedAudienceContainingExpected() throws Exception {
    RSAKey key = new RSAKeyGenerator(2048).keyID("k1").generate();
    String issuer = "https://kc.example.com/realms/r";
    SignedJWT jwt = new SignedJWT(
        new JWSHeader.Builder(JWSAlgorithm.RS256).keyID("k1").build(),
        new JWTClaimsSet.Builder().issuer(issuer)
            .audience(List.of("app", "realm-management"))
            .expirationTime(new Date(System.currentTimeMillis() + 60_000)).build());
    jwt.sign(new RSASSASigner(key));
    JwtValidator v = JwtValidator.withStaticJwks(
        new JWKSet(key.toPublicJWK()), issuer, "app",
        Set.of(JWSAlgorithm.RS256), java.time.Duration.ofSeconds(30));

    ValidatedToken claims = v.validate(jwt.serialize());
    assertEquals(issuer, claims.getIssuer());
    assertTrue(claims.getAudience().containsAll(List.of("app", "realm-management")));
  }

  // 보안 회귀 테스트: aud 포함 검사는 여전히 강제되어야 한다 — 기대 audience를
  // 전혀 포함하지 않는 토큰은 거부된다.
  @Test void validate_rejectsAudienceNotContainingExpected() throws Exception {
    RSAKey key = new RSAKeyGenerator(2048).keyID("k1").generate();
    String issuer = "https://kc.example.com/realms/r";
    SignedJWT jwt = new SignedJWT(
        new JWSHeader.Builder(JWSAlgorithm.RS256).keyID("k1").build(),
        new JWTClaimsSet.Builder().issuer(issuer)
            .audience(List.of("someone-else"))
            .expirationTime(new Date(System.currentTimeMillis() + 60_000)).build());
    jwt.sign(new RSASSASigner(key));
    JwtValidator v = JwtValidator.withStaticJwks(
        new JWKSet(key.toPublicJWK()), issuer, "app",
        Set.of(JWSAlgorithm.RS256), java.time.Duration.ofSeconds(30));

    assertThrows(io.github.xzawed.keycloak.core.exception.TokenValidationException.class,
        () -> v.validate(jwt.serialize()));
  }

  // config.expectedAudience 미설정(기본): 기대 audience는 clientId — 기존 동작과 완전히 동일하다.
  @Test void expectedAudienceUnset_tokenAudienceWithClientId_passes() throws Exception {
    RSAKey key = new RSAKeyGenerator(2048).keyID("k1").generate();
    String issuer = "https://kc.example.com/realms/r";
    io.github.xzawed.keycloak.core.KeycloakConfig cfg =
        io.github.xzawed.keycloak.core.KeycloakConfig.builder()
            .serverUrl(SERVER_URL).realm("r").clientId("app").build();
    SignedJWT jwt = new SignedJWT(
        new JWSHeader.Builder(JWSAlgorithm.RS256).keyID("k1").build(),
        new JWTClaimsSet.Builder().issuer(issuer).audience("app")
            .expirationTime(new Date(System.currentTimeMillis() + 60_000)).build());
    jwt.sign(new RSASSASigner(key));
    JwtValidator v = JwtValidator.withStaticJwks(
        new JWKSet(key.toPublicJWK()), issuer, cfg.getExpectedAudience(),
        Set.of(JWSAlgorithm.RS256), java.time.Duration.ofSeconds(30));

    assertEquals(issuer, v.validate(jwt.serialize()).getIssuer());
  }

  // 미설정 경로의 부정 테스트: clientId를 포함하지 않는 aud는 여전히 거부된다.
  @Test void expectedAudienceUnset_tokenAudienceWithoutClientId_rejected() throws Exception {
    RSAKey key = new RSAKeyGenerator(2048).keyID("k1").generate();
    String issuer = "https://kc.example.com/realms/r";
    io.github.xzawed.keycloak.core.KeycloakConfig cfg =
        io.github.xzawed.keycloak.core.KeycloakConfig.builder()
            .serverUrl(SERVER_URL).realm("r").clientId("app").build();
    SignedJWT jwt = new SignedJWT(
        new JWSHeader.Builder(JWSAlgorithm.RS256).keyID("k1").build(),
        new JWTClaimsSet.Builder().issuer(issuer).audience(API_AUDIENCE)
            .expirationTime(new Date(System.currentTimeMillis() + 60_000)).build());
    jwt.sign(new RSASSASigner(key));
    JwtValidator v = JwtValidator.withStaticJwks(
        new JWKSet(key.toPublicJWK()), issuer, cfg.getExpectedAudience(),
        Set.of(JWSAlgorithm.RS256), java.time.Duration.ofSeconds(30));

    assertThrows(io.github.xzawed.keycloak.core.exception.TokenValidationException.class,
        () -> v.validate(jwt.serialize()));
  }

  // config.expectedAudience 설정: 기본 realm(audience 매퍼 없음)이나 리소스 서버 사례 — 토큰의 aud가
  // clientId가 아니라 설정한 값이어야 통과한다.
  @Test void expectedAudienceSet_tokenAudienceWithThatValue_passes() throws Exception {
    RSAKey key = new RSAKeyGenerator(2048).keyID("k1").generate();
    String issuer = "https://kc.example.com/realms/r";
    io.github.xzawed.keycloak.core.KeycloakConfig cfg =
        io.github.xzawed.keycloak.core.KeycloakConfig.builder()
            .serverUrl(SERVER_URL).realm("r").clientId("app")
            .expectedAudience(API_AUDIENCE).build();
    SignedJWT jwt = new SignedJWT(
        new JWSHeader.Builder(JWSAlgorithm.RS256).keyID("k1").build(),
        new JWTClaimsSet.Builder().issuer(issuer).audience(API_AUDIENCE)
            .expirationTime(new Date(System.currentTimeMillis() + 60_000)).build());
    jwt.sign(new RSASSASigner(key));
    JwtValidator v = JwtValidator.withStaticJwks(
        new JWKSet(key.toPublicJWK()), issuer, cfg.getExpectedAudience(),
        Set.of(JWSAlgorithm.RS256), java.time.Duration.ofSeconds(30));

    assertTrue(v.validate(jwt.serialize()).getAudience().contains(API_AUDIENCE));
  }

  // 설정 경로의 부정 테스트: expectedAudience를 재정의했으면 clientId만 담은 aud는 더 이상 통과하지
  // 않는다 — 재정의가 실제로 기대값을 바꾼다는 증거(이 테스트가 없으면 fallback 회귀를 못 잡는다).
  @Test void expectedAudienceSet_tokenAudienceWithOnlyClientId_rejected() throws Exception {
    RSAKey key = new RSAKeyGenerator(2048).keyID("k1").generate();
    String issuer = "https://kc.example.com/realms/r";
    io.github.xzawed.keycloak.core.KeycloakConfig cfg =
        io.github.xzawed.keycloak.core.KeycloakConfig.builder()
            .serverUrl(SERVER_URL).realm("r").clientId("app")
            .expectedAudience(API_AUDIENCE).build();
    SignedJWT jwt = new SignedJWT(
        new JWSHeader.Builder(JWSAlgorithm.RS256).keyID("k1").build(),
        new JWTClaimsSet.Builder().issuer(issuer).audience("app")
            .expirationTime(new Date(System.currentTimeMillis() + 60_000)).build());
    jwt.sign(new RSASSASigner(key));
    JwtValidator v = JwtValidator.withStaticJwks(
        new JWKSet(key.toPublicJWK()), issuer, cfg.getExpectedAudience(),
        Set.of(JWSAlgorithm.RS256), java.time.Duration.ofSeconds(30));

    assertThrows(io.github.xzawed.keycloak.core.exception.TokenValidationException.class,
        () -> v.validate(jwt.serialize()));
  }

  // 부정 테스트(PR6): 만료된 토큰은 서명이 유효해도 거부돼야 한다 — 이 테스트가 없으면 exp
  // 검증(DefaultJWTClaimsVerifier)이 사라져도 나머지 테스트가 전부 통과한다(감사 test-quality).
  @Test void expiredToken_rejected() throws Exception {
    RSAKey key = new RSAKeyGenerator(2048).keyID("k1").generate();
    String issuer = "https://kc.example.com/realms/r";
    SignedJWT jwt = new SignedJWT(
        new JWSHeader.Builder(JWSAlgorithm.RS256).keyID("k1").build(),
        new JWTClaimsSet.Builder().issuer(issuer).audience("app")
            .expirationTime(new Date(System.currentTimeMillis() - 60_000)).build());
    jwt.sign(new RSASSASigner(key));
    JwtValidator v = JwtValidator.withStaticJwks(
        new JWKSet(key.toPublicJWK()), issuer, "app",
        Set.of(JWSAlgorithm.RS256), java.time.Duration.ofSeconds(30));

    assertThrows(io.github.xzawed.keycloak.core.exception.TokenValidationException.class,
        () -> v.validate(jwt.serialize()));
  }

  // 부정 테스트(PR6): 기대 issuer와 다른 issuer의 토큰은 거부돼야 한다(exact match).
  @Test void wrongIssuer_rejected() throws Exception {
    RSAKey key = new RSAKeyGenerator(2048).keyID("k1").generate();
    String realIssuer = "https://kc.example.com/realms/r";
    SignedJWT jwt = new SignedJWT(
        new JWSHeader.Builder(JWSAlgorithm.RS256).keyID("k1").build(),
        new JWTClaimsSet.Builder().issuer("https://evil.example.com/realms/r").audience("app")
            .expirationTime(new Date(System.currentTimeMillis() + 60_000)).build());
    jwt.sign(new RSASSASigner(key));
    JwtValidator v = JwtValidator.withStaticJwks(
        new JWKSet(key.toPublicJWK()), realIssuer, "app",
        Set.of(JWSAlgorithm.RS256), java.time.Duration.ofSeconds(30));

    assertThrows(io.github.xzawed.keycloak.core.exception.TokenValidationException.class,
        () -> v.validate(jwt.serialize()));
  }

  // 부정 테스트(PR6): JWKS의 키와 다른 키로 서명된 토큰(서명 변조)은 kid가 맞아도 거부돼야 한다.
  @Test void tamperedSignature_rejected() throws Exception {
    RSAKey signingKey = new RSAKeyGenerator(2048).keyID("k1").generate();
    RSAKey jwksKey = new RSAKeyGenerator(2048).keyID("k1").generate(); // 검증기에 배포된 다른 키(같은 kid)
    String issuer = "https://kc.example.com/realms/r";
    SignedJWT jwt = new SignedJWT(
        new JWSHeader.Builder(JWSAlgorithm.RS256).keyID("k1").build(),
        new JWTClaimsSet.Builder().issuer(issuer).audience("app")
            .expirationTime(new Date(System.currentTimeMillis() + 60_000)).build());
    jwt.sign(new RSASSASigner(signingKey)); // signingKey로 서명
    JwtValidator v = JwtValidator.withStaticJwks(
        new JWKSet(jwksKey.toPublicJWK()), issuer, "app", // 검증기는 jwksKey를 신뢰
        Set.of(JWSAlgorithm.RS256), java.time.Duration.ofSeconds(30));

    assertThrows(io.github.xzawed.keycloak.core.exception.TokenValidationException.class,
        () -> v.validate(jwt.serialize()));
  }

  // ── 릴리스 전 감사 후속: 구현만 있고 테스트가 없던 3개 불변식 ──
  // exp 필수 · 클록 스큐 경계 · JWKS 재조회 rate-limit(행동). 앞의 둘은 JwtValidator 생성자의
  // `Set.of("exp")`/`setMaxClockSkew`가, 셋째는 forRealm의 `.rateLimited(...)`가 대상이다.

  /** 서명된 토큰이라도 exp가 없으면 거부된다 — 무만료 토큰 방지(Node/Go/Rust/Python 동형). */
  @Test void missingExp_rejected() throws Exception {
    RSAKey key = new RSAKeyGenerator(2048).keyID("k1").generate();
    String issuer = "https://kc.example.com/realms/r";
    SignedJWT jwt = new SignedJWT(
        new JWSHeader.Builder(JWSAlgorithm.RS256).keyID("k1").build(),
        // expirationTime을 넣지 않는다 — 나머지 클레임은 전부 정상이라, 거부된다면 그 이유는 exp 부재뿐이다.
        new JWTClaimsSet.Builder().issuer(issuer).audience("app").build());
    jwt.sign(new RSASSASigner(key));
    JwtValidator v = JwtValidator.withStaticJwks(
        new JWKSet(key.toPublicJWK()), issuer, "app",
        Set.of(JWSAlgorithm.RS256), java.time.Duration.ofSeconds(30));

    assertThrows(io.github.xzawed.keycloak.core.exception.TokenValidationException.class,
        () -> v.validate(jwt.serialize()));
  }

  /**
   * 클록 스큐 경계 — 스큐 안에서 만료된 토큰은 통과하고, 밖에서 만료된 토큰은 거부된다.
   * 두 단언이 한 쌍이어야 의미가 있다: 통과 케이스만 있으면 "스큐가 무한대"여도 통과하고,
   * 거부 케이스만 있으면 "스큐가 0"이어도 통과한다. 쌍으로 두어야 설정값이 실제로 배선됐음이 증명된다.
   */
  @Test void clockSkewBoundary_withinPasses_beyondRejected() throws Exception {
    RSAKey key = new RSAKeyGenerator(2048).keyID("k1").generate();
    String issuer = "https://kc.example.com/realms/r";
    java.time.Duration skew = java.time.Duration.ofSeconds(30);
    JwtValidator v = JwtValidator.withStaticJwks(
        new JWKSet(key.toPublicJWK()), issuer, "app", Set.of(JWSAlgorithm.RS256), skew);

    assertEquals(issuer, v.validate(signExpiredSecondsAgo(key, issuer, 10)).getIssuer(),
        "스큐(30s) 안에서 10초 전 만료된 토큰은 통과해야 한다");
    assertThrows(io.github.xzawed.keycloak.core.exception.TokenValidationException.class,
        () -> v.validate(signExpiredSecondsAgo(key, issuer, 90)),
        "스큐(30s) 밖에서 90초 전 만료된 토큰은 거부되어야 한다");
  }

  private static String signExpiredSecondsAgo(RSAKey key, String issuer, long secondsAgo)
      throws Exception {
    SignedJWT jwt = new SignedJWT(
        new JWSHeader.Builder(JWSAlgorithm.RS256).keyID("k1").build(),
        new JWTClaimsSet.Builder().issuer(issuer).audience("app")
            .expirationTime(new Date(System.currentTimeMillis() - secondsAgo * 1000)).build());
    jwt.sign(new RSASSASigner(key));
    return jwt.serialize();
  }

  /**
   * DoS-safe JWKS 재조회(행동 검증). 기존 {@code forRealmBuildsRemoteValidatorWithConfiguredJwksRefetch}는
   * 구성만 확인해 rate-limit이 실제로 걸리는지는 증명하지 못했다 — `.rateLimited(...)` 한 줄을 지워도
   * 통과한다. 여기서는 JDK 내장 HTTP 서버로 실제 JWKS를 서빙하고 **요청 수를 센다**(새 의존성 없음).
   *
   * ⚠️ 대조군이 핵심이다(Node의 같은 교훈 — `.claude/rules/node.md`). rate-limit이 사라져도
   * "히트가 토큰 수보다 적다"는 단언은 캐시 때문에 여전히 통과할 수 있다. 그래서 rate-limit을
   * 사실상 끈 검증기(간격 0)를 나란히 돌려 **히트가 유의미하게 늘어나는지**까지 확인한다.
   */
  @Test void jwksRefetch_isRateLimited_provenByHitCount() throws Exception {
    RSAKey key = new RSAKeyGenerator(2048).keyID("served-kid").generate();
    java.util.concurrent.atomic.AtomicInteger hits = new java.util.concurrent.atomic.AtomicInteger();
    com.sun.net.httpserver.HttpServer server =
        com.sun.net.httpserver.HttpServer.create(new java.net.InetSocketAddress("127.0.0.1", 0), 0);
    byte[] body = new JWKSet(key.toPublicJWK()).toString().getBytes(java.nio.charset.StandardCharsets.UTF_8);
    server.createContext("/realms/r/protocol/openid-connect/certs", ex -> {
      hits.incrementAndGet();
      ex.getResponseHeaders().add("Content-Type", "application/json");
      ex.sendResponseHeaders(200, body.length);
      try (java.io.OutputStream os = ex.getResponseBody()) { os.write(body); }
    });
    server.start();
    try {
      String base = "http://127.0.0.1:" + server.getAddress().getPort();
      int attempts = 8;

      // ⚠️ 간격은 Nimbus 캐시 TTL(기본 5분)보다 작아야 한다 — 그 이상이면 JWKSourceBuilder가
      // IllegalStateException을 던진다(아래 jwksMinRefetch_atOrAboveCacheTtl_isRejectedAsConfigError 참고).
      int limited = countJwksHitsForUnknownKids(base, java.time.Duration.ofMinutes(2), attempts, hits, key);
      int unlimited = countJwksHitsForUnknownKids(base, java.time.Duration.ZERO, attempts, hits, key);

      assertTrue(limited < attempts,
          "rate-limit이 걸리면 미해결 kid " + attempts + "건이 JWKS를 " + attempts
              + "번 때리지 않아야 한다 — 실제 " + limited);
      assertTrue(unlimited > limited,
          "대조군(간격 0)이 rate-limit 적용본보다 많이 조회해야 이 테스트가 rate-limit을 실제로 "
              + "증명한다 — limited=" + limited + " unlimited=" + unlimited);
    } finally {
      server.stop(0);
    }
  }

  /**
   * jwksMinRefetch가 Nimbus 캐시 TTL(5분) 이상이면 SDK 설정 오류로 거부된다.
   * 이 경계는 위 rate-limit 테스트를 쓰다 발견했다 — 고치기 전에는 Nimbus의 `IllegalStateException`이
   * `forRealm`에서 그대로 새어나와, 공개 API에 하위 라이브러리 예외가 노출됐다(§4 위반).
   * 구성 자체를 거부하는 것은 정당하다: 캐시가 만료돼도 rate-limit이 재조회를 막으면 JWKS를
   * 영영 갱신할 수 없다. 다만 진단은 SDK 타입으로, 한계값을 담아 돌려준다.
   */
  @Test void jwksMinRefetch_atOrAboveCacheTtl_isRejectedAsConfigError() {
    io.github.xzawed.keycloak.core.KeycloakConfig cfg =
        io.github.xzawed.keycloak.core.KeycloakConfig.builder()
            .serverUrl(SERVER_URL).realm("r").clientId("app")
            .jwksMinRefetch(java.time.Duration.ofMinutes(10)).build();
    OidcMetadata md = OidcMetadata.forRealm(cfg);

    io.github.xzawed.keycloak.core.exception.KeycloakConfigException ex =
        assertThrows(io.github.xzawed.keycloak.core.exception.KeycloakConfigException.class,
            () -> JwtValidator.forRealm(md, cfg, Set.of(JWSAlgorithm.RS256), "app"));
    assertTrue(ex.getMessage().contains("jwksMinRefetch"),
        "진단 메시지는 어떤 설정이 문제인지 말해야 한다: " + ex.getMessage());
  }

  /** 위조(미해결) kid 토큰을 연속 주입하고 그동안 JWKS 엔드포인트가 몇 번 조회됐는지 센다. */
  private static int countJwksHitsForUnknownKids(String baseUrl, java.time.Duration minRefetch,
      int attempts, java.util.concurrent.atomic.AtomicInteger hits, RSAKey signingKey)
      throws Exception {
    io.github.xzawed.keycloak.core.KeycloakConfig cfg =
        io.github.xzawed.keycloak.core.KeycloakConfig.builder()
            .serverUrl(baseUrl).realm("r").clientId("app").jwksMinRefetch(minRefetch).build();
    OidcMetadata md = OidcMetadata.forRealm(cfg);
    JwtValidator v = JwtValidator.forRealm(md, cfg, Set.of(JWSAlgorithm.RS256), "app");
    hits.set(0);
    for (int i = 0; i < attempts; i++) {
      SignedJWT jwt = new SignedJWT(
          new JWSHeader.Builder(JWSAlgorithm.RS256).keyID("forged-" + i).build(), // 매번 다른 미해결 kid
          new JWTClaimsSet.Builder().issuer(md.getIssuer()).audience("app")
              .expirationTime(new Date(System.currentTimeMillis() + 60_000)).build());
      jwt.sign(new RSASSASigner(signingKey));
      final String serialized = jwt.serialize();
      assertThrows(io.github.xzawed.keycloak.core.exception.TokenValidationException.class,
          () -> v.validate(serialized), "미해결 kid 토큰은 항상 거부되어야 한다");
    }
    return hits.get();
  }
}
