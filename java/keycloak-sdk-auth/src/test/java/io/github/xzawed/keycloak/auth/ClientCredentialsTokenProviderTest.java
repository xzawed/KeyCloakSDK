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

  // ⚠️ **single-flight 의 "진 쪽"이 검증된 적이 없었다.** 락 안의 `cached == null ||
  // cached.isExpired(...)` 는 네 갈래인데, 위 두 테스트가 (a) 콜드 (b) 만료 후 재요청 (c) 캐시
  // 히트(락 밖 조기반환) 셋만 밟는다. 남은 하나 — **락을 기다리는 동안 다른 스레드가 이미
  // 채워 넣은 경우** — 는 단일 스레드로 도달할 수 없어 미검증이었다(실측: JaCoCo 해당 줄 mb=1).
  // 그 갈래가 뒤집히면 대기하던 스레드가 **방금 받아온 토큰을 버리고 다시 받아온다** — §4 의
  // 캐시/single-flight 불변식이 깨지고, 부하가 걸릴수록 IdP 요청이 증폭된다.
  // 결정적 재현: 첫 호출을 래치로 붙잡아 두 스레드를 락 앞에 줄 세운다.
  @Test void concurrentCallersShareOneFetch() throws Exception {
    AuthClient auth = mock(AuthClient.class);
    Instant future = Instant.parse("2026-07-02T01:00:00Z");
    java.util.concurrent.CountDownLatch bothQueued = new java.util.concurrent.CountDownLatch(1);
    java.util.concurrent.atomic.AtomicInteger calls = new java.util.concurrent.atomic.AtomicInteger();
    when(auth.clientCredentialsToken()).thenAnswer(inv -> {
      calls.incrementAndGet();
      // 두 번째 스레드가 락 앞에 붙을 때까지 붙잡아 둔다 — 붙지 않으면 이 갈래에 못 간다.
      assertTrue(bothQueued.await(5, java.util.concurrent.TimeUnit.SECONDS), "second caller never queued");
      return new TokenSet("tok1", null, null, "Bearer", null, future);
    });
    Clock clock = Clock.fixed(Instant.parse("2026-07-02T00:00:00Z"), ZoneOffset.UTC);
    ClientCredentialsTokenProvider p = new ClientCredentialsTokenProvider(auth, clock, Duration.ofSeconds(30));

    java.util.concurrent.ExecutorService pool = java.util.concurrent.Executors.newFixedThreadPool(2);
    try {
      java.util.concurrent.Future<String> first = pool.submit(p::getAccessToken);
      // 첫 스레드가 fetch 에 들어간 뒤에 둘째를 띄운다.
      while (calls.get() == 0) { Thread.sleep(1); }
      java.util.concurrent.Future<String> second = pool.submit(p::getAccessToken);
      Thread.sleep(50);          // 둘째가 락 앞에 붙을 시간
      bothQueued.countDown();

      assertEquals("tok1", first.get(5, java.util.concurrent.TimeUnit.SECONDS));
      assertEquals("tok1", second.get(5, java.util.concurrent.TimeUnit.SECONDS));
    } finally {
      pool.shutdownNow();
    }
    verify(auth, times(1)).clientCredentialsToken();   // 둘이 한 번의 fetch 를 나눠 쓴다
  }
}
