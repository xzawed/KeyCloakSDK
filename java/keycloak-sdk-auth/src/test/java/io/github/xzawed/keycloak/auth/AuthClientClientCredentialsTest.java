package io.github.xzawed.keycloak.auth;
import static org.junit.jupiter.api.Assertions.*;
import com.nimbusds.oauth2.sdk.token.*;
import java.time.Instant;
import org.junit.jupiter.api.Test;

class AuthClientClientCredentialsTest {
  @Test void mapsBearerTokensToTokenSet() {
    BearerAccessToken at = new BearerAccessToken("acc", 300, null); // expires_in=300
    Tokens tokens = new Tokens(at, null);
    io.github.xzawed.keycloak.core.TokenSet ts = AuthClient.toTokenSet(tokens, 1000L);
    assertEquals("acc", ts.getAccessToken());
    assertEquals(Instant.ofEpochSecond(1300), ts.getExpiresAt());
    assertEquals("Bearer", ts.getTokenType());
  }
}
