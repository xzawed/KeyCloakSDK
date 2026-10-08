package io.github.xzawed.keycloak.auth;
import com.nimbusds.common.contenttype.ContentType;
import com.nimbusds.oauth2.sdk.*;
import com.nimbusds.oauth2.sdk.auth.*;
import com.nimbusds.oauth2.sdk.http.HTTPRequest;
import com.nimbusds.oauth2.sdk.http.HTTPResponse;
import com.nimbusds.oauth2.sdk.id.*;
import com.nimbusds.oauth2.sdk.pkce.CodeChallengeMethod;
import com.nimbusds.oauth2.sdk.token.RefreshToken;
import com.nimbusds.oauth2.sdk.token.Tokens;
import com.nimbusds.oauth2.sdk.token.TypelessAccessToken;
import com.nimbusds.oauth2.sdk.util.URLUtils;
import com.nimbusds.openid.connect.sdk.*;
import io.github.xzawed.keycloak.core.*;
import io.github.xzawed.keycloak.core.exception.KeycloakAuthException;
import io.github.xzawed.keycloak.core.exception.KeycloakConfigException;
import io.github.xzawed.keycloak.core.exception.KeycloakTransportException;
import java.net.URI;
import java.time.Instant;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

public class AuthClient {
  private final KeycloakConfig config; private final OidcMetadata metadata;
  private volatile JwtValidator jwtValidator;   // 지연 생성 + 캐시 (WBS 3.6)
  public AuthClient(KeycloakConfig config, OidcMetadata metadata) {
    this(config, metadata, null);
  }
  // 패키지 전용 테스트 시임: 미리 만든 JwtValidator(예: withStaticJwks)를 주입해, 라이브 JWKS
  // 엔드포인트 없이 exchangeCode의 nonce 검증을 실 서명 id_token으로 검증할 수 있게 한다
  // (Kotlin AuthClient injectedValidator 동형). null이면 validate() 첫 호출 시 지연 생성된다.
  AuthClient(KeycloakConfig config, OidcMetadata metadata, JwtValidator injectedValidator) {
    this.config = config; this.metadata = metadata; this.jwtValidator = injectedValidator;
  }

  // JWKS 기반 서명·issuer·audience·만료 검증. 실패 시 TokenValidationException.
  // 반환 타입은 SDK 소유의 ValidatedToken (I.1) — Nimbus 타입을 공개 API에 노출하지 않는다.
  public ValidatedToken validate(String accessToken) {
    return validator().validate(accessToken);
  }

  // 액세스 토큰 검증기(aud = expectedAudience). 키 원천(JWKS 캐시·재조회 제한)은 이것 하나다 — 교환의 id_token 검증기도
  // 여기서 withAudience 로 파생해 같은 원천을 쓴다.
  private JwtValidator validator() {
    JwtValidator v = jwtValidator;
    if (v == null) {
      synchronized (this) {
        v = jwtValidator;
        if (v == null) {
          v = JwtValidator.forRealm(metadata, config, allowedAlgorithms(), config.getExpectedAudience());
          jwtValidator = v;
        }
      }
    }
    return v;
  }

