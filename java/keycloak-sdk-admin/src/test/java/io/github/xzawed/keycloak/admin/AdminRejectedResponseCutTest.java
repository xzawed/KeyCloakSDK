package io.github.xzawed.keycloak.admin;

import static org.junit.jupiter.api.Assertions.*;

import io.github.xzawed.keycloak.core.KeycloakConfig;
import io.github.xzawed.keycloak.core.exception.KeycloakTransportException;
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
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicLong;
import java.util.concurrent.atomic.AtomicReference;
import java.util.concurrent.locks.LockSupport;
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

/**
 * admin 레인이 거부한 토큰 응답은 더 읽지 않는다 — 그 연결을 끊고 풀에 돌려주지 않는다(auth 레인과 같은 규칙: EOF 까지 읽은 본문만
 * 연결을 돌려주고, 그 밖의 끝은 읽기 타임아웃을 0 으로 둔 채 끊는다).
 *
 * <p>수정 전(실측 2026-10-09, Windows · JDK 21.0.8 · 루프백 · main 80547df): {@code TokenResponseGuard} 는 상한+1 바이트를 읽고 거부한 뒤
 * 스트림을 닫았고, HttpCore 의 닫기({@code ContentLengthInputStream}·{@code ChunkedInputStream.close})는 나머지를 EOF 까지 비웠다 — 세
 * 거부 자리(미디어 타입 있는 2xx · 없는 2xx · 오류 상태) 모두 서버가 128 MiB 본문을 끝까지 썼고, 1 바이트 청크면 할당이 비운 양을
 * 따라 자랐고(세 번 잰 최소로 2 MiB 80 MB · 16 MiB 811 MB — 2026-10-10 main), 상한+64 KiB 뒤 멈춘 서버 앞에서 거부가 읽기 타임아웃(3
 * 초)을 기다렸다. 비운 연결은 풀로 돌아가 다음 호출이 다시 썼다.
 *
 * <p>계약: (1) 세 거부 자리 모두 서버가 상한과 소켓 버퍼를 넘어 쓰지 못한다. (2) 멈춘 서버 앞의 거부는 읽기 타임아웃을 기다리지 않는다 —
 * 평문과 TLS 1.3(JSSE 는 닫을 때 받은 바이트가 없으면 읽기 타임아웃만큼 한 번 더 읽는다 — 그래서 끊기 전에 그 타임아웃을 0 으로
 * 둔다). (3) 1 바이트 청크 본문도 상한 너머를 읽지 않는다 — 서버가 쓴 양이 묶이고 할당이 길이를 따라 자라지 않는다. (4) 끊긴 연결은
 * 다시 쓰이지 않는다. 대조: EOF 까지
 * 읽은 응답(쓸 수 있는 토큰 · 상한 안에서 거부한 토큰)의 연결은 지금처럼 다시 쓰인다. 공개 API 와 로컬 루프백만 쓴다.
 */
class AdminRejectedResponseCutTest {
  private static final int CAP = 1_048_576;
  private static final String REALM = "r";
  private static final String TOKEN_PATH = "/realms/" + REALM + "/protocol/openid-connect/token";
  private static final String USABLE = "{\"access_token\":\"good\",\"token_type\":\"Bearer\",\"expires_in\":300}";
  private static final byte[] USER = utf8("{\"id\":\"x\",\"username\":\"alice\"}");
  /** 거부되는 본문의 길이 — 수정 전에는 닫기가 이것을 끝까지 비웠다. */
  private static final long HUGE = 64L << 20;
  /** 끊긴 교환에서 서버가 써도 되는 본문 — 상한 + 소켓 버퍼(리눅스 tcp_rmem 6 MiB · tcp_wmem 4 MiB)를 넉넉히 넘는 16 MiB. */
  private static final long WRITTEN_BOUND = 16L << 20;
  /** 1 바이트 청크 본문의 두 길이 — 상한 바로 위(기준)와 그 8 배. 선 위는 본문의 6 배다(「1\r\n \r\n」). */
  private static final long[] CHUNKED_SIZES = {2L << 20, 16L << 20};
  /**
   * 1 바이트 청크로 끊긴 교환에서 서버가 써도 되는 본문 — 판정이 읽는 상한+1(선 위 6 MiB)에 소켓 버퍼(리눅스 최대 약 10 MiB 의 선 위 =
   * 본문 1.7 MiB)를 넉넉히 넘는 4 MiB. 결정적인 신호다: 끊지 않으면 닫기가 16 MiB 본문을 끝까지 읽어 서버가 전부 쓴다.
   */
  private static final long CHUNKED_WRITTEN_BOUND = 4L << 20;
  /** 한 길이를 이만큼 재고 가장 작은 할당을 쓴다 — 같은 일의 할당이 JIT 상태에 따라 실행마다 갈린다(CI 35.8 MB · 로컬 56 MB). */
  private static final int ALLOCATION_REPEATS = 3;
  /** 16 MiB 와 2 MiB 의 최소 할당 차의 한도 — 근거(측정)는 {@link #oneByteChunksPastTheCap_areNotReadOn_andDoNotGrowTheAllocation} 에. */
  private static final long ALLOCATION_GROWTH_BOUND = 128L << 20;

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

