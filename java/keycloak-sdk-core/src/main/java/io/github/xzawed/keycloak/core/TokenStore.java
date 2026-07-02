package io.github.xzawed.keycloak.core;
import java.util.Optional;
public interface TokenStore {
  void save(TokenSet tokens);
  Optional<TokenSet> load();
  void clear();
}
