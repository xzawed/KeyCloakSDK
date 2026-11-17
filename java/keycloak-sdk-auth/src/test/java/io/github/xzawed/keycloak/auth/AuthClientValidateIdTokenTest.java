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
import java.time.Duration;
import java.util.Date;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.function.UnaryOperator;
import java.util.stream.Stream;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.Arguments;
import org.junit.jupiter.params.provider.MethodSource;

/**
 * 공개 id_token 검증 {@link AuthClient#validateIdToken} — 코드 교환이 nonce 를 대조하기 <b>전에</b> 돌리는 바로 그 검사다(교환의
 * {@code requireValidNonce} 가 이 메서드를 부른다): 서명(validate() 와 같은 키 원천) · alg 핀 · 길이 상한 · iss · aud 에 client id ·
 * exp · skew · azp(OIDC Core §3.1.3.7 4·5), 그리고 id_token 자리의 종류 — 페이로드 typ 이 정확히 문자열 "ID". nonce 는 보지
 * 않는다(교환의 몫). 등록부 {@code id-token-validator-not-public}.
 *
 * <p>종류는 허용 목록이다(액세스 쪽 validate() 는 거부 목록): Keycloak 은 id_token 을 한 곳에서만 만들고 늘 typ "ID" 를 싣는다
 * (TokenManager.generateIDToken — 실서버 통합에서도 "ID" 를 쟀다). 액세스 토큰은 typ 이 "Bearer" 이고 aud 에 client id 를, azp 에
 * 그 client 를 담을 수 있다 — 종류를 안 보면 그 토큰이 이 길의 다른 검사를 전부 지난다(아래 첫 거부 시험의 대조군이 그것을 보인다).
 * 검증기는 정적 JWKS 를 주입한다(키 원천 공유는 {@code IdTokenAudienceJwksSharingTest} 가 운영 경로 forRealm 으로 잰다).
 */
class AuthClientValidateIdTokenTest {
  private static final String ISSUER = "https://kc.example.com/realms/r";
  private static final String CLIENT_ID = "app";
  private static final String OVERRIDE = "api";
  /** 종류 거부의 메시지 — 상수다. 토큰이 고른 typ 값은 싣지 않는다(azp 를 싣지 않는 것과 같은 이유). */
  private static final String NOT_AN_ID_TOKEN = "not an id_token (typ is not \"ID\")";

  private static RSAKey key;

  @BeforeAll
  static void generateKey() throws Exception {
    key = new RSAKeyGenerator(2048).keyID("k1").generate();
  }

  // Keycloak 이 내는 id_token 의 모양(typ "ID" · aud = azp = client id) — 공개 메서드는 그 클레임을 돌려준다. 같은 토큰을 같은
  // 클라이언트의 validate() 는 액세스 토큰이 아니라고 거부한다 — 두 공개 메서드는 다른 길이다.
  @Test
  void validateIdToken_acceptsTheIdTokenKeycloakIssues_andReturnsItsClaims() throws Exception {
    AuthClient client = client(null);
    String idToken = sign(claims(List.of(CLIENT_ID), c -> c.claim("typ", "ID").claim("azp", CLIENT_ID)
        .subject("user-1").claim("nonce", "n-1")));

    ValidatedToken validated = client.validateIdToken(idToken);

    assertEquals("user-1", validated.getSubject());
    assertEquals(ISSUER, validated.getIssuer());
    assertEquals(List.of(CLIENT_ID), validated.getAudience());
    assertEquals("ID", validated.getClaims().get("typ"));
    assertEquals(CLIENT_ID, validated.getClaims().get("azp"));
    assertEquals("n-1", validated.getClaims().get("nonce"), "nonce 는 대조하지 않고 돌려준다");
    assertEquals("not an access token (typ \"ID\")",
        assertThrows(TokenValidationException.class, () -> client.validate(idToken)).getMessage());
  }

  // 이 규칙이 닫는 구멍 — aud 에 client id, azp 에 그 client 를 담은 액세스 토큰(typ "Bearer"). 대조군: 같은 클라이언트의 validate()
  // 가 같은 토큰을 받는다 — 서명 · iss · aud · exp 가 맞는 토큰이라, 거부의 원인은 종류 하나다(메시지까지 본다).
  @Test
  void validateIdToken_refusesAnAccessTokenThatNamesTheClient() throws Exception {
    AuthClient client = client(null);
    String accessToken = sign(claims(List.of(CLIENT_ID), c -> c.claim("typ", "Bearer").claim("azp", CLIENT_ID)));

    TokenValidationException refused =
        assertThrows(TokenValidationException.class, () -> client.validateIdToken(accessToken));

    assertEquals(NOT_AN_ID_TOKEN, refused.getMessage());
    assertEquals(CLIENT_ID, client.validate(accessToken).getClaims().get("azp"), "대조군: 액세스 검증은 이 토큰을 받는다");
  }