  /** 토큰 엔드포인트의 응답 하나 — 쓴 본문 바이트를 {@code written} 에 센다. 돌려주는 값은 연결을 이어 쓸지다. */
  @FunctionalInterface
  private interface Reply {
    boolean write(InputStream in, OutputStream out, AtomicLong written) throws IOException;
  }

  private static Reply json(String body) {
    byte[] b = utf8(body);
    return (in, out, written) -> {
      out.write(latin1("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: " + b.length + "\r\n\r\n"));
      out.write(b);
      out.flush();
      written.addAndGet(b.length);
      return true;
    };
  }

  private static String head(String status, boolean typed, String framing) {
    return "HTTP/1.1 " + status + "\r\n" + (typed ? "Content-Type: application/json\r\n" : "") + framing + "\r\n\r\n";
  }

  /** {@code json} 뒤를 JSON 공백으로 채운 {@code total} 바이트의 Content-Length 본문. */
  private static Reply padded(String status, boolean typed, String json, long total) {
    return (in, out, written) -> {
      out.write(latin1(head(status, typed, "Content-Length: " + total)));
      byte[] h = utf8(json);
      out.write(h);
      written.addAndGet(h.length);
      spaces(out, total - h.length, written);
      out.flush();
      return true;
    };
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

  /** 쓸 수 있는 토큰(청크 하나) 뒤에 1 바이트 청크(공백)를 이어 {@code total} 바이트를 채운 청크 본문. */
  private static Reply oneByteChunks(long total) {
    return (in, out, written) -> {
      out.write(latin1(head("200 OK", true, "Transfer-Encoding: chunked")));
      byte[] h = utf8(USABLE);
      out.write(latin1(Integer.toHexString(h.length) + "\r\n"));
      out.write(h);
      out.write(latin1("\r\n"));
      written.addAndGet(h.length);
      byte[] unit = latin1("1\r\n \r\n");
      byte[] slab = new byte[unit.length * 10_000];
      for (int i = 0; i < 10_000; i++) System.arraycopy(unit, 0, slab, i * unit.length, unit.length);
      long left = total - h.length;
      while (left > 0) {
        int n = (int) Math.min(left, 10_000);
        out.write(slab, 0, n * unit.length);
        written.addAndGet(n);
        left -= n;
      }
      out.write(latin1("0\r\n\r\n"));
      out.flush();
      return true;
    };
  }

  /**
   * {@code declared} 바이트를 알리고 {@code sent} 바이트(쓸 수 있는 토큰 + 공백)만 보낸 뒤 멈춘다 — 20 초 동안 연결을 붙들고 <b>읽지도
   * 않는다</b>. ⚠️ 읽으면 TLS 1.3 에서 클라이언트의 close_notify 에 답해 닫게 되고, 그러면 JSSE 가 닫을 때 기다릴 바이트가 생겨 끊기
   * 전에 읽기 타임아웃을 0 으로 두지 않아도 거부가 빨랐다(그 단계를 지운 변이가 살았다).
   */
  private static Reply stalled(long declared, long sent) {
    return (in, out, written) -> {
      out.write(latin1(head("200 OK", true, "Content-Length: " + declared)));
      byte[] h = utf8(USABLE);
      out.write(h);
      spaces(out, sent - h.length, written);
      out.flush();
      LockSupport.parkNanos(TimeUnit.SECONDS.toNanos(20)); // 읽지 않고 붙든다(인터럽트면 일찍 깬다 — 시험이 끝난 뒤다)
      return false;
    };
  }

  /**
   * 원시 HTTP/1.1 서버(평문 또는 TLS) — 연결 하나에 요청 여럿(keep-alive). 토큰 엔드포인트는 {@link #token} 을, admin 사용자 조회는
   * 사용자 하나를 낸다. 받아들인 연결 수 · 토큰 요청 수 · admin 요청 수 · 마지막 토큰 응답이 쓴 본문 바이트를 센다.
   */
  private static final class RawServer implements AutoCloseable {
    final ServerSocket socket;
    final AtomicInteger connections = new AtomicInteger();
    final AtomicInteger tokenHits = new AtomicInteger();
    final AtomicInteger adminHits = new AtomicInteger();
    final AtomicLong written = new AtomicLong();
    /** 마지막 토큰 응답의 쓰기가 끝났거나(성공·실패) — 시험 스레드가 바꾸고 서버 스레드가 센다. */
    final AtomicReference<CountDownLatch> replied = new AtomicReference<>(new CountDownLatch(1));
    final AtomicReference<Reply> token = new AtomicReference<>(json(USABLE));

    RawServer(SSLContext tls) throws IOException {
      socket = tls == null ? new ServerSocket(0, 50, InetAddress.getLoopbackAddress())
          : tls.getServerSocketFactory().createServerSocket(0, 50, InetAddress.getLoopbackAddress());
      Thread t = new Thread(this::serve, "admin-cut-server");
      t.setDaemon(true);
      t.start();
    }

    void reply(Reply r) {
      token.set(r);
      written.set(0);
      replied.set(new CountDownLatch(1));
      tokenHits.set(0);
      adminHits.set(0);
    }

    int port() {
      return socket.getLocalPort();
    }

    /** 마지막 토큰 응답의 쓰기가 끝날 때까지(최대 30 초) — 끝나지 않으면 거짓. */
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
        Thread t = new Thread(() -> exchanges(s), "admin-cut-connection");
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
        for (String path = request(in); path != null; path = request(in)) {
          if (!answer(path, in, out)) return;
        }
      } catch (IOException clientLeft) {
        // 클라이언트가 끊었다 — 거부의 정상 결말이다
      }
    }

