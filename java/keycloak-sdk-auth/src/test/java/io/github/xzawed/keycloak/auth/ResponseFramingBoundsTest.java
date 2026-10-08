package io.github.xzawed.keycloak.auth;

import static org.junit.jupiter.api.Assertions.*;

import com.nimbusds.common.contenttype.ContentType;
import com.nimbusds.jose.util.Resource;
import com.nimbusds.oauth2.sdk.http.HTTPRequest;
import com.nimbusds.oauth2.sdk.http.HTTPResponse;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.io.PrintWriter;
import java.io.StringWriter;
import java.lang.management.ManagementFactory;
import java.net.InetAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.net.URI;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.Arrays;
import java.util.concurrent.atomic.AtomicLong;
import org.junit.jupiter.api.Assumptions;
import org.junit.jupiter.api.Test;

/**
 * 응답의 <b>틀</b>(헤더 줄·청크 크기 줄·청크 확장·트레일러)과 상한을 넘는 본문의 <b>닫기</b>가 SDK 의 상한에 비례해 묶이는가 —
 * auth 레인({@link CappedResponseSender})과 JWKS 레인({@link NoRedirectResourceRetriever}).
 *
 * <p>왜: 본문 상한(1 MiB · JWKS 51,200)은 SDK 가 요청하는 본문 바이트만 센다. 짧은 청크 본문 뒤 EOF 까지 읽으면 운송이
 * 트레일러를 담고, 상한을 넘은 본문을 거부하며 연결을 닫으면 운송이 나머지를 비운다 — 둘 다 그 운송의 몫이다. JDK
 * ({@code sun.net} ChunkedInputStream)는 트레일러에 한도가 없었고(4 KiB 줄 32 MiB → 토큰 수락 · 163 MiB 할당, 한 줄 1 MiB →
 * 16.4 GB · 5 초 — 등록부 {@code jvm-chunked-trailers-unbounded}), 평문 청크 닫기는 쌓인 바이트의 제곱 비용이었다(리눅스 3.7–13.9 초
 * — {@code close-drain-time-unbounded}).
 *
 * <p>⚠️ 닫기 시험({@code anEndless…})의 차이는 <b>리눅스에서만</b> 보인다 — JDK 의 닫기는 소켓에 이미 쌓인 바이트를 읽는데, Windows
 * 루프백의 수신 버퍼는 작아 그 양이 1 MB 아래였다(TokenResponseCapTest 클래스 설명의 실측). 그래서 이 시험의 적색은 Docker
 * 리눅스에서 잰다(커밋 메시지). 할당은 호출 스레드의 몫이다 — 예열 뒤에 잰다.
 *
 * <p>응답 인용 검사는 원인 사슬 전체({@code printStackTrace})에 표식이 없어야 하고, 사슬에 하위 운송의 타입
 * ({@code org.apache.http.*})이 없어야 한다(§4 — 호출부가 원인을 그대로 단다).
 */
class ResponseFramingBoundsTest {
  private static final int CAP = 1_048_576;
  private static final byte[] TOKEN = utf8("{\"access_token\":\"AT\",\"token_type\":\"Bearer\",\"expires_in\":300}");
  private static final byte[] JWKS = utf8("{\"keys\":[{\"kty\":\"oct\",\"kid\":\"k1\",\"k\":\"AAAA\"}]}");
  /** 거부의 어느 표현에도 찍히면 안 되는 응답 바이트. */
  private static final String MARKER = "ZframeMARKER0123456789";
  /** 32 MiB 트레일러·한 줄 1 MiB 트레일러·16 MiB 헤더 줄·청크 확장을 거부하는 호출 하나가 써도 되는 할당 — 상한의 16 배. */
  private static final long FRAMING_BOUND = 16L * CAP;
  /**
   * 1 바이트 청크로 끝없이 오는 본문을 상한에서 거부하는 호출 하나의 할당 한도. 상한+1 바이트를 읽는 동안 청크 머리 백만 개를
   * 해석하므로 상한의 수십 배가 정상이다(실측 HttpCore ≈ 37 MB) — 닫기가 비우던 때는 리눅스에서 32–153 GB 였다.
   */
  private static final long ENDLESS_BODY_BOUND = 96L * CAP;