  /** typ 이 정확히 문자열 "ID" 가 아닌 것 — 부재 · 다른 대소문자 · 문자열이 아닌 값(JSON null 포함). aud · azp 는 전부 맞다. */
  static Stream<Arguments> typClaimsThatAreNotExactlyId() {
    return Stream.of(
        Arguments.of("absent", null),
        Arguments.of("bearer in lower case", "bearer"),
        Arguments.of("id in lower case", "id"),
        Arguments.of("ID with a trailing space", "ID "),
        Arguments.of("a number", 1L),
        Arguments.of("an array holding ID", List.of("ID")),
        Arguments.of("an object holding ID", Map.of("typ", "ID")));
  }

  @ParameterizedTest(name = "{0}")
  @MethodSource("typClaimsThatAreNotExactlyId")
  void validateIdToken_refusesATokenWhoseTypIsNotExactlyId(String name, Object typ) throws Exception {
    AuthClient client = client(null);
    String token = sign(claims(List.of(CLIENT_ID), c -> {
      JWTClaimsSet.Builder b = c.claim("azp", CLIENT_ID);
      return typ == null ? b : b.claim("typ", typ);
    }));
    // 전제: 토큰이 정말 그 typ 을 실었다(되읽은 값) — 직렬화가 값을 바꿨다면 이 경우는 아무것도 재지 않는다.
    assertEquals(typ, SignedJWT.parse(token).getJWTClaimsSet().getClaim("typ"), name);

    TokenValidationException refused = assertThrows(TokenValidationException.class, () -> client.validateIdToken(token));
    assertEquals(NOT_AN_ID_TOKEN, refused.getMessage(), name);
  }

  // JSON null 인 typ — 「있지만 문자열이 아닌」 값이다. 부재와 따로 친다(직렬화가 null 을 빼면 부재를 잰다 — 전제로 막는다).
  @Test
  void validateIdToken_refusesATokenWhoseTypIsJsonNull() throws Exception {
    AuthClient client = client(null);
    String token = sign(claims(List.of(CLIENT_ID), c -> c.claim("azp", CLIENT_ID).serializeNullClaims(true)
        .claim("typ", null)));
    assertTrue(SignedJWT.parse(token).getPayload().toString().contains("\"typ\":null"));

    assertEquals(NOT_AN_ID_TOKEN,
        assertThrows(TokenValidationException.class, () -> client.validateIdToken(token)).getMessage());
  }

  // back-channel logout 토큰의 모양(OIDC Back-Channel Logout §2.4) — Keycloak 은 typ "Logout" 을 싣고, aud 는 client id 하나라
  // azp 규칙(aud 하나 · azp 없음)은 지난다. exp 가 있어 필수 exp 도 지난다. 종류만이 그것을 id_token 자리에서 가른다.
  @Test
  void validateIdToken_refusesABackChannelLogoutToken() throws Exception {
    AuthClient client = client(null);
    String logoutToken = sign(claims(List.of(CLIENT_ID), c -> c.claim("typ", "Logout").claim("sid", "s-1")
        .claim("events", Map.of("http://schemas.openid.net/event/backchannel-logout", Map.of()))));
    assertNull(SignedJWT.parse(logoutToken).getJWTClaimsSet().getClaim("azp"), "전제: azp 가 없다");

    assertEquals(NOT_AN_ID_TOKEN,
        assertThrows(TokenValidationException.class, () -> client.validateIdToken(logoutToken)).getMessage());
  }

  // expectedAudience 는 액세스 토큰의 값이다 — id_token 의 aud 는 client id 로 본다(OIDC Core §2 · §3.1.3.7). 재정의 값만 담은
  // id_token 은 aud 검사에서 거부된다(종류 검사보다 앞 — 메시지까지 본다). 대조군 둘: 같은 클라이언트가 client id 를 담은 id_token 은
  // 받고, 그 클라이언트의 validate() 는 재정의 값을 담은 액세스 토큰을 받는다(재정의가 살아 있다).
  @Test
  void validateIdToken_holdsTheAudienceToTheClientId_notTheExpectedAudienceOverride() throws Exception {
    AuthClient client = client(OVERRIDE);
    String forTheOverride = sign(claims(List.of(OVERRIDE), c -> c.claim("typ", "ID").claim("azp", CLIENT_ID)));
    String forTheClient = sign(claims(List.of(CLIENT_ID), c -> c.claim("typ", "ID").claim("azp", CLIENT_ID)));
    String accessForTheOverride = sign(claims(List.of(OVERRIDE), c -> c.claim("typ", "Bearer").claim("azp", CLIENT_ID)));

    assertEquals("JWT validation failed",
        assertThrows(TokenValidationException.class, () -> client.validateIdToken(forTheOverride)).getMessage());
    assertEquals(List.of(CLIENT_ID), client.validateIdToken(forTheClient).getAudience());
    assertEquals(List.of(OVERRIDE), client.validate(accessForTheOverride).getAudience());
  }

