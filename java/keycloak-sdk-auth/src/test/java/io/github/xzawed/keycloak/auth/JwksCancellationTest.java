package io.github.xzawed.keycloak.auth;

import static org.junit.jupiter.api.Assertions.*;

import com.nimbusds.jose.JWSAlgorithm;
import com.nimbusds.jose.JWSHeader;
import com.nimbusds.jose.crypto.RSASSASigner;
import com.nimbusds.jose.jwk.JWKSet;
import com.nimbusds.jose.jwk.RSAKey;
import com.nimbusds.jose.jwk.gen.RSAKeyGenerator;
import com.nimbusds.jwt.JWTClaimsSet;
import com.nimbusds.jwt.SignedJWT;
import com.sun.net.httpserver.HttpServer;
import io.github.xzawed.keycloak.core.KeycloakConfig;
import io.github.xzawed.keycloak.core.exception.TokenValidationException;
import java.io.IOException;
import java.io.OutputStream;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.Date;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicReference;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledForJreRange;
import org.junit.jupiter.api.condition.JRE;

/**
 * 취소가 강제 재조회 창을 헛되이 쓰지 않는다(등록부 {@code jwks-forced-refetch-window-burned}).
 *
 * <p>Nimbus 의 {@code RateLimitedJWKSetSource} 는 강제 재조회(미해결 kid)를 하기로 정한 <b>뒤에</b> 창의 크레딧을 쓰고 그다음
 * 조회한다(되돌리지 않는다). 그 조회가 호출자의 인터럽트로 끊기면 크레딧은 썼는데 캐시는 안 찬다 — 창이 닫힐 때까지 회전한 진짜
 * 키(k2)의 토큰이 {@code RateLimitReachedException} 으로 거부된다. 플랫폼 스레드의 {@code HttpURLConnection} 읽기는 인터럽트를
 * 무시해 이 일이 없지만, <b>JDK 21 가상 스레드</b>에서는 인터럽트가 소켓 읽기를 끊는다(수정 전 실측: 「Closed by interrupt」 →
 * 다음 k2 검증 「RateLimitReachedException」, /certs 1→2).
 *
 * <p>계약: 창의 크레딧을 쓴 조회는 호출자의 취소와 무관하게 SDK 자신의 HTTP 타임아웃만큼만 묶여 끝까지 가고 그 결과가 캐시를 채운다.
 * Java 에서 그 조회의 결과는 Nimbus 가 조회한 호출자의 스택에서 캐시에 넣으므로, 인터럽트된 호출자는 조회가 끝날 때까지(타임아웃이
 * 묶는다) 기다렸다가 플랫폼 스레드의 오늘과 같은 결과 — 검증 결과와 그대로 남은 인터럽트 표시 — 로 돌아온다. 같은 조회를 기다리던
 * 다른 호출자는 그 취소로 실패하지 않는다. 실패한 조회(503)는 여전히 창을 쓴다(의도된 동작 — 대조군). ⚠️ 취소에서 크레딧을 되돌리는
 * 것으로 고치지 않는다 — 위조 kid 검증을 취소할 때마다 IdP 요청 하나가 된다(Python 실측 10 대 1). 아래 홍수 시험이 그것을 지킨다.
 *
 * <p>창은 240 초(캐시 TTL 300 초 아래)라 시험이 끝날 때까지 다시 열리지 않는다 — 실시간 경계에 기대는 판정이 없다.
 */
class JwksCancellationTest {
  private static final String CERTS = "/realms/r/protocol/openid-connect/certs";

  private RSAKey k1;
  private RSAKey k2;
  private HttpServer server;
  private java.util.concurrent.ExecutorService handlers;
  private final AtomicInteger certs = new AtomicInteger();
  private volatile JWKSet served;
  private volatile int fail503;
  /** 설정되면 /certs 응답이 이 래치가 열릴 때까지 멈춘다 — 요청이 닿으면 {@link #arrived} 를 연다. */
  private volatile CountDownLatch release;
  private volatile CountDownLatch arrived;