  // ───────────── 응답 ─────────────

  /** 서버가 쓰는 응답 — 끝없는 응답은 클라이언트가 떠나 쓰기가 실패할 때까지 쓴다. */
  @FunctionalInterface
  private interface Reply {
    void write(OutputStream out, RawServer server) throws IOException;
  }

  private static byte[] utf8(String s) {
    return s.getBytes(StandardCharsets.UTF_8);
  }

  private static byte[] latin1(String s) {
    return s.getBytes(StandardCharsets.ISO_8859_1);
  }

  private static void chunkedHead(OutputStream out, byte[] body) throws IOException {
    out.write(latin1("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n"
        + Integer.toHexString(body.length) + "\r\n"));
    out.write(body);
    out.write(latin1("\r\n"));
  }

  private static void repeat(OutputStream out, RawServer server, byte[] block, long total) throws IOException {
    for (long left = total; left > 0 && !server.stop; ) {
      int k = (int) Math.min(block.length, left);
      out.write(block, 0, k);
      left -= k;
    }
  }

  private static byte[] filled(int size, char c) {
    byte[] b = new byte[size];
    Arrays.fill(b, (byte) c);
    return b;
  }

  /** 짧은 청크 본문 뒤 4 KiB 트레일러 줄을 {@code total} 바이트. */
  private static Reply manyTrailers(byte[] body, long total) {
    return (out, server) -> {
      chunkedHead(out, body);
      out.write(latin1("0\r\n"));
      byte[] line = filled(4096, 'A');
      System.arraycopy(latin1("X-Trail-x: "), 0, line, 0, 11);
      line[4094] = '\r';
      line[4095] = '\n';
      repeat(out, server, line, total);
      out.write(latin1("\r\n"));
    };
  }

  /** 짧은 청크 본문 뒤 {@code size} 바이트짜리 트레일러 한 줄. */
  private static Reply oneTrailer(byte[] body, int size) {
    return (out, server) -> {
      chunkedHead(out, body);
      out.write(latin1("0\r\nX-Trail-Big: "));
      repeat(out, server, filled(64 * 1024, 'A'), size);
      out.write(latin1("\r\n\r\n"));
    };
  }

  /** {@code size} 바이트짜리 응답 헤더 한 줄 — 그 뒤는 멀쩡한 Content-Length 본문. */
  private static Reply oneHeaderLine(byte[] body, int size) {
    return (out, server) -> {
      out.write(latin1("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nX-Big: "));
      repeat(out, server, filled(64 * 1024, 'B'), size);
      out.write(latin1("\r\nContent-Length: " + body.length + "\r\n\r\n"));
      out.write(body);
    };
  }

  /** 둘째 청크의 크기 줄에 {@code size} 바이트짜리 청크 확장. */
  private static Reply chunkExtension(byte[] body, int size) {
    return (out, server) -> {
      chunkedHead(out, body);
      out.write(latin1("1;x="));
      repeat(out, server, filled(64 * 1024, 'A'), size);
      out.write(latin1("\r\n \r\n0\r\n\r\n"));
    };
  }

  /** 짧은 청크 본문 뒤 1 바이트 청크를 64 KiB 덩이로 끝없이 — 전속력으로 쓰는 서버. */
  private static Reply endlessOneByteChunks(byte[] body) {
    return (out, server) -> {
      chunkedHead(out, body);
      byte[] one = latin1("1\r\n \r\n");
      byte[] block = new byte[one.length * 10_922];
      for (int i = 0; i < 10_922; i++) System.arraycopy(one, 0, block, i * one.length, one.length);
      while (!server.stop) out.write(block);
    };
  }

  /** 응답 바이트를 그대로 쓴다. */
  private static Reply raw(String response) {
    return (out, server) -> out.write(latin1(response));
  }

