package io.github.xzawed.keycloak;

import static org.junit.jupiter.api.Assertions.*;

import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;
import io.github.xzawed.keycloak.core.KeycloakConfig;
import io.github.xzawed.keycloak.core.exception.KeycloakAuthException;
import io.github.xzawed.keycloak.core.exception.KeycloakTransportException;
import java.io.IOException;
import java.io.OutputStream;
import java.io.PrintWriter;
import java.io.StringWriter;
import java.lang.management.ManagementFactory;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.atomic.AtomicInteger;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Assumptions;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.EnumSource;

/**
 * 토큰 응답 크기 상한 — 이 SDK 가 토큰 엔드포인트(client_credentials·refresh_token·authorization_code 그랜트 — auth 레인과 admin
 * 레인의 자기 토큰 부여)·introspection·logout 에서 읽는 응답 본문은 <b>정확히 1,048,576 바이트</b>까지만 읽는다. 공개 API 만 쓴다.
 *
 * <p>계약: (1) 상한 이하의 본문은 지금과 똑같이 동작한다. (2) 상한+1 바이트 이상이면 그 레인의 {@link KeycloakTransportException}
 * 으로 실패하고(하위 예외도, 프로세스를 죽이는 오류도 아니다) 메시지는 무엇이 상한을 넘었는지 말한다 — admin 레인은 admin 요청을
 * 하나도 보내지 않는다. (3) 할당은 읽은 바이트를 따라간다 — 16·32 MiB 본문도 상한 근처에서 멈춘다. 오류 상태(400)의 본문도 같다.
 *
 * <p>수정 전 실측(가짜 IdP · 32 MiB 공백 패딩): auth 다섯 레인(client_credentials·refresh·코드 교환·introspect·logout)이 전부
 * 받아들였고 호출 하나가 약 235 MB 를 할당했다(Nimbus {@code HTTPRequest.send()} 의 readLine 고리). admin 레인은 2xx 는 이미
 * 상한이 있었지만({@code TokenResponseGuard}) 400 오류 본문은 RESTEasy 가 통째로 버퍼에 담아 약 107 MB 를 할당했다.
 *
 * <p>⚠️ 상한은 SDK 상수를 빌리지 않고 리터럴로 고정한다 — 상수를 빌리면 그 값이 바뀌어도 이 시험이 따라 움직여 아무것도 지키지
 * 않는다(교차언어 가드가 같은 값을 읽는다).
 */
class TokenResponseCapTest {
  private static final int CAP = 1_048_576;
  /** Keycloak 26.6 기본 설정(start-dev)이 받아들이는 가장 긴 Bearer — 실측 2026-10-03, 한 바이트 더 길면 HTTP 431. */
  private static final int KEYCLOAK_MAX_BEARER = 65_459;
  /** 거부 오류의 어느 표현에도 찍히면 안 된다(응답 인용 검사). */
  private static final String RT_CANARY = "ZcapRT-0123456789abcdef";
  private static final String REALM = "r";
  private static final String OIDC = "/realms/" + REALM + "/protocol/openid-connect";
  private static final URI CB = URI.create("https://app.example/cb");
  private static final String VERIFIER = "ZcapVERIFIER-0123456789abcdefghijklmnopqrstuvwxyz";
  /** 16·32 MiB 본문을 거부하는 호출 하나가 호출 스레드에서 할당해도 되는 상한 — 상한의 네 배. */
  private static final long ALLOCATION_BOUND = 4L * CAP;

  /** 레인과 그 레인이 상한을 넘었을 때의 메시지. */
  enum Lane {
    CLIENT_CREDENTIALS("Client credentials failed: token response exceeds 1048576 bytes"),
    REFRESH("Token refresh failed: token response exceeds 1048576 bytes"),
    CODE_EXCHANGE("Authorization code exchange failed: token response exceeds 1048576 bytes"),
    INTROSPECT("Introspection failed: introspection response exceeds 1048576 bytes"),
    LOGOUT("Logout failed: logout response exceeds 1048576 bytes"),
    ADMIN("admin transport failure");