    private boolean answer(String path, InputStream in, OutputStream out) throws IOException {
      if (path.equals(TOKEN_PATH)) {
        tokenHits.incrementAndGet();
        CountDownLatch done = replied.get();
        try {
          return token.get().write(in, out, written);
        } finally {
          done.countDown();
        }
      }
      if (path.startsWith("/admin/realms/" + REALM + "/users")) {
        adminHits.incrementAndGet();
        out.write(latin1("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: " + USER.length + "\r\n\r\n"));
        out.write(USER);
      } else {
        out.write(latin1("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n"));
      }
      out.flush();
      return true;
    }

    /** 요청 하나(머리와 Content-Length 본문)를 읽고 그 경로를 돌려준다 — 연결이 끝났으면 null. */
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
          return lines[0].split(" ")[1];
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

  /** admin 호출 하나 — 던진 것(없으면 null), 걸린 시간, 호출 스레드의 할당. */
  private record Outcome(Throwable thrown, long millis, long allocated) {
    String describe() {
      return (thrown == null ? "accepted" : thrown.getClass().getSimpleName() + "(" + thrown.getMessage() + ")") + " · "
          + millis + " ms · allocated " + allocated + " B";
    }
  }

  private static Outcome call(AdminClient admin) {
    com.sun.management.ThreadMXBean threads = allocationCounter();
    long before = threads.getCurrentThreadAllocatedBytes();
    long start = System.nanoTime();
    Throwable thrown = null;
    try {
      admin.users().get("x");
    } catch (Throwable t) {
      thrown = t;
    }
    long millis = (System.nanoTime() - start) / 1_000_000;
    return new Outcome(thrown, millis, threads.getCurrentThreadAllocatedBytes() - before);
  }

  private static com.sun.management.ThreadMXBean allocationCounter() {
    java.lang.management.ThreadMXBean bean = ManagementFactory.getThreadMXBean();
    Assumptions.assumeTrue(bean instanceof com.sun.management.ThreadMXBean t && t.isThreadAllocatedMemorySupported()
        && t.isThreadAllocatedMemoryEnabled(), "스레드 할당 계수기가 없는 JVM");
    return (com.sun.management.ThreadMXBean) bean;
  }

  private static void expectRejected(String label, Outcome o, RawServer server, List<String> wrong) {
    if (!(o.thrown() instanceof KeycloakTransportException) || !"admin transport failure".equals(o.thrown().getMessage())) {
      wrong.add(label + ": KeycloakTransportException(admin transport failure) 가 아니다 — " + o.describe());
    }
    if (server.adminHits.get() != 0) wrong.add(label + ": admin 요청이 나갔다 — " + server.adminHits.get());
  }

