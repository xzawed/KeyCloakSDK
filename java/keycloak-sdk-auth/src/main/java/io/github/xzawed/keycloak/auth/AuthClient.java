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
    this.config = config; this.metadata = metadata;
  }

  // JWKS 기반 서명·issuer·audience·만료 검증. 실패 시 TokenValidationException.
  // 반환 타입은 SDK 소유의 ValidatedToken (I.1) — Nimbus 타입을 공개 API에 노출하지 않는다.
  public ValidatedToken validate(String accessToken) {
    JwtValidator v = jwtValidator;
    if (v == null) {
      synchronized (this) {
        v = jwtValidator;
        if (v == null) {
          v = JwtValidator.forRealm(metadata, config,
              java.util.Set.of(com.nimbusds.jose.JWSAlgorithm.RS256), config.getClientId());
          jwtValidator = v;
        }
      }
    }
    return v.validate(accessToken);
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
    try {
      long issuedAt = Instant.now().getEpochSecond();
      TokenResponse resp = TokenResponse.parse(
          applyTimeouts(buildExchangeCodeRequest(code, redirectUri, codeVerifier)).send());
      if (!resp.indicatesSuccess()) {
        var err = resp.toErrorResponse().getErrorObject();
        throw new KeycloakAuthException("Authorization code exchange failed: " + err.getDescription(),
            err.getCode(), null);
      }
      return toTokenSet(resp.toSuccessResponse().getTokens(), issuedAt);
    } catch (java.io.IOException | com.nimbusds.oauth2.sdk.ParseException e) {
      throw new KeycloakAuthException("Authorization code exchange request error", null, e);
    }
  }

  // exchangeCode()의 send() 이전 요청 구성만 분리: send() 없이 grant_type/code/code_verifier/
  // 엔드포인트를 빠른 단위 테스트로 검증하기 위한 패키지 가시성 헬퍼 (buildLogoutRequest와 동일 패턴).
  HTTPRequest buildExchangeCodeRequest(String code, URI redirectUri, String codeVerifier) {
    AuthorizationCodeGrant grant = new AuthorizationCodeGrant(
        new AuthorizationCode(code), redirectUri,
        new com.nimbusds.oauth2.sdk.pkce.CodeVerifier(codeVerifier));
    TokenRequest tr = config.getClientSecret() != null
        ? new TokenRequest.Builder(metadata.getTokenEndpoint(), clientAuth(), grant).build()
        : new TokenRequest.Builder(metadata.getTokenEndpoint(), new ClientID(config.getClientId()), grant).build();
    return tr.toHTTPRequest();
  }

  public TokenSet clientCredentialsToken() {
    try {
      TokenRequest tr = new TokenRequest.Builder(metadata.getTokenEndpoint(), clientAuth(),
          new ClientCredentialsGrant())
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
    } catch (java.io.IOException | com.nimbusds.oauth2.sdk.ParseException e) {
      throw new KeycloakAuthException("Client credentials request error", null, e);
    }
  }

  public TokenSet refresh(String refreshToken) {
    if (refreshToken == null) {
      throw new IllegalArgumentException("refreshToken must not be null");
    }
    try {
      TokenRequest tr = new TokenRequest.Builder(metadata.getTokenEndpoint(), clientAuth(),
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
    } catch (java.io.IOException | com.nimbusds.oauth2.sdk.ParseException e) {
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
      throw new KeycloakAuthException("Logout request error", null, e);
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
      clientAuth().applyTo(req);
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
    } catch (java.io.IOException | com.nimbusds.oauth2.sdk.ParseException e) {
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
        metadata.getIntrospectionEndpoint(), clientAuth(), new TypelessAccessToken(token));
    return req.toHTTPRequest();
  }

  static IntrospectionResult toIntrospectionResult(TokenIntrospectionSuccessResponse s) {
    return new IntrospectionResult(s.isActive(),
        java.util.Optional.ofNullable(s.getUsername()),
        java.util.Optional.ofNullable(s.getClientID()).map(ClientID::getValue));
  }

  private ClientAuthentication clientAuth() {
    return new ClientSecretBasic(
        new ClientID(config.getClientId()),
        new Secret(new String(config.getClientSecret())));
  }

  static TokenSet toTokenSet(Tokens tokens, long issuedAtEpoch) {
    var at = tokens.getAccessToken();
    Instant exp = Instant.ofEpochSecond(issuedAtEpoch + at.getLifetime());
    String refresh = tokens.getRefreshToken() == null ? null : tokens.getRefreshToken().getValue();
    return new TokenSet(
        at.getValue(), refresh, null, "Bearer",
        at.getScope() == null ? null : at.getScope().toString(), exp);
  }
}