  /** 1xx 중간 응답을 끝없이 — 각 응답에 표식을 싣는다. */
  private static Reply endlessInterim() {
    return (out, server) -> {
      byte[] interim = latin1("HTTP/1.1 103 Early Hints\r\nLink: </" + MARKER + ">; rel=preload\r\n\r\n");
      while (!server.stop) out.write(interim);
    };
  }

  /** 상태 줄 대신 짧은 쓰레기 줄을 끝없이. */
  private static Reply endlessGarbage() {
    return (out, server) -> {
      byte[] line = latin1(MARKER + "\r\n");
      while (!server.stop) out.write(line);
    };
  }

  // ───────────── 서버 ─────────────

  /** 원시 HTTP 서버 — 요청 머리와 Content-Length 본문을 읽고 응답을 쓴다. 쓴 바이트를 센다. */
  private static final class RawServer implements AutoCloseable {
    final ServerSocket socket;
    final Reply reply;
    final AtomicLong written = new AtomicLong();
    volatile boolean stop;

    RawServer(Reply reply) throws IOException {
      this.reply = reply;
      socket = new ServerSocket(0, 50, InetAddress.getLoopbackAddress());
      Thread t = new Thread(this::serve, "raw-framing-server");
      t.setDaemon(true);
      t.start();
    }

    int port() {
      return socket.getLocalPort();
    }

    private void serve() {
      while (!stop) {
        try (Socket s = socket.accept()) {
          s.setSoTimeout(10_000);
          InputStream in = s.getInputStream();
          int contentLength = readRequestHead(in);
          in.readNBytes(contentLength);
          OutputStream out = new OutputStream() {
            final OutputStream sink = s.getOutputStream();

            @Override public void write(int b) throws IOException {
              sink.write(b);
              written.incrementAndGet();
            }

            @Override public void write(byte[] b, int off, int len) throws IOException {
              sink.write(b, off, len);
              written.addAndGet(len);
            }
          };
          reply.write(out, this);
          out.flush();
          s.shutdownOutput();
          while (in.read() >= 0) { /* 클라이언트가 닫을 때까지 */ }
        } catch (IOException clientLeft) {
          // 클라이언트가 떠났다 — 끝없는 응답의 정상 결말이다
        }
      }
    }

    /** 요청 머리를 읽고 Content-Length 를 돌려준다(없으면 0). */
    private static int readRequestHead(InputStream in) throws IOException {
      ByteArrayOutputStream head = new ByteArrayOutputStream();
      int last4 = 0;
      for (int b = in.read(); b != -1; b = in.read()) {
        head.write(b);
        last4 = (last4 << 8) | b;
        if (last4 == 0x0d0a0d0a) break;
      }
      for (String line : head.toString(StandardCharsets.ISO_8859_1).split("\r\n")) {
        if (line.regionMatches(true, 0, "Content-Length:", 0, 15)) return Integer.parseInt(line.substring(15).trim());
      }
      return 0;
    }

    @Override public void close() throws IOException {
      stop = true;
      socket.close();
    }
  }

  // ───────────── 레인 ─────────────

  private static HTTPRequest tokenRequest(int port) throws IOException {
    HTTPRequest req = new HTTPRequest(HTTPRequest.Method.POST, URI.create("http://127.0.0.1:" + port + "/token").toURL());
    req.setEntityContentType(ContentType.APPLICATION_URLENCODED);
    req.setBody("grant_type=client_credentials");
    req.setConnectTimeout(5_000);
    req.setReadTimeout(20_000);
    req.setFollowRedirects(false); // AuthClient.applyTimeouts 와 같다
    return req;
  }

  private static URL certs(int port) throws IOException {
    return URI.create("http://127.0.0.1:" + port + "/certs").toURL();
  }

  /** 레인 호출의 결과 — 던진 것(없으면 null)·호출 스레드의 할당·벽시계 시간. */
  private record Outcome(Throwable thrown, long allocated, long millis) {
    String describe() {
      return (thrown == null ? "accepted" : thrown.getClass().getName() + ": " + thrown.getMessage())
          + " · allocated " + allocated + " B · " + millis + " ms";
    }
  }