  // config의 서명 알고리즘 이름(List<String>)을 Nimbus JWSAlgorithm 집합으로 변환한다 — §4에 따라
  // Nimbus 타입은 공개 API(config)에 노출하지 않으므로 config는 문자열로 보유하고 경계에서만 변환한다.
  // 패키지 가시성: 변환 로직을 단위 테스트로 직접 검증하기 위함(AuthClient는 커버리지 게이트 제외).
  java.util.Set<com.nimbusds.jose.JWSAlgorithm> allowedAlgorithms() {
    java.util.Set<com.nimbusds.jose.JWSAlgorithm> algs = new java.util.LinkedHashSet<>();
    for (String name : config.getSignatureAlgorithms()) {
      algs.add(com.nimbusds.jose.JWSAlgorithm.parse(name));
    }
    return algs;
  }
  // Nimbus HTTPRequest에 KeycloakConfig 타임아웃 적용 후 전송 (3.4~3.7 공용 헬퍼)
  // ⚠️ 전송은 req.send() 가 아니라 CappedResponseSender.send(req, …) 다 — Nimbus send() 는 응답 본문을 크기 제한 없이 담는다
  // (32 MiB 본문에 호출 하나가 약 235 MB 할당 — TokenResponseCapTest). 다섯 호출부 모두 그것을 지난다.
  HTTPRequest applyTimeouts(HTTPRequest req) {
    req.setConnectTimeout((int) config.getConnectTimeout().toMillis());
    req.setReadTimeout((int) config.getReadTimeout().toMillis());
    // SSRF 하드닝: back-channel 요청은 3xx를 따라가지 않는다. Nimbus 기본값은 **추종**이라
    // 명시하지 않으면 token/refresh/introspect/logout이 전부 예상 밖 리다이렉트를 따라간다.
    // 이 헬퍼가 5개 send() 호출부의 단일 병목이라 여기 한 줄이 그 전부를 덮는다.
    // ⚠️ 단순한 SSRF보다 나쁜 실패 모드가 있다: logout이 302를 따라가 무관한 200을 받으면
    // **정상 반환**한다 — 호출자는 세션이 폐기됐다고 믿지만 살아 있다.
    // Rust(redirect::Policy::none())·Ruby·Go(ErrUseLastResponse)·.NET(AllowAutoRedirect=false)과 동형.
    // ⚠️ OIDC authorization-code의 redirect_uri는 브라우저 front-channel 개념이라 무관하다.
    req.setFollowRedirects(false);
    return req;
  }
  public AuthorizationUrlRequest createAuthorizationRequest(URI redirectUri) {
    if (redirectUri == null) {
      throw new IllegalArgumentException("redirectUri must not be null");
    }
    Pkce pkce = Pkce.generate();
    State state = new State(); Nonce nonce = new Nonce();
    Scope scope = configuredScope();
    if (scope.isEmpty()) scope = new Scope("openid");
    // ⚠️ scope 에 정확한 "openid" 가 없으면 Nimbus AuthenticationRequest.Builder 가 IAE 로 공개 API 에 샜다(실측).
    // 자매 일곱은 scope 를 그대로 보내므로(실측 2026-09-25) 그 경우만 플레인 OAuth2 인가 요청으로 만든다 —
    // nonce 는 파라미터로 싣는다. openid 가 있으면 지금까지의 OIDC 경로 그대로다. Kotlin 자매와 동형.
    URI authorizationUrl;
    try {
      authorizationUrl = scope.contains("openid")
          ? new com.nimbusds.openid.connect.sdk.AuthenticationRequest.Builder(
                new ResponseType(ResponseType.Value.CODE), scope,
                new ClientID(config.getClientId()), redirectUri)
              .endpointURI(metadata.getAuthorizationEndpoint())
              .state(state).nonce(nonce)
              .codeChallenge(pkce.nimbusVerifier(), CodeChallengeMethod.S256)
              .build().toURI()
          : new AuthorizationRequest.Builder(new ResponseType(ResponseType.Value.CODE), new ClientID(config.getClientId()))
              .redirectionURI(redirectUri).scope(scope)
              .endpointURI(metadata.getAuthorizationEndpoint())
              .state(state).customParameter("nonce", nonce.getValue())
              .codeChallenge(pkce.nimbusVerifier(), CodeChallengeMethod.S256)
              .build().toURI();
    } catch (IllegalStateException e) {
      // ⚠️ Nimbus 는 build() 에서 redirect_uri 를 검사한다 — fragment(RFC 6749 §3.1.2)·금지 scheme
      // (javascript·data 등)·금지 쿼리 파라미터(code·state 등)를 IllegalStateException 으로 거부하고,
      // 그대로 두면 §4 경계를 넘어 공개 API 로 샌다. 잘못된 콜백 URL 은 IdP 가 거절한 것이 아니라 앱 구성
      // 오류다 — Rust `redirect_url()`·Kotlin 과 같은 분류. Nimbus 사유를 메시지에 그대로 싣는다(입력 URI
      // 전체를 되울리지 않고, 다른 원인이 섞여도 진단이 남는다).
      throw new KeycloakConfigException("invalid redirect_uri: " + e.getMessage(), e);
    }
    return new AuthorizationUrlRequest(authorizationUrl, pkce.getVerifier(), state.getValue(), nonce.getValue());
  }
  // Authorization Code 그랜트로 토큰 교환 (I.2). PKCE code_verifier를 포함해 토큰 엔드포인트에
  // POST한다. 기밀 클라이언트(clientSecret 설정됨)는 ClientSecretBasic, 퍼블릭 클라이언트는
  // client_id만 본문에 포함한다(clientAuth() 미사용 — Secret 없이 인증 불가하므로).
  public TokenSet exchangeCode(String code, URI redirectUri, String codeVerifier) {
    return exchangeCode(code, redirectUri, codeVerifier, null);
  }

  // OIDC nonce 재생 방지: expectedNonce가 주어지면(createAuthorizationRequest의 getNonce()) 응답
  // id_token을 강화 JwtValidator로 서명·iss·aud(= clientId)·exp까지 검증한 뒤 nonce 클레임을 대조한다 —
  // 불일치·부재·검증실패는 모두 거부(fail-closed). null이면 id_token 검증을 건너뛴다(무-nonce 흐름).
  public TokenSet exchangeCode(String code, URI redirectUri, String codeVerifier, String expectedNonce) {
    TokenSet tokenSet;
    try {
      long issuedAt = Instant.now().getEpochSecond();
      // OIDC 인지 파서로 파싱해야 id_token이 보존된다(플레인 TokenResponse.parse는 Tokens만
      // 만들고 OIDCTokens/id_token을 인지하지 못한다).
      HTTPRequest req = applyTimeouts(buildExchangeCodeRequest(code, redirectUri, codeVerifier));
      TokenResponse resp = OIDCTokenResponseParser.parse(CappedResponseSender.send(req, "token"));
      if (!resp.indicatesSuccess()) {
        var err = resp.toErrorResponse().getErrorObject();
        throw new KeycloakAuthException("Authorization code exchange failed: "
            + describe(err.getDescription(), req, config.getClientSecret()), err.getCode(), null);
      }
      tokenSet = toTokenSet(resp.toSuccessResponse().getTokens(), issuedAt);
    } catch (java.io.IOException e) {
      throw transportFailure("Authorization code exchange", e);
    } catch (com.nimbusds.oauth2.sdk.ParseException e) {
      throw new KeycloakAuthException("Authorization code exchange request error", null, e);
    }
    if (expectedNonce != null) {
      requireValidNonce(tokenSet.getIdToken(), expectedNonce);
    }
    return tokenSet;
  }

