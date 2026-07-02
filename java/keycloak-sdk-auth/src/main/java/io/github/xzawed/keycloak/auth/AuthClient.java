package io.github.xzawed.keycloak.auth;
import com.nimbusds.oauth2.sdk.*;
import com.nimbusds.oauth2.sdk.auth.*;
import com.nimbusds.oauth2.sdk.http.HTTPRequest;
import com.nimbusds.oauth2.sdk.id.*;
import com.nimbusds.oauth2.sdk.pkce.CodeChallengeMethod;
import com.nimbusds.oauth2.sdk.token.Tokens;
import com.nimbusds.openid.connect.sdk.*;
import io.github.xzawed.keycloak.core.*;
import io.github.xzawed.keycloak.core.exception.KeycloakAuthException;
import java.net.URI;
import java.time.Instant;

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
      ClientAuthentication auth = new ClientSecretBasic(
          new ClientID(config.getClientId()),
          new Secret(new String(config.getClientSecret())));
      TokenRequest tr = new TokenRequest.Builder(metadata.getTokenEndpoint(), auth,
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
  static TokenSet toTokenSet(Tokens tokens, long issuedAtEpoch) {
    var at = tokens.getAccessToken();
    Instant exp = Instant.ofEpochSecond(issuedAtEpoch + at.getLifetime());
    String refresh = tokens.getRefreshToken() == null ? null : tokens.getRefreshToken().getValue();
    return new TokenSet(
        at.getValue(), refresh, null, "Bearer",
        at.getScope() == null ? null : at.getScope().toString(), exp);
  }
}
