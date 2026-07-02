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
    // exactMatchClaims에는 issuer만 둔다: audience까지 넣으면 Nimbus가 aud를 [audience]와
    // "완전 일치"로 요구하게 되어, 실제 Keycloak처럼 aud가 다중값(예: ["it-client","realm-management"])인
    // 정상 토큰이 오탐 거부된다. audience는 아래 requiredAudience(첫 인자)로만 넘겨 "포함 검사"로 검증한다.
    JWTClaimsSet exact = new JWTClaimsSet.Builder().issuer(issuer).build();
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
    try {
      // alg=none / 미서명 JWT를 Nimbus의 암묵적 기본 동작에 의존하지 않고 명시적으로 거부한다.
      com.nimbusds.jwt.JWT jwt = com.nimbusds.jwt.JWTParser.parse(accessToken);
      if (!(jwt instanceof com.nimbusds.jwt.SignedJWT)) {
        throw new TokenValidationException("Unsecured or non-signed JWT rejected", null);
      }
      return processor.process((com.nimbusds.jwt.SignedJWT) jwt, null);
    }
    catch (Exception e) { throw new TokenValidationException("JWT validation failed", e); }
  }
}