  /** 교환의 다른 id_token 검사 — 공개 메서드도 같은 것을 건다(같은 함수다). 전부 typ "ID" 라 거부는 그 검사의 것이다. */
  static Stream<Arguments> idTokensTheExchangeAlsoRefuses() throws Exception {
    RSAKey forger = new RSAKeyGenerator(2048).keyID("k1").generate();
    UnaryOperator<JWTClaimsSet.Builder> typed = c -> c.claim("typ", "ID").claim("azp", CLIENT_ID);
    return Stream.of(
        Arguments.of("wrong issuer", sign(key, JWSAlgorithm.RS256,
            typed.apply(claims(List.of(CLIENT_ID), c -> c.issuer("https://evil.example.com/realms/r"))).build()),
            "JWT validation failed"),
        Arguments.of("algorithm outside the pin", sign(key, JWSAlgorithm.RS512,
            typed.apply(claims(List.of(CLIENT_ID), c -> c)).build()), "JWT validation failed"),
        Arguments.of("expired beyond the skew", sign(key, JWSAlgorithm.RS256,
            typed.apply(claims(List.of(CLIENT_ID), c -> c.expirationTime(secondsFromNow(-45)))).build()),
            "JWT validation failed"),
        Arguments.of("no exp", sign(key, JWSAlgorithm.RS256,
            typed.apply(claims(List.of(CLIENT_ID), c -> c.expirationTime(null))).build()), "JWT validation failed"),
        Arguments.of("forged signature", sign(forger, JWSAlgorithm.RS256,
            typed.apply(claims(List.of(CLIENT_ID), c -> c)).build()), "JWT validation failed"),
        Arguments.of("two audiences, no azp", sign(key, JWSAlgorithm.RS256,
            claims(List.of(CLIENT_ID, "other"), c -> c.claim("typ", "ID")).build()),
            "id_token has more than one audience but no azp"),
        Arguments.of("azp names another client", sign(key, JWSAlgorithm.RS256,
            claims(List.of(CLIENT_ID), c -> c.claim("typ", "ID").claim("azp", "evil")).build()),
            "id_token azp is not this client"),
        Arguments.of("over the length cap", "a".repeat(JwtValidator.JWT_MAX_BYTES - 1) + "..",
            "token exceeds 256000 bytes"));
  }

  @ParameterizedTest(name = "{0}")
  @MethodSource("idTokensTheExchangeAlsoRefuses")
  void validateIdToken_keepsEveryCheckOfTheExchange(String name, String idToken, String message) {
    assertEquals(message,
        assertThrows(TokenValidationException.class, () -> client(null).validateIdToken(idToken)).getMessage(), name);
  }

  // 운영 경로의 모양 — 주입 검증기는 validate() 의 것(aud = expectedAudience, 미설정이면 client id)이고, id_token 쪽은 거기서
  // client id 로 파생된다(AuthClientNonceTest 와 같은 시임).
  private static AuthClient client(String expectedAudienceOrNull) {
    KeycloakConfig cfg = KeycloakConfig.builder()
        .serverUrl("https://kc.example.com").realm("r").clientId(CLIENT_ID)
        .expectedAudience(expectedAudienceOrNull).build();
    JwtValidator access = JwtValidator.withStaticJwks(new JWKSet(key.toPublicJWK()), ISSUER, cfg.getExpectedAudience(),
        Set.of(JWSAlgorithm.RS256), Duration.ofSeconds(30));
    return new AuthClient(cfg, OidcMetadata.forRealm(cfg), access);
  }

  /** iss · aud · exp(1분 뒤) · iat 가 맞는 클레임 — more 가 더하거나 바꾼다. */
  private static JWTClaimsSet.Builder claims(List<String> audience, UnaryOperator<JWTClaimsSet.Builder> more) {
    return more.apply(new JWTClaimsSet.Builder().issuer(ISSUER).audience(audience)
        .issueTime(new Date()).expirationTime(secondsFromNow(60)));
  }

  private static String sign(JWTClaimsSet.Builder claims) throws Exception {
    return sign(key, JWSAlgorithm.RS256, claims.build());
  }

  private static String sign(RSAKey signer, JWSAlgorithm alg, JWTClaimsSet claims) throws Exception {
    SignedJWT jwt = new SignedJWT(new JWSHeader.Builder(alg).keyID("k1").build(), claims);
    jwt.sign(new RSASSASigner(signer));
    return jwt.serialize();
  }

  private static Date secondsFromNow(int seconds) {
    return new Date(System.currentTimeMillis() + seconds * 1000L);
  }
}