    final String overCap;

    Lane(String overCap) {
      this.overCap = overCap;
    }
  }

  /** 응답 하나 — {@code head} 뒤를 JSON 공백으로 채워 정확히 {@code size} 바이트(0 이면 {@code head} 그대로). */
  private record Reply(int status, String head, long size, boolean chunked) {
    long length() {
      return size > 0 ? size : head.getBytes(StandardCharsets.UTF_8).length;
    }
  }

  private HttpServer server;
  private ExecutorService handlers;
  private volatile Reply tokenReply;
  private volatile Reply introspectReply;
  private volatile Reply logoutReply;
  private final AtomicInteger adminHits = new AtomicInteger();
  private volatile int adminBearerLength = -1;

  @BeforeEach void start() throws IOException {
    server = HttpServer.create(new InetSocketAddress(InetAddress.getLoopbackAddress(), 0), 0);
    handlers = Executors.newCachedThreadPool();
    server.setExecutor(handlers);
    server.createContext("/", this::handle);
    server.start();
  }

  @AfterEach void stop() {
    server.stop(0);
    handlers.shutdownNow();
  }

  private void handle(HttpExchange ex) throws IOException {
    String path = ex.getRequestURI().getPath();
    ex.getRequestBody().readAllBytes();
    if (path.equals("/admin/realms")) {
      adminHits.incrementAndGet();
      String authorization = ex.getRequestHeaders().getFirst("Authorization");
      adminBearerLength = authorization == null ? -1 : authorization.length() - "Bearer ".length();
      send(ex, new Reply(200, "[]", 0, false));
    } else if (path.equals(OIDC + "/token")) {
      send(ex, tokenReply);
    } else if (path.equals(OIDC + "/token/introspect")) {
      send(ex, introspectReply);
    } else if (path.equals(OIDC + "/logout")) {
      send(ex, logoutReply);
    } else {
      send(ex, new Reply(404, "{}", 0, false));
    }
  }

  /** 본문을 64 KiB 씩 흘려 보낸다 — 32 MiB 를 메모리에 만들지 않는다. 클라이언트가 상한에서 끊으면 쓰기가 실패한다(기대한 결말). */
  private static void send(HttpExchange ex, Reply r) throws IOException {
    byte[] head = r.head().getBytes(StandardCharsets.UTF_8);
    ex.getResponseHeaders().add("Content-Type", "application/json");
    ex.sendResponseHeaders(r.status(), r.chunked() ? 0 : r.length());
    byte[] spaces = new byte[64 * 1024];
    Arrays.fill(spaces, (byte) ' ');
    try (OutputStream os = ex.getResponseBody()) {
      os.write(head);
      for (long left = r.length() - head.length; left > 0; ) {
        int n = (int) Math.min(left, spaces.length);
        os.write(spaces, 0, n);
        left -= n;
      }
    } catch (IOException clientWentAway) {
      // 클라이언트가 상한에서 연결을 끊었다
    } finally {
      ex.close();
    }
  }

  private KeycloakConfig config() {
    return KeycloakConfig.builder().serverUrl("http://127.0.0.1:" + server.getAddress().getPort())
        .realm(REALM).clientId("app").clientSecret("s3cr3t".toCharArray())
        .connectTimeout(Duration.ofSeconds(5)).readTimeout(Duration.ofSeconds(20)).build();
  }

  /** 레인의 엔드포인트가 낼 성공 응답 — 토큰 레인은 {@code token} 을 access_token 에, introspect 는 username 에 싣는다. */
  private void replyOk(Lane lane, String token, long size, boolean chunked) {
    switch (lane) {
      case INTROSPECT -> introspectReply = new Reply(200,
          "{\"active\":true,\"username\":\"" + token + "\",\"client_id\":\"app\"}", size, chunked);
      case LOGOUT -> logoutReply = new Reply(200, "{}", size, chunked);
      default -> tokenReply = new Reply(200, "{\"access_token\":\"" + token + "\",\"token_type\":\"Bearer\","
          + "\"expires_in\":300,\"refresh_token\":\"" + RT_CANARY + "\"}", size, chunked);
    }
    adminHits.set(0);
    adminBearerLength = -1;
  }

