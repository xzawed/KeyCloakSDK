package io.github.xzawed.keycloak.admin;

import static org.junit.jupiter.api.Assertions.*;

import io.github.xzawed.keycloak.core.KeycloakConfig;
import io.github.xzawed.keycloak.core.ResponseLimits;
import io.github.xzawed.keycloak.core.exception.KeycloakAdminException;
import io.github.xzawed.keycloak.core.exception.KeycloakConflictException;
import io.github.xzawed.keycloak.core.exception.KeycloakNotFoundException;
import java.io.BufferedInputStream;
import java.io.ByteArrayOutputStream;
import java.io.FileInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.lang.management.ManagementFactory;
import java.net.InetAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.nio.file.Path;
import java.security.KeyStore;
import java.time.Duration;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.Optional;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicLong;
import java.util.concurrent.atomic.AtomicReference;
import java.util.concurrent.locks.LockSupport;
import java.util.function.Function;
import javax.net.ssl.KeyManagerFactory;
import javax.net.ssl.SSLContext;
import javax.net.ssl.SSLSocket;
import javax.net.ssl.TrustManagerFactory;
import org.junit.jupiter.api.Assumptions;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.Timeout;
import org.junit.jupiter.api.io.TempDir;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.EnumSource;
import org.keycloak.representations.idm.UserRepresentation;

/**
 * admin 자원 응답에서 SDK 가 읽지 않는 본문은 읽지 않는다 — 결과를 얻은 뒤 닫을 때 끝인지 한 번만 엿보고(소켓 기다림 1 ms), 끝이
 * 아니면 연결을 끊는다. 오류 본문은 상한({@link ResponseLimits#MAX_TOKEN_RESPONSE_BYTES})까지만 쥔다. 토큰 응답 갈래는
 * {@code AdminRejectedResponseCutTest} 가 맡는다.
 *
 * <p>수정 전(실측 2026-10-25, Windows · JDK 21.0.8 · 루프백 · main ee862c6): RESTEasy 는 결과를 얻은 응답을 닫고
 * ({@code ClientResponse.close} → {@code releaseConnection(true)}) HttpCore 의 닫기({@code ContentLengthInputStream}·
 * {@code ChunkedInputStream.close})가 나머지를 EOF 까지 비웠다 — 아래 2xx 다섯 자리 모두 서버가 64 MiB 를 끝까지 썼다. 미디어 타입이
 * 있는 오류 상태는 {@code ClientInvocation.extractResult} 의 {@code bufferEntity} 가 본문을 통째로 담아 64 MiB 오류 본문에 호출 하나가
 * 약 475 MB 를 할당했고 그 본문 전부가 예외의 {@code keycloakError} 에 실렸다. 결과 뒤 멈춘 서버 앞에서는 닫기가 읽기 타임아웃을
 * 기다린 끝에 <b>쓸 수 있던 응답이 전송 실패가 됐다</b>(평문 4,014 ms — 읽기 타임아웃 4 초 · TLS 1.3 은 닫기가 한 번 더 읽어 8,111 ms).
 *
 * <p>계약: (1) SDK 가 읽지 않는 2xx 본문(create 의 201 · update·delete 의 2xx — 미디어 타입 유무) — 서버는 상한과 소켓 버퍼를 넘어
 * 쓰지 못하고 호출은 그 결과를 돌려준다. (2) 오류 본문 — 상한까지만 쥐고(상태와 본문 머리는 그대로) 나머지는 읽지 않는다. (3) 결과 뒤
 * 멈춘 서버 — 평문과 TLS 1.3 모두 읽기 타임아웃을 기다리지 않고 결과를 돌려준다. 대조: EOF 까지 읽은 응답의 연결은 지금처럼 다시
 * 쓰이고, 엿보려고 낮춘 기다림은 다음 교환에 남지 않으며, 상한 안의 오류 본문은 통째로 실리고, 성공 본문에는 상한이 없다. 공개 API 와
 * 로컬 루프백만 쓴다(길이 0 의 읽기 한 건만 엔진의 스트림을 직접 잰다).
 *
 * <p>⚠️ 미디어 타입이 있는 JSON 성공 본문(get·search)은 이 계약 밖이다 — 결합(Jackson)이 값 뒤의 공백까지 EOF 로 읽는다
 * ({@code FAIL_ON_TRAILING_TOKENS} — 실측 스택 {@code ObjectReader._verifyNoTrailingTokens}). 그 공백은 JSON 텍스트이고 성공 본문에는
 * 상한을 걸지 않는다({@link ResponseLimits#MAX_TOKEN_RESPONSE_BYTES} 의 설명) — 그 본문 중간에 멈춘 서버는 읽기마다의 타임아웃
 * 몫이다(등록부 {@code response-read-deadline-divergent}).
 */
