package io.github.xzawed.keycloak.auth;
import com.nimbusds.jose.JWSAlgorithm;
import com.nimbusds.jose.jwk.JWKSet;
import com.nimbusds.jose.jwk.source.*;
import com.nimbusds.jose.proc.*;
import com.nimbusds.jwt.JWTClaimsSet;
import com.nimbusds.jwt.proc.*;
import io.github.xzawed.keycloak.core.exception.TokenValidationException;
import java.time.Duration; import java.util.*;

public final class JwtValidator {
  private final ConfigurableJWTProcessor<SecurityContext> processor;   // issuer당 1회 구성(JWKSource 캐시)
  private JwtValidator(JWKSource<SecurityContext> jwkSource, String issuer, String audience,
                       Set<JWSAlgorithm> allowedAlgs, Duration skew) {
    DefaultJWTProcessor<SecurityContext> p = new DefaultJWTProcessor<>();
    p.setJWSKeySelector(new JWSVerificationKeySelector<>(allowedAlgs, jwkSource)); // 허용 alg만 → none/기타 거부
    JWTClaimsSet exact = new JWTClaimsSet.Builder().issuer(issuer).audience(audience).build();
    DefaultJWTClaimsVerifier<SecurityContext> v =
        new DefaultJWTClaimsVerifier<>(audience, exact, Set.of("exp"));
    v.setMaxClockSkew((int) skew.getSeconds());
    p.setJWTClaimsSetVerifier(v);
    this.processor = p;
  }
  public static JwtValidator forRealm(OidcMetadata md, io.github.xzawed.keycloak.core.KeycloakConfig cfg,
                                      Set<JWSAlgorithm> allowedAlgs, String audience) {
    try {
      JWKSource<SecurityContext> src = JWKSourceBuilder.create(md.getJwksUri().toURL()).build();
      return new JwtValidator(src, md.getIssuer(), audience, allowedAlgs, cfg.getClockSkew());
    } catch (java.net.MalformedURLException e) {
      throw new TokenValidationException("Invalid JWKS URI", e);
    }
  }
  static JwtValidator withStaticJwks(JWKSet jwks, String issuer, String audience,
                                     Set<JWSAlgorithm> allowedAlgs, Duration skew) {
    return new JwtValidator(new ImmutableJWKSet<>(jwks), issuer, audience, allowedAlgs, skew);
  }
  public JWTClaimsSet validate(String accessToken) {
    try { return processor.process(accessToken, null); }
    catch (Exception e) { throw new TokenValidationException("JWT validation failed", e); }
  }
}
