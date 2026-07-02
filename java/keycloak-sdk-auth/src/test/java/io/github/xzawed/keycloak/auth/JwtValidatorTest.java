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
}
