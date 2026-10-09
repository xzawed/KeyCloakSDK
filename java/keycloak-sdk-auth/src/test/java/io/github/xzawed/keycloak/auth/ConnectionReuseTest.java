package io.github.xzawed.keycloak.auth;

import static org.junit.jupiter.api.Assertions.*;

import com.nimbusds.oauth2.sdk.http.HTTPRequest;
import io.github.xzawed.keycloak.core.KeycloakConfig;
import io.github.xzawed.keycloak.core.exception.KeycloakTransportException;
import java.io.ByteArrayOutputStream;
import java.io.FileInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.net.SocketTimeoutException;
import java.net.URI;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.nio.file.Path;
import java.security.KeyStore;
import java.time.Duration;
import java.util.ArrayList;
import java.util.List;
import java.util.Set;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.concurrent.FutureTask;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicLong;
import java.util.stream.Collectors;
import javax.net.ssl.HostnameVerifier;
import javax.net.ssl.KeyManagerFactory;
import javax.net.ssl.SSLContext;
import javax.net.ssl.SSLSocket;
import javax.net.ssl.SSLSocketFactory;
import javax.net.ssl.TrustManagerFactory;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.Timeout;
import org.junit.jupiter.api.io.TempDir;

/**
 * 연결 재사용 — {@link BoundedTransport} 의 프로세스 풀은 HttpURLConnection 의 keep-alive 처럼 연결을 다시 쓰되, 한도 안에서다:
 * EOF 까지 읽은 응답의 연결만 풀로 돌아가고(재사용), 넘침·거부·실패의 연결은 읽지 않고 끊겨 돌아가지 않으며, 같은 TLS 근원의 교환만
 * 연결을 함께 쓰고, 쉬는 동안 서버가 닫은 연결은 빌려줄 때 걸러지거나 한 번 다시 보내진다. 백그라운드 스레드가 없고, 거부하며 닫는
 * TLS 연결은 조용한 서버 앞에서 기다리지 않는다.
 *
 * <p>⚠️ 풀은 프로세스에 하나다 — 시험마다 새 서버(새 포트 = 새 경로)를 써서 서로의 연결을 다시 쓰지 않는다. 연결 수는 서버가 받아들인
 * 수로 잰다. 시간 한도는 별도 스레드에서 끊는다({@code SEPARATE_THREAD}) — 블로킹 소켓 읽기는 인터럽트로 멈추지 않아, 회귀(예: 거부한
 * 본문을 비우는 닫기)가 빌드를 붙잡지 않고 실패하게.
 */
class ConnectionReuseTest {
  private static final int CAP = 1_048_576;
  private static final byte[] ACTIVE = utf8("{\"active\":true,\"client_id\":\"app\"}");
  /** 인증서의 이름(other.example)이 아니라 접속한 이름이 루프백이면 받아들이는 검증기. */
  private static final HostnameVerifier ACCEPTS_LOOPBACK = (host, session) -> "127.0.0.1".equals(host);
  /** 무엇이든 거부하는 검증기(접속한 이름이 결코 아닌 이름만 받아들인다). */
  private static final HostnameVerifier REJECTS = (host, session) -> "never.invalid".equals(host);

  @TempDir static Path dir;
  /** 시험 키 저장소의 암호 — 실행마다 새로 만든다(저장소에 키도, 그 암호도 두지 않는다). */
  private static final String STOREPASS = java.util.UUID.randomUUID().toString();
  /** SAN 이 127.0.0.1 인 서버 키 · 다른 이름(other.example)의 서버 키 · 둘을 믿는 클라이언트 팩토리. */
  private static SSLContext serverIp;
  private static SSLContext serverOther;
  /**
   * {@code serverOther} 의 키로, 핸드셰이크 뒤 세션 티켓을 보내지 않는 서버 — JDK 의 TLS 1.3 서버는 세션 시한이 7 일을 넘으면 티켓을 보내지
   * 않는다({@code NewSessionTicket} 「Session timeout is too long」). 보내면 그 바이트가 와 있어 JSSE 의 닫기가 기다리지 않는다.
   */
  private static SSLContext serverOtherWithoutTickets;
  private static SSLSocketFactory trusting;

