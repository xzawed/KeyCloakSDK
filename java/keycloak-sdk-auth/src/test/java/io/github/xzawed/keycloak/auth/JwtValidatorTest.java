package io.github.xzawed.keycloak.auth;
import static org.junit.jupiter.api.Assertions.*;
import com.nimbusds.jose.*; import com.nimbusds.jose.crypto.*;
import com.nimbusds.jose.jwk.*; import com.nimbusds.jose.jwk.gen.RSAKeyGenerator;
import com.nimbusds.jwt.*;
import java.security.SecureRandom;
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
  // 공격자가 (예: 공개된 RSA 공개키를 HMAC 비밀키처럼 사용해) HS256으로 서명한 토큰을 제시하는 경우를 시뮬레이션한다.
  // claim은 모두 유효하지만 alg가 허용 집합(RS256)에 없으므로 반드시 거부되어야 한다.
  @Test void hs256Token_rejected_whenValidatorPinnedToRs256() throws Exception {
    RSAKey rsaKey = new RSAKeyGenerator(2048).keyID("k1").generate();
    String issuer = "https://kc.example.com/realms/r";
    JwtValidator v = JwtValidator.withStaticJwks(
        new JWKSet(rsaKey.toPublicJWK()), issuer, "app",
        Set.of(JWSAlgorithm.RS256), java.time.Duration.ofSeconds(30));

    byte[] secret = new byte[32]; // >=256-bit HMAC secret
    new SecureRandom().nextBytes(secret);

    SignedJWT hs256Jwt = new SignedJWT(
        new JWSHeader.Builder(JWSAlgorithm.HS256).build(),
        new JWTClaimsSet.Builder().issuer(issuer).audience("app")
            .expirationTime(new Date(System.currentTimeMillis() + 60_000)).build());
    hs256Jwt.sign(new MACSigner(secret));

    assertThrows(io.github.xzawed.keycloak.core.exception.TokenValidationException.class,
        () -> v.validate(hs256Jwt.serialize()));
  }
}
