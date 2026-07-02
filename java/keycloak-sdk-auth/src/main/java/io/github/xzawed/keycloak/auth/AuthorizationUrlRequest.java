package io.github.xzawed.keycloak.auth;
import java.net.URI;
public final class AuthorizationUrlRequest {
  private final URI authorizationUrl; private final String codeVerifier, state, nonce;
  AuthorizationUrlRequest(URI url, String verifier, String state, String nonce) {
    this.authorizationUrl = url; this.codeVerifier = verifier; this.state = state; this.nonce = nonce;
  }
  public URI getAuthorizationUrl() { return authorizationUrl; }
  public String getCodeVerifier() { return codeVerifier; }
  public String getState() { return state; }
  public String getNonce() { return nonce; }
}