  // id_token의 nonce 클레임을 대조하기 전에 강화 JwtValidator로 서명·iss·aud·exp까지 검증한다.
  // aud 는 expectedAudience 가 아니라 **clientId** 다 — id_token 의 aud 는 client id 를 담고(OIDC Core §2·§3.1.3.7),
  // expectedAudience 는 액세스 토큰이 향하는 리소스 서버의 값이다. 키 원천·iss·alg 핀·skew 는 validate() 의 검증기
  // 것을 그대로 쓴다(withAudience — 두 번째 키 저장소를 만들지 않는다). forRealm 의 TokenValidationException 도
  // 「invalid id_token」으로 가도록 파생은 try 안에 둔다.
  // 패키지 가시성: 토큰 엔드포인트 send() 없이 nonce 로직을 단위 테스트로 검증하기 위함
  // (buildExchangeCodeRequest/buildLogoutRequest와 동일 패턴).
  void requireValidNonce(String idToken, String expectedNonce) {
    if (idToken == null) {
      throw new KeycloakAuthException(
          "Authorization code exchange failed: missing id_token for nonce validation", null, null);
    }
    ValidatedToken claims;
    try {
      claims = validator().withAudience(config.getClientId()).validate(idToken);
    } catch (io.github.xzawed.keycloak.core.exception.TokenValidationException e) {
      throw new KeycloakAuthException("Authorization code exchange failed: invalid id_token", null, e);
    }
    if (!expectedNonce.equals(claims.getClaims().get("nonce"))) {
      throw new KeycloakAuthException("Authorization code exchange failed: unexpected nonce", null, null);
    }
  }

  // exchangeCode()의 send() 이전 요청 구성만 분리: send() 없이 grant_type/code/code_verifier/
  // 엔드포인트를 빠른 단위 테스트로 검증하기 위한 패키지 가시성 헬퍼 (buildLogoutRequest와 동일 패턴).
  HTTPRequest buildExchangeCodeRequest(String code, URI redirectUri, String codeVerifier) {
    if (code == null) {
      throw new IllegalArgumentException("code must not be null");
    }
    if (codeVerifier == null) {
      throw new IllegalArgumentException("codeVerifier must not be null");
    }
    AuthorizationCodeGrant grant = new AuthorizationCodeGrant(
        requestValue("Authorization code exchange", "code", () -> new AuthorizationCode(code)), redirectUri,
        requestValue("Authorization code exchange", "code_verifier",
            () -> new com.nimbusds.oauth2.sdk.pkce.CodeVerifier(codeVerifier)));
    TokenRequest tr = config.getClientSecret() != null
        ? new TokenRequest.Builder(metadata.getTokenEndpoint(),
            clientAuth("authorization code exchange"), grant).build()
        : new TokenRequest.Builder(metadata.getTokenEndpoint(), new ClientID(config.getClientId()), grant).build();
    return tr.toHTTPRequest();
  }

  public TokenSet clientCredentialsToken() {
    try {
      TokenRequest tr = new TokenRequest.Builder(metadata.getTokenEndpoint(),
          clientAuth("the client_credentials grant"), new ClientCredentialsGrant())
          .scope(configuredScope())
          .build();
      long issuedAt = Instant.now().getEpochSecond();
      HTTPRequest req = applyTimeouts(tr.toHTTPRequest());
      TokenResponse resp = TokenResponse.parse(CappedResponseSender.send(req, "token"));
      if (!resp.indicatesSuccess()) {
        var err = resp.toErrorResponse().getErrorObject();
        throw new KeycloakAuthException("Client credentials failed: "
            + describe(err.getDescription(), req, config.getClientSecret()), err.getCode(), null);
      }
      return toTokenSet(resp.toSuccessResponse().getTokens(), issuedAt);
    } catch (java.io.IOException e) {
      throw transportFailure("Client credentials", e);
    } catch (com.nimbusds.oauth2.sdk.ParseException e) {
      throw new KeycloakAuthException("Client credentials request error", null, e);
    }
  }

  public TokenSet refresh(String refreshToken) {
    if (refreshToken == null) {
      throw new IllegalArgumentException("refreshToken must not be null");
    }
    try {
      long issuedAt = Instant.now().getEpochSecond();
      HTTPRequest req = applyTimeouts(buildRefreshRequest(refreshToken));
      TokenResponse resp = TokenResponse.parse(CappedResponseSender.send(req, "token"));
      if (!resp.indicatesSuccess()) {
        var err = resp.toErrorResponse().getErrorObject();
        throw new KeycloakAuthException("Token refresh failed: "
            + describe(err.getDescription(), req, config.getClientSecret()), err.getCode(), null);
      }
      return toTokenSet(resp.toSuccessResponse().getTokens(), issuedAt);
    } catch (java.io.IOException e) {
      throw transportFailure("Token refresh", e);
    } catch (com.nimbusds.oauth2.sdk.ParseException e) {
      throw new KeycloakAuthException("Token refresh request error", null, e);
    }
  }

  // refresh()의 send() 이전 요청 구성. ⚠️ 공개 클라이언트도 refresh 할 수 있다 — Keycloak 이
  // 허용한다(실측 2026-09-24, KC 26.6: 200). exchangeCode 와 같이 시크릿이 없으면 client_id 를
  // 본문에 싣는다(예전엔 clientAuth() 가 로컬에서 거부해 공개 클라이언트가 갱신을 못 했다).
  HTTPRequest buildRefreshRequest(String refreshToken) {
    RefreshTokenGrant grant = new RefreshTokenGrant(
        requestValue("Token refresh", "refresh_token", () -> new RefreshToken(refreshToken)));
    TokenRequest tr = config.getClientSecret() != null
        ? new TokenRequest.Builder(metadata.getTokenEndpoint(), clientAuth("token refresh"), grant).build()
        : new TokenRequest.Builder(metadata.getTokenEndpoint(), new ClientID(config.getClientId()), grant).build();
    return tr.toHTTPRequest();
  }

  public void logout(String refreshToken) {
    try {
      HTTPResponse resp = CappedResponseSender.send(applyTimeouts(buildLogoutRequest(refreshToken)), "logout");
      if (!resp.indicatesSuccess()) {
        throw new KeycloakAuthException("Logout failed (HTTP " + resp.getStatusCode() + ")", null, null);
      }
    } catch (java.io.IOException e) {
      throw transportFailure("Logout", e);
    }
  }