  /** 레인의 엔드포인트가 낼 OAuth 오류(400) — 본문을 {@code size} 바이트로 채운다. */
  private void replyError(Lane lane, long size, boolean chunked) {
    Reply r = new Reply(400, "{\"error\":\"invalid_grant\",\"error_description\":\"Zcap bad grant\"}", size, chunked);
    switch (lane) {
      case INTROSPECT -> introspectReply = r;
      case LOGOUT -> logoutReply = r;
      default -> tokenReply = r;
    }
    adminHits.set(0);
  }

  /** 새 클라이언트로 레인 하나를 부른다. */
  private String call(Lane lane) {
    try (KeycloakClient kc = KeycloakClient.create(config())) {
      return run(kc, lane);
    }
  }

  /** 공개 API 로 레인 하나를 부른다 — 돌려받은 토큰(introspect 는 username, logout·admin 은 요약). */
  private static String run(KeycloakClient kc, Lane lane) {
    return switch (lane) {
      case CLIENT_CREDENTIALS -> kc.auth().clientCredentialsToken().getAccessToken();
      case REFRESH -> kc.auth().refresh("rt-1").getAccessToken();
      case CODE_EXCHANGE -> kc.auth().exchangeCode("code-1", CB, VERIFIER).getAccessToken();
      case INTROSPECT -> kc.auth().introspect("tok-1").getUsername().orElse(null);
      case LOGOUT -> {
        kc.auth().logout("rt-1");
        yield "logged out";
      }
      case ADMIN -> "realms=" + kc.admin().realms().list().size();
    };
  }

  /** 잰 호출 하나의 결과 — 던진 것(없으면 null)과 호출 스레드가 그동안 할당한 바이트. */
  private record Measured(Throwable thrown, long allocated) {}

  /**
   * 레인 하나를 새 클라이언트로 부르며 호출 스레드의 할당을 잰다 — 클라이언트 조립(admin 은 RESTEasy 클라이언트까지)은 잰 구간
   * 밖이다. admin 토큰은 첫 admin 호출에서 받으므로 잰 구간 안에 든다.
   */
  private Measured measured(Lane lane) {
    com.sun.management.ThreadMXBean threads = allocationCounter();
    try (KeycloakClient kc = KeycloakClient.create(config())) {
      if (lane == Lane.ADMIN) kc.admin();
      long before = threads.getCurrentThreadAllocatedBytes();
      Throwable thrown = null;
      try {
        run(kc, lane);
      } catch (Throwable t) {
        thrown = t;
      }
      return new Measured(thrown, threads.getCurrentThreadAllocatedBytes() - before);
    }
  }

  private static Throwable outcome(Runnable r) {
    try {
      r.run();
      return null;
    } catch (Throwable t) {
      return t;
    }
  }

  /** 넘침 거부의 계약 — 레인의 메시지 · admin 요청 0 건 · 응답(refresh_token) 미인용. 어긋남은 {@code wrong} 에 쌓는다. */
  private void expectOverCap(Lane lane, String label, Throwable thrown, List<String> wrong) {
    if (!(thrown instanceof KeycloakTransportException) || !lane.overCap.equals(thrown.getMessage())) {
      wrong.add(lane + " " + label + ": KeycloakTransportException(" + lane.overCap + ") 가 아니다 — "
          + (thrown == null ? "성공(본문을 받아들였다)" : thrown.getClass().getName() + "(" + thrown.getMessage() + ")"));
    }
    if (adminHits.get() != 0) wrong.add(lane + " " + label + ": admin 요청이 나갔다 — " + adminHits.get());
    if (thrown != null) {
      StringWriter trace = new StringWriter();
      thrown.printStackTrace(new PrintWriter(trace, true));
      if (trace.toString().contains(RT_CANARY.substring(0, 10))) wrong.add(lane + " " + label + ": 오류가 응답을 인용했다");
    }
  }