  @FunctionalInterface
  private interface Call {
    void run(int port) throws Exception;
  }

  private static final Call AUTH = port -> CappedResponseSender.send(tokenRequest(port), "token");
  private static final Call JWKS_LANE = port -> new NoRedirectResourceRetriever(5_000, 20_000).retrieveResource(certs(port));

  /** {@code reply} 를 내는 서버에 레인을 한 번 부르고 잰다 — 같은 레인을 작은 정상 응답으로 먼저 예열한다. */
  private static Outcome measure(Call lane, Reply reply) throws Exception {
    warm(lane);
    com.sun.management.ThreadMXBean threads = allocationCounter();
    try (RawServer server = new RawServer(reply)) {
      long before = threads.getCurrentThreadAllocatedBytes();
      long start = System.nanoTime();
      Throwable thrown = null;
      try {
        lane.run(server.port());
      } catch (Throwable t) {
        thrown = t;
      }
      return new Outcome(thrown, threads.getCurrentThreadAllocatedBytes() - before, (System.nanoTime() - start) / 1_000_000);
    }
  }

  private static void warm(Call lane) throws Exception {
    byte[] body = lane == AUTH ? TOKEN : JWKS;
    try (RawServer server = new RawServer(raw("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: "
        + body.length + "\r\n\r\n" + new String(body, StandardCharsets.UTF_8)))) {
      lane.run(server.port());
    }
  }

  private static com.sun.management.ThreadMXBean allocationCounter() {
    java.lang.management.ThreadMXBean bean = ManagementFactory.getThreadMXBean();
    Assumptions.assumeTrue(bean instanceof com.sun.management.ThreadMXBean t && t.isThreadAllocatedMemorySupported()
        && t.isThreadAllocatedMemoryEnabled(), "스레드 할당 계수기가 없는 JVM");
    return (com.sun.management.ThreadMXBean) bean;
  }

  /** 거부의 계약 — IOException · 원인 사슬에 표식도 하위 운송의 타입도 없다. */
  private static void expectRejectedWithoutQuoting(String label, Throwable thrown) {
    assertInstanceOf(IOException.class, thrown, () -> label + ": IOException 으로 거부해야 한다 — " + thrown);
    StringWriter trace = new StringWriter();
    thrown.printStackTrace(new PrintWriter(trace, true));
    assertFalse(trace.toString().contains(MARKER), () -> label + ": 거부가 응답 바이트를 인용했다:\n" + trace);
    for (Throwable t = thrown; t != null; t = t.getCause()) {
      Throwable at = t;
      assertFalse(at.getClass().getName().startsWith("org.apache.http."),
          () -> label + ": 하위 운송의 예외 타입이 원인 사슬에 남았다 — " + at.getClass().getName());
    }
  }

  // ───────────── 트레일러 (jvm-chunked-trailers-unbounded) ─────────────

  @Test void auth_manyTrailerLines_areRejectedWithBoundedAllocation() throws Exception {
    Outcome o = measure(AUTH, manyTrailers(TOKEN, 32L << 20));
    System.out.println("[ResponseFramingBoundsTest] auth 32 MiB 트레일러 → " + o.describe());
    expectRejectedWithoutQuoting("auth 32 MiB 트레일러", o.thrown());
    assertTrue(o.allocated() < FRAMING_BOUND, () -> "auth 32 MiB 트레일러: " + o.describe());
  }

  @Test void auth_oneHugeTrailerLine_isRejectedWithBoundedAllocation() throws Exception {
    Outcome o = measure(AUTH, oneTrailer(TOKEN, 1 << 20));
    System.out.println("[ResponseFramingBoundsTest] auth 1 MiB 트레일러 한 줄 → " + o.describe());
    expectRejectedWithoutQuoting("auth 1 MiB 트레일러 한 줄", o.thrown());
    assertTrue(o.allocated() < FRAMING_BOUND, () -> "auth 1 MiB 트레일러 한 줄: " + o.describe());
  }