  // logout()의 send() 이전 요청 구성만 분리: send() 없이 HTTP method/endpoint/content-type/
  // Authorization 헤더/body를 빠른 단위 테스트로 검증하기 위한 패키지 가시성 헬퍼 (3a Important fix).
  HTTPRequest buildLogoutRequest(String refreshToken) {
    if (refreshToken == null) {
      throw new IllegalArgumentException("refreshToken must not be null");
    }
    try {
      HTTPRequest req = new HTTPRequest(HTTPRequest.Method.POST, metadata.getEndSessionEndpoint().toURL());
      req.setEntityContentType(ContentType.APPLICATION_URLENCODED);
      Map<String, List<String>> params = new LinkedHashMap<>();
      // 공개 클라이언트도 로그아웃할 수 있다(실측: 204, 이후 같은 토큰 "Session not active") —
      // 시크릿이 없으면 Basic 대신 client_id 를 본문에 싣는다.
      if (config.getClientSecret() != null) {
        clientAuth("logout").applyTo(req);
      } else {
        params.put("client_id", Collections.singletonList(config.getClientId()));
      }
      params.put("refresh_token", Collections.singletonList(refreshToken));
      req.setBody(URLUtils.serializeParameters(params));
      return req;
    } catch (java.net.MalformedURLException e) {
      throw new KeycloakAuthException("Logout request error", null, e);
    }
  }

  // RFC 7662 토큰 introspection: metadata.getIntrospectionEndpoint()에 client 인증 포함 POST (WBS 3.7).
  public IntrospectionResult introspect(String token) {
    try {
      HTTPRequest req = applyTimeouts(buildIntrospectionRequest(token));
      TokenIntrospectionResponse tir = TokenIntrospectionResponse.parse(CappedResponseSender.send(req, "introspection"));
      if (!tir.indicatesSuccess()) {
        var err = tir.toErrorResponse().getErrorObject();
        throw new KeycloakAuthException("Introspection failed: "
            + describe(err.getDescription(), req, config.getClientSecret()), err.getCode(), null);
      }
      return toIntrospectionResult(tir.toSuccessResponse());
    } catch (java.io.IOException e) {
      throw transportFailure("Introspection", e);
    } catch (com.nimbusds.oauth2.sdk.ParseException e) {
      throw new KeycloakAuthException("Introspection request error", null, e);
    }
  }

  // 전송 실패 — 상한을 넘는 응답(CappedResponseSender.TooLarge)도 IOException 이라 같은 타입으로 던지되, 메시지는 무엇이
  // 상한을 넘었는지 말한다(응답을 인용하지 않는다). 그 밖의 IOException 은 지금까지의 「… transport failure」 그대로다.
  private static KeycloakTransportException transportFailure(String operation, java.io.IOException e) {
    return new KeycloakTransportException(e instanceof CappedResponseSender.TooLarge
        ? operation + " failed: " + e.getMessage() : operation + " transport failure", e);
  }

  // introspect()의 send() 이전 요청 구성만 분리: send() 없이 HTTP method/endpoint/content-type/
  // Authorization 헤더/body를 빠른 단위 테스트로 검증하기 위한 패키지 가시성 헬퍼 (buildLogoutRequest와 동일 패턴).
  HTTPRequest buildIntrospectionRequest(String token) {
    if (token == null) {
      throw new IllegalArgumentException("token must not be null");
    }
    TokenIntrospectionRequest req = new TokenIntrospectionRequest(
        metadata.getIntrospectionEndpoint(), clientAuth("token introspection"),
        requestValue("Introspection", "token", () -> new TypelessAccessToken(token)));
    return req.toHTTPRequest();
  }

  // ⚠️ `Scope.isEmpty()`는 **원소 수**를 센다 — 원소가 하나라도 있으면 그 값이 공백이든 빈
  // 문자열이든 폴백이 발동하지 않고, Nimbus 가 `IllegalArgumentException("The value must not be
  // null or empty string")` 을 던져 §4 경계를 넘어 공개 API 로 샌다. `KeycloakConfig.Builder`
  // 는 scope 값을 검증하지 않으므로(그 클래스에 scope 검증 0건) 도달 가능하다.
  // 그래서 **생성 전에** 공백 원소를 거른다 — 인가 요청과 client_credentials 가 이 한 곳을 지난다
  // (한때 인가 요청만 걸러 client_credentials 가 같은 설정으로 샜다). Kotlin 자매도 같은 모양이다.
  private Scope configuredScope() {
    return new Scope(
        config.getScopes().stream()
            .filter(s -> s != null && !s.isBlank())
            .toArray(String[]::new));
  }

  // ⚠️ Nimbus 값 타입(AuthorizationCode·CodeVerifier·RefreshToken·TypelessAccessToken)은 생성자에서
  // 값을 검사한다 — 빈·공백 문자열과 RFC 7636 §4.1 밖의 verifier(43–128 자, [A-Za-z0-9-._~])를
  // `IllegalArgumentException` 으로 거부하고, 그대로 두면 §4 경계를 넘어 공개 API 로 샌다(공백 scope 와
  // 같은 모양). 자매 일곱은 같은 값을 서버로 보내 400 → SDK 인증 오류를 받으므로(실측 2026-09-25),
  // 요청을 보내지 않은 채 같은 분류인 KeycloakAuthException 으로 바꾼다. null 은 여기 오기 전에 각
  // 호출부가 SDK 소유의 IllegalArgumentException 으로 거부한다(호출 계약 위반이지 값 오류가 아니다).
  private static <T> T requestValue(String operation, String param, java.util.function.Supplier<T> ctor) {
    try {
      return ctor.get();
    } catch (IllegalArgumentException e) {
      throw new KeycloakAuthException(operation + " request error: invalid " + param, null, e);
    }
  }