class AdminResourceResponseCutTest {
  private static final int CAP = ResponseLimits.MAX_TOKEN_RESPONSE_BYTES;
  private static final String REALM = "r";
  private static final String TOKEN_PATH = "/realms/" + REALM + "/protocol/openid-connect/token";
  private static final String LOGOUT_PATH = "/realms/" + REALM + "/protocol/openid-connect/logout";
  private static final byte[] TOKEN = utf8("{\"access_token\":\"good\",\"token_type\":\"Bearer\",\"expires_in\":300}");
  private static final String USER = "{\"id\":\"x\",\"username\":\"alice\"}";
  private static final String NOT_FOUND = "{\"error\":\"User not found\"}";
  private static final String TYPED = "Content-Type: application/json\r\n";
  private static final String LOCATION = "Location: http://127.0.0.1:1/admin/realms/" + REALM + "/users/abc\r\n";
  /** 쓰지 않는 나머지의 길이 — 수정 전에는 닫기가 이것을 끝까지 비웠다. */
  private static final long HUGE = 64L << 20;
  /** 끊긴 교환에서 서버가 써도 되는 본문 — 상한 + 소켓 버퍼(리눅스 tcp_rmem 6 MiB · tcp_wmem 4 MiB)를 넉넉히 넘는 16 MiB. */
  private static final long WRITTEN_BOUND = 16L << 20;
  /** 64 MiB 오류 본문 호출 하나의 할당 한도 — 근거(측정)는 {@link #anErrorBody_isHeldOnlyUpToTheCap}. */
  private static final long ERROR_ALLOCATION_BOUND = 64L << 20;
  /**
   * 400 + 32 MiB logout 본문을 받는 close() 하나의 할당 한도. 근거(2026-10-25 실측, Windows · JDK 21.0.8): 수정 전 100.7 MB(서버가 32 MiB 를
   * 끝까지 썼다 — kotlin #718 의 수정 전 101 MiB 와 같다), 수정 뒤 3.2 MB(서버 1.77 MB) — 16 MiB(16.8 MB)는 수정 뒤보다 5 배, 수정 전보다
   * 6 배 떨어진다.
   */
  private static final long LOGOUT_ALLOCATION_BOUND = 16L << 20;
  /** 멈춤 갈래 하나를 되풀이하는 횟수 — 근거는 {@link #aServerStalledAfterTheResult_isNotWaitedFor}. */
  private static final int STALL_REPEATS = 5;

  @TempDir static Path dir;
  /** 시험 키 저장소의 암호 — 실행마다 새로 만든다(저장소에 키도, 그 암호도 두지 않는다). */
  private static final String STOREPASS = java.util.UUID.randomUUID().toString();
  private static SSLContext serverTls;
  private static SSLContext clientTls;