  /** (1)(2) 상한 경계 — 정확히 상한이면 지금처럼 통과하고, 한 바이트 더면 실패한다. 청크·Content-Length 둘 다. */
  @ParameterizedTest
  @EnumSource(Lane.class)
  void aBodyOfExactlyTheCapPasses_andOneByteMoreFails(Lane lane) {
    List<String> wrong = new ArrayList<>();
    for (boolean chunked : new boolean[] {true, false}) {
      String framing = chunked ? "chunked" : "content-length";
      replyOk(lane, "AT-cap", CAP, chunked);
      try {
        String got = call(lane);
        String want = switch (lane) {
          case LOGOUT -> "logged out";
          case ADMIN -> "realms=0";
          default -> "AT-cap";
        };
        if (!want.equals(got)) wrong.add(lane + " " + framing + " = 상한: " + want + " 이 아니라 " + got);
        if (lane == Lane.ADMIN && adminHits.get() != 1) wrong.add(lane + " " + framing + " = 상한: admin 요청 " + adminHits);
      } catch (RuntimeException e) {
        wrong.add(lane + " " + framing + " = 상한: 통과해야 한다 — " + e);
      }
      replyOk(lane, "AT-cap", CAP + 1L, chunked);
      expectOverCap(lane, framing + " = 상한+1", outcome(() -> call(lane)), wrong);
    }
    assertTrue(wrong.isEmpty(), () -> wrong.size() + " 건:\n" + String.join("\n", wrong));
  }

  /** (6) 서버가 받아들이는 가장 긴 토큰(65,459 바이트)은 모든 레인에서 통과한다 — introspect 는 그 길이의 username 이다. */
  @ParameterizedTest
  @EnumSource(value = Lane.class, names = {"CLIENT_CREDENTIALS", "REFRESH", "CODE_EXCHANGE", "INTROSPECT", "ADMIN"})
  void theLargestBearerKeycloakAccepts_passesOnEveryLane(Lane lane) {
    String token = "a".repeat(KEYCLOAK_MAX_BEARER);
    replyOk(lane, token, 0, false);
    String got = call(lane);
    if (lane == Lane.ADMIN) {
      assertEquals("realms=0", got);
      assertEquals(KEYCLOAK_MAX_BEARER, adminBearerLength, "admin 요청이 그 Bearer 를 그대로 실어야 한다");
    } else {
      assertEquals(token, got);
    }
  }

  /** (3) 16·32 MiB 본문은 실패하고, 호출 스레드의 할당은 상한 근처에서 멈춘다(수정 전 auth 레인은 약 235 MB). */
  @ParameterizedTest
  @EnumSource(Lane.class)
  void aHugeBodyFailsWithBoundedAllocation(Lane lane) {
    List<String> wrong = new ArrayList<>();
    replyOk(lane, "AT-warm", 2048, false);
    call(lane); // 예열 — 클래스 적재·JIT 를 잰 구간 밖으로
    long[][] cases = {{32L << 20, 1}, {16L << 20, 0}};
    for (long[] c : cases) {
      boolean chunked = c[1] == 1;
      String label = (c[0] >> 20) + " MiB " + (chunked ? "chunked" : "content-length");
      replyOk(lane, "AT-huge", c[0], chunked);
      Measured m = measured(lane);
      System.out.println("[TokenResponseCapTest] " + lane + " " + label + " → allocated " + m.allocated() + " bytes");
      expectOverCap(lane, label, m.thrown(), wrong);
      if (m.allocated() > ALLOCATION_BOUND) wrong.add(lane + " " + label + ": 할당 " + m.allocated() + " > " + ALLOCATION_BOUND);
    }
    assertTrue(wrong.isEmpty(), () -> wrong.size() + " 건:\n" + String.join("\n", wrong));
  }

