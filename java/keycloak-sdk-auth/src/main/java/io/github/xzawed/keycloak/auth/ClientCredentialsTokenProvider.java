package io.github.xzawed.keycloak.auth;
import io.github.xzawed.keycloak.core.*;
import java.time.*;
public final class ClientCredentialsTokenProvider implements TokenProvider {
  private final AuthClient auth; private final Clock clock; private final Duration skew;
  private volatile TokenSet cached;
  private final Object lock = new Object();
  public ClientCredentialsTokenProvider(AuthClient auth, Clock clock, Duration skew) {
    this.auth = auth; this.clock = clock; this.skew = skew;
  }
  @Override public String getAccessToken() {
    TokenSet t = cached;
    if (t != null && !t.isExpired(clock, skew)) return t.getAccessToken();
    synchronized (lock) {                       // single-flight
      if (cached == null || cached.isExpired(clock, skew)) {
        cached = auth.clientCredentialsToken();
      }
      return cached.getAccessToken();
    }
  }
}