  @Test void jwks_manyTrailerLines_areRejected() throws Exception {
    Outcome o = measure(JWKS_LANE, manyTrailers(JWKS, 32L << 20));
    System.out.println("[ResponseFramingBoundsTest] jwks 32 MiB 트레일러 → " + o.describe());
    expectRejectedWithoutQuoting("jwks 32 MiB 트레일러", o.thrown());
  }

  @Test void jwks_oneHugeTrailerLine_isRejectedPromptly() throws Exception {
    Outcome o = measure(JWKS_LANE, oneTrailer(JWKS, 1 << 20));
    System.out.println("[ResponseFramingBoundsTest] jwks 1 MiB 트레일러 한 줄 → " + o.describe());
    expectRejectedWithoutQuoting("jwks 1 MiB 트레일러 한 줄", o.thrown());
    assertTrue(o.millis() < 3_000, () -> "jwks 1 MiB 트레일러 한 줄: " + o.describe());
  }

  // ───────────── 헤더 줄·청크 확장 (운송의 줄 한도) ─────────────

  @Test void auth_aHugeHeaderLine_isRejectedWithBoundedAllocation() throws Exception {
    Outcome o = measure(AUTH, oneHeaderLine(TOKEN, 16 << 20));
    System.out.println("[ResponseFramingBoundsTest] auth 16 MiB 헤더 줄 → " + o.describe());
    expectRejectedWithoutQuoting("auth 16 MiB 헤더 줄", o.thrown());
    assertTrue(o.allocated() < FRAMING_BOUND, () -> "auth 16 MiB 헤더 줄: " + o.describe());
  }

  @Test void auth_aHugeChunkExtension_isRejectedWithBoundedAllocation() throws Exception {
    Outcome o = measure(AUTH, chunkExtension(TOKEN, 16 << 20));
    System.out.println("[ResponseFramingBoundsTest] auth 16 MiB 청크 확장 → " + o.describe());
    expectRejectedWithoutQuoting("auth 16 MiB 청크 확장", o.thrown());
    assertTrue(o.allocated() < FRAMING_BOUND, () -> "auth 16 MiB 청크 확장: " + o.describe());
  }

  // ───────────── 상한을 넘은 본문의 닫기 (close-drain-time-unbounded) ─────────────

  /** 끝없는 1 바이트 청크 본문 — 상한에서 거부하고 곧바로 돌아온다(닫기가 나머지를 비우지 않는다). */
  @Test void auth_anEndlessChunkedBody_isRefusedPromptly() throws Exception {
    // 닫기가 나머지를 비우면 끝없는 본문에서 돌아오지 않는다 — 빌드를 붙잡지 않고 실패하게 시간을 건다
    Outcome o = assertTimeoutPreemptively(Duration.ofSeconds(30), () -> measure(AUTH, endlessOneByteChunks(TOKEN)));
    System.out.println("[ResponseFramingBoundsTest] auth 끝없는 1 바이트 청크 → " + o.describe());
    assertInstanceOf(CappedResponseSender.TooLarge.class, o.thrown(), o::describe);
    assertTrue(o.millis() < 5_000, () -> "auth 끝없는 1 바이트 청크: " + o.describe());
    assertTrue(o.allocated() < ENDLESS_BODY_BOUND, () -> "auth 끝없는 1 바이트 청크: " + o.describe());
  }

  /** JWKS 레인 — 51,200 바이트 상한에서 거부하고 곧바로 돌아온다. */
  @Test void jwks_anEndlessChunkedBody_isRefusedPromptly() throws Exception {
    Outcome o = assertTimeoutPreemptively(Duration.ofSeconds(30), () -> measure(JWKS_LANE, endlessOneByteChunks(JWKS)));
    System.out.println("[ResponseFramingBoundsTest] jwks 끝없는 1 바이트 청크 → " + o.describe());
    assertInstanceOf(IOException.class, o.thrown(), o::describe);
    assertEquals("Exceeded configured input limit of 51200 bytes", o.thrown().getMessage());
    assertTrue(o.millis() < 5_000, () -> "jwks 끝없는 1 바이트 청크: " + o.describe());
  }

