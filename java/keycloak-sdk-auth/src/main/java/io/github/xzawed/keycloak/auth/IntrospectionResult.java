package io.github.xzawed.keycloak.auth;
import java.util.Optional;

/** RFC 7662 토큰 introspection 응답의 SDK 표현 (WBS 3.7). */
public final class IntrospectionResult {
  private final boolean active;
  private final Optional<String> username;
  private final Optional<String> clientId;

  IntrospectionResult(boolean active, Optional<String> username, Optional<String> clientId) {
    this.active = active; this.username = username; this.clientId = clientId;
  }
  public boolean isActive() { return active; }
  public Optional<String> getUsername() { return username; }
  public Optional<String> getClientId() { return clientId; }
}
