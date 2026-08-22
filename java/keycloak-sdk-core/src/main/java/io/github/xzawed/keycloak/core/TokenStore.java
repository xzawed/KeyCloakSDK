package io.github.xzawed.keycloak.core;
import java.util.Optional;
/**
 * Pluggable token storage.
 *
 * <p><b>Not wired into any production path, and Java-only.</b> The only references are
 * {@link InMemoryTokenStore} and its test — no facade accepts one, and the other eight SDKs have
 * no equivalent seam. So this is <em>not</em> part of the cross-language security baseline in the
 * root {@code CLAUDE.md}; that line claimed it was until it was measured (PR #296).
 *
 * <p>Wiring it here alone would break the §4 isomorphism — the other eight would have to follow in
 * the same change.
 */
public interface TokenStore {
  void save(TokenSet tokens);
  Optional<TokenSet> load();
  void clear();
}