  // ⚠️ error_description 은 IdP 가 쓴 산문이라 진단 가치가 커서 메시지에 싣는다 — 그런데 IdP 가 요청을 되울리면 이
  // 요청이 보낸 비밀(Basic 자격·code·verifier·refresh/introspect 토큰)이 SDK 메시지에 원문으로 실렸다(실측 2026-09-26,
  // MalformedIdpResponseTest e1·e2·e7). 가린다: (1) 보낸 비밀의 되울림 꼴 전부({@link #echoForms})와 퍼센트 인코딩을 풀면
  // 그 값이 되는 구간({@link #maskDecoded}), (2) 보낸 비밀과
  // 10 자 창 하나라도 겹치는 연속(잘린·이름표에 붙은 되울림 `token=<앞 12 자>`), (3) 토큰 모양의 20 자 이상 연속 —
  // 숫자·대문자·`+=~` 중 하나를 품은 것(`code_challenge_method` 같은 산문 식별자와 소문자 URL 은 남는다).
  // 연속은 안쪽 `.` 을 품는다 — 마디마다 20 자 미만인 JWT 도 통째로 잡히고, 앞뒤 `.`(말줄임표)는 떼고 잰다(Grok 레그
  // h2·h3). ⚠️ 정규식은 **문자 클래스 하나의 반복**이어야 한다 — 그룹 반복 `(?:\.[..]+)*` 은 반복마다 재귀해 600 KB
  // 설명에서 StackOverflowError 가 SDK 타입 대신 나갔다(실측 h8, Sonar S5998 이 먼저 짚었다).
  // ⚠️ 보내지 않았고 토큰 모양도 아닌 값(20 자 미만, 또는 소문자뿐)은 낱말과 못 가른다 — 그 경계는
  // MalformedIdpResponseTest 의 KNOWN_LEAKS(e6·h1·h4)가 고정한다.
  private static final java.util.regex.Pattern RUN = java.util.regex.Pattern.compile("[A-Za-z0-9_~+/=.-]+");
  private static final java.util.regex.Pattern TOKENISH = java.util.regex.Pattern.compile("[A-Z0-9+=~]");
  private static final int WINDOW = 10;
  private static final java.util.Set<String> SECRET_PARAMS = java.util.Set.of(
      "code", "code_verifier", "refresh_token", "token", "client_secret", "client_assertion", "password");

  /**
   * 이보다 긴 error_description 은 싣지 않는다 — 고정된 표식으로 바꾼다. ⚠️ 가리기의 최악 비용은 설명 길이 × 보낸 값 길이다: 적대적
   * IdP 는 자기가 보낸(받은) 값을 알므로 그 값의 앞 999 자로 채운 설명이 indexOf 를 자리마다 끝까지 돌린다 — 1 MiB 설명(토큰 응답 상한)에
   * 호출 하나가 4.6 초였다(`a`×999+`b` refresh 토큰 · 설명 `a`×1 MiB, 실측 — 상한 전 main 도 String.replace 로 3.1 초). 앞부분만 남기지
   * 않는 것은 자르는 자리에 걸친 되울림의 앞 조각이 가려지지 않은 채 남기 때문이다. 정상 설명은 이보다 훨씬 짧다(Keycloak 은 300 자 밑).
   */
  static final int MAX_DESCRIPTION_CHARS = 4096;

  static String describe(String description, HTTPRequest sent, char[] clientSecret) {
    if (description == null) return null;
    if (description.length() > MAX_DESCRIPTION_CHARS) {
      return "(error_description omitted: " + description.length() + " chars > " + MAX_DESCRIPTION_CHARS + ")";
    }
    List<String> secrets = sentSecrets(sent.getAuthorization(), sentValues(sent, clientSecret));
    // 푼 바이트로 먼저 가린다 — 그대로의 꼴을 먼저 가리면 인코딩된 되울림의 아스키 부분만 사라지고 나머지(`&#233;`)가 남는다.
    String out = maskDecoded(description, secrets);
    for (String s : secrets) out = out.replace(s, "***");
    java.util.regex.Matcher m = RUN.matcher(out);
    StringBuilder masked = new StringBuilder();
    while (m.find()) {
      m.appendReplacement(masked, java.util.regex.Matcher.quoteReplacement(maskRun(m.group(), secrets)));
    }
    m.appendTail(masked);
    return masked.toString();
  }

  /** 이 요청이 실어 보낸 비밀 값 — Basic 자격, 시크릿, 비밀 파라미터(디코딩된 값). */
  private static List<String> sentValues(HTTPRequest sent, char[] clientSecret) {
    List<String> values = new java.util.ArrayList<>();
    String authorization = sent.getAuthorization();
    if (authorization != null) values.add(authorization.substring(authorization.indexOf(' ') + 1));
    if (clientSecret != null) values.add(new String(clientSecret));
    if (sent.getBody() != null) {
      URLUtils.parseParameters(sent.getBody()).forEach((name, vs) -> {
        if (SECRET_PARAMS.contains(name)) values.addAll(vs);
      });
    }
    values.removeIf(v -> v == null || v.isEmpty());
    return values;
  }