  @BeforeEach void start() throws Exception {
    k1 = new RSAKeyGenerator(2048).keyID("k1").generate();
    k2 = new RSAKeyGenerator(2048).keyID("k2").generate();
    served = new JWKSet(k1.toPublicJWK());
    server = HttpServer.create(new InetSocketAddress(InetAddress.getLoopbackAddress(), 0), 0);
    handlers = Executors.newCachedThreadPool();
    server.setExecutor(handlers);
    server.createContext(CERTS, ex -> {
      certs.incrementAndGet();
      CountDownLatch gate = release;
      if (gate != null) {
        arrived.countDown();
        try {
          gate.await(10, TimeUnit.SECONDS);
        } catch (InterruptedException e) {
          Thread.currentThread().interrupt();
        }
      }
      if (fail503 > 0) {
        fail503--;
        ex.sendResponseHeaders(503, -1);
        ex.close();
        return;
      }
      byte[] body = served.toString().getBytes(StandardCharsets.UTF_8);
      ex.getResponseHeaders().add("Content-Type", "application/json");
      ex.sendResponseHeaders(200, body.length);
      try (OutputStream os = ex.getResponseBody()) {
        os.write(body);
      } catch (IOException clientWentAway) {
        // 수정 전 가상 스레드는 여기서 끊는다
      }
    });
    server.start();
  }

  @AfterEach void stop() {
    if (release != null) release.countDown();
    server.stop(0);
    handlers.shutdownNow();
  }

  private AuthClient client() {
    KeycloakConfig cfg = KeycloakConfig.builder()
        .serverUrl("http://127.0.0.1:" + server.getAddress().getPort()).realm("r").clientId("app")
        .expectedAudience("app").jwksMinRefetch(Duration.ofSeconds(240)).readTimeout(Duration.ofSeconds(10)).build();
    return new AuthClient(cfg, OidcMetadata.forRealm(cfg));
  }

  private String token(RSAKey signer, String kid) throws Exception {
    String issuer = "http://127.0.0.1:" + server.getAddress().getPort() + "/realms/r";
    SignedJWT jwt = new SignedJWT(new JWSHeader.Builder(JWSAlgorithm.RS256).keyID(kid).build(),
        new JWTClaimsSet.Builder().issuer(issuer).subject("u-" + kid).audience("app")
            .expirationTime(new Date(System.currentTimeMillis() + 300_000)).build());
    jwt.sign(new RSASSASigner(signer));
    return jwt.serialize();
  }

  /** 한 검증의 결과 — 주체(거부면 null), 거부 원인, 돌아온 뒤의 인터럽트 표시. */
  private record Outcome(String subject, Throwable refusal, boolean interruptedAfter) {
    String describe() {
      return subject != null ? "ACCEPTED " + subject : "REFUSED " + refusal + " / cause " + refusal.getCause();
    }
  }

  private static Outcome validate(AuthClient auth, String token) {
    try {
      String sub = auth.validate(token).getSubject();
      return new Outcome(sub, null, Thread.interrupted());
    } catch (TokenValidationException e) {
      return new Outcome(null, e, Thread.interrupted());
    }
  }

  /** k1 으로 데우고(콜드 로드 — 창이 열린다) IdP 를 k2 로 돌린다. */
  private AuthClient warmedThenRotated() throws Exception {
    AuthClient auth = client();
    assertEquals("u-k1", validate(auth, token(k1, "k1")).subject(), "데우기");
    assertEquals(1, certs.get(), "데우기는 콜드 로드 한 번이다");
    served = new JWKSet(k2.toPublicJWK());
    return auth;
  }

  /** JDK 21 가상 스레드 — 이 모듈은 --release 17 로 컴파일하므로 리플렉션으로 만든다. */
  private static Thread startVirtual(Runnable task) throws ReflectiveOperationException {
    Object builder = Thread.class.getMethod("ofVirtual").invoke(null);
    Thread t = (Thread) Class.forName("java.lang.Thread$Builder").getMethod("start", Runnable.class).invoke(builder, task);
    assertTrue((Boolean) Thread.class.getMethod("isVirtual").invoke(t), "가상 스레드가 아니다");
    return t;
  }

  private static Thread startPlatform(Runnable task) {
    Thread t = new Thread(task, "jwks-cancellation-caller");
    t.start();
    return t;
  }

  private interface Starter {
    Thread start(Runnable task) throws ReflectiveOperationException;
  }