  /** 세 거부 자리 — 결합 직전 ReaderInterceptor · 응답 필터(미디어 타입 없는 2xx) · 오류 상태의 상한. */
  enum Site {
    TYPED_2XX("200 OK", true, USABLE),
    UNTYPED_2XX("201 Created", false, USABLE),
    ERROR_STATUS("400 Bad Request", true, "{\"error\":\"invalid_grant\"}");

    final String status;
    final boolean typed;
    final String head;

    Site(String status, boolean typed, String head) {
      this.status = status;
      this.typed = typed;
      this.head = head;
    }
  }

  /** (1) 거부한 응답은 더 읽지 않는다 — 서버는 64 MiB 본문의 상한과 소켓 버퍼 너머를 쓰지 못한다. 수정 전: 세 자리 모두 끝까지. */
  @ParameterizedTest
  @EnumSource(Site.class)
  @Timeout(value = 120, threadMode = Timeout.ThreadMode.SEPARATE_THREAD)
  void aRejectedTokenResponse_isNotReadOn(Site site) throws Exception {
    List<String> wrong = new ArrayList<>();
    try (RawServer server = new RawServer(null)) {
      server.reply(padded(site.status, site.typed, site.head, HUGE));
      Outcome o;
      try (AdminClient admin = admin(server, Duration.ofSeconds(20))) {
        o = call(admin);
      }
      boolean finished = server.awaitReply();
      String row = site + " " + (HUGE >> 20) + " MiB → " + o.describe() + " · server wrote " + server.written.get() + " B"
          + (finished ? "" : " (still writing)");
      System.out.println("[AdminRejectedResponseCutTest] " + row);
      expectRejected(site.toString(), o, server, wrong);
      if (!finished || server.written.get() > WRITTEN_BOUND) {
        wrong.add(site + ": 거부한 뒤에도 본문을 읽었다 — " + row + " (한도 " + WRITTEN_BOUND + ")");
      }
    }
    assertTrue(wrong.isEmpty(), () -> wrong.size() + " 건:\n" + String.join("\n", wrong));
  }

  /**
   * (2) 거부는 멈춘 서버를 기다리지 않는다 — 읽기 타임아웃 4 초의 절반 안에 끝나야 한다. 세 모양: 평문 상한+64 KiB 뒤 멈춤(닫기가
   * 나머지를 기다렸다) · 평문 정확히 상한+1 뒤 멈춤(JDK 의 {@code readNBytes} 가 다 채운 뒤 길이 0 으로 한 번 더 묻고 HttpCore 의 빈
   * 버퍼는 그것도 소켓에서 기다린다) · TLS 1.3 정확히 상한+1 뒤 멈춤(그 둘에 더해 JSSE 는 닫을 때 받은 바이트가 없으면 읽기
   * 타임아웃만큼 한 번 더 읽는다 — 끊기 전에 그 타임아웃을 0 으로 둔다). 수정 전: 4,019 · 4,108 ms(평문 상한+64 KiB · TLS).
   */
  @Test @Timeout(value = 120, threadMode = Timeout.ThreadMode.SEPARATE_THREAD)
  void aRejection_doesNotWaitForAStalledServer() throws Exception {
    List<String> wrong = new ArrayList<>();
    Duration readTimeout = Duration.ofSeconds(4);
    try (RawServer plainAfter64k = new RawServer(null); RawServer plainAfterCap = new RawServer(null);
         RawServer tlsAfterCap = new RawServer(serverTls)) {
      plainAfter64k.reply(stalled(CAP + (1L << 20), CAP + 65_536L));
      plainAfterCap.reply(stalled(CAP + (1L << 20), CAP + 1L));
      tlsAfterCap.reply(stalled(CAP + (1L << 20), CAP + 1L));
      String[] labels = {"평문 · 상한+64 KiB 뒤 멈춤", "평문 · 상한+1 뒤 멈춤", "TLS 1.3 · 상한+1 뒤 멈춤"};
      RawServer[] servers = {plainAfter64k, plainAfterCap, tlsAfterCap};
      for (int i = 0; i < servers.length; i++) {
        RawServer server = servers[i];
        Outcome o;
        try (AdminClient admin = server == tlsAfterCap ? tlsAdmin(server, readTimeout) : admin(server, readTimeout)) {
          o = call(admin);
        }
        System.out.println("[AdminRejectedResponseCutTest] " + labels[i] + " → " + o.describe() + " (읽기 타임아웃 4,000 ms)");
        expectRejected(labels[i], o, server, wrong);
        if (o.millis() >= readTimeout.toMillis() / 2) wrong.add(labels[i] + ": 거부가 멈춘 서버를 기다렸다 — " + o.millis() + " ms");
      }
    }
    assertTrue(wrong.isEmpty(), () -> wrong.size() + " 건:\n" + String.join("\n", wrong));
  }

