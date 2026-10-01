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
  // withAudience 가 넘겨줄 것 — 특히 jwkSource 는 **같은 객체**여야 한다(JWKS 캐시·재조회 제한·콜드 캐시 창이 그 안에 있다).
  private final JWKSource<SecurityContext> jwkSource;
  private final String issuer;
  private final Set<JWSAlgorithm> allowedAlgs;
  private final Duration skew;
  private JwtValidator(JWKSource<SecurityContext> jwkSource, String issuer, String audience,
                       Set<JWSAlgorithm> allowedAlgs, Duration skew) {
    this.jwkSource = jwkSource; this.issuer = issuer; this.allowedAlgs = allowedAlgs; this.skew = skew;
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
      // JWKS fetch도 KeycloakConfig의 connect/read 타임아웃을 따른다 (M.7): 기본
      // DefaultResourceRetriever는 자체 기본 타임아웃을 쓰므로 그대로 두면 설정이 무시된다.
      // ⚠️ 기본 DefaultResourceRetriever는 HttpURLConnection의 기본 동작(리다이렉트 추종)을
      // 그대로 쓴다 — JWKS가 예상 밖 3xx를 주면 공격자가 고른 URL의 응답을 **서명 검증용 키
      // 집합으로 사용**하게 된다. NoRedirectResourceRetriever가 그 확장점을 막는다.
      com.nimbusds.jose.util.DefaultResourceRetriever retriever =
          new NoRedirectResourceRetriever(
              (int) cfg.getConnectTimeout().toMillis(), (int) cfg.getReadTimeout().toMillis());
      // 미해결 kid 재조회 rate-limit 간격을 config로 설정 가능하게 한다(기본 30초 = Nimbus
      // DEFAULT_RATE_LIMIT_MIN_INTERVAL 동형). 위조 kid 폭주에 대한 DoS 증폭 상한.
      // ⚠️ Nimbus는 rate-limit 간격이 캐시 TTL(기본 5분) 이상이면 build()에서 IllegalStateException을
      // 던진다(캐시가 만료돼도 rate-limit이 재조회를 막아 영영 갱신할 수 없는 구성이므로 정당한 거부다).
      // 그대로 두면 이 foreign 예외가 공개 API로 새어나가므로(§4 위반) 경계에서 SDK 타입으로 바꾼다.
      JWKSource<SecurityContext> src;
      try {
        src = JWKSourceBuilder.create(md.getJwksUri().toURL(), retriever)
            .rateLimited(cfg.getJwksMinRefetch().toMillis())
            .build();
      } catch (IllegalStateException e) {
        throw new io.github.xzawed.keycloak.core.exception.KeycloakConfigException(
            "jwksMinRefetch (" + cfg.getJwksMinRefetch().toSeconds()
                + "s) must be shorter than the JWKS cache time-to-live ("
                + (JWKSourceBuilder.DEFAULT_CACHE_TIME_TO_LIVE / 1000) + "s)", e);
      }
      return new JwtValidator(src, md.getIssuer(), audience, allowedAlgs, cfg.getClockSkew());
    } catch (java.net.MalformedURLException e) {
      throw new TokenValidationException("Invalid JWKS URI", e);
    }
  }
  static JwtValidator withStaticJwks(JWKSet jwks, String issuer, String audience,
                                     Set<JWSAlgorithm> allowedAlgs, Duration skew) {
    return new JwtValidator(new ImmutableJWKSet<>(jwks), issuer, audience, allowedAlgs, skew);
  }
  // 요구 aud 만 바꾼 검증기 — 키 원천·iss·alg 핀·skew·필수 exp 는 이 검증기 것 그대로다. 교환의 id_token 용이다:
  // id_token 의 aud 는 client id 를 담는다(OIDC Core §2·§3.1.3.7). ⚠️ 여기서 forRealm 을 다시 부르면 키 저장소가 둘이
  // 되어 교환 뒤 첫 validate() 가 JWKS 를 다시 받고 장애 때 창당 상한이 두 배다(IdTokenAudienceJwksSharingTest).
  // 네트워크 I/O 없이 처리기만 새로 만든다. 패키지 전용 — 공개 API 가 아니다.
  JwtValidator withAudience(String audience) {
    return new JwtValidator(jwkSource, issuer, audience, allowedAlgs, skew);
  }
  // 반환 타입은 SDK 소유의 ValidatedToken (I.1): 이 SDK의 공개 API는 어떤 시그니처에서도
  // Nimbus 타입을 노출하지 않는다.
  public ValidatedToken validate(String accessToken) {
    try {
      // alg=none / 미서명 JWT를 Nimbus의 암묵적 기본 동작에 의존하지 않고 명시적으로 거부한다.
      com.nimbusds.jwt.JWT jwt = com.nimbusds.jwt.JWTParser.parse(accessToken);
      if (!(jwt instanceof com.nimbusds.jwt.SignedJWT)) {
        throw new TokenValidationException("Unsecured or non-signed JWT rejected", null);
      }
      JWTClaimsSet claims = processor.process((com.nimbusds.jwt.SignedJWT) jwt, null);
      return ValidatedToken.from(claims);
    }
    catch (Exception e) { throw new TokenValidationException("JWT validation failed", e); }
  }
}