  /** 검증 #1 — 호출 전에 이미 인터럽트된 스레드에서. 그다음 #2(취소 없음)가 창 안에서 k2 를 받아야 한다. */
  private void cancelledBeforeTheFetch(Starter starter) throws Exception {
    AuthClient auth = warmedThenRotated();
    String k2Token = token(k2, "k2");
    AtomicReference<Outcome> first = new AtomicReference<>();
    Thread caller = starter.start(() -> {
      Thread.currentThread().interrupt();
      first.set(validate(auth, k2Token));
    });
    caller.join(15_000);
    assertFalse(caller.isAlive(), "취소된 호출자가 SDK 의 타임아웃 안에 돌아오지 않았다");
    Outcome second = validate(auth, k2Token);
    String row = "#1 " + first.get().describe() + " · #2 " + second.describe() + " · /certs " + certs.get();
    System.out.println("[JwksCancellationTest 호출 전 취소] " + row);
    assertEquals("u-k2", second.subject(), "창 안의 다음 k2 검증이 받아들여져야 한다 — " + row);
    assertEquals(2, certs.get(), "창의 강제 재조회는 정확히 한 번이다 — " + row);
    assertEquals("u-k2", first.get().subject(), "취소된 호출자도 끝난 조회로 검증을 마친다 — " + row);
    assertTrue(first.get().interruptedAfter(), "취소된 호출자의 인터럽트 표시는 남아 있어야 한다 — " + row);
  }

  /** 검증 #1 — 조회가 IdP 에 닿은 뒤(응답 전) 인터럽트. 그다음 #2 가 창 안에서 k2 를 받아야 한다. */
  private void cancelledMidFlight(Starter starter) throws Exception {
    AuthClient auth = warmedThenRotated();
    String k2Token = token(k2, "k2");
    arrived = new CountDownLatch(1);
    release = new CountDownLatch(1);
    AtomicReference<Outcome> first = new AtomicReference<>();
    Thread caller = starter.start(() -> first.set(validate(auth, k2Token)));
    assertTrue(arrived.await(10, TimeUnit.SECONDS), "강제 재조회가 IdP 에 닿지 않았다");
    caller.interrupt();
    Thread.sleep(200); // 인터럽트가 닿을 시간 — 수정 전 가상 스레드는 여기서 소켓이 닫힌다
    release.countDown();
    caller.join(15_000);
    assertFalse(caller.isAlive(), "취소된 호출자가 SDK 의 타임아웃 안에 돌아오지 않았다");
    release = null;
    Outcome second = validate(auth, k2Token);
    String row = "#1 " + first.get().describe() + " · #2 " + second.describe() + " · /certs " + certs.get();
    System.out.println("[JwksCancellationTest 조회 중 취소] " + row);
    assertEquals("u-k2", second.subject(), "창 안의 다음 k2 검증이 받아들여져야 한다 — " + row);
    assertEquals(2, certs.get(), "창의 강제 재조회는 정확히 한 번이다 — " + row);
    assertEquals("u-k2", first.get().subject(), "취소된 호출자도 끝난 조회로 검증을 마친다 — " + row);
    assertTrue(first.get().interruptedAfter(), "취소된 호출자의 인터럽트 표시는 남아 있어야 한다 — " + row);
  }

  @Test @EnabledForJreRange(min = JRE.JAVA_21)
  void virtualThreadCancelledBeforeTheFetch_doesNotBurnTheWindow() throws Exception {
    cancelledBeforeTheFetch(JwksCancellationTest::startVirtual);
  }

  @Test @EnabledForJreRange(min = JRE.JAVA_21)
  void virtualThreadCancelledMidFlight_doesNotBurnTheWindow() throws Exception {
    cancelledMidFlight(JwksCancellationTest::startVirtual);
  }

  /** 플랫폼 스레드(JDK 17 하한에서 유일한 경우) — 오늘도 인터럽트가 조회를 끊지 못한다. 그 결과가 그대로여야 한다. */
  @Test void platformThreadCancelledBeforeTheFetch_doesNotBurnTheWindow() throws Exception {
    cancelledBeforeTheFetch(JwksCancellationTest::startPlatform);
  }

  @Test void platformThreadCancelledMidFlight_doesNotBurnTheWindow() throws Exception {
    cancelledMidFlight(JwksCancellationTest::startPlatform);
  }

