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
  public AuthClient(KeycloakConfig config, OidcMetadata metadata) {
    this.config = config; this.metadata = metadata;
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
  // exchangeCode(...) 는 3.3 확장: TokenRequest(AuthorizationCodeGrant)를 applyTimeouts(tr.toHTTPRequest()).send() 후 toTokenSet 매핑.
  // 실제 HTTP 성공/실패 경로는 통합 테스트(6.2)에서 검증.

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
      HTTPResponse resp = applyTimeouts(req).send();
      if (!resp.indicatesSuccess()) {
        throw new KeycloakAuthException("Logout failed (HTTP " + resp.getStatusCode() + ")", null, null);
      }
    } catch (java.io.IOException e) {
      throw new KeycloakAuthException("Logout request error", null, e);
    }
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