  /** 짧은 청크 본문 뒤 1 바이트 청크를 끝없이 — 크기 줄마다 0 을 {@code zeros} 개 채운다(「0000…01」, 값은 1). */
  private static Reply endlessPaddedChunks(byte[] body, int zeros) {
    return (out, server) -> {
      chunkedHead(out, body);
      byte[] chunk = new byte[zeros + 6];
      Arrays.fill(chunk, 0, zeros, (byte) '0');
      System.arraycopy(latin1("1\r\n \r\n"), 0, chunk, zeros, 6);
      while (!server.stop) out.write(chunk);
    };
  }

  /** 1 바이트 청크 {@code count} 개 — 본문 상한 안의 멀쩡한(그러나 잘게 나눈) 청크 본문. */
  private static Reply tinyChunks(byte[] body, int count) {
    return (out, server) -> {
      chunkedHead(out, body);
      byte[] one = latin1("1\r\n \r\n");
      for (int i = 0; i < count; i++) out.write(one);
      out.write(latin1("0\r\n\r\n"));
    };
  }

  /**
   * 크기 줄을 줄 한도까지 채운 1 바이트 청크(Grok 레그 A 의 지적 — 재현: 청크 200,000 개에 1.6 GB 를 받아 할당하고 4.0 초, 그리고
   * 받아들였다). 본문을 읽는 동안 받은 틀이 본문 상한의 8 배를 넘으면 거부한다 — 두 레인 모두 곧바로, 할당이 묶인 채로.
   */
  @Test void paddedChunkSizeLines_areRefusedOnTheWireBudget() throws Exception {
    for (Call lane : new Call[] {AUTH, JWKS_LANE}) {
      String name = lane == AUTH ? "auth" : "jwks";
      long cap = lane == AUTH ? CAP : 51_200;
      Outcome o = assertTimeoutPreemptively(Duration.ofSeconds(30),
          () -> measure(lane, endlessPaddedChunks(lane == AUTH ? TOKEN : JWKS, 8000)));
      System.out.println("[ResponseFramingBoundsTest] " + name + " 채운 크기 줄의 1 바이트 청크 → " + o.describe());
      assertInstanceOf(IOException.class, o.thrown(), o::describe);
      assertEquals("HTTP response body framing exceeds " + 8 * cap + " bytes on the wire", o.thrown().getMessage());
      assertTrue(o.millis() < 5_000, () -> name + ": " + o.describe());
      assertTrue(o.allocated() < 8 * FRAMING_BOUND, () -> name + ": " + o.describe());
    }
  }

  /** 대조 — 상한 안의 본문을 1 바이트 청크로 잘게 나눠도(틀이 본문의 6 배) 두 레인 모두 받아들인다. */
  @Test void control_tinyChunksUnderTheCap_areAccepted() throws Exception {
    try (RawServer server = new RawServer(tinyChunks(TOKEN, 100_000))) {
      HTTPResponse response = CappedResponseSender.send(tokenRequest(server.port()), "token");
      assertEquals(200, response.getStatusCode());
      assertEquals(TOKEN.length + 100_000 + System.lineSeparator().length(), response.getBody().length());
    }
    try (RawServer server = new RawServer(tinyChunks(JWKS, 40_000))) {
      Resource r = new NoRedirectResourceRetriever(5_000, 20_000).retrieveResource(certs(server.port()));
      assertEquals(JWKS.length + 40_000, r.getContent().length());
    }
  }

  // ───────────── 끝없는 머리 ─────────────

