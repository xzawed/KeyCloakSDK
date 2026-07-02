package io.github.xzawed.keycloak.core;
import java.util.Optional;
public final class InMemoryTokenStore implements TokenStore {
  private volatile TokenSet current;
  @Override public void save(TokenSet tokens) { this.current = tokens; }
  @Override public Optional<TokenSet> load() { return Optional.ofNullable(current); }
  @Override public void clear() { this.current = null; }
}