  /**
   * (3) 1 바이트 청크 본문 — 상한까지는 읽어야 하지만(판정) 그 너머는 읽지 않는다. 두 신호: (a) 결정적 — 16 MiB 본문에서 서버가 쓴
   * 본문이 {@link #CHUNKED_WRITTEN_BOUND} 를 넘지 않는다. (b) 할당 — 16 MiB 와 2 MiB 의 최소 할당 차가 {@link #ALLOCATION_GROWTH_BOUND}
   * 안이다. 한 길이를 {@link #ALLOCATION_REPEATS} 번 재고 최소를 쓴다 — 같은 일의 할당이 실행마다 갈렸고(CI 의 2 MiB 35.8 MB · 같은
   * 실행의 8 MiB 55.9 MB — 서버가 쓴 양은 1.39·1.40 MB 로 같았다) 그 소음이 한 번 잰 차를 8 MiB 한도 위로 밀었다. 예열도 1 바이트
   * 청크의 거부 경로로 한다. 한도의 근거(2026-10-10 실측, 로컬 Windows · JDK 21.0.8, 실행마다 새 JVM): 수정 뒤 열 번 — 한 번 잰
   * 할당이 30.6–55.9 MB 의 두 갈래라 최소의 차가 가장 크게 흔들려도 25.3 MB(CI 의 한 번 잰 차 20.0 MB), 실제 최소의 차 −0.1–0.6 MB ·
   * 서버가 쓴 양 1,120,062–1,190,062 B. 수정 전(main) 세 번 — 최소 할당 2 MiB 80.3 MB · 16 MiB 810.7 MB(차 730.3–730.5 MB), 서버가
   * 16 MiB 를 다 썼다(kotlin 704.6 MB). 할당 한도 128 MiB(134.2 MB)는 두 끝의 기하 평균 근처라 양쪽에서 5 배 넘게 떨어지고(134.2/25.3 ·
   * 704.6/134.2), 서버가 쓴 양의 한도 4 MiB 는 CI 의 1.40 MB 보다 3 배 · 수정 전의 16 MiB 보다 4 배 떨어진다.
   */
  @Test @Timeout(value = 180, threadMode = Timeout.ThreadMode.SEPARATE_THREAD)
  void oneByteChunksPastTheCap_areNotReadOn_andDoNotGrowTheAllocation() throws Exception {
    List<String> wrong = new ArrayList<>();
    try (RawServer server = new RawServer(null)) {
      server.reply(oneByteChunks(CHUNKED_SIZES[0]));
      try (AdminClient warm = admin(server, Duration.ofSeconds(20))) {
        call(warm); // 예열 — 1 바이트 청크의 거부 경로를 잰 구간 밖에서 한 번 돈다
      }
      server.awaitReply();
      long[] least = {Long.MAX_VALUE, Long.MAX_VALUE};
      for (int i = 0; i < CHUNKED_SIZES.length; i++) {
        for (int r = 0; r < ALLOCATION_REPEATS; r++) {
          server.reply(oneByteChunks(CHUNKED_SIZES[i]));
          Outcome o;
          try (AdminClient admin = admin(server, Duration.ofSeconds(20))) {
            o = call(admin);
          }
          boolean finished = server.awaitReply();
          long written = server.written.get();
          String label = "1 바이트 청크 " + (CHUNKED_SIZES[i] >> 20) + " MiB #" + (r + 1);
          System.out.println("[AdminRejectedResponseCutTest] " + label + " → " + o.describe() + " · server wrote " + written + " B"
              + " · [sample size=" + (CHUNKED_SIZES[i] >> 20) + " allocated=" + o.allocated() + " written=" + written + "]");
          expectRejected(label, o, server, wrong);
          if (!finished || written > CHUNKED_WRITTEN_BOUND) {
            wrong.add(label + ": 거부한 뒤에도 본문을 읽었다 — server wrote " + written + " B (한도 " + CHUNKED_WRITTEN_BOUND + ")");
          }
          least[i] = Math.min(least[i], o.allocated());
        }
      }
      long growth = least[1] - least[0];
      System.out.println("[AdminRejectedResponseCutTest] 1 바이트 청크 최소 할당 2 MiB " + least[0] + " B · 16 MiB " + least[1] + " B"
          + " · [growth=" + growth + "]");
      if (growth >= ALLOCATION_GROWTH_BOUND) {
        wrong.add("본문이 14 MiB 더 길어 최소 할당이 " + growth + " B 더 늘었다(한도 " + ALLOCATION_GROWTH_BOUND + ") — 상한 너머를 읽었다");
      }
    }
    assertTrue(wrong.isEmpty(), () -> wrong.size() + " 건:\n" + String.join("\n", wrong));
  }