  /**
   * 같은 조회를 기다리던 다른 호출자는 한 호출자의 취소로 실패하지 않는다 — T1(가상)이 조회하는 동안 T2 가 같은 k2 를 검증하러 와
   * Nimbus 의 갱신 잠금을 기다린다. T1 을 인터럽트해도 둘 다 받아들여지고 /certs 는 한 번만 는다(수정 전: T1 이 끊기면 T2 는 잠금을
   * 얻고 스스로 조회하려다 창에 막혀 거부됐다).
   */
  @Test @EnabledForJreRange(min = JRE.JAVA_21)
  void anotherCallerWaitingOnTheSameFetch_isNotFailedByOneCancellation() throws Exception {
    AuthClient auth = warmedThenRotated();
    String k2Token = token(k2, "k2");
    arrived = new CountDownLatch(1);
    release = new CountDownLatch(1);
    AtomicReference<Outcome> first = new AtomicReference<>();
    AtomicReference<Outcome> waiter = new AtomicReference<>();
    Thread t1 = startVirtual(() -> first.set(validate(auth, k2Token)));
    assertTrue(arrived.await(10, TimeUnit.SECONDS), "강제 재조회가 IdP 에 닿지 않았다");
    Thread t2 = startPlatform(() -> waiter.set(validate(auth, k2Token)));
    Thread.sleep(200); // T2 가 갱신 잠금에 닿을 시간
    t1.interrupt();
    Thread.sleep(200);
    release.countDown();
    t1.join(15_000);
    t2.join(15_000);
    String row = "T1 " + first.get().describe() + " · T2 " + waiter.get().describe() + " · /certs " + certs.get();
    System.out.println("[JwksCancellationTest 같은 조회의 대기자] " + row);
    assertEquals("u-k2", waiter.get().subject(), "기다리던 호출자가 실패했다 — " + row);
    assertEquals("u-k2", first.get().subject(), "취소된 호출자도 끝난 조회로 검증을 마친다 — " + row);
    assertEquals(2, certs.get(), "조회는 한 번이다 — " + row);
  }

  /**
   * 대조군 — 실패한 강제 재조회(503)는 여전히 창을 쓴다(의도된 동작): 같은 창의 다음 k2 검증은 IdP 에 가지 않고 거부된다. 이것이
   * 없으면 위 시험은 창이 살아 있지 않아도(재조회 제한이 꺼져도) 통과한다.
   */
  @Test void aFailedForcedFetch_stillUsesTheWindow() throws Exception {
    AuthClient auth = warmedThenRotated();
    String k2Token = token(k2, "k2");
    fail503 = 1;
    Outcome first = validate(auth, k2Token);
    Outcome second = validate(auth, k2Token);
    String row = "#1 " + first.describe() + " · #2 " + second.describe() + " · /certs " + certs.get();
    System.out.println("[JwksCancellationTest 503] " + row);
    assertNull(first.subject(), row);
    assertNull(second.subject(), "실패한 조회 뒤 같은 창의 k2 는 거부돼야 한다 — " + row);
    assertEquals("com.nimbusds.jose.jwk.source.RateLimitReachedException", second.refusal().getCause().getClass().getName(), row);
    assertEquals(2, certs.get(), "#2 는 IdP 에 가지 않는다 — " + row);
  }

  /** 조회가 던진 것은 그 타입 그대로 올라간다 — IOException 은 돌려주고(호출부가 던진다) 비검사 예외·Error 는 그대로 던진다. */
  @Test void aFetchFailure_isRethrownAsIs() {
    IOException io = new IOException("fetch failed");
    assertSame(io, NoRedirectResourceRetriever.rethrow(io));
    IllegalStateException unchecked = new IllegalStateException("unchecked");
    assertSame(unchecked, assertThrows(IllegalStateException.class, () -> NoRedirectResourceRetriever.rethrow(unchecked)));
    AssertionError error = new AssertionError("error");
    assertSame(error, assertThrows(AssertionError.class, () -> NoRedirectResourceRetriever.rethrow(error)));
  }

  /**
   * 취소에서 크레딧을 되돌리지 않는다 — 취소된 위조 kid 검증 열 번이 IdP 요청을 창의 상한(2 — 콜드 로드 + 강제 한 번) 넘게 만들지
   * 않는다. 되돌리기로 고치면 취소마다 한 번씩 IdP 에 간다(Python 실측 10 대 1).
   */
  @Test @EnabledForJreRange(min = JRE.JAVA_21)
  void cancelledForgedKidFlood_staysWithinTheWindow() throws Exception {
    AuthClient auth = warmedThenRotated();
    served = new JWKSet(k1.toPublicJWK());
    for (int i = 0; i < 10; i++) {
      String forged = token(k1, "forged-" + i);
      Thread t = startVirtual(() -> {
        Thread.currentThread().interrupt();
        validate(auth, forged);
      });
      t.join(15_000);
    }
    System.out.println("[JwksCancellationTest 취소된 위조 kid 10] /certs " + certs.get());
    assertTrue(certs.get() <= 2, "취소된 위조 kid 검증이 창 상한을 넘어 IdP 에 갔다 — /certs " + certs.get());
  }
}