  /** 그대로 가릴 문자열 — Authorization 값, 그리고 보낸 값마다 그 되울림 꼴({@link #echoForms}). 긴 것부터. */
  private static List<String> sentSecrets(String authorization, List<String> values) {
    java.util.Set<String> secrets = new java.util.LinkedHashSet<>();
    if (authorization != null) secrets.add(authorization);
    for (String v : values) secrets.addAll(echoForms(v));
    secrets.removeIf(s -> s == null || s.isEmpty());
    List<String> sorted = new java.util.ArrayList<>(secrets);
    sorted.sort(java.util.Comparator.comparingInt(String::length).reversed()); // "Basic x" 를 "x" 보다 먼저
    return sorted;
  }

  /**
   * 퍼센트 인코딩을 푼 사본에서 보낸 값을 찾아 원문의 그 구간을 가린다. ⚠️ 꼴을 늘어놓는 것으로는 끝나지 않는다 — 인코더마다 그대로
   * 두는 글자·공백의 꼴·16진의 대소문자·문자 집합이 다르고(Grok 레그 1: Go {@code url.QueryEscape} →
   * {@code sec+ret%2F%2B%3D~0005%C3%A9} · Python {@code quote} → {@code sec%20ret/%2B%3D~0005%C3%A9} · JS {@code encodeURI} ·
   * ISO-8859-1 폼 → {@code …%E9}), 한 겹 더 인코딩되거나 공백과 {@code +} 가 뒤섞이기도 한다(레그 2: 이미 {@code quote_plus} 된 값을 다시
   * 인코딩한 {@code sec%2Bret%252F…} · 공백을 {@code %2B} 로 쓴 게이트웨이 · {@code %uXXXX} · 비 ASCII 를 {@code \\u00e9}·
   * {@code &#233;}·ISO-8859-1 로 읽은 깨진 글자로 쓴 뒤 URL 인코딩한 것 — 아스키만 가려지고 {@code é} 가 남았다) — 전부 위의 꼴과 달라
   * 그대로 찍혔다({@code AuthEchoedSecretFormsTest}). 그래서 꼴이 아니라 <b>푼 바이트</b>를 맞춘다: 이스케이프({@link #unescapeAt})를
   * <b>두 겹까지</b> 풀고, 공백과 {@code +} 는 같은 글자로 본다(폼 인코딩에서 둘은 서로의 꼴이다). 바늘은 그대로 가릴 꼴({@code forms})마다
   * 그 UTF-8 바이트 · ISO-8859-1 로 쓸 수 있으면 그 바이트 · UTF-8 바이트를 ISO-8859-1 글자로 읽어 다시 UTF-8 로 쓴 깨진 꼴의 바이트다.
   * 보낸 값과 같은 바이트가 되는 구간만 가린다 — 산문은 건드리지 않는다.
   */
  private static String maskDecoded(String text, List<String> forms) {
    java.util.Set<String> needles = decodedNeedles(forms);
    if (needles.isEmpty()) return text;
    boolean[] hit = new boolean[text.length()];
    // 이스케이프 하나는 제 길이보다 적은 바이트를 낸다 — 사본은 원문보다 길어지지 않는다
    int[] from = new int[text.length()];
    int[] to = new int[text.length()];
    String once = unescape(text, null, null, from, to);
    mark(once, from, to, needles, hit);
    int[] from2 = new int[once.length()];
    int[] to2 = new int[once.length()];
    mark(unescape(once, from, to, from2, to2), from2, to2, needles, hit);
    return starred(text, hit);
  }

  /** {@link #maskDecoded} 의 바늘 — 한 바이트를 한 글자(0–255)로, 공백은 {@code +} 로({@link #unescape} 와 같이). */
  private static java.util.Set<String> decodedNeedles(List<String> forms) {
    java.nio.charset.Charset utf8 = java.nio.charset.StandardCharsets.UTF_8;
    java.nio.charset.Charset latin1 = java.nio.charset.StandardCharsets.ISO_8859_1;
    java.nio.charset.CharsetEncoder latin1Encoder = latin1.newEncoder();
    java.util.Set<String> needles = new java.util.LinkedHashSet<>();
    for (String f : forms) {
      String bytes = new String(f.getBytes(utf8), latin1);
      needles.add(bytes.replace(' ', '+'));
      needles.add(new String(bytes.getBytes(utf8), latin1).replace(' ', '+')); // UTF-8 을 ISO-8859-1 로 읽은 깨진 꼴
      if (latin1Encoder.canEncode(f)) needles.add(f.replace(' ', '+')); // ISO-8859-1 의 바이트는 그 글자 값과 같다
    }
    needles.removeIf(String::isEmpty);
    return needles;
  }

  /**
   * {@code src} 의 이스케이프({@link #unescapeAt})를 한 겹 푼 사본 — 한 바이트를 한 글자(0–255)로, 공백은 {@code +} 로 적는다. 사본의
   * 글자 j 는 원문의 구간 [{@code from[j]}, {@code to[j]}) 에서 왔다 — {@code srcFrom} 이 있으면 {@code src} 자체가 사본이고, 구간을
   * 그 원문으로 옮긴다. ⚠️ 상태를 쥔 객체를 만들지 않는다 — 되울린 비밀을 품은 사본이 어디에도 남지 않는다({@code FacadeDumpTest}).
   */
  private static String unescape(String src, int[] srcFrom, int[] srcTo, int[] from, int[] to) {
    StringBuilder out = new StringBuilder(src.length());
    int i = 0;
    while (i < src.length()) {
      int k = out.length();
      int end = unescapeAt(src, i, out);
      if (end < 0) {
        out.append(src.charAt(i)); // 0–255 밖의 글자는 바늘(0–255)과 맞을 수 없다
        end = i + 1;
      }
      for (int j = k; j < out.length(); j++) {
        if (out.charAt(j) == ' ') out.setCharAt(j, '+');
        from[j] = srcFrom == null ? i : srcFrom[i];
        to[j] = srcTo == null ? end : srcTo[end - 1];
      }
      i = end;
    }
    return out.toString();
  }