  /** (3) 2 KiB 본문의 판정은 상한 가까이 할당하지 않는다 — 상한만 한 버퍼를 미리 잡지 않는다(auth 레인 — 호출 전체를 잰다). */
  @ParameterizedTest
  @EnumSource(value = Lane.class, names = {"CLIENT_CREDENTIALS", "REFRESH", "CODE_EXCHANGE", "INTROSPECT", "LOGOUT"})
  void aSmallBodyAllocatesFarBelowTheCap(Lane lane) {
    replyOk(lane, "AT-small", 2048, false);
    call(lane);
    Measured m = measured(lane);
    System.out.println("[TokenResponseCapTest] " + lane + " 2 KiB → allocated " + m.allocated() + " bytes");
    assertNull(m.thrown(), () -> lane + ": 2 KiB 본문은 통과해야 한다 — " + m.thrown());
    assertTrue(m.allocated() < CAP / 4, lane + ": 2 KiB 본문의 호출이 " + m.allocated() + " 바이트를 할당했다");
  }

  /**
   * 오류 상태(400)의 본문도 같은 상한이다 — 상한이면 지금처럼 OAuth 오류로 실패하고(본문을 읽어 해석했다), 한 바이트 더면 전송
   * 실패다. admin 레인의 토큰 부여 400 은 RESTEasy 가 본문을 통째로 버퍼에 담았다(수정 전 32 MiB → 약 107 MB 할당) — 그 레인은
   * 상한 안팎이 같은 타입이라 할당으로 잰다(상한 안의 복구 경로는 {@code AdminTokenResponseTest} 가 잰다).
   */
  @ParameterizedTest
  @EnumSource(Lane.class)
  void anErrorBodyIsCappedToo(Lane lane) {
    List<String> wrong = new ArrayList<>();
    if (lane != Lane.ADMIN) {
      replyError(lane, CAP, true);
      Throwable atCap = outcome(() -> call(lane));
      if (atCap instanceof KeycloakAuthException e) {
        boolean parsed = lane == Lane.LOGOUT
            ? "Logout failed (HTTP 400)".equals(e.getMessage()) : "invalid_grant".equals(e.getError());
        if (!parsed) wrong.add(lane + " 400 = 상한: OAuth 오류를 해석하지 못했다 — " + e.getMessage() + " / " + e.getError());
      } else {
        wrong.add(lane + " 400 = 상한: KeycloakAuthException 이어야 한다 — " + atCap);
      }
      replyError(lane, CAP + 1L, true);
      expectOverCap(lane, "400 = 상한+1", outcome(() -> call(lane)), wrong);
    }
    replyOk(lane, "AT-warm", 2048, false);
    call(lane);
    replyError(lane, 32L << 20, true);
    Measured m = measured(lane);
    System.out.println("[TokenResponseCapTest] " + lane + " 400 32 MiB chunked → allocated " + m.allocated() + " bytes");
    if (!(m.thrown() instanceof KeycloakTransportException)) wrong.add(lane + " 400 32 MiB: 전송 실패여야 한다 — " + m.thrown());
    if (m.allocated() > ALLOCATION_BOUND) wrong.add(lane + " 400 32 MiB: 할당 " + m.allocated() + " > " + ALLOCATION_BOUND);
    if (adminHits.get() != 0) wrong.add(lane + " 400 32 MiB: admin 요청이 나갔다");
    assertTrue(wrong.isEmpty(), () -> wrong.size() + " 건:\n" + String.join("\n", wrong));
  }

  /** 호출 스레드의 할당 계수기 — HotSpot 이 아니면 할당 단언은 건너뛴다(계약의 나머지는 위 경계 시험이 진다). */
  private static com.sun.management.ThreadMXBean allocationCounter() {
    java.lang.management.ThreadMXBean bean = ManagementFactory.getThreadMXBean();
    Assumptions.assumeTrue(bean instanceof com.sun.management.ThreadMXBean t && t.isThreadAllocatedMemorySupported()
        && t.isThreadAllocatedMemoryEnabled(), "스레드 할당 계수기가 없는 JVM");
    return (com.sun.management.ThreadMXBean) bean;
  }
}
