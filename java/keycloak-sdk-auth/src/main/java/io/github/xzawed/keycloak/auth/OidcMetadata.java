package io.github.xzawed.keycloak.auth;
import io.github.xzawed.keycloak.core.KeycloakConfig;
import java.net.URI;
public final class OidcMetadata {
  private final String issuer;
  private final URI authorizationEndpoint, tokenEndpoint, introspectionEndpoint, endSessionEndpoint, jwksUri;
  private OidcMetadata(String issuer, URI auth, URI token, URI introspect, URI endSession, URI jwks) {
    this.issuer = issuer; this.authorizationEndpoint = auth; this.tokenEndpoint = token;
    this.introspectionEndpoint = introspect; this.endSessionEndpoint = endSession; this.jwksUri = jwks;
  }
  public static OidcMetadata forRealm(KeycloakConfig c) {
    String base = c.getServerUrl().replaceAll("/+$", "") + "/realms/" + c.getRealm();
    String oc = base + "/protocol/openid-connect";
    return new OidcMetadata(base,
        URI.create(oc + "/auth"), URI.create(oc + "/token"),
        URI.create(oc + "/token/introspect"), URI.create(oc + "/logout"),
        URI.create(oc + "/certs"));
  }
  public String getIssuer() { return issuer; }
  public URI getAuthorizationEndpoint() { return authorizationEndpoint; }
  public URI getTokenEndpoint() { return tokenEndpoint; }
  public URI getIntrospectionEndpoint() { return introspectionEndpoint; }
  public URI getEndSessionEndpoint() { return endSessionEndpoint; }
  public URI getJwksUri() { return jwksUri; }
}
