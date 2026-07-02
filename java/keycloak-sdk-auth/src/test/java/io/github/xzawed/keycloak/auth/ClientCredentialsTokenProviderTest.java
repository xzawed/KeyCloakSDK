package io.github.xzawed.keycloak.auth;
import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;
import io.github.xzawed.keycloak.core.TokenSet;
import java.time.*;
import org.junit.jupiter.api.Test;

class ClientCredentialsTokenProviderTest {
  @Test void cachesTokenUntilExpiry() {
    AuthClient auth = mock(AuthClient.class);
    Instant future = Instant.parse("2026-07-02T01:00:00Z");
    when(auth.clientCredentialsToken())
        .thenReturn(new TokenSet("tok1", null, null, "Bearer", null, future));
    Clock clock = Clock.fixed(Instant.parse("2026-07-02T00:00:00Z"), ZoneOffset.UTC);
    ClientCredentialsTokenProvider p = new ClientCredentialsTokenProvider(auth, clock, Duration.ofSeconds(30));
    assertEquals("tok1", p.getAccessToken());
    assertEquals("tok1", p.getAccessToken());
    verify(auth, times(1)).clientCredentialsToken();   // 캐시 → 1회만
  }
  @Test void refetchesAfterExpiry() {
    AuthClient auth = mock(AuthClient.class);
    when(auth.clientCredentialsToken())
        .thenReturn(new TokenSet("tok1", null, null, "Bearer", null, Instant.parse("2026-07-02T00:00:10Z")))
        .thenReturn(new TokenSet("tok2", null, null, "Bearer", null, Instant.parse("2026-07-02T02:00:00Z")));
    Clock clock = Clock.fixed(Instant.parse("2026-07-02T00:00:00Z"), ZoneOffset.UTC);
    ClientCredentialsTokenProvider p = new ClientCredentialsTokenProvider(auth, clock, Duration.ofSeconds(30));
    assertEquals("tok1", p.getAccessToken());  // 만료 임박(10s < now+30s)이지만 최초 로드
    assertEquals("tok2", p.getAccessToken());  // 만료 판정 → 재요청
    verify(auth, times(2)).clientCredentialsToken();
  }
}