  @BeforeAll static void keys() throws Exception {
    KeyStore ip = keystore("ip", "CN=127.0.0.1", "SAN=ip:127.0.0.1");
    KeyStore other = keystore("other", "CN=other.example", "SAN=dns:other.example");
    serverIp = serverContext(ip);
    serverOther = serverContext(other);
    serverOtherWithoutTickets = serverContext(other);
    serverOtherWithoutTickets.getServerSessionContext().setSessionTimeout(8 * 24 * 3600);
    KeyStore trust = KeyStore.getInstance("PKCS12");
    trust.load(null, null);
    trust.setCertificateEntry("ip", ip.getCertificate("ip"));
    trust.setCertificateEntry("other", other.getCertificate("other"));
    TrustManagerFactory tmf = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm());
    tmf.init(trust);
    SSLContext client = SSLContext.getInstance("TLS");
    client.init(null, tmf.getTrustManagers(), null);
    trusting = client.getSocketFactory();
  }

  /** 시험 때마다 keytool 로 만든다 — 저장소에 키를 두지 않는다. */
  private static KeyStore keystore(String alias, String dname, String san) throws Exception {
    Path file = dir.resolve(alias + ".p12");
    Process p = new ProcessBuilder(Path.of(System.getProperty("java.home"), "bin", "keytool").toString(),
        "-genkeypair", "-alias", alias, "-keyalg", "EC", "-groupname", "secp256r1", "-validity", "2", "-dname", dname,
        "-ext", san, "-keystore", file.toString(), "-storetype", "PKCS12", "-storepass", STOREPASS, "-keypass", STOREPASS)
        .redirectErrorStream(true).start();
    String out = new String(p.getInputStream().readAllBytes(), StandardCharsets.UTF_8);
    assertTrue(p.waitFor(60, TimeUnit.SECONDS) && p.exitValue() == 0, () -> "keytool 실패: " + out);
    KeyStore ks = KeyStore.getInstance("PKCS12");
    try (InputStream in = new FileInputStream(file.toFile())) {
      ks.load(in, STOREPASS.toCharArray());
    }
    return ks;
  }

  private static SSLContext serverContext(KeyStore ks) throws Exception {
    KeyManagerFactory kmf = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm());
    kmf.init(ks, STOREPASS.toCharArray());
    SSLContext ctx = SSLContext.getInstance("TLS");
    ctx.init(kmf.getKeyManagers(), null, null);
    return ctx;
  }

  private static byte[] utf8(String s) {
    return s.getBytes(StandardCharsets.UTF_8);
  }

  private static byte[] latin1(String s) {
    return s.getBytes(StandardCharsets.ISO_8859_1);
  }

  private static byte[] ok(byte[] body) {
    ByteArrayOutputStream out = new ByteArrayOutputStream();
    out.writeBytes(latin1("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: " + body.length + "\r\n\r\n"));
    out.writeBytes(body);
    return out.toByteArray();
  }

  // ───────────── 서버 ─────────────

  /** 연결 하나를 맡는 서버 쪽 코드 — 읽기·쓰기·닫기를 시험이 정한다. */
  @FunctionalInterface
  private interface Handler {
    void handle(Peer peer) throws Exception;
  }

  /** 원시 서버 — 연결마다 새 스레드에서 {@code handler} 를 돌린다. 받아들인 연결 수, 지금 열린 수의 최고치, 받은 요청을 적는다. */
  private static final class RawServer implements AutoCloseable {
    final ServerSocket socket;
    final AtomicInteger accepted = new AtomicInteger();
    final AtomicInteger open = new AtomicInteger();
    final AtomicInteger peakOpen = new AtomicInteger();
    /** 「연결 번호 요청 줄」 — 연결 번호는 받아들인 순서(1 부터). */
    final List<String> requests = new CopyOnWriteArrayList<>();
    private final Handler handler;

    RawServer(SSLContext tls, Handler handler) throws IOException {
      this.handler = handler;
      socket = tls == null ? new ServerSocket(0, 100, InetAddress.getLoopbackAddress())
          : tls.getServerSocketFactory().createServerSocket(0, 100, InetAddress.getLoopbackAddress());
      Thread t = new Thread(this::serve, "reuse-raw-server");
      t.setDaemon(true);
      t.start();
    }

    int port() {
      return socket.getLocalPort();
    }

    private void serve() {
      while (!socket.isClosed()) {
        Socket s;
        try {
          s = socket.accept();
        } catch (IOException closed) {
          return;
        }
        int index = accepted.incrementAndGet();
        Thread t = new Thread(() -> run(s, index), "reuse-raw-connection");
        t.setDaemon(true);
        t.start();
      }
    }

    private void run(Socket s, int index) {
      peakOpen.accumulateAndGet(open.incrementAndGet(), Math::max);
      try (s) {
        s.setSoTimeout(30_000);
        if (s instanceof SSLSocket tls) tls.startHandshake();
        handler.handle(new Peer(this, s, index));
      } catch (Exception gone) {
        // 클라이언트가 떠났다(끊기·TLS 거부 포함)
      } finally {
        open.decrementAndGet();
      }
    }

    @Override public void close() throws IOException {
      socket.close();
    }
  }

  /** 서버 쪽 연결 하나. */
  private static final class Peer {
    final RawServer server;
    final Socket socket;
    final int index;
    final InputStream in;
    final OutputStream out;

    Peer(RawServer server, Socket socket, int index) throws IOException {
      this.server = server;
      this.socket = socket;
      this.index = index;
      this.in = socket.getInputStream();
      this.out = socket.getOutputStream();
    }

    /** 요청 하나(머리 + Content-Length 본문) — 그 전에 클라이언트가 닫으면 null. 받은 요청은 서버에 적는다. */
    String readRequest() throws IOException {
      ByteArrayOutputStream head = new ByteArrayOutputStream();
      int last4 = 0;
      for (int b = in.read(); ; b = in.read()) {
        if (b == -1) return null;
        head.write(b);
        last4 = (last4 << 8) | b;
        if (last4 == 0x0d0a0d0a) break;
      }
      String[] lines = head.toString(StandardCharsets.ISO_8859_1).split("\r\n");
      int length = 0;
      for (String h : lines) {
        if (h.regionMatches(true, 0, "Content-Length:", 0, 15)) length = Integer.parseInt(h.substring(15).trim());
      }
      in.readNBytes(length);
      server.requests.add(index + " " + lines[0]);
      return lines[0];
    }

    void write(byte[] bytes) throws IOException {
      out.write(bytes);
      out.flush();
    }

    /** 요청마다 {@code reply} — 클라이언트가 닫을 때까지. */
    void serveAll(byte[] reply) throws IOException {
      while (readRequest() != null) write(reply);
    }
  }

  private static AuthClient authClient(String base, Duration connectTimeout, Duration readTimeout) {
    KeycloakConfig c = KeycloakConfig.builder().serverUrl(base).realm("r").clientId("app").clientSecret("s3cr3t".toCharArray())
        .connectTimeout(connectTimeout).readTimeout(readTimeout).build();
    return new AuthClient(c, OidcMetadata.forRealm(c));
  }

  private static AuthClient authClient(String base, Duration readTimeout) {
    return authClient(base, Duration.ofSeconds(2), readTimeout);
  }

  private static AuthClient authClient(String base) {
    return authClient(base, Duration.ofSeconds(5));
  }

  /** Nimbus 의 기본 TLS 근원을 시험 팩토리로 바꾼 채 {@code call} 을 돈다 — 끝에서 되돌린다(surefire 는 한 JVM 에서 클래스를 차례로 돈다). */
  private static void withTrustingNimbusDefault(ThrowingCall call) throws Exception {
    SSLSocketFactory saved = HTTPRequest.getDefaultSSLSocketFactory();
    try {
      HTTPRequest.setDefaultSSLSocketFactory(trusting);
      call.run();
    } finally {
      HTTPRequest.setDefaultSSLSocketFactory(saved);
    }
  }

  @FunctionalInterface
  private interface ThrowingCall {
    void run() throws Exception;
  }

  /** CappedResponseSender 로 보내는 POST — 요청의 TLS 근원(팩토리·검증기)과 타임아웃을 시험이 정한다. */
  private static HTTPRequest post(String url, SSLSocketFactory factory, HostnameVerifier verifier, int readTimeoutMs)
      throws IOException {
    HTTPRequest req = new HTTPRequest(HTTPRequest.Method.POST, URI.create(url).toURL());
    req.setBody("grant_type=client_credentials");
    req.setConnectTimeout(2_000);
    req.setReadTimeout(readTimeoutMs);
    req.setFollowRedirects(false);
    if (factory != null) req.setSSLSocketFactory(factory);
    if (verifier != null) req.setHostnameVerifier(verifier);
    return req;
  }

  private static long leased() {
    return BoundedTransport.POOL.getTotalStats().getLeased();
  }

  /**
   * {@code n} 개의 호출을 각자의 데몬 스레드에서 함께 시작한다 — ExecutorService 를 쓰지 않는다(JDK 19 부터 AutoCloseable 인데 이 시험은
   * release 17 로 컴파일돼 그 close() 를 부를 수 없다). 끝나면 {@link #cancelAll} 로 남은 것을 중단한다.
   */
  private static List<FutureTask<Boolean>> concurrently(int n, java.util.concurrent.Callable<Boolean> call) {
    List<FutureTask<Boolean>> tasks = new ArrayList<>();
    for (int i = 0; i < n; i++) {
      FutureTask<Boolean> task = new FutureTask<>(call);
      Thread t = new Thread(task, "reuse-test-call");
      t.setDaemon(true);
      t.start();
      tasks.add(task);
    }
    return tasks;
  }

  private static void cancelAll(List<FutureTask<Boolean>> tasks) {
    for (FutureTask<Boolean> task : tasks) task.cancel(true);
  }

  // ───────────── 재사용 ─────────────

  /** AuthClient 의 introspection 20 번이 연결 하나로 간다 — 서버는 연결 하나에서 요청 20 개를 받는다. */
  @Test void sequentialAuthClientCalls_shareOneConnection() throws Exception {
    try (RawServer server = new RawServer(null, p -> p.serveAll(ok(ACTIVE)))) {
      AuthClient auth = authClient("http://127.0.0.1:" + server.port());
      for (int i = 0; i < 20; i++) assertTrue(auth.introspect("tok-" + i).isActive());
      assertEquals(1, server.accepted.get(), () -> "연결 " + server.accepted + " · " + server.requests);
      assertEquals(20, server.requests.size());
      assertTrue(server.requests.stream().allMatch(r -> r.startsWith("1 POST ")), () -> server.requests.toString());
      assertEquals(0, leased());
    }
  }

  /** HTTPS 도 같다 — 연결 하나(그래서 핸드셰이크 하나)에서 요청 20 개. TLS 근원은 Nimbus 의 기본값이다(SDK 의 호출과 같다). */
  @Test void sequentialHttpsCalls_shareOneConnectionAndOneHandshake() throws Exception {
    try (RawServer server = new RawServer(serverIp, p -> p.serveAll(ok(ACTIVE)))) {
      withTrustingNimbusDefault(() -> {
        AuthClient auth = authClient("https://127.0.0.1:" + server.port());
        for (int i = 0; i < 20; i++) assertTrue(auth.introspect("tok-" + i).isActive());
      });
      assertEquals(1, server.accepted.get(), () -> "연결 " + server.accepted + " · " + server.requests);
      assertEquals(20, server.requests.size());
    }
  }

  /**
   * 풀은 프로세스에 하나다 — AuthClient 를 호출마다 새로 만드는 소비자도 연결 하나를 함께 쓴다(HttpURLConnection 의 keep-alive 캐시와
   * 같다). 클라이언트마다 풀을 두었다면 연결이 클라이언트 수만큼 생겼을 것이다.
   */
  @Test void manyAuthClients_shareTheProcessPool() throws Exception {
    try (RawServer server = new RawServer(null, p -> p.serveAll(ok(ACTIVE)))) {
      for (int i = 0; i < 100; i++) assertTrue(authClient("http://127.0.0.1:" + server.port()).introspect("tok").isActive());
      assertEquals(1, server.accepted.get());
      assertEquals(100, server.requests.size());
    }
  }

  /**
   * 경로마다 연결은 {@value BoundedTransport#MAX_PER_ROUTE} 개까지 — 60 개를 함께 부르면 서버에 동시에 열린 연결은 50 개이고, 나머지는
   * 연결을 기다렸다가 성공한다.
   */
  @Test void concurrentCalls_areBoundedPerRoute() throws Exception {
    try (RawServer server = new RawServer(null, p -> {
      while (p.readRequest() != null) {
        Thread.sleep(300);
        p.write(ok(ACTIVE));
      }
    })) {
      AuthClient auth = authClient("http://127.0.0.1:" + server.port());
      List<FutureTask<Boolean>> calls = concurrently(60, () -> auth.introspect("tok").isActive());
      try {
        for (FutureTask<Boolean> call : calls) assertTrue(call.get(20, TimeUnit.SECONDS));
      } finally {
        cancelAll(calls);
      }
      System.out.println("[ConnectionReuseTest] 동시 60 호출 → 서버가 받아들인 연결 " + server.accepted + " · 동시에 열린 최고 "
          + server.peakOpen);
      assertEquals(BoundedTransport.MAX_PER_ROUTE, server.peakOpen.get());
      assertEquals(60, server.requests.size());
    }
  }

  // ───────────── 끊기 — 다 읽지 않은 연결은 풀로 돌아가지 않는다 ─────────────

  /**
   * 상한을 넘는 본문(끝없는 1 바이트 청크) — 거부한 연결은 읽지 않고 끊긴다: 서버의 쓰기가 곧 실패하고, 다음 호출은 새 연결이며, 그
   * 새 연결은 다시 쓰인다(연결 2 개에 요청 3 개).
   */
  @Test @Timeout(value = 30, threadMode = Timeout.ThreadMode.SEPARATE_THREAD) void aRejectedResponse_isCutAndNeverReturnedToThePool() throws Exception {
    AtomicLong written = new AtomicLong();
    AtomicLong cutAt = new AtomicLong();
    byte[] one = latin1("1\r\n \r\n");
    byte[] block = new byte[one.length * 1024];
    for (int i = 0; i < 1024; i++) System.arraycopy(one, 0, block, i * one.length, one.length);
    try (RawServer server = new RawServer(null, p -> {
      if (p.index > 1) {
        p.serveAll(ok(ACTIVE));
        return;
      }
      p.readRequest();
      p.write(latin1("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n"));
      try {
        while (true) {
          p.out.write(block);
          written.addAndGet(block.length);
        }
      } catch (IOException cut) {
        cutAt.set(System.nanoTime());
      }
    })) {
      AuthClient auth = authClient("http://127.0.0.1:" + server.port());
      KeycloakTransportException e = assertThrows(KeycloakTransportException.class, () -> auth.introspect("tok"));
      long returned = System.nanoTime();
      assertInstanceOf(CappedResponseSender.TooLarge.class, e.getCause());
      assertEquals(0, leased(), "거부한 연결이 빌린 채로 남았다");
      for (int i = 0; i < 50 && cutAt.get() == 0; i++) Thread.sleep(100);
      assertNotEquals(0, cutAt.get(), "서버의 쓰기가 실패하지 않았다 — 연결이 끊기지 않았다");
      System.out.println("[ConnectionReuseTest] 끝없는 본문 → " + e.getCause() + " · 서버가 쓴 " + written + " B · 끊김은 돌아온 뒤 "
          + Math.max(0, (cutAt.get() - returned) / 1_000_000) + " ms");
      assertTrue(auth.introspect("tok").isActive());
      assertTrue(auth.introspect("tok").isActive());
      assertEquals(2, server.accepted.get(), () -> server.requests.toString());
      assertEquals(List.of("1 POST", "2 POST", "2 POST"),
          server.requests.stream().map(r -> r.substring(0, r.indexOf(' ', 2))).collect(Collectors.toList()));
    }
  }

  /**
   * 거부가 풀의 자리를 남기지 않는다 — 경로의 상한(50)보다 많은 거부(JWKS 상한 51,200 바이트를 넘는 본문) 뒤에도 빌린 연결은 0 이고,
   * 거부마다 연결을 기다리지 않는다(자리가 새면 51 번째부터 연결 타임아웃만큼 기다려 실패했을 것이다).
   */
  @Test void rejects_neverLeakPoolSlots() throws Exception {
    byte[] tooBig = ok(new byte[60_000]);
    try (RawServer server = new RawServer(null, p -> p.serveAll(tooBig))) {
      URL certs = URI.create("http://127.0.0.1:" + server.port() + "/certs").toURL();
      NoRedirectResourceRetriever jwks = new NoRedirectResourceRetriever(2_000, 5_000);
      for (int i = 0; i < 60; i++) {
        IOException e = assertThrows(IOException.class, () -> jwks.fetch(certs), "거부 " + i);
        assertEquals("Exceeded configured input limit of 51200 bytes", e.getMessage(), "거부 " + i);
      }
      assertEquals(0, leased());
      assertEquals(60, server.accepted.get(), "거부한 연결은 다시 쓰이지 않는다");
    }
  }

  /** 다시 쓴 연결에도 틀 예산은 그대로다 — 첫 응답은 받아들이고, 같은 연결의 두 번째 응답(채운 청크 크기 줄)은 거부한다. */
  @Test void aReusedConnection_stillEnforcesTheWireBudget() throws Exception {
    ByteArrayOutputStream padded = new ByteArrayOutputStream();
    padded.writeBytes(latin1("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n"));
    byte[] chunk = latin1("0".repeat(8_000) + "1\r\n \r\n");
    for (int i = 0; i < 60; i++) padded.writeBytes(chunk);
    padded.writeBytes(latin1("0\r\n\r\n"));
    byte[] keys = ok(utf8("{\"keys\":[{\"kty\":\"oct\",\"kid\":\"k1\",\"k\":\"AAAA\"}]}"));
    try (RawServer server = new RawServer(null, p -> {
      p.readRequest();
      p.write(keys);
      p.readRequest();
      p.write(padded.toByteArray());
      p.readRequest();
    })) {
      URL certs = URI.create("http://127.0.0.1:" + server.port() + "/certs").toURL();
      NoRedirectResourceRetriever jwks = new NoRedirectResourceRetriever(2_000, 5_000);
      assertNotNull(jwks.fetch(certs));
      IOException e = assertThrows(IOException.class, () -> jwks.fetch(certs));
      assertEquals("HTTP response body framing exceeds 409600 bytes on the wire", e.getMessage());
      assertEquals(1, server.accepted.get(), "두 번째 조회는 다시 쓴 연결이어야 한다");
    }
  }

  // ───────────── 묻지 않은 바이트 ─────────────

  /**
   * 응답 뒤에 서버가 더 보낸 바이트(다음 응답처럼 생긴 「EVIL」)는 다음 호출의 응답이 되지 않는다 — 다시 쓰려는 연결에 묻지 않은 바이트가
   * 와 있으면 그 연결은 버리고 새 연결을 맺는다. 204 · Content-Length 0 · 본문 · 청크 본문 뒤에 같은 쓰기로 붙인 것(평문 · TLS)과, 평문에서
   * 앞 응답을 다 읽은 뒤 늦게 도착한 것. HttpURLConnection 은 응답마다 새 버퍼로 읽어 버퍼에 남은 것을 버렸다(실측 — 다음 호출은 서버의
   * 답을 기다렸다).
   */
  @Test @Timeout(value = 60, threadMode = Timeout.ThreadMode.SEPARATE_THREAD)
  void bytesSentAfterAResponse_areNeverReadAsTheNextResponse() throws Exception {
    String evil = "HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\nEVIL";
    java.util.Map<String, String> outcomes = new java.util.LinkedHashMap<>();
    outcomes.put("204 뒤", secondCallAfter(null, "HTTP/1.1 204 No Content\r\n\r\n" + evil, null));
    outcomes.put("Content-Length 0 뒤", secondCallAfter(null, "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n" + evil, null));
    outcomes.put("본문 뒤", secondCallAfter(null, "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}" + evil, null));
    outcomes.put("청크 본문 뒤",
        secondCallAfter(null, "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\n{}\r\n0\r\n\r\n" + evil, null));
    outcomes.put("204 뒤 늦게(평문)", secondCallAfter(null, "HTTP/1.1 204 No Content\r\n\r\n", evil));
    outcomes.put("204 뒤(TLS)", secondCallAfter(serverIp, "HTTP/1.1 204 No Content\r\n\r\n" + evil, null));
    System.out.println("[ConnectionReuseTest] 응답 뒤에 붙인 바이트 → " + outcomes);
    assertTrue(outcomes.values().stream().allMatch("GOOD · 연결 2"::equals), outcomes::toString);
  }

  /**
   * 첫 연결은 첫 요청에 {@code first}(뒤에 붙은 바이트 포함)를 보내고, {@code late} 가 있으면 100 ms 뒤 그것을 더 보낸 다음 답하지 않는다
   * (두 번째 요청이 이 연결로 오면 응답 대신 그 바이트를 읽거나 기다린다). 뒤의 연결은 「GOOD」 을 답한다. 두 번째 호출의 본문과 연결 수.
   */
  private static String secondCallAfter(SSLContext tls, String first, String late) throws Exception {
    try (RawServer server = new RawServer(tls, p -> {
      if (p.index > 1) {
        p.serveAll(latin1("HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\nGOOD"));
        return;
      }
      p.readRequest();
      p.write(latin1(first));
      if (late != null) {
        Thread.sleep(100);
        p.write(latin1(late));
      }
      p.readRequest();
      Thread.sleep(20_000);
    })) {
      String url = (tls == null ? "http" : "https") + "://127.0.0.1:" + server.port() + "/x";
      CappedResponseSender.send(get(url), "token");
      Thread.sleep(300);
      try {
        return String.valueOf(CappedResponseSender.send(get(url), "token").getBody()).trim() + " · 연결 " + server.accepted.get();
      } catch (IOException e) {
        return e + " · 연결 " + server.accepted.get();
      }
    }
  }

  private static HTTPRequest get(String url) throws IOException {
    HTTPRequest req = new HTTPRequest(HTTPRequest.Method.GET, URI.create(url).toURL());
    req.setConnectTimeout(2_000);
    req.setReadTimeout(3_000);
    req.setFollowRedirects(false);
    req.setSSLSocketFactory(trusting);
    return req;
  }

  // ───────────── TLS 근원 ─────────────

  /**
   * 연결은 같은 TLS 근원의 교환만 다시 쓴다 — 받아들이는 검증기로 맺은 연결을 거부하는 검증기의 교환이 다시 쓰지 않는다(새 연결에서
   * 검증하고 거부한다). HttpURLConnection 은 소켓 팩토리만 가려 이 교환이 검증 없이 성공했다. 원래 근원의 교환은 첫 연결을 다시 쓴다.
   */
  @Test void aPooledConnection_isReusedOnlyUnderTheSameTlsConfig() throws Exception {
    try (RawServer server = new RawServer(serverOther, p -> p.serveAll(ok(ACTIVE)))) {
      String url = "https://127.0.0.1:" + server.port() + "/token";
      assertEquals(200, CappedResponseSender.send(post(url, trusting, ACCEPTS_LOOPBACK, 5_000), "token").getStatusCode());
      IOException rejected = assertThrows(IOException.class,
          () -> CappedResponseSender.send(post(url, trusting, REJECTS, 5_000), "token"));
      assertEquals("HTTPS hostname wrong:  should be <127.0.0.1>", rejected.getMessage());
      assertEquals(200, CappedResponseSender.send(post(url, trusting, ACCEPTS_LOOPBACK, 5_000), "token").getStatusCode());
      assertEquals(2, server.accepted.get(), () -> server.requests.toString());
      assertEquals(List.of("1 POST /token HTTP/1.1", "1 POST /token HTTP/1.1"), server.requests);
    }
  }

  // ───────────── 쉬는 동안 닫힌 연결 ─────────────

  /**
   * 쉬는 동안 서버가 닫은 연결(Connection: close 없이)을 곧바로 다시 쓰면 응답 바이트 하나 없이 끊긴다 — 그때만 새 연결로 한 번 다시
   * 보낸다. 서버는 그 요청을 한 번 받는다.
   */
  @Test void aConnectionTheServerClosedWhileIdle_isSentAgainOnce() throws Exception {
    try (RawServer server = new RawServer(null, p -> {
      if (p.index == 1) {
        p.readRequest();
        p.write(ok(ACTIVE));
        return; // 닫는다
      }
      p.serveAll(ok(ACTIVE));
    })) {
      AuthClient auth = authClient("http://127.0.0.1:" + server.port());
      assertTrue(auth.introspect("tok").isActive());
      Thread.sleep(200); // 서버의 FIN 이 닿을 시간 — 빌려줄 때 보는 시간(2 초)보다 짧다
      assertTrue(auth.introspect("tok").isActive());
      assertEquals(2, server.accepted.get());
      assertEquals(List.of("1 POST", "2 POST"),
          server.requests.stream().map(r -> r.substring(0, r.indexOf(' ', 2))).collect(Collectors.toList()));
    }
  }

  /** 새 연결이 응답 없이 끊기면 다시 보내지 않는다 — 서버가 처리했을지 모르는 요청(인가 코드·회전하는 refresh 토큰)을 두 번 보내지 않게. */
  @Test void aFreshConnectionThatGetsNoResponse_isNotSentAgain() throws Exception {
    try (RawServer server = new RawServer(null, Peer::readRequest)) {
      AuthClient auth = authClient("http://127.0.0.1:" + server.port());
      KeycloakTransportException e = assertThrows(KeycloakTransportException.class, () -> auth.introspect("tok"));
      assertEquals(BoundedTransport.INVALID_RESPONSE, e.getCause().getMessage());
      assertEquals(1, server.accepted.get());
      assertEquals(1, server.requests.size());
    }
  }

  /** 다시 보낸 시도도 응답 없이 끊기면 거기서 끝난다 — 한 번만 다시 보낸다(서버는 그 요청을 두 번까지만 받는다). */
  @Test void theStaleRetry_isMadeOnlyOnce() throws Exception {
    try (RawServer server = new RawServer(null, p -> {
      p.readRequest();
      if (p.index == 1) p.write(ok(ACTIVE)); // 첫 연결만 답하고 닫는다 · 다음 연결은 받고 답하지 않고 닫는다
    })) {
      AuthClient auth = authClient("http://127.0.0.1:" + server.port());
      assertTrue(auth.introspect("tok").isActive());
      Thread.sleep(200);
      KeycloakTransportException e = assertThrows(KeycloakTransportException.class, () -> auth.introspect("tok"));
      assertEquals(BoundedTransport.INVALID_RESPONSE, e.getCause().getMessage());
      assertEquals(2, server.accepted.get());
      assertEquals(2, server.requests.size(), () -> server.requests.toString());
    }
  }

  /**
   * 다시 보내기는 새 연결로 간다 — 함께 쉬던 연결 둘이 모두 죽었으면(서버가 둘 다 닫았다) 첫 시도가 하나를 빌려 끊기고, 다시 보내기는 다른
   * 죽은 연결이 아니라 새 연결을 맺는다(다시 보내기 전에 쉬는 연결을 닫는다). 그 호출은 성공한다 — 다시 보내기가 남은 죽은 연결을
   * 빌렸다면 두 시도 모두 끊겨 실패했을 것이다.
   */
  @Test void theStaleRetry_goesOutOnAFreshConnection_evenWhenOtherPooledConnectionsAreStale() throws Exception {
    java.util.concurrent.CountDownLatch both = new java.util.concurrent.CountDownLatch(2);
    try (RawServer server = new RawServer(null, p -> {
      if (p.index <= 2) {
        p.readRequest();
        both.countDown();
        assertTrue(both.await(10, TimeUnit.SECONDS)); // 둘 다 열린 채로 답한다 — 풀에 연결 둘이 쉬게
        p.write(ok(ACTIVE));
        Thread.sleep(100);
        return; // 닫는다(Connection: close 없이)
      }
      p.serveAll(ok(ACTIVE));
    })) {
      AuthClient auth = authClient("http://127.0.0.1:" + server.port());
      List<FutureTask<Boolean>> pair = concurrently(2, () -> auth.introspect("tok").isActive());
      try {
        for (FutureTask<Boolean> call : pair) assertTrue(call.get(10, TimeUnit.SECONDS));
      } finally {
        cancelAll(pair);
      }
      Thread.sleep(300); // 두 연결의 FIN 이 닿을 시간 — 빌려줄 때 보는 시간(2 초)보다 짧다
      assertTrue(auth.introspect("c").isActive());
      assertEquals(3, server.accepted.get(), () -> server.requests.toString());
    }
  }

  /** 쉬는 동안 RST 로 끊긴 연결 — 다시 쓰면 연결 재설정(SocketException)이고, 응답 바이트 없이 끊긴 것이라 한 번 다시 보낸다. */
  @Test void aConnectionTheServerResetWhileIdle_isSentAgainOnce() throws Exception {
    try (RawServer server = new RawServer(null, p -> {
      if (p.index == 1) {
        p.readRequest();
        p.write(ok(ACTIVE));
        p.socket.setSoLinger(true, 0); // 닫으며 RST
        return;
      }
      p.serveAll(ok(ACTIVE));
    })) {
      AuthClient auth = authClient("http://127.0.0.1:" + server.port());
      assertTrue(auth.introspect("tok").isActive());
      Thread.sleep(200);
      assertTrue(auth.introspect("tok").isActive());
      assertEquals(2, server.accepted.get());
      assertEquals(List.of("1 POST", "2 POST"),
          server.requests.stream().map(r -> r.substring(0, r.indexOf(' ', 2))).collect(Collectors.toList()));
    }
  }

  /**
   * 다시 쓴 연결에서 서버가 요청을 다 읽고 답 없이 닫으면(응답 바이트 0 — NoHttpResponseException) 한 번 다시 보낸다. ⚠️ 그래서 서버는
   * 그 요청을 두 번 받는다 — 응답 바이트가 없으면 처리됐는지 알 수 없다. HttpURLConnection 도 이때 다시 보냈다(새 연결이어도).
   */
  @Test void aReusedConnectionClosedAfterReadingTheRequest_isSentAgainOnce() throws Exception {
    try (RawServer server = new RawServer(null, p -> {
      if (p.index == 1) {
        p.readRequest();
        p.write(ok(ACTIVE));
        p.readRequest(); // 다 읽고 답 없이 닫는다
        return;
      }
      p.serveAll(ok(ACTIVE));
    })) {
      AuthClient auth = authClient("http://127.0.0.1:" + server.port());
      assertTrue(auth.introspect("tok").isActive());
      assertTrue(auth.introspect("tok").isActive());
      assertEquals(2, server.accepted.get());
      assertEquals(List.of("1 POST", "1 POST", "2 POST"),
          server.requests.stream().map(r -> r.substring(0, r.indexOf(' ', 2))).collect(Collectors.toList()));
    }
  }

  /**
   * 다시 쓴 연결이라도 응답이 오기 시작한 뒤 끊기면 다시 보내지 않는다(서버가 처리했을 수 있다) — 서버가 100 Continue 를 보내고 닫으면
   * 그 호출은 실패하고 새 연결을 맺지 않는다.
   */
  @Test void aReusedConnectionThatStartedAnswering_isNotSentAgain() throws Exception {
    try (RawServer server = new RawServer(null, p -> {
      p.readRequest();
      p.write(ok(ACTIVE));
      p.readRequest();
      p.write(latin1("HTTP/1.1 100 Continue\r\n\r\n")); // 그리고 닫는다
    })) {
      AuthClient auth = authClient("http://127.0.0.1:" + server.port());
      assertTrue(auth.introspect("tok").isActive());
      assertThrows(KeycloakTransportException.class, () -> auth.introspect("tok"));
      assertEquals(1, server.accepted.get());
      assertEquals(2, server.requests.size());
    }
  }

  /** 다시 쓴 연결의 읽기 타임아웃은 다시 보내지 않는다 — 서버가 받아 처리하는 중일 수 있다. 실패는 그 타임아웃 한 번이다. */
  @Test void aTimeoutOnAReusedConnection_isNotSentAgain() throws Exception {
    try (RawServer server = new RawServer(null, p -> {
      p.readRequest();
      p.write(ok(ACTIVE));
      p.readRequest();
      Thread.sleep(5_000);
    })) {
      AuthClient auth = authClient("http://127.0.0.1:" + server.port(), Duration.ofSeconds(1));
      assertTrue(auth.introspect("tok").isActive());
      KeycloakTransportException e = assertThrows(KeycloakTransportException.class, () -> auth.introspect("tok"));
      assertInstanceOf(SocketTimeoutException.class, e.getCause());
      assertEquals(1, server.accepted.get());
      assertEquals(2, server.requests.size());
    }
  }

  /**
   * 경로의 연결 50 개가 모두 쓰이는 동안 연결 타임아웃(1 초)이 지나면, 연결을 기다리던 호출은 JDK 의 타임아웃이다(응답과 무관한 상수
   * 메시지 — 연결을 빌리지 못했으니 끊을 것도 없다). 연결을 쥔 호출들은 그대로 끝난다.
   */
  @Test @Timeout(value = 30, threadMode = Timeout.ThreadMode.SEPARATE_THREAD) void aCallThatCannotGetAPooledConnection_timesOutAfterTheConnectTimeout() throws Exception {
    java.util.concurrent.CountDownLatch busy = new java.util.concurrent.CountDownLatch(BoundedTransport.MAX_PER_ROUTE);
    try (RawServer server = new RawServer(null, p -> {
      p.readRequest();
      busy.countDown();
      Thread.sleep(3_000);
      p.write(ok(ACTIVE));
    })) {
      String base = "http://127.0.0.1:" + server.port();
      AuthClient holder = authClient(base, Duration.ofSeconds(10));
      List<FutureTask<Boolean>> holders = concurrently(BoundedTransport.MAX_PER_ROUTE, () -> holder.introspect("tok").isActive());
      try {
        assertTrue(busy.await(10, TimeUnit.SECONDS), "연결 50 개가 차지 않았다");
        AuthClient waiting = authClient(base, Duration.ofSeconds(1), Duration.ofSeconds(10));
        long start = System.nanoTime();
        KeycloakTransportException e = assertThrows(KeycloakTransportException.class, () -> waiting.introspect("tok"));
        long millis = (System.nanoTime() - start) / 1_000_000;
        assertInstanceOf(SocketTimeoutException.class, e.getCause());
        assertEquals(BoundedTransport.POOL_TIMEOUT, e.getCause().getMessage());
        assertTrue(millis >= 900 && millis < 2_900, () -> millis + " ms");
        for (FutureTask<Boolean> call : holders) assertTrue(call.get(20, TimeUnit.SECONDS));
      } finally {
        cancelAll(holders);
      }
      assertEquals(BoundedTransport.MAX_PER_ROUTE, server.accepted.get());
      assertEquals(0, leased());
    }
  }

  /**
   * {@value BoundedTransport#VALIDATE_AFTER_MILLIS} ms 넘게 쉰 연결은 빌려줄 때 살아 있는지 본다 — 서버가 반쯤 닫은(보내기만 닫고 받기는
   * 연) 연결에 요청을 보내지 않고 새 연결을 맺는다. 서버는 반쯤 닫은 연결에서 요청을 받지 않는다.
   */
  @Test void aConnectionIdleLongerThanTheValidationWindow_isCheckedBeforeReuse() throws Exception {
    try (RawServer server = new RawServer(null, p -> {
      if (p.index == 1) {
        p.readRequest();
        p.write(ok(ACTIVE));
        p.socket.shutdownOutput();
        p.readRequest(); // 들어오면 적힌다 — 들어오면 안 된다
        return;
      }
      p.serveAll(ok(ACTIVE));
    })) {
      AuthClient auth = authClient("http://127.0.0.1:" + server.port());
      assertTrue(auth.introspect("tok").isActive());
      Thread.sleep(BoundedTransport.VALIDATE_AFTER_MILLIS + 300L);
      assertTrue(auth.introspect("tok").isActive());
      assertEquals(List.of("1 POST", "2 POST"),
          server.requests.stream().map(r -> r.substring(0, r.indexOf(' ', 2))).collect(Collectors.toList()));
    }
  }

  /**
   * 쉬는 연결의 수명({@value BoundedTransport#IDLE_MILLIS} ms)은 스레드 없이 지킨다 — 수명이 지난 연결은 다음 교환(어느 경로든)이
   * 닫는다. 그 전에는 아무것도 닫지 않는다(백그라운드 스레드가 없다). 서버가 {@code Keep-Alive} 를 주지 않으면 HttpClient 의 기본은
   * 무한이다.
   */
  @Test @Timeout(value = 30, threadMode = Timeout.ThreadMode.SEPARATE_THREAD) void anExpiredIdleConnection_isClosedByTheNextExchange_withoutAThread() throws Exception {
    AtomicLong closedAt = new AtomicLong();
    try (RawServer a = new RawServer(null, p -> {
      p.serveAll(ok(ACTIVE));
      closedAt.set(System.nanoTime());
    });
         RawServer b = new RawServer(null, p -> p.serveAll(ok(ACTIVE)))) {
      assertTrue(authClient("http://127.0.0.1:" + a.port()).introspect("tok").isActive());
      Set<String> before = threadNames();
      Thread.sleep(BoundedTransport.IDLE_MILLIS + 300L);
      assertEquals(0, closedAt.get(), "수명이 지났어도 교환이 없으면 아무것도 닫지 않는다(스레드가 없다)");
      long exchange = System.nanoTime();
      assertTrue(authClient("http://127.0.0.1:" + b.port()).introspect("tok").isActive());
      for (int i = 0; i < 50 && closedAt.get() == 0; i++) Thread.sleep(20);
      assertNotEquals(0, closedAt.get(), "다음 교환이 수명이 지난 연결을 닫지 않았다");
      assertTrue(closedAt.get() >= exchange);
      Set<String> created = threadNames();
      created.removeAll(before);
      created.removeIf(name -> name.startsWith("reuse-raw-"));
      assertEquals(Set.of(), created, "운송이 스레드를 만들었다");
    }
  }

  private static Set<String> threadNames() {
    return Thread.getAllStackTraces().keySet().stream().filter(Thread::isAlive).map(Thread::getName)
        .collect(Collectors.toCollection(java.util.TreeSet::new));
  }

  /**
   * 교환 중의 Error(여기서는 검증기가 던진 AssertionError)는 그대로 나가고 풀을 닫지 않는다 — HttpClient 는 그때 관리자를 닫는데, 이
   * 풀은 프로세스에 하나라 그러면 이 JVM 의 auth·JWKS 레인이 끝난다. 그 교환이 쥔 연결은 돌아가지 않고 끊긴다.
   */
  @Test void anErrorInsideAnExchange_doesNotShutThePoolDown() throws Exception {
    try (RawServer server = new RawServer(serverOther, p -> p.serveAll(ok(ACTIVE)))) {
      String url = "https://127.0.0.1:" + server.port() + "/token";
      HostnameVerifier throwing = (host, session) -> {
        throw new AssertionError("검증기 실패");
      };
      assertThrows(AssertionError.class, () -> CappedResponseSender.send(post(url, trusting, throwing, 5_000), "token"));
      assertEquals(0, leased());
      assertEquals(200, CappedResponseSender.send(post(url, trusting, ACCEPTS_LOOPBACK, 5_000), "token").getStatusCode());
    }
  }

  // ───────────── 소켓 타임아웃 — 풀의 소켓 설정이 아니라 교환의 읽기 타임아웃 ─────────────

  /** TCP 는 받지만 TLS 핸드셰이크에 답하지 않는 서버 — 교환의 읽기 타임아웃(1 초)에 끝난다. */
  @Test @Timeout(value = 15, threadMode = Timeout.ThreadMode.SEPARATE_THREAD) void aStalledTlsHandshake_isBoundedByTheReadTimeout() throws Exception {
    try (RawServer silent = new RawServer(null, p -> Thread.sleep(20_000))) {
      long start = System.nanoTime();
      IOException e = assertThrows(IOException.class, () -> CappedResponseSender.send(
          post("https://127.0.0.1:" + silent.port() + "/token", trusting, ACCEPTS_LOOPBACK, 1_000), "token"));
      long millis = (System.nanoTime() - start) / 1_000_000;
      assertInstanceOf(SocketTimeoutException.class, e);
      assertTrue(millis < 5_000, () -> millis + " ms");
    }
  }

  /** CONNECT 를 받고 답하지 않는 프록시 — 교환의 읽기 타임아웃(1 초)에 끝난다. */
  @Test @Timeout(value = 15, threadMode = Timeout.ThreadMode.SEPARATE_THREAD) void aStalledProxyConnect_isBoundedByTheReadTimeout() throws Exception {
    try (RawServer proxy = new RawServer(null, p -> {
      p.readRequest();
      Thread.sleep(20_000);
    })) {
      String host = System.getProperty("https.proxyHost");
      String port = System.getProperty("https.proxyPort");
      try {
        System.setProperty("https.proxyHost", "127.0.0.1");
        System.setProperty("https.proxyPort", String.valueOf(proxy.port()));
        long start = System.nanoTime();
        IOException e = assertThrows(IOException.class, () -> CappedResponseSender.send(
            post("https://kc.invalid/token", trusting, ACCEPTS_LOOPBACK, 1_000), "token"));
        long millis = (System.nanoTime() - start) / 1_000_000;
        assertInstanceOf(SocketTimeoutException.class, e);
        assertTrue(millis < 5_000, () -> millis + " ms");
        assertTrue(proxy.requests.get(0).endsWith("CONNECT kc.invalid:443 HTTP/1.1"), () -> proxy.requests.toString());
      } finally {
        if (host == null) System.clearProperty("https.proxyHost");
        else System.setProperty("https.proxyHost", host);
        if (port == null) System.clearProperty("https.proxyPort");
        else System.setProperty("https.proxyPort", port);
      }
    }
  }

  // ───────────── 조용한 TLS 서버 앞의 거부 — 닫기가 기다리지 않는다 ─────────────

  /**
   * TLS 1.3 을 닫을 때 JSSE 는 받은 바이트가 없으면 읽기 타임아웃만큼 한 번 더 읽어 기다린다 — 거부한 뒤 조용한(닫지도 않는) 서버 앞에서
   * 그만큼 늦었다(실측 8,025 ms · 12,206 ms). 거부의 네 자리가 읽기 타임아웃(8 초)을 기다리지 않는다.
   */
  @Test @Timeout(value = 60, threadMode = Timeout.ThreadMode.SEPARATE_THREAD) void aRejectAgainstASilentTlsServer_doesNotWaitForTheReadTimeout() throws Exception {
    List<String> slow = new ArrayList<>();
    // 상태 줄이 아닌 첫 줄 뒤 조용하다 — 머리 단계의 거부(실행기)
    rejectFast(slow, "머리 단계", serverIp, ACCEPTS_LOOPBACK, p -> {
      p.readRequest();
      p.write(latin1("HTTP/1.1 abc Weird\r\n"));
      Thread.sleep(20_000);
    }, BoundedTransport.INVALID_RESPONSE);
    // 상한보다 긴 본문을 알리고 상한+1 바이트 뒤 조용하다 — 본문 단계의 거부(교환의 끝)
    rejectFast(slow, "상한+1 뒤 멈춤", serverIp, ACCEPTS_LOOPBACK, p -> {
      p.readRequest();
      p.write(latin1("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: " + (CAP + 10) + "\r\n\r\n"));
      p.write(new byte[CAP + 1]);
      Thread.sleep(20_000);
    }, "token response exceeds 1048576 bytes");
    // 핸드셰이크 뒤 아무것도 보내지도 읽지도 않는다(세션 티켓도 없다) — 검증기의 거부(HttpURLConnection 의 checkURLSpoofing)
    rejectFast(slow, "검증기 거부", serverOtherWithoutTickets, REJECTS, p -> Thread.sleep(20_000),
        "HTTPS hostname wrong:  should be <127.0.0.1>");
    assertTrue(slow.isEmpty(), () -> String.join("\n", slow));
  }

  private static void rejectFast(List<String> slow, String label, SSLContext tls, HostnameVerifier verifier, Handler handler,
                                 String message) throws Exception {
    try (RawServer server = new RawServer(tls, handler)) {
      long start = System.nanoTime();
      IOException e = assertThrows(IOException.class, () -> CappedResponseSender.send(
          post("https://127.0.0.1:" + server.port() + "/token", trusting, verifier, 8_000), "token"), label);
      long millis = (System.nanoTime() - start) / 1_000_000;
      System.out.println("[ConnectionReuseTest] 조용한 TLS 서버 · " + label + " → " + e + " · " + millis + " ms (읽기 타임아웃 8,000)");
      assertEquals(message, e.getMessage(), label);
      if (millis >= 4_000) slow.add(label + ": " + millis + " ms");
    }
  }

  /**
   * 본문 중간에서 멈춘 서버 — 읽기 타임아웃(2 초)에 한 번 끝나고, 그 연결을 닫으며 한 번 더 기다리지 않는다(JSSE 가 닫기에서 읽기
   * 타임아웃을 또 기다리면 4 초였다).
   */
  @Test @Timeout(value = 30, threadMode = Timeout.ThreadMode.SEPARATE_THREAD) void aBodyStalledMidway_timesOutOnce() throws Exception {
    try (RawServer server = new RawServer(serverIp, p -> {
      p.readRequest();
      p.write(latin1("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 1000\r\n\r\n{\"acti"));
      Thread.sleep(20_000);
    })) {
      long start = System.nanoTime();
      IOException e = assertThrows(IOException.class, () -> CappedResponseSender.send(
          post("https://127.0.0.1:" + server.port() + "/token", trusting, ACCEPTS_LOOPBACK, 2_000), "token"));
      long millis = (System.nanoTime() - start) / 1_000_000;
      System.out.println("[ConnectionReuseTest] 본문 중간에서 멈춘 TLS 서버 → " + e + " · " + millis + " ms (읽기 타임아웃 2,000)");
      assertInstanceOf(SocketTimeoutException.class, e);
      assertTrue(millis < 3_500, () -> millis + " ms");
    }
  }
}