  /** 1xx 중간 응답을 끝없이 보내는 서버 — 곧바로 IOException 으로 끝난다(시간·할당이 응답 수를 따르지 않는다). */
  @Test void auth_endlessInterimResponses_areRefusedPromptly() throws Exception {
    Outcome o = assertTimeoutPreemptively(Duration.ofSeconds(30), () -> measure(AUTH, endlessInterim()));
    System.out.println("[ResponseFramingBoundsTest] auth 끝없는 1xx → " + o.describe());
    expectRejectedWithoutQuoting("auth 끝없는 1xx", o.thrown());
    assertTrue(o.millis() < 5_000, () -> "auth 끝없는 1xx: " + o.describe());
  }

  /** 상태 줄 대신 쓰레기 줄을 끝없이 보내는 서버 — 첫 줄에서 거부한다(JDK 처럼 「Invalid Http response」). */
  @Test void auth_endlessGarbageBeforeTheStatusLine_isRefusedPromptly() throws Exception {
    Outcome o = assertTimeoutPreemptively(Duration.ofSeconds(30), () -> measure(AUTH, endlessGarbage()));
    System.out.println("[ResponseFramingBoundsTest] auth 끝없는 쓰레기 줄 → " + o.describe());
    expectRejectedWithoutQuoting("auth 끝없는 쓰레기 줄", o.thrown());
    assertTrue(o.millis() < 5_000, () -> "auth 끝없는 쓰레기 줄: " + o.describe());
  }

  // ───────────── 거부가 응답 바이트를 인용하지 않는다 ─────────────

  /** 틀이 깨진 응답 — 청크 크기 줄·트레일러 줄·상태 줄·첫 줄에 표식. 각 레인이 IOException 으로 거부하고 표식을 싣지 않는다. */
  @Test void malformedFraming_isRejectedWithoutQuotingTheResponse() throws Exception {
    String chunked = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n";
    String[][] cases = {
        {"청크 크기 줄", chunked + hex(TOKEN) + "\r\n%BODY%\r\n" + MARKER + "\r\nxx\r\n0\r\n\r\n"},
        {"트레일러 줄", chunked + hex(TOKEN) + "\r\n%BODY%\r\n0\r\n" + MARKER + "\r\n\r\n"},
        {"상태 줄", "HTTP/1.1 abc " + MARKER + "\r\nContent-Length: 2\r\n\r\n{}"},
        {"첫 줄", MARKER + "\r\nHTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}"},
    };
    for (Call lane : new Call[] {AUTH, JWKS_LANE}) {
      String name = lane == AUTH ? "auth" : "jwks";
      byte[] body = lane == AUTH ? TOKEN : JWKS;
      for (String[] c : cases) {
        String response = c[1].replace("%BODY%", new String(body, StandardCharsets.UTF_8));
        Outcome o = measure(lane, raw(response));
        System.out.println("[ResponseFramingBoundsTest] " + name + " " + c[0] + " 표식 → " + o.describe());
        expectRejectedWithoutQuoting(name + " " + c[0], o.thrown());
      }
    }
  }

  private static String hex(byte[] body) {
    return Integer.toHexString(body.length);
  }

  /** 대조 — 같은 서버의 멀쩡한 청크 응답(트레일러 둘)은 두 레인 모두 받아들인다(위 거부가 서버 고장이 아님을 보인다). */
  @Test void control_wellFormedChunkedResponsesWithTrailers_areAccepted() throws Exception {
    String trailers = "0\r\nX-Trail-A: one\r\nX-Trail-B: two\r\n\r\n";
    try (RawServer server = new RawServer((out, s) -> {
      chunkedHead(out, TOKEN);
      out.write(latin1(trailers));
    })) {
      assertEquals(200, CappedResponseSender.send(tokenRequest(server.port()), "token").getStatusCode());
    }
    try (RawServer server = new RawServer((out, s) -> {
      chunkedHead(out, JWKS);
      out.write(latin1(trailers));
    })) {
      Resource r = new NoRedirectResourceRetriever(5_000, 20_000).retrieveResource(certs(server.port()));
      assertEquals(new String(JWKS, StandardCharsets.UTF_8), r.getContent());
    }
  }
}
