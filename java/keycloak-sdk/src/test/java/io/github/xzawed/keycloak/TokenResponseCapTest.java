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
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicReference;
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
 *
 * <p>⚠️ <b>상한을 넘는 auth 레인의 청크 본문은 서버가 붙잡는다</b>({@link #send}) — 잰 할당이 SDK 가 정하는 몫이어야 해서다. 그
 * 레인의 운송(HttpURLConnection)은 닫을 때 소켓에 이미 와 있는 바이트를 한 번에 읽고({@code ChunkedInputStream.hurry()}) 청크
 * 하나마다 모은 배열을 새로 잡는다 — 할당이 그 양의 제곱으로 자라고, 그 양은 SDK 가 아니라 커널 수신 버퍼와 시점이 정한다(Linux
 * 루프백은 {@code tcp_rmem} 최대 6 MiB 까지 자란다). 실측(2026-10-05 · JDK 21 · Docker Linux): SDK 의 읽기는 매번 2,111,536
 * 바이트, 닫기는 6.5 MB–4.58 GB 였다(Windows 는 수신 버퍼가 작아 닫기가 0.77 MB 이하라 통과했다). 그래서 상한+{@value
 * #PACED_SLACK} 바이트까지만 곧바로 보내 닫기가 읽을 양을 고정하고, 클라이언트가 떠날 때까지 기다린다 — {@link #HOLD} 가
 * 지나도록 읽고 있는 클라이언트(상한 없는 읽기)에게는 나머지를 전속력으로 보내 그 할당을 잡는다. admin 레인(HttpCore 는 닫기가
 * 고정 버퍼로 비운다)과 Content-Length 본문(JDK 가 닫을 때 읽지 않고 끊는다)은 빠른 서버 그대로 — 현실적인 경우로 남긴다.
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
  /**
   * 붙잡는 응답이 상한 너머로 곧바로 보내는 바이트 — 클라이언트가 상한+1 번째 바이트를 기다리지 않게 하는 여유이자 닫기가 읽을
   * 양의 상한이다. 작게 둔다: 닫기의 할당이 16 KiB 면 53,488 · 64 KiB 면 619,600 · 256 KiB 면 8,782,288 바이트다(JDK 21 실측 —
   * 256 KiB 는 닫기만으로 한도를 넘는다).
   */
  private static final int PACED_SLACK = 16 * 1024;
  /** 붙잡는 시간 — 이만큼 지나도 연결이 살아 있으면 끝까지 읽는 클라이언트다(SDK 는 상한+1 바이트를 읽자마자 끊는다). */
  private static final Duration HOLD = Duration.ofSeconds(3);
  /** 붙잡는 동안 클라이언트가 떠났는지 보는 간격 — 떠난 클라이언트에게 쓰면 실패한다. */
  private static final long PROBE_MILLIS = 50;

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

  /**
   * 응답 하나 — {@code head} 뒤를 JSON 공백으로 채워 정확히 {@code size} 바이트(0 이면 {@code head} 그대로). {@code clientLeft} 가
   * 있으면 붙잡는 응답이고({@link #send}) 서버가 그 결말을 채운다 — 붙잡힌 동안 클라이언트가 떠났으면 true.
   */
  private record Reply(int status, String head, long size, boolean chunked, CompletableFuture<Boolean> clientLeft) {
    Reply(int status, String head, long size, boolean chunked) {
      this(status, head, size, chunked, null);
    }

    long length() {
      return size > 0 ? size : head.getBytes(StandardCharsets.UTF_8).length;
    }
  }

  private HttpServer server;
  private ExecutorService handlers;
  private final AtomicReference<Reply> tokenReply = new AtomicReference<>();
  private final AtomicReference<Reply> introspectReply = new AtomicReference<>();
  private final AtomicReference<Reply> logoutReply = new AtomicReference<>();
  private final AtomicInteger adminHits = new AtomicInteger();
  private volatile int adminBearerLength = -1;
  /** 마지막으로 준비한 응답이 붙잡는 응답이면 그 결말(아니면 null). */
  private final AtomicReference<CompletableFuture<Boolean>> clientLeft = new AtomicReference<>();

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
      send(ex, tokenReply.get());
    } else if (path.equals(OIDC + "/token/introspect")) {
      send(ex, introspectReply.get());
    } else if (path.equals(OIDC + "/logout")) {
      send(ex, logoutReply.get());
    } else {
      send(ex, new Reply(404, "{}", 0, false));
    }
  }

  /**
   * 본문을 64 KiB 씩 흘려 보낸다 — 32 MiB 를 메모리에 만들지 않는다. 클라이언트가 상한에서 끊으면 쓰기가 실패한다(기대한 결말).
   * 붙잡는 응답은 상한+{@value #PACED_SLACK} 바이트까지만 곧바로 보내고 클라이언트가 떠날 때까지 기다린다({@link #probeUntilGone}) —
   * {@link #HOLD} 가 지나도록 떠나지 않으면 끝까지 읽는 클라이언트이므로 나머지를 전속력으로 보낸다.
   */
  private static void send(HttpExchange ex, Reply r) throws IOException {
    byte[] head = r.head().getBytes(StandardCharsets.UTF_8);
    ex.getResponseHeaders().add("Content-Type", "application/json");
    ex.sendResponseHeaders(r.status(), r.chunked() ? 0 : r.length());
    byte[] spaces = new byte[64 * 1024];
    Arrays.fill(spaces, (byte) ' ');
    boolean stayed = false;
    try (OutputStream os = ex.getResponseBody()) {
      os.write(head);
      long left = r.length() - head.length;
      if (r.clientLeft() != null) {
        long quick = (long) CAP + PACED_SLACK - head.length;
        pad(os, spaces, quick);
        os.flush();
        left -= quick + probeUntilGone(os);
        stayed = true;
      }
      pad(os, spaces, left);
    } catch (IOException clientWentAway) {
      // 클라이언트가 상한에서 연결을 끊었다
    } catch (InterruptedException stopped) {
      Thread.currentThread().interrupt(); // 시험이 끝나 서버를 멈췄다
    } finally {
      if (r.clientLeft() != null) r.clientLeft().complete(!stayed);
      ex.close();
    }
  }

  private static void pad(OutputStream os, byte[] spaces, long n) throws IOException {
    for (long left = n; left > 0; ) {
      int k = (int) Math.min(left, spaces.length);
      os.write(spaces, 0, k);
      left -= k;
    }
  }

  /**
   * {@value #PROBE_MILLIS} ms 마다 공백 한 바이트(청크 하나)를 써 본다 — 떠난 클라이언트에게 쓰면 실패한다(그 {@link IOException} 을
   * 그대로 던진다). {@link #HOLD} 가 지나도록 살아 있으면 써 본 바이트 수를 돌려준다.
   */
  private static long probeUntilGone(OutputStream os) throws IOException, InterruptedException {
    long probes = 0;
    for (long end = System.nanoTime() + HOLD.toNanos(); System.nanoTime() < end; probes++) {
      Thread.sleep(PROBE_MILLIS);
      os.write(' ');
      os.flush();
    }
    return probes;
  }

  private KeycloakConfig config() {
    return KeycloakConfig.builder().serverUrl("http://127.0.0.1:" + server.getAddress().getPort())
        .realm(REALM).clientId("app").clientSecret("s3cr3t".toCharArray())
        .connectTimeout(Duration.ofSeconds(5)).readTimeout(Duration.ofSeconds(20)).build();
  }

  /** 레인의 엔드포인트가 낼 성공 응답 — 토큰 레인은 {@code token} 을 access_token 에, introspect 는 username 에 싣는다. */
  private void replyOk(Lane lane, String token, long size, boolean chunked) {
    CompletableFuture<Boolean> held = pacing(lane, size, chunked);
    switch (lane) {
      case INTROSPECT -> introspectReply.set(new Reply(200,
          "{\"active\":true,\"username\":\"" + token + "\",\"client_id\":\"app\"}", size, chunked, held));
      case LOGOUT -> logoutReply.set(new Reply(200, "{}", size, chunked, held));
      default -> tokenReply.set(new Reply(200, "{\"access_token\":\"" + token + "\",\"token_type\":\"Bearer\","
          + "\"expires_in\":300,\"refresh_token\":\"" + RT_CANARY + "\"}", size, chunked, held));
    }
    adminHits.set(0);
    adminBearerLength = -1;
  }

  /**
   * 붙잡을 응답이면 그 결말 자리(아니면 null)를 {@link #clientLeft} 에도 둔다 — 상한+{@value #PACED_SLACK} 바이트를 넘는 auth
   * 레인의 청크 본문만 붙잡는다(클래스 설명).
   */
  private CompletableFuture<Boolean> pacing(Lane lane, long size, boolean chunked) {
    CompletableFuture<Boolean> held = chunked && lane != Lane.ADMIN && size > CAP + PACED_SLACK ? new CompletableFuture<>() : null;
    clientLeft.set(held);
    return held;
  }

  /** 붙잡은 응답이었으면 클라이언트가 붙잡힌 동안 떠났어야 한다 — 끝까지 읽는 클라이언트는 나머지를 받았다. */
  private void expectLeftWhileHeld(Lane lane, String label, List<String> wrong) {
    CompletableFuture<Boolean> held = clientLeft.get();
    if (held == null) return;
    try {
      if (!held.get(HOLD.toMillis() + 10_000, TimeUnit.MILLISECONDS)) {
        wrong.add(lane + " " + label + ": 붙잡힌 " + HOLD.toSeconds() + " 초 동안 떠나지 않았다 — 본문을 끝까지 읽었다");
      }
    } catch (InterruptedException e) {
      Thread.currentThread().interrupt(); // 표시를 삼키지 않는다 — 시험은 아래 어긋남으로 실패한다
      wrong.add(lane + " " + label + ": 서버가 붙잡은 응답의 결말을 기다리다 인터럽트됐다 — " + e);
    } catch (ExecutionException | TimeoutException e) {
      wrong.add(lane + " " + label + ": 서버가 붙잡은 응답의 결말을 알리지 않았다 — " + e);
    }
  }

  /** 레인의 엔드포인트가 낼 OAuth 오류(400) — 본문을 {@code size} 바이트로 채운다. */
  private void replyError(Lane lane, long size, boolean chunked) {
    Reply r = new Reply(400, "{\"error\":\"invalid_grant\",\"error_description\":\"Zcap bad grant\"}", size, chunked,
        pacing(lane, size, chunked));
    switch (lane) {
      case INTROSPECT -> introspectReply.set(r);
      case LOGOUT -> logoutReply.set(r);
      default -> tokenReply.set(r);
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

  /**
   * (3) 16·32 MiB 본문은 실패하고, 호출 스레드의 할당은 상한 근처에서 멈춘다(수정 전 auth 레인은 약 235 MB). auth 레인의 32 MiB
   * 청크는 붙잡는 서버이고, 16 MiB Content-Length 와 admin 레인은 빠른 서버다(클래스 설명).
   */
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
      System.out.println("[TokenResponseCapTest] " + lane + " " + label + (clientLeft.get() != null ? " (held)" : "")
          + " → allocated " + m.allocated() + " bytes");
      expectOverCap(lane, label, m.thrown(), wrong);
      if (m.allocated() > ALLOCATION_BOUND) wrong.add(lane + " " + label + ": 할당 " + m.allocated() + " > " + ALLOCATION_BOUND);
      expectLeftWhileHeld(lane, label, wrong);
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
    System.out.println("[TokenResponseCapTest] " + lane + " 400 32 MiB chunked" + (clientLeft.get() != null ? " (held)" : "")
        + " → allocated " + m.allocated() + " bytes");
    if (!(m.thrown() instanceof KeycloakTransportException)) wrong.add(lane + " 400 32 MiB: 전송 실패여야 한다 — " + m.thrown());
    if (m.allocated() > ALLOCATION_BOUND) wrong.add(lane + " 400 32 MiB: 할당 " + m.allocated() + " > " + ALLOCATION_BOUND);
    if (adminHits.get() != 0) wrong.add(lane + " 400 32 MiB: admin 요청이 나갔다");
    expectLeftWhileHeld(lane, "400 32 MiB", wrong);
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