  /** 바늘이 사본 {@code view} 에 나오는 곳마다 그 원문 구간을 {@code hit} 에 표시한다. */
  private static void mark(String view, int[] from, int[] to, java.util.Set<String> needles, boolean[] hit) {
    for (String needle : needles) {
      for (int at = view.indexOf(needle); at >= 0; at = view.indexOf(needle, at + 1)) {
        java.util.Arrays.fill(hit, from[at], to[at + needle.length() - 1], true);
      }
    }
  }

  /**
   * {@code src} 의 {@code i} 에서 시작하는 이스케이프를 풀어 그 바이트를 {@code out} 에 한 글자(0–255)씩 덧붙이고 끝 위치를 돌려준다 —
   * 이스케이프가 아니면 -1(덧붙이지 않는다). {@code %XX} 는 그 바이트, {@code %uXXXX}·{@code \\uXXXX}(서로게이트 쌍이면 둘을 이어)와 HTML
   * 숫자 참조 {@code &#NNN;}·{@code &#xHH;} 는 그 글자의 UTF-8 바이트. ⚠️ {@code \\u} 는 퍼센트 인코딩 <b>안</b>에서만 나온다 — 날
   * {@code \\} 는 Nimbus 가 이미 지웠다. 이름 참조({@code &eacute;})는 풀지 않는다.
   */
  private static int unescapeAt(String src, int i, StringBuilder out) {
    char c = src.charAt(i);
    if (c == '&') return entityAt(src, i, out);
    if (c != '%' && c != '\\') return -1;
    int b = c == '%' && i + 2 < src.length() ? hexByte(src.charAt(i + 1), src.charAt(i + 2)) : -1;
    if (b >= 0) {
      out.append((char) b);
      return i + 3;
    }
    int unit = unitAt(src, i);
    if (unit < 0) return -1;
    int low = Character.isHighSurrogate((char) unit) ? unitAt(src, i + 6) : -1;
    String ch = low >= 0 && Character.isLowSurrogate((char) low)
        ? new String(new char[] {(char) unit, (char) low}) : String.valueOf((char) unit);
    appendUtf8(out, ch);
    return i + 6 * ch.length();
  }

  /** {@code %uXXXX}·{@code \\uXXXX} 의 16 비트 값, 아니면 -1. */
  private static int unitAt(String src, int i) {
    if (i + 5 >= src.length() || (src.charAt(i) != '%' && src.charAt(i) != '\\')
        || Character.toLowerCase(src.charAt(i + 1)) != 'u') {
      return -1;
    }
    int v = 0;
    for (int k = i + 2; k < i + 6; k++) {
      int d = hexDigit(src.charAt(k));
      if (d < 0) return -1;
      v = v * 16 + d;
    }
    return v;
  }

  /** HTML 숫자 참조 {@code &#NNN;}·{@code &#xHH;}(일곱 자리까지) — 그 글자의 UTF-8 바이트를 덧붙이고 끝 위치를, 아니면 -1. */
  private static int entityAt(String src, int i, StringBuilder out) {
    int n = src.length();
    if (i + 3 >= n || src.charAt(i + 1) != '#') return -1;
    int radix = Character.toLowerCase(src.charAt(i + 2)) == 'x' ? 16 : 10;
    int start = radix == 16 ? i + 3 : i + 2;
    int k = start;
    int cp = 0;
    while (k < n && k - start < 7 && digit(src.charAt(k), radix) >= 0) {
      cp = cp * radix + digit(src.charAt(k), radix);
      k++;
    }
    if (k == start || k >= n || src.charAt(k) != ';' || cp > Character.MAX_CODE_POINT) return -1;
    appendUtf8(out, new String(Character.toChars(cp)));
    return k + 1;
  }

  /** {@code s} 의 UTF-8 바이트를 한 글자(0–255)씩. */
  private static void appendUtf8(StringBuilder out, String s) {
    for (byte b : s.getBytes(java.nio.charset.StandardCharsets.UTF_8)) out.append((char) (b & 0xFF));
  }

  /** ASCII 숫자 하나의 값({@code radix} 16 이면 16진), 아니면 -1. */
  private static int digit(char c, int radix) {
    int d = hexDigit(c);
    return d >= radix ? -1 : d;
  }

  /** {@code %} 뒤 두 글자가 ASCII 16진이면 그 바이트, 아니면 -1. */
  private static int hexByte(char hi, char lo) {
    int h = hexDigit(hi);
    int l = hexDigit(lo);
    return h < 0 || l < 0 ? -1 : h * 16 + l;
  }

  private static int hexDigit(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
  }

  /** 표시된 구간마다 {@code ***} 하나로. */
  private static String starred(String text, boolean[] hit) {
    StringBuilder out = new StringBuilder(text.length());
    int i = 0;
    while (i < text.length()) {
      if (hit[i]) {
        out.append("***");
        while (i < text.length() && hit[i]) i++;
      } else {
        out.append(text.charAt(i++));
      }
    }
    return out.toString();
  }