  @BeforeAll static void keys() throws Exception {
    Path file = dir.resolve("ip.p12");
    Process p = new ProcessBuilder(Path.of(System.getProperty("java.home"), "bin", "keytool").toString(),
        "-genkeypair", "-alias", "ip", "-keyalg", "EC", "-groupname", "secp256r1", "-validity", "2", "-dname", "CN=127.0.0.1",
        "-ext", "SAN=ip:127.0.0.1", "-keystore", file.toString(), "-storetype", "PKCS12", "-storepass", STOREPASS,
        "-keypass", STOREPASS).redirectErrorStream(true).start();
    String out = new String(p.getInputStream().readAllBytes(), StandardCharsets.UTF_8);
    assertTrue(p.waitFor(60, TimeUnit.SECONDS) && p.exitValue() == 0, () -> "keytool 실패: " + out);
    KeyStore ks = KeyStore.getInstance("PKCS12");
    try (InputStream in = new FileInputStream(file.toFile())) {
      ks.load(in, STOREPASS.toCharArray());
    }
    KeyManagerFactory kmf = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm());
    kmf.init(ks, STOREPASS.toCharArray());
    serverTls = SSLContext.getInstance("TLSv1.3");
    serverTls.init(kmf.getKeyManagers(), null, null);
    KeyStore trust = KeyStore.getInstance("PKCS12");
    trust.load(null, null);
    trust.setCertificateEntry("ip", ks.getCertificate("ip"));
    TrustManagerFactory tmf = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm());
    tmf.init(trust);
    clientTls = SSLContext.getInstance("TLSv1.3");
    clientTls.init(null, tmf.getTrustManagers(), null);
  }

  private static byte[] utf8(String s) {
    return s.getBytes(StandardCharsets.UTF_8);
  }

  private static byte[] latin1(String s) {
    return s.getBytes(StandardCharsets.ISO_8859_1);
  }

  /** admin 자원 응답 하나 — 쓴 본문 바이트를 {@code written} 에 센다. 돌려주는 값은 연결을 이어 쓸지다. */
  @FunctionalInterface
  private interface Reply {
    boolean write(OutputStream out, AtomicLong written) throws IOException;
  }

  /** 공백 {@code count} 바이트를 64 KiB 씩 쓴다. */
  private static void spaces(OutputStream out, long count, AtomicLong written) throws IOException {
    byte[] slab = new byte[64 * 1024];
    Arrays.fill(slab, (byte) ' ');
    long left = count;
    while (left > 0) {
      int k = (int) Math.min(left, slab.length);
      out.write(slab, 0, k);
      written.addAndGet(k);
      left -= k;
    }
  }

  /** {@code head} 뒤를 공백으로 채운 {@code total} 바이트의 Content-Length 본문. */
  private static Reply padded(String status, String headers, String head, long total) {
    return (out, written) -> {
      out.write(latin1("HTTP/1.1 " + status + "\r\n" + headers + "Content-Length: " + total + "\r\n\r\n"));
      byte[] h = utf8(head);
      out.write(h);
      written.addAndGet(h.length);
      spaces(out, total - h.length, written);
      out.flush();
      return true;
    };
  }

  private static Reply exact(String status, String headers, String body) {
    return padded(status, headers, body, utf8(body).length);
  }

  /** 공백 {@code sent} 바이트만 보내고(알린 길이는 1 MiB) 20 초 동안 읽지도 쓰지도 않고 붙든다. */
  private static Reply stalled(String status, String headers, long sent) {
    return (out, written) -> {
      out.write(latin1("HTTP/1.1 " + status + "\r\n" + headers + "Content-Length: " + (1L << 20) + "\r\n\r\n"));
      spaces(out, sent, written);
      out.flush();
      LockSupport.parkNanos(TimeUnit.SECONDS.toNanos(20)); // 읽지 않고 붙든다(인터럽트면 일찍 깬다 — 시험이 끝난 뒤다)
      return false;
    };
  }

  /**
   * 원시 HTTP/1.1 서버(평문 또는 TLS) — 연결 하나에 요청 여럿(keep-alive). 토큰 엔드포인트는 쓸 수 있는 토큰을, admin 사용자 경로는
   * {@code admin}(「메서드 경로」 → 응답)이 고른 응답을 낸다. 받아들인 연결 수 · admin 요청 수 · 마지막 admin 응답이 쓴 본문 바이트를 센다.
   */
  private static final class RawServer implements AutoCloseable {
    final ServerSocket socket;
    final AtomicInteger connections = new AtomicInteger();
    final AtomicInteger adminHits = new AtomicInteger();
    final AtomicLong written = new AtomicLong();
    /** 마지막 admin 응답의 쓰기가 끝났다(성공·실패) — 시험 스레드가 기다린다. */
    final AtomicReference<CountDownLatch> replied = new AtomicReference<>(new CountDownLatch(1));
    final Function<String, Reply> admin;
    /** 토큰 엔드포인트의 본문 — logout 시험은 refresh_token 을 단다(TokenManager 는 그것이 있을 때만 logout 을 보낸다). */
    volatile byte[] token = TOKEN;
    /** logout 엔드포인트의 응답(없으면 404) · 받은 수 · 그 응답이 쓴 본문 바이트. */
    volatile Reply logout;
    final AtomicInteger logouts = new AtomicInteger();
    final AtomicLong logoutWritten = new AtomicLong();
    final AtomicReference<CountDownLatch> loggedOut = new AtomicReference<>(new CountDownLatch(1));

    RawServer(SSLContext tls, Function<String, Reply> admin) throws IOException {
      this.admin = admin;
      socket = tls == null ? new ServerSocket(0, 50, InetAddress.getLoopbackAddress())
          : tls.getServerSocketFactory().createServerSocket(0, 50, InetAddress.getLoopbackAddress());
      Thread t = new Thread(this::serve, "admin-resource-server");
      t.setDaemon(true);
      t.start();
    }

    RawServer(Reply reply) throws IOException {
      this(null, any -> reply);
    }

    int port() {
      return socket.getLocalPort();
    }

    /** 마지막 admin 응답의 쓰기가 끝날 때까지(최대 30 초) — 끝나지 않으면 거짓. */
    boolean awaitReply() throws InterruptedException {
      return replied.get().await(30, TimeUnit.SECONDS);
    }

    private void serve() {
      while (!socket.isClosed()) {
        Socket s;
        try {
          s = socket.accept();
        } catch (IOException closed) {
          return;
        }
        connections.incrementAndGet();
        Thread t = new Thread(() -> exchanges(s), "admin-resource-connection");
        t.setDaemon(true);
        t.start();
      }
    }

    private void exchanges(Socket s) {
      try (s) {
        s.setSoTimeout(20_000);
        if (s instanceof SSLSocket tls) tls.startHandshake();
        InputStream in = new BufferedInputStream(s.getInputStream());
        OutputStream out = s.getOutputStream();
        for (String request = request(in); request != null; request = request(in)) {
          if (!answer(request, out)) return;
        }
      } catch (IOException clientLeft) {
        // 클라이언트가 끊었다 — 끊기의 정상 결말이다
      }
    }

    private boolean answer(String request, OutputStream out) throws IOException {
      String path = request.substring(request.indexOf(' ') + 1);
      if (path.equals(TOKEN_PATH)) {
        byte[] body = token;
        out.write(latin1("HTTP/1.1 200 OK\r\n" + TYPED + "Content-Length: " + body.length + "\r\n\r\n"));
        out.write(body);
        out.flush();
        return true;
      }
      if (path.equals(LOGOUT_PATH) && logout != null) {
        logouts.incrementAndGet();
        CountDownLatch done = loggedOut.get();
        try {
          return logout.write(out, logoutWritten);
        } finally {
          done.countDown();
        }
      }
      if (path.startsWith("/admin/realms/" + REALM + "/users")) {
        adminHits.incrementAndGet();
        written.set(0);
        CountDownLatch done = replied.get();
        try {
          return admin.apply(request).write(out, written);
        } finally {
          done.countDown();
        }
      }
      out.write(latin1("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n"));
      out.flush();
      return true;
    }

    /** 요청 하나(머리와 Content-Length 본문)를 읽고 「메서드 경로」를 돌려준다 — 연결이 끝났으면 null. */
    private static String request(InputStream in) throws IOException {
      ByteArrayOutputStream head = new ByteArrayOutputStream();
      int last4 = 0;
      for (int b = in.read(); b != -1; b = in.read()) {
        head.write(b);
        last4 = (last4 << 8) | b;
        if (last4 == 0x0d0a0d0a) {
          String[] lines = head.toString(StandardCharsets.ISO_8859_1).split("\r\n");
          for (String line : lines) {
            if (line.regionMatches(true, 0, "Content-Length:", 0, 15)) in.readNBytes(Integer.parseInt(line.substring(15).trim()));
          }
          String[] first = lines[0].split(" ");
          return first[0] + " " + first[1];
        }
      }
      return null;
    }

    @Override public void close() throws IOException {
      socket.close();
    }
  }

  private static KeycloakConfig config(String scheme, int port, Duration readTimeout) {
    return KeycloakConfig.builder().serverUrl(scheme + "://127.0.0.1:" + port).realm(REALM).clientId("app")
        .clientSecret("s3cr3t".toCharArray()).connectTimeout(Duration.ofSeconds(5)).readTimeout(readTimeout).build();
  }

  private static AdminClient admin(RawServer server, Duration readTimeout) {
    return new AdminClient(config("http", server.port(), readTimeout));
  }

  /** TLS admin — 시험 인증서를 믿는 기본 SSLContext 로 엔진을 짓는다(RESTEasy 는 지을 때 그것을 읽는다). 끝에서 되돌린다. */
  private static AdminClient tlsAdmin(RawServer server, Duration readTimeout) throws Exception {
    SSLContext saved = SSLContext.getDefault();
    SSLContext.setDefault(clientTls);
    try {
      return new AdminClient(config("https", server.port(), readTimeout));
    } finally {
      SSLContext.setDefault(saved);
    }
  }

  /** admin 호출 하나 — 돌려준 값, 던진 것(없으면 null), 걸린 시간, 호출 스레드의 할당. */
  private record Outcome(Object result, Throwable thrown, long millis, long allocated) {
    String describe() {
      String what = thrown == null ? "returned " + result : thrown.getClass().getSimpleName() + "(" + thrown.getMessage() + ")";
      return what + " · " + millis + " ms · allocated " + allocated + " B";
    }
  }

  @FunctionalInterface
  private interface Call {
    Object run(AdminClient admin);
  }

  private static Outcome call(AdminClient admin, Call call) {
    java.lang.management.ThreadMXBean bean = ManagementFactory.getThreadMXBean();
    Assumptions.assumeTrue(bean instanceof com.sun.management.ThreadMXBean t && t.isThreadAllocatedMemorySupported()
        && t.isThreadAllocatedMemoryEnabled(), "스레드 할당 계수기가 없는 JVM");
    com.sun.management.ThreadMXBean threads = (com.sun.management.ThreadMXBean) bean;
    long before = threads.getCurrentThreadAllocatedBytes();
    long start = System.nanoTime();
    Object result = null;
    Throwable thrown = null;
    try {
      result = call.run(admin);
    } catch (Throwable t) {
      thrown = t;
    }
    long millis = (System.nanoTime() - start) / 1_000_000;
    return new Outcome(result, thrown, millis, threads.getCurrentThreadAllocatedBytes() - before);
  }

  private static UserRepresentation user() {
    UserRepresentation u = new UserRepresentation();
    u.setUsername("u");
    return u;
  }

  /** SDK 가 읽지 않는 2xx 본문의 자리 다섯 — 응답과 호출과 그 결과. */
  enum Site {
    CREATE_UNTYPED(padded("201 Created", LOCATION, "", HUGE), a -> a.users().create(user()), "abc"),
    CREATE_TYPED(padded("201 Created", LOCATION + TYPED, "{}", HUGE), a -> a.users().create(user()), "abc"),
    UPDATE_TYPED(padded("200 OK", TYPED, "{}", HUGE), a -> {
      a.users().update("x", user());
      return "void";
    }, "void"),
    DELETE_TYPED(padded("200 OK", TYPED, "{}", HUGE), a -> {
      a.users().delete("x");
      return "void";
    }, "void"),
    DELETE_UNTYPED(padded("200 OK", "", "", HUGE), a -> {
      a.users().delete("x");
      return "void";
    }, "void");

    final Reply reply;
    final Call call;
    final Object expected;

    Site(Reply reply, Call call, Object expected) {
      this.reply = reply;
      this.call = call;
      this.expected = expected;
    }
  }

  /** (1) SDK 가 읽지 않는 2xx 본문은 읽지 않는다 — 호출은 결과를 돌려주고 서버는 64 MiB 를 다 쓰지 못한다. 수정 전: 다섯 자리 모두 끝까지. */
  @ParameterizedTest
  @EnumSource(Site.class)
  @Timeout(value = 120, threadMode = Timeout.ThreadMode.SEPARATE_THREAD)
  void theRemainderOfAResourceResponse_isNotReadOn(Site site) throws Exception {
    try (RawServer server = new RawServer(site.reply)) {
      Outcome o;
      try (AdminClient admin = admin(server, Duration.ofSeconds(20))) {
        o = call(admin, site.call);
      }
      boolean finished = server.awaitReply();
      String row = site + " → " + o.describe() + " · server wrote " + server.written.get() + " B" + (finished ? "" : " (still writing)");
      System.out.println("[AdminResourceResponseCutTest] " + row);
      assertNull(o.thrown(), row);
      assertEquals(site.expected, o.result(), row);
      assertTrue(finished && server.written.get() <= WRITTEN_BOUND, () -> "쓰지 않는 나머지를 읽었다 — " + row + " (한도 " + WRITTEN_BOUND + ")");
    }
  }

  /**
   * (2) 오류 본문은 상한까지만 쥔다 — 상태의 갈래(404·409)와 본문 머리는 그대로, {@code keycloakError} 는 상한을 넘지 않고, 서버는 64 MiB 를
   * 다 쓰지 못하고, 호출의 할당은 {@link #ERROR_ALLOCATION_BOUND} 안이다. 미디어 타입이 없는 오류 상태는 RESTEasy 가 버퍼에 담지 않고
   * 닫는다(비우기 갈래). 한도의 근거(2026-10-25 실측, Windows · JDK 21.0.8): 미디어 타입이 있는 64 MiB 오류 본문의 호출 하나가 수정 전
   * 475.1 · 472.9 MB(서버 64 MiB 끝까지), 수정 뒤 12.7 · 10.4 MB(서버 1.77 MB) — 한도 64 MiB(67.1 MB)는 수정 뒤보다 5 배, 수정 전보다 7 배
   * 떨어진다.
   */
  @Test @Timeout(value = 180, threadMode = Timeout.ThreadMode.SEPARATE_THREAD)
  void anErrorBody_isHeldOnlyUpToTheCap() throws Exception {
    List<String> wrong = new ArrayList<>();
    record Case(String label, Reply reply, Call call, Class<? extends KeycloakAdminException> type, String head) {}
    List<Case> cases = List.of(
        new Case("get 404 typed", padded("404 Not Found", TYPED, NOT_FOUND, HUGE), a -> a.users().get("x"),
            KeycloakNotFoundException.class, NOT_FOUND),
        new Case("get 404 untyped", padded("404 Not Found", "", NOT_FOUND, HUGE), a -> a.users().get("x"),
            KeycloakNotFoundException.class, null),
        new Case("delete 404 typed", padded("404 Not Found", TYPED, NOT_FOUND, HUGE), a -> {
          a.users().delete("x");
          return "void";
        }, KeycloakNotFoundException.class, NOT_FOUND),
        new Case("create 409 typed", padded("409 Conflict", TYPED, "{\"errorMessage\":\"exists\"}", HUGE),
            a -> a.users().create(user()), KeycloakConflictException.class, null));
    for (Case c : cases) {
      try (RawServer server = new RawServer(c.reply())) {
        Outcome o;
        try (AdminClient admin = admin(server, Duration.ofSeconds(20))) {
          o = call(admin, c.call());
        }
        boolean finished = server.awaitReply();
        String error = o.thrown() instanceof KeycloakAdminException e ? e.getKeycloakError() : null;
        int errorLength = error == null ? 0 : error.length();
        String row = c.label() + " → " + o.describe() + " · keycloakError " + errorLength + " chars · server wrote "
            + server.written.get() + " B" + (finished ? "" : " (still writing)");
        System.out.println("[AdminResourceResponseCutTest] " + row);
        if (!c.type().isInstance(o.thrown())) wrong.add(c.label() + ": " + c.type().getSimpleName() + " 가 아니다 — " + row);
        if (c.head() != null && (error == null || !error.startsWith(c.head()))) wrong.add(c.label() + ": 본문 머리를 잃었다 — " + row);
        if (errorLength > CAP) wrong.add(c.label() + ": 상한을 넘는 본문을 쥐었다 — " + row);
        if (!finished || server.written.get() > WRITTEN_BOUND) wrong.add(c.label() + ": 오류 본문의 나머지를 읽었다 — " + row);
        if (o.allocated() > ERROR_ALLOCATION_BOUND) wrong.add(c.label() + ": 할당이 한도를 넘었다 — " + row);
      }
    }
    assertTrue(wrong.isEmpty(), () -> wrong.size() + " 건:\n" + String.join("\n", wrong));
  }

  /** 대조 — 성공 본문에는 상한을 걸지 않는다(정당하게 크다): 상한을 넘는 사용자 목록도 통째로 결합된다. */
  @Test @Timeout(value = 60, threadMode = Timeout.ThreadMode.SEPARATE_THREAD)
  void aSuccessBodyPastTheCap_isReadWhole() throws Exception {
    int users = CAP / USER.length() + 1_000;
    StringBuilder list = new StringBuilder(users * (USER.length() + 1) + 2).append('[');
    for (int i = 0; i < users; i++) list.append(i == 0 ? "" : ",").append(USER);
    String body = list.append(']').toString();
    try (RawServer server = new RawServer(exact("200 OK", TYPED, body)); AdminClient admin = admin(server, Duration.ofSeconds(20))) {
      Outcome o = call(admin, a -> a.users().search("u", 0, users).size());
      System.out.println("[AdminResourceResponseCutTest] 사용자 " + users + " 명(" + body.length() + " B) → " + o.describe());
      assertTrue(body.length() > CAP);
      assertEquals(users, o.result(), o::describe);
    }
  }

  /** 대조 — 상한 안의 오류 본문은 통째로 실리고, 한 바이트 넘으면 상한까지 잘린다(경계). */
  @Test @Timeout(value = 60, threadMode = Timeout.ThreadMode.SEPARATE_THREAD)
  void anErrorBodyAtTheCap_isCarriedWhole() throws Exception {
    for (long total : new long[] {CAP, CAP + 1L}) {
      try (RawServer server = new RawServer(padded("404 Not Found", TYPED, NOT_FOUND, total));
           AdminClient admin = admin(server, Duration.ofSeconds(20))) {
        Outcome o = call(admin, a -> a.users().get("x"));
        KeycloakNotFoundException e = assertInstanceOf(KeycloakNotFoundException.class, o.thrown(), o.describe());
        System.out.println("[AdminResourceResponseCutTest] 404 " + total + " B → keycloakError " + e.getKeycloakError().length() + " chars");
        assertEquals(CAP, e.getKeycloakError().length(), () -> total + " B 본문 → " + e.getKeycloakError().length() + " chars");
        assertTrue(e.getKeycloakError().startsWith(NOT_FOUND));
      }
    }
  }

  /**
   * (3) 결과 뒤 멈춘 서버를 기다리지 않는다 — create 201(1 MiB 를 알린 본문)의 머리만 받은 뒤, 읽기 타임아웃 4 초의 절반 안에 그 id 를
   * 돌려준다. 두 갈래: 본문 64 KiB 가 와 있다(엿보기가 바이트를 받는다) · 본문이 한 바이트도 없다(엿보기의 1 ms 가 다한다 — HttpClient 가
   * 그 연결을 닫고, TLS 1.3 이면 그 닫기가 한 번 더 읽는다). 평문과 TLS 1.3 각각, 갈래마다 {@link #STALL_REPEATS} 번 — 끊긴 TLS 연결의
   * 닫기 실패(「Premature end of Content-Length delimited message body」)는 실행마다 났다 안 났다 했다(한 번 잰 시험은 통과하고 같은 JVM 의
   * 40 번 되풀이는 40 번 다 났다). 수정 전: 평문 4,042 · 4,020 ms 에 전송 실패 · TLS 1.3 은 닫기가 한 번 더 기다려 8,091 · 8,041 ms.
   */
  @Test @Timeout(value = 120, threadMode = Timeout.ThreadMode.SEPARATE_THREAD)
  void aServerStalledAfterTheResult_isNotWaitedFor() throws Exception {
    List<String> wrong = new ArrayList<>();
    Duration readTimeout = Duration.ofSeconds(4);
    record Case(String label, SSLContext tls, long sent) {}
    List<Case> cases = List.of(new Case("평문 · 본문 64 KiB 뒤 멈춤", null, 65_536), new Case("평문 · 본문 없이 멈춤", null, 0),
        new Case("TLS 1.3 · 본문 64 KiB 뒤 멈춤", serverTls, 65_536), new Case("TLS 1.3 · 본문 없이 멈춤", serverTls, 0));
    for (Case c : cases) {
      for (int r = 1; r <= STALL_REPEATS; r++) {
        try (RawServer server = new RawServer(c.tls(), any -> stalled("201 Created", LOCATION, c.sent()))) {
          Outcome o;
          try (AdminClient admin = c.tls() == null ? admin(server, readTimeout) : tlsAdmin(server, readTimeout)) {
            o = call(admin, a -> a.users().create(user()));
          }
          String row = c.label() + " #" + r + " → " + o.describe() + " (읽기 타임아웃 4,000 ms)";
          System.out.println("[AdminResourceResponseCutTest] " + row);
          int before = wrong.size();
          if (o.thrown() != null || !"abc".equals(o.result())) wrong.add(c.label() + ": 결과를 돌려주지 않았다 — " + row);
          if (o.millis() >= readTimeout.toMillis() / 2) wrong.add(c.label() + ": 멈춘 서버를 기다렸다 — " + row);
          if (wrong.size() > before) break; // 한 갈래의 첫 실패로 충분하다(수정 전에는 되풀이마다 4–8 초)
        }
      }
    }
    assertTrue(wrong.isEmpty(), () -> wrong.size() + " 건:\n" + String.join("\n", wrong));
  }

  /**
   * 길이 0 의 읽기는 아래 스트림에 넘기지 않는다 — JDK 의 {@code readNBytes} 는 버퍼 한 칸을 채울 때마다 길이 0 으로 한 번 더 묻고 HttpCore 의
   * 빈 버퍼는 그것도 소켓에서 기다린다({@code TokenResponseGuard.capPlusOne} 와 같은 자리 — {@code raw()} 로 응답 스트림을 받은 소비자가
   * 닿는다). 아래 스트림이 길이 0 의 읽기를 받으면 실패하게 해 잰다. 오류 본문의 상한은 한 바이트씩 읽는 길에서도 같다.
   */
  @Test
  void aZeroLengthRead_doesNotReachTheStream() throws IOException {
    InputStream refusesZero = new InputStream() {
      @Override public int read() {
        return 'x';
      }

      @Override public int read(byte[] b, int off, int len) {
        if (len == 0) throw new AssertionError("길이 0 의 읽기가 아래 스트림에 닿았다");
        b[off] = 'x';
        return 1;
      }
    };
    AdminEngine.Settled settled = new AdminEngine.Settled(refusesZero, null, Long.MAX_VALUE);
    assertEquals(0, settled.read(new byte[1], 0, 0));
    assertEquals(1, settled.read(new byte[1], 0, 1));
    // 상한은 한 바이트씩 읽어도 같다 — limit 바이트 뒤에는 아래 스트림을 읽지 않고 끝(-1)이다
    AdminEngine.Settled capped = new AdminEngine.Settled(refusesZero, null, 2);
    assertEquals('x', capped.read());
    assertEquals('x', capped.read());
    assertEquals(-1, capped.read());
  }

  /**
   * admin 이 닫힐 때의 logout — 내장 TokenManager 가 refresh_token 을 logout 엔드포인트로 보내고({@code Keycloak.close}) 오류 상태면
   * RESTEasy 가 그 본문을 버퍼에 담는다. 그 실패는 close() 가 삼켜 결과는 같고 달라지는 것은 메모리와 읽은 양뿐이다. 토큰 엔드포인트가
   * 아니라 {@link TokenResponseGuard} 범위 밖이지만(kotlin 은 그 가드가 logout 도 맡는다 — #718) 엔진의 오류 본문 상한이 같은 자리를
   * 묶는다(등록부 {@code wave4-hardening-java} (1)). 한도의 근거는 {@link #LOGOUT_ALLOCATION_BOUND}. 상한 안의 오류의 close() 는 예전처럼
   * 조용히 끝난다(대조). 수정 전: 400 + 32 MiB 에 close() 하나 100.7 MB · 서버 32 MiB 끝까지.
   */
  @Test @Timeout(value = 120, threadMode = Timeout.ThreadMode.SEPARATE_THREAD)
  void aHugeLogoutErrorBodyOnClose_isHeldOnlyUpToTheCap() throws Exception {
    byte[] withRefresh = utf8("{\"access_token\":\"good\",\"token_type\":\"Bearer\",\"expires_in\":300,"
        + "\"refresh_token\":\"rt\",\"refresh_expires_in\":300}");
    String error = "{\"error\":\"invalid_grant\"}";
    List<String> wrong = new ArrayList<>();
    try (RawServer server = new RawServer(exact("200 OK", TYPED, USER))) {
      server.token = withRefresh;
      server.logout = exact("204 No Content", "", "");
      try (AdminClient warm = admin(server, Duration.ofSeconds(20))) {
        warm.users().get("x"); // 예열 — 첫 close() 의 클래스 적재를 재지 않는다
      }
      record Case(String label, Reply reply, long body) {}
      List<Case> cases = List.of(new Case("logout 400 작은 본문", exact("400 Bad Request", TYPED, error), error.length()),
          new Case("logout 400 = 상한", padded("400 Bad Request", TYPED, error, CAP), CAP),
          new Case("logout 400 + 32 MiB", padded("400 Bad Request", TYPED, error, 32L << 20), 32L << 20));
      for (Case c : cases) {
        server.logout = c.reply();
        server.logouts.set(0);
        server.logoutWritten.set(0);
        server.loggedOut.set(new CountDownLatch(1));
        AdminClient admin = admin(server, Duration.ofSeconds(20));
        admin.users().get("x");
        Outcome o = call(admin, a -> {
          a.close();
          return "closed";
        });
        boolean finished = server.loggedOut.get().await(30, TimeUnit.SECONDS);
        String row = c.label() + " → close() " + o.describe() + " · logout " + server.logouts.get() + " 건 · server wrote "
            + server.logoutWritten.get() + " B" + (finished ? "" : " (still writing)");
        System.out.println("[AdminResourceResponseCutTest] " + row);
        if (o.thrown() != null || server.logouts.get() != 1) wrong.add(c.label() + ": close() 가 logout 을 보내고 조용히 끝나야 한다 — " + row);
        if (c.body() > CAP && (!finished || o.allocated() > LOGOUT_ALLOCATION_BOUND || server.logoutWritten.get() > WRITTEN_BOUND)) {
          wrong.add(c.label() + ": 상한 너머의 logout 오류 본문을 읽었다 — " + row);
        }
      }
    }
    assertTrue(wrong.isEmpty(), () -> wrong.size() + " 건:\n" + String.join("\n", wrong));
  }

  /**
   * 오류 본문을 상한까지 받은 뒤 멈춘 서버도 기다리지 않는다 — RESTEasy 의 {@code bufferEntity} 는 상한에서 끝난 것처럼 보이는 스트림을
   * 다 읽고 {@code releaseConnection} 으로 닫으며, 그 닫기가 엿보기 뒤 끊는다. 404(미디어 타입 있음)가 상한만큼 쓰고 멈추면 읽기 타임아웃
   * 4 초의 절반 안에 {@code KeycloakNotFoundException} 이 온다(상태가 전송 실패로 바뀌지 않는다). 평문과 TLS 1.3 각각. Grok 레그의 지적
   * (「상한에서 끊긴 오류 본문은 닫기가 다시 비우고, 멈추면 상태가 읽기 타임아웃으로 바뀐다」)을 재는 시험이다.
   */
  @Test @Timeout(value = 120, threadMode = Timeout.ThreadMode.SEPARATE_THREAD)
  void aServerStalledAfterACappedErrorBody_isNotWaitedFor() throws Exception {
    List<String> wrong = new ArrayList<>();
    Duration readTimeout = Duration.ofSeconds(4);
    Reply capThenStall = (out, written) -> {
      byte[] h = utf8(NOT_FOUND);
      out.write(latin1("HTTP/1.1 404 Not Found\r\n" + TYPED + "Content-Length: " + (CAP + (1L << 20)) + "\r\n\r\n"));
      out.write(h);
      written.addAndGet(h.length);
      spaces(out, CAP - h.length, written);
      out.flush();
      LockSupport.parkNanos(TimeUnit.SECONDS.toNanos(20)); // 상한만큼 쓰고 읽지도 쓰지도 않고 붙든다
      return false;
    };
    for (SSLContext tls : new SSLContext[] {null, serverTls}) {
      String label = tls == null ? "평문" : "TLS 1.3";
      try (RawServer server = new RawServer(tls, any -> capThenStall)) {
        Outcome o;
        try (AdminClient admin = tls == null ? admin(server, readTimeout) : tlsAdmin(server, readTimeout)) {
          o = call(admin, a -> a.users().get("x"));
        }
        String row = label + " · 404 상한 뒤 멈춤 → " + o.describe() + " (읽기 타임아웃 4,000 ms)";
        System.out.println("[AdminResourceResponseCutTest] " + row);
        if (!(o.thrown() instanceof KeycloakNotFoundException e) || e.getKeycloakError().length() != CAP) {
          wrong.add(label + ": 상한까지의 본문을 실은 KeycloakNotFoundException 이 아니다 — " + row);
        }
        if (o.millis() >= readTimeout.toMillis() / 2) wrong.add(label + ": 멈춘 서버를 기다렸다 — " + row);
      }
    }
    assertTrue(wrong.isEmpty(), () -> wrong.size() + " 건:\n" + String.join("\n", wrong));
  }

  /**
   * {@code raw()} 로 오류 응답의 스트림을 읽어도 상한에서 끝난다 — 엔진이 상태 3xx 이상의 엔티티를 그 길이에서 끝난 것처럼 보이게 하므로
   * 소비자의 {@code readEntity(InputStream)} 은 상한만큼 읽고 끝(-1)을 본다(예외가 아니다 — 예외로 알리면 RESTEasy 의 {@code bufferEntity}
   * 가 {@code ProcessingException} 을 내 파사드가 상태 갈래를 잃는다). 상한 너머의 꼬리는 읽지 않는다. Grok 레그가 지목한 동작을 고정한다.
   */
  @Test @Timeout(value = 60, threadMode = Timeout.ThreadMode.SEPARATE_THREAD)
  void aRawErrorStream_endsAtTheCap() throws Exception {
    try (RawServer server = new RawServer(padded("500 Internal Server Error", TYPED, NOT_FOUND, CAP + 10L));
         AdminClient admin = admin(server, Duration.ofSeconds(20))) {
      int read;
      try (jakarta.ws.rs.core.Response r = admin.raw().realm(REALM).users().delete("x")) {
        assertEquals(500, r.getStatus());
        read = r.readEntity(InputStream.class).readAllBytes().length;
      }
      System.out.println("[AdminResourceResponseCutTest] raw() 500 " + (CAP + 10L) + " B → 읽은 바이트 " + read);
      assertEquals(CAP, read);
    }
  }

  /** 대조 — 끊긴 연결은 풀로 돌아가지 않는다: 나머지를 끊은 create 다음의 get 은 새 연결에서 성공한다(연결 2). */
  @Test @Timeout(value = 120, threadMode = Timeout.ThreadMode.SEPARATE_THREAD)
  void aCutConnection_isNotReturnedToThePool() throws Exception {
    try (RawServer server = new RawServer(null, request -> request.startsWith("POST")
        ? padded("201 Created", LOCATION, "", 16L << 20) : exact("200 OK", TYPED, USER));
         AdminClient admin = admin(server, Duration.ofSeconds(20))) {
      Outcome cut = call(admin, a -> a.users().create(user()));
      Outcome next = call(admin, a -> a.users().get("x").map(UserRepresentation::getUsername));
      String row = "create " + cut.describe() + " · get " + next.describe() + " · 연결 " + server.connections.get();
      System.out.println("[AdminResourceResponseCutTest] " + row);
      assertEquals("abc", cut.result(), row);
      assertEquals(Optional.of("alice"), next.result(), row);
      assertEquals(2, server.connections.get(), () -> "끊긴 연결을 다시 썼거나 연결이 더 열렸다 — " + row);
    }
  }

  /**
   * 대조 — EOF 까지 읽은 응답의 연결은 지금처럼 다시 쓰인다(create 201 빈 본문 · get · search · update 204 · delete 204 가 연결 하나에서). 엿보려고
   * 낮춘 기다림(1 ms)은 다음 교환에 남지 않는다 — 300 ms 늦게 답하는 get 도 같은 연결에서 성공한다(HttpClient 가 교환마다 읽기 타임아웃을
   * 다시 건다).
   */
  @Test @Timeout(value = 60, threadMode = Timeout.ThreadMode.SEPARATE_THREAD)
  void responsesReadToTheirEnd_keepTheirConnection() throws Exception {
    Reply late = (out, written) -> {
      LockSupport.parkNanos(TimeUnit.MILLISECONDS.toNanos(300));
      return exact("200 OK", TYPED, USER).write(out, written);
    };
    try (RawServer server = new RawServer(null, request -> request.startsWith("POST") ? exact("201 Created", LOCATION, "")
        : request.startsWith("PUT") || request.startsWith("DELETE") ? exact("204 No Content", "", "")
        : request.contains("?") ? exact("200 OK", TYPED, "[" + USER + "]")
        : request.endsWith("/late") ? late : exact("200 OK", TYPED, USER));
         AdminClient admin = admin(server, Duration.ofSeconds(20))) {
      List<Outcome> outcomes = List.of(
          call(admin, a -> a.users().create(user())),
          call(admin, a -> a.users().get("x").map(UserRepresentation::getUsername)),
          call(admin, a -> a.users().search("u", 0, 10).size()),
          call(admin, a -> {
            a.users().update("x", user());
            return "void";
          }),
          call(admin, a -> {
            a.users().delete("x");
            return "void";
          }),
          call(admin, a -> a.users().get("late").map(UserRepresentation::getUsername)));
      StringBuilder row = new StringBuilder();
      for (Outcome o : outcomes) row.append(o.describe()).append(" | ");
      row.append("admin ").append(server.adminHits.get()).append(" · 연결 ").append(server.connections.get());
      System.out.println("[AdminResourceResponseCutTest] " + row);
      assertEquals(List.of("abc", Optional.of("alice"), 1, "void", "void", Optional.of("alice")),
          outcomes.stream().map(Outcome::result).toList(), row::toString);
      assertEquals(1, server.connections.get(), () -> "EOF 까지 읽은 응답의 연결을 다시 쓰지 않았다 — " + row);
    }
  }
}
