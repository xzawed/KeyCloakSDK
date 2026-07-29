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
    JwtValidator v = jwtValidator;
    if (v == null) {
      synchronized (this) {
        v = jwtValidator;
        if (v == null) {
          v = JwtValidator.forRealm(metadata, config, allowedAlgorithms(), config.getClientId());
          jwtValidator = v;
        }
      }
    }
    return v.validate(accessToken);
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
  HTTPRequest applyTimeouts(HTTPRequest req) {
    req.setConnectTimeout((int) config.getConnectTimeout().toMillis());
    req.setReadTimeout((int) config.getReadTimeout().toMillis());
    return req;
  }
  public AuthorizationUrlRequest createAuthorizationRequest(URI redirectUri) {
    Pkce pkce = Pkce.generate();
    State state = new State(); Nonce nonce = new Nonce();
    Scope scope = new Scope(config.getScopes().toArray(new String[0]));
    if (scope.isEmpty()) scope = new Scope("openid");
    com.nimbusds.openid.connect.sdk.AuthenticationRequest ar =
        new com.nimbusds.openid.connect.sdk.AuthenticationRequest.Builder(
            new ResponseType(ResponseType.Value.CODE), scope,
            new ClientID(config.getClientId()), redirectUri)
          .endpointURI(metadata.getAuthorizationEndpoint())
          .state(state).nonce(nonce)
          .codeChallenge(pkce.nimbusVerifier(), CodeChallengeMethod.S256)
          .build();
    return new AuthorizationUrlRequest(ar.toURI(), pkce.getVerifier(), state.getValue(), nonce.getValue());
  }
  // Authorization Code 그랜트로 토큰 교환 (I.2). PKCE code_verifier를 포함해 토큰 엔드포인트에
  // POST한다. 기밀 클라이언트(clientSecret 설정됨)는 ClientSecretBasic, 퍼블릭 클라이언트는
  // client_id만 본문에 포함한다(clientAuth() 미사용 — Secret 없이 인증 불가하므로).
  public TokenSet exchangeCode(String code, URI redirectUri, String codeVerifier) {
    return exchangeCode(code, redirectUri, codeVerifier, null);
  }

  // OIDC nonce 재생 방지: expectedNonce가 주어지면(createAuthorizationRequest의 getNonce()) 응답
  // id_token을 강화 JwtValidator로 서명·iss·aud·exp까지 검증한 뒤 nonce 클레임을 대조한다 —
  // 불일치·부재·검증실패는 모두 거부(fail-closed). null이면 id_token 검증을 건너뛴다(무-nonce 흐름).
  public TokenSet exchangeCode(String code, URI redirectUri, String codeVerifier, String expectedNonce) {
    TokenSet tokenSet;
    try {
      long issuedAt = Instant.now().getEpochSecond();
      // OIDC 인지 파서로 파싱해야 id_token이 보존된다(플레인 TokenResponse.parse는 Tokens만
      // 만들고 OIDCTokens/id_token을 인지하지 못한다).
      TokenResponse resp = OIDCTokenResponseParser.parse(
          applyTimeouts(buildExchangeCodeRequest(code, redirectUri, codeVerifier)).send());
      if (!resp.indicatesSuccess()) {
        var err = resp.toErrorResponse().getErrorObject();
        throw new KeycloakAuthException("Authorization code exchange failed: " + err.getDescription(),
            err.getCode(), null);
      }
      tokenSet = toTokenSet(resp.toSuccessResponse().getTokens(), issuedAt);
    } catch (java.io.IOException e) {
      throw new KeycloakTransportException("Authorization code exchange transport failure", e);
    } catch (com.nimbusds.oauth2.sdk.ParseException e) {
      throw new KeycloakAuthException("Authorization code exchange request error", null, e);
    }
    if (expectedNonce != null) {
      requireValidNonce(tokenSet.getIdToken(), expectedNonce);
    }
    return tokenSet;
  }

  // id_token의 nonce 클레임을 대조하기 전에 강화 JwtValidator로 서명·iss·aud·exp까지 검증한다
  // (validate() 재사용 — 액세스 토큰과 id_token 모두 aud=clientId라 검증기를 공유해도 안전).
  // 패키지 가시성: 토큰 엔드포인트 send() 없이 nonce 로직을 단위 테스트로 검증하기 위함
  // (buildExchangeCodeRequest/buildLogoutRequest와 동일 패턴).
  void requireValidNonce(String idToken, String expectedNonce) {
    if (idToken == null) {
      throw new KeycloakAuthException(
          "Authorization code exchange failed: missing id_token for nonce validation", null, null);
    }
    ValidatedToken claims;
    try {
      claims = validate(idToken);
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
    AuthorizationCodeGrant grant = new AuthorizationCodeGrant(
        new AuthorizationCode(code), redirectUri,
        new com.nimbusds.oauth2.sdk.pkce.CodeVerifier(codeVerifier));
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
          .scope(new Scope(config.getScopes().toArray(new String[0])))
          .build();
      long issuedAt = Instant.now().getEpochSecond();
      TokenResponse resp = TokenResponse.parse(applyTimeouts(tr.toHTTPRequest()).send());
      if (!resp.indicatesSuccess()) {
        var err = resp.toErrorResponse().getErrorObject();
        throw new KeycloakAuthException("Client credentials failed: " + err.getDescription(),
            err.getCode(), null);
      }
      return toTokenSet(resp.toSuccessResponse().getTokens(), issuedAt);
    } catch (java.io.IOException e) {
      throw new KeycloakTransportException("Client credentials transport failure", e);
    } catch (com.nimbusds.oauth2.sdk.ParseException e) {
      throw new KeycloakAuthException("Client credentials request error", null, e);
    }
  }

  public TokenSet refresh(String refreshToken) {
    if (refreshToken == null) {
      throw new IllegalArgumentException("refreshToken must not be null");
    }
    try {
      TokenRequest tr = new TokenRequest.Builder(metadata.getTokenEndpoint(), clientAuth("token refresh"),
          new RefreshTokenGrant(new RefreshToken(refreshToken)))
          .build();
      long issuedAt = Instant.now().getEpochSecond();
      TokenResponse resp = TokenResponse.parse(applyTimeouts(tr.toHTTPRequest()).send());
      if (!resp.indicatesSuccess()) {
        var err = resp.toErrorResponse().getErrorObject();
        throw new KeycloakAuthException("Token refresh failed: " + err.getDescription(),
            err.getCode(), null);
      }
      return toTokenSet(resp.toSuccessResponse().getTokens(), issuedAt);
    } catch (java.io.IOException e) {
      throw new KeycloakTransportException("Token refresh transport failure", e);
    } catch (com.nimbusds.oauth2.sdk.ParseException e) {
      throw new KeycloakAuthException("Token refresh request error", null, e);
    }
  }

  public void logout(String refreshToken) {
    try {
      HTTPResponse resp = applyTimeouts(buildLogoutRequest(refreshToken)).send();
      if (!resp.indicatesSuccess()) {
        throw new KeycloakAuthException("Logout failed (HTTP " + resp.getStatusCode() + ")", null, null);
      }
    } catch (java.io.IOException e) {
      throw new KeycloakTransportException("Logout transport failure", e);
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
      clientAuth("logout").applyTo(req);
      Map<String, List<String>> params = new LinkedHashMap<>();
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
      HTTPResponse resp = applyTimeouts(buildIntrospectionRequest(token)).send();
      TokenIntrospectionResponse tir = TokenIntrospectionResponse.parse(resp);
      if (!tir.indicatesSuccess()) {
        var err = tir.toErrorResponse().getErrorObject();
        throw new KeycloakAuthException("Introspection failed: " + err.getDescription(), err.getCode(), null);
      }
      return toIntrospectionResult(tir.toSuccessResponse());
    } catch (java.io.IOException e) {
      throw new KeycloakTransportException("Introspection transport failure", e);
    } catch (com.nimbusds.oauth2.sdk.ParseException e) {
      throw new KeycloakAuthException("Introspection request error", null, e);
    }
  }

  // introspect()의 send() 이전 요청 구성만 분리: send() 없이 HTTP method/endpoint/content-type/
  // Authorization 헤더/body를 빠른 단위 테스트로 검증하기 위한 패키지 가시성 헬퍼 (buildLogoutRequest와 동일 패턴).
  HTTPRequest buildIntrospectionRequest(String token) {
    if (token == null) {
      throw new IllegalArgumentException("token must not be null");
    }
    TokenIntrospectionRequest req = new TokenIntrospectionRequest(
        metadata.getIntrospectionEndpoint(), clientAuth("token introspection"), new TypelessAccessToken(token));
    return req.toHTTPRequest();
  }

  static IntrospectionResult toIntrospectionResult(TokenIntrospectionSuccessResponse s) {
    return new IntrospectionResult(s.isActive(),
        java.util.Optional.ofNullable(s.getUsername()),
        java.util.Optional.ofNullable(s.getClientID()).map(ClientID::getValue));
  }

  // 기밀 클라이언트(clientSecret 설정됨)를 요구하는 흐름(client-credentials/refresh/logout/introspect)의
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