  /**
   * 보낸 값이 error_description 으로 되돌아올 수 있는 꼴 — 그대로 · IdP 가 받은 꼴(UTF-8 이 짝 없는 서로게이트를 {@code ?} 로 바꾼다) ·
   * 그 둘에서 RFC 6749 §5.2 밖의 글자를 지운 꼴(Nimbus {@code ErrorObject} 가 설명에 한 일 — 같은 함수로 지운다) · 폼 인코딩
   * ({@code URLEncoder} — Basic 의 비밀번호 칸과 본문이 이 꼴이다, RFC 6749 §2.3.1) · RFC 3986 퍼센트 인코딩(공백 {@code %20},
   * {@code ~} 그대로, {@code *} 는 {@code %2A}) · 두 인코딩의 소문자 16진. ⚠️ 그대로만 찾으면 {@code é} 를 지운 사본이 빗나가 첫 낱말이
   * 남았고({@code Bad credentials: sec ***}), 인코딩된 사본은 {@code %} 가 연속을 끊어 10 자 창도 못 잡았다
   * ({@code AuthEchoedSecretFormsTest}). Kotlin {@code echoForms} 와 같은 꼴이다.
   */
  private static List<String> echoForms(String value) {
    String received = new String(value.getBytes(java.nio.charset.StandardCharsets.UTF_8),
        java.nio.charset.StandardCharsets.UTF_8);
    String form = java.net.URLEncoder.encode(value, java.nio.charset.StandardCharsets.UTF_8);
    // URLEncoder 는 공백만 `+` 로 쓰고(`+` 자체는 %2B), `~` 를 %7E 로, `*` 를 그대로 쓴다 — RFC 3986 의 unreserved 로 고친다.
    String pct = form.replace("+", "%20").replace("*", "%2A").replace("%7E", "~");
    return List.of(value, received, ErrorObject.removeIllegalChars(value), ErrorObject.removeIllegalChars(received),
        form, pct, lowerHex(form), lowerHex(pct));
  }

  /** {@code %XX} 의 16진만 소문자로 — 값 자체의 대문자는 그대로 둔다. */
  private static String lowerHex(String encoded) {
    char[] c = encoded.toCharArray();
    int i = 0;
    while (i + 2 < c.length) {
      if (c[i] == '%') {
        c[i + 1] = Character.toLowerCase(c[i + 1]);
        c[i + 2] = Character.toLowerCase(c[i + 2]);
        i += 3;
      } else {
        i++;
      }
    }
    return new String(c);
  }

  /** 연속 하나 — 앞뒤 `.` 을 뗀 몸통이 토큰 모양이거나 보낸 비밀과 10 자 창을 나누면 몸통을 가린다. */
  private static String maskRun(String run, List<String> secrets) {
    int from = 0;
    int to = run.length();
    while (from < to && run.charAt(from) == '.') from++;
    while (to > from && run.charAt(to - 1) == '.') to--;
    String core = run.substring(from, to);
    boolean mask = core.length() >= WINDOW
        && ((core.length() >= 20 && TOKENISH.matcher(core).find()) || sharesWindow(core, secrets));
    return mask ? run.substring(0, from) + "***" + run.substring(to) : run;
  }

  private static boolean sharesWindow(String run, List<String> secrets) {
    for (String s : secrets) {
      for (int i = 0; i + WINDOW <= s.length(); i++) {
        if (run.contains(s.substring(i, i + WINDOW))) return true;
      }
    }
    return false;
  }

  static IntrospectionResult toIntrospectionResult(TokenIntrospectionSuccessResponse s) {
    return new IntrospectionResult(s.isActive(),
        java.util.Optional.ofNullable(s.getUsername()),
        java.util.Optional.ofNullable(s.getClientID()).map(ClientID::getValue));
  }

  // 기밀 클라이언트(clientSecret 설정됨)를 요구하는 흐름(client-credentials/introspect — 서버도 공개
  // 클라이언트에게 401/403 으로 거부한다)의. refresh/logout/code 교환은 시크릿이 없으면 여기 오지 않는다.
  // 공용 클라이언트 인증. 퍼블릭/PKCE 클라이언트는 getClientSecret()이 null이라 예전에는
  // new String((char[]) null)이 맨 NPE로 터졌다 — 어떤 작업이 기밀 클라이언트를 요구하는지 알려주는
  // SDK 예외로 대체한다(실패 조건은 동일, 진단만 개선).
  // 타입은 KeycloakConfigException이다 — IdP가 거절한 것이 아니라 요청이 전송조차 되지 않는 로컬 구성
  // 미비이며, 같은 조건("clientSecret이 없다")을 admin AdminClient.requireClientSecret()이 이미
  // KeycloakConfigException으로 분류한다(Python KeycloakConfigError·Go *ConfigError 동형).
  private ClientAuthentication clientAuth(String operation) {
    char[] secret = config.getClientSecret();
    if (secret == null) {
      throw new KeycloakConfigException("Confidential client required: " + operation
          + " needs a configured clientSecret. Public/PKCE clients cannot use this operation — set"
          + " clientSecret on KeycloakConfig, or use createAuthorizationRequest()/exchangeCode()"
          + " for the public client flow.", null);
    }
    return new ClientSecretBasic(new ClientID(config.getClientId()), new Secret(new String(secret)));
  }

  static TokenSet toTokenSet(Tokens tokens, long issuedAtEpoch) {
    var at = tokens.getAccessToken();
    Instant exp = Instant.ofEpochSecond(issuedAtEpoch + at.getLifetime());
    String refresh = tokens.getRefreshToken() == null ? null : tokens.getRefreshToken().getValue();
    // authorization_code 그랜트는 OIDCTokens(=id_token 포함 가능)를 돌려준다 — id_token을 실어
    // nonce 재생 방지에 쓴다. 비-OIDC 그랜트(client-credentials/refresh)는 플레인 Tokens라 null.
    String idToken = tokens instanceof com.nimbusds.openid.connect.sdk.token.OIDCTokens oidc
        ? oidc.getIDTokenString() : null;
    return new TokenSet(
        at.getValue(), refresh, idToken, "Bearer",
        at.getScope() == null ? null : at.getScope().toString(), exp);
  }
}
