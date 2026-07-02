package io.github.xzawed.keycloak.auth;
import static org.junit.jupiter.api.Assertions.*;
import com.nimbusds.jose.*; import com.nimbusds.jose.crypto.*;
import com.nimbusds.jose.jwk.*; import com.nimbusds.jose.jwk.gen.RSAKeyGenerator;
import com.nimbusds.jwt.*;
import java.util.*;
import org.junit.jupiter.api.Test;

class JwtValidatorTest {
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
}