  /** (4) 끊긴 연결은 풀로 돌아가지 않는다 — 다음 호출은 새 연결을 맺어 성공한다. 수정 전: 비운 연결을 다시 썼다(연결 1). */
  @Test @Timeout(value = 120, threadMode = Timeout.ThreadMode.SEPARATE_THREAD)
  void aCutConnection_isNotReturnedToThePool() throws Exception {
    try (RawServer server = new RawServer(null); AdminClient admin = admin(server, Duration.ofSeconds(20))) {
      server.reply(padded("200 OK", true, USABLE, 16L << 20));
      Outcome rejected = call(admin);
      server.awaitReply();
      server.token.set(json(USABLE));
      Outcome next = call(admin);
      String row = "거부 " + rejected.describe() + " · 다음 " + next.describe() + " · 연결 " + server.connections.get();
      System.out.println("[AdminRejectedResponseCutTest] " + row);
      assertInstanceOf(KeycloakTransportException.class, rejected.thrown(), row);
      assertNull(next.thrown(), row);
      assertEquals(2, server.connections.get(), () -> "끊긴 연결을 다시 썼거나 연결이 더 열렸다 — " + row);
    }
  }

  /**
   * 대조 — EOF 까지 읽은 응답의 연결은 지금처럼 다시 쓰인다: 쓸 수 있는 토큰(부여 + 갱신 둘)과 admin 응답 셋이 연결 하나에서, 그리고
   * 상한 안에서 거부한 토큰(본문을 끝까지 읽었다)의 연결도 다음 호출이 다시 쓴다.
   */
  @Test @Timeout(value = 60, threadMode = Timeout.ThreadMode.SEPARATE_THREAD)
  void responsesReadToTheirEnd_keepTheirConnection() throws Exception {
    String refreshing = "{\"access_token\":\"good\",\"token_type\":\"Bearer\",\"expires_in\":1,"
        + "\"refresh_token\":\"rt\",\"refresh_expires_in\":300}";
    try (RawServer server = new RawServer(null)) {
      server.reply(json(refreshing));
      try (AdminClient admin = admin(server, Duration.ofSeconds(20))) {
        for (int i = 0; i < 3; i++) assertNull(call(admin).thrown());
      }
      String used = "토큰 " + server.tokenHits.get() + " · admin " + server.adminHits.get() + " · 연결 " + server.connections.get();
      System.out.println("[AdminRejectedResponseCutTest] 쓸 수 있는 토큰(부여·갱신) → " + used);
      assertEquals(3, server.tokenHits.get(), used); // expires_in 1 < TokenManager 최소 유효기간 30 초 — 호출마다 갱신한다
      assertEquals(3, server.adminHits.get(), used);
      assertEquals(1, server.connections.get(), () -> "EOF 까지 읽은 응답의 연결을 다시 쓰지 않았다 — " + used);
    }
    try (RawServer server = new RawServer(null); AdminClient admin = admin(server, Duration.ofSeconds(20))) {
      server.reply(json("{\"access_token\":12345,\"token_type\":\"Bearer\",\"expires_in\":300}"));
      Outcome rejected = call(admin);
      server.token.set(json(USABLE));
      Outcome next = call(admin);
      String row = "상한 안의 거부 " + rejected.describe() + " · 다음 " + next.describe() + " · 연결 " + server.connections.get();
      System.out.println("[AdminRejectedResponseCutTest] " + row);
      assertInstanceOf(KeycloakTransportException.class, rejected.thrown(), row);
      assertNull(next.thrown(), row);
      assertEquals(1, server.connections.get(), () -> "EOF 까지 읽고 거부한 응답의 연결을 다시 쓰지 않았다 — " + row);
    }
  }
}
