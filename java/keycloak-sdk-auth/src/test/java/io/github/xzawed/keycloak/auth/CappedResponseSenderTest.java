package io.github.xzawed.keycloak.auth;

import static org.junit.jupiter.api.Assertions.*;

import com.nimbusds.common.contenttype.ContentType;
import com.nimbusds.oauth2.sdk.http.HTTPRequest;
import com.nimbusds.oauth2.sdk.http.HTTPResponse;
import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;
import io.github.xzawed.keycloak.core.ResponseLimits;
import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.ServerSocket;
import java.net.SocketTimeoutException;
import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicReference;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

/**
 * {@link CappedResponseSender} 단위 — Nimbus {@code HTTPRequest.send()} 와 같은 응답을 만들되(상한 안) 본문을 상한까지만 읽는다.
 * 레인별 공개 API 계약은 {@code TokenResponseCapTest}(keycloak-sdk 모듈)가 진다.
 *
 * <p>⚠️ 대조의 기준은 Nimbus 의 {@code send()} 자신이다 — 같은 서버, 같은 응답에 둘을 붙여 상태·메시지·헤더·본문 문자열이 같은지 본다.
 * 그래서 「상한 이하의 본문은 지금과 똑같이 동작한다」가 줄 끝 정규화({@code line.separator})·잘못된 UTF-8 의 대체 문자까지 잰다.
 */
class CappedResponseSenderTest {
  private static final int CAP = 1_048_576;

  private HttpServer server;
  private final AtomicReference<Reply> reply = new AtomicReference<>();
  private final AtomicInteger redirectTargetHits = new AtomicInteger();

  /**
   * {@code body} 가 null 이면 본문 없음(-1). {@code location} 이 있으면 그 헤더를 단다. {@code stallMs} 만큼 늦게 답한다. 같음·해시는
   * 배열의 내용으로 정한다(record 의 기본은 배열의 참조를 비교한다) — 문자열은 1 MiB 를 늘어놓지 않게 본문의 길이만 적는다.
   */
  private record Reply(int status, byte[] body, String location, int stallMs) {
    Reply(int status, byte[] body) {
      this(status, body, null, 0);
    }

    @Override public boolean equals(Object o) {
      if (!(o instanceof Reply r)) return false;
      return status == r.status && stallMs == r.stallMs && Arrays.equals(body, r.body)
          && java.util.Objects.equals(location, r.location);
    }

    @Override public int hashCode() {
      return java.util.Objects.hash(status, Arrays.hashCode(body), location, stallMs);
    }

    @Override public String toString() {
      return "Reply[status=" + status + ", body=" + (body == null ? "null" : body.length + " bytes") + ", location=" + location
          + ", stallMs=" + stallMs + "]";
    }
  }

  @BeforeEach void start() throws IOException {
    server = HttpServer.create(new InetSocketAddress(InetAddress.getLoopbackAddress(), 0), 0);
    server.createContext("/token", this::handle);
    server.createContext("/elsewhere", ex -> {
      redirectTargetHits.incrementAndGet();
      ex.sendResponseHeaders(200, -1);
      ex.close();
    });
    server.start();
  }

  @AfterEach void stop() {
    server.stop(0);
  }

  private void handle(HttpExchange ex) throws IOException {
    ex.getRequestBody().readAllBytes();
    Reply r = reply.get();
    if (r.stallMs() > 0) {
      try {
        Thread.sleep(r.stallMs());
      } catch (InterruptedException e) {
        Thread.currentThread().interrupt();
      }
    }
    if (r.location() != null) ex.getResponseHeaders().add("Location", r.location());
    ex.getResponseHeaders().add("Content-Type", "application/json");
    try {
      if (r.body() == null) {
        ex.sendResponseHeaders(r.status(), -1);
      } else {
        ex.sendResponseHeaders(r.status(), r.body().length == 0 ? -1 : r.body().length);
        try (OutputStream os = ex.getResponseBody()) {
          os.write(r.body());
        }
      }
    } catch (IOException clientWentAway) {
      // 상한에서 끊었다
    } finally {
      ex.close();
    }
  }

  private HTTPRequest post(int readTimeoutMs) throws IOException {
    HTTPRequest req = new HTTPRequest(HTTPRequest.Method.POST,
        URI.create("http://127.0.0.1:" + server.getAddress().getPort() + "/token").toURL());
    req.setEntityContentType(ContentType.APPLICATION_URLENCODED);
    req.setBody("grant_type=client_credentials");
    req.setConnectTimeout(5_000);
    req.setReadTimeout(readTimeoutMs);
    req.setFollowRedirects(false); // AuthClient.applyTimeouts 와 같다
    return req;
  }

  private static byte[] utf8(String s) {
    return s.getBytes(StandardCharsets.UTF_8);
  }

  private static byte[] concat(byte[]... parts) {
    ByteArrayOutputStream out = new ByteArrayOutputStream();
    for (byte[] p : parts) out.write(p, 0, p.length);
    return out.toByteArray();
  }

  @Test void theCapIsTheSharedLiteral() {
    assertEquals(CAP, ResponseLimits.MAX_TOKEN_RESPONSE_BYTES);
  }

  /**
   * (1) 상한 안의 응답은 Nimbus {@code send()} 와 같다 — 상태·메시지·Content-Type·Location·본문 문자열. 줄 끝(CRLF·CR·LF)은
   * Nimbus 처럼 {@code line.separator} 로 바뀌고 마지막 줄 뒤에도 붙으며, 잘못된 UTF-8 은 같은 대체 문자가 되고, 빈 본문·본문 없는
   * 오류 상태는 둘 다 본문이 없다. 오류 상태(400)는 오류 스트림에서, 3xx 는 따라가지 않고 그대로 읽는다.
   */
  @Test void withinTheCap_theResponseIsWhatNimbusSendBuilds() throws IOException {
    List<Reply> replies = List.of(
        new Reply(200, utf8("{\"access_token\":\"AT\",\"token_type\":\"Bearer\",\"expires_in\":300}")),
        new Reply(200, utf8("{\"a\":1}\r\n{\"b\":2}")),
        new Reply(200, utf8("x\ry\nz\r\n\n")),
        new Reply(200, concat(utf8("{\"access_token\":\"bad"), new byte[] {(byte) 0xC3, (byte) 0x28}, utf8("\"}"))),
        new Reply(200, new byte[0]),
        new Reply(400, utf8("{\"error\":\"invalid_grant\",\"error_description\":\"no\"}")),
        new Reply(401, null),
        new Reply(302, null, "/elsewhere", 0),
        new Reply(200, padded(CAP)));
    List<String> wrong = new ArrayList<>();
    for (Reply r : replies) {
      reply.set(r);
      HTTPResponse stock = post(10_000).send();
      HTTPResponse capped = CappedResponseSender.send(post(10_000), "token");
      String label = r.status() + " " + (r.body() == null ? "(no body)" : r.body().length + " bytes");
      if (stock.getStatusCode() != capped.getStatusCode()) wrong.add(label + ": status " + capped.getStatusCode());
      if (!java.util.Objects.equals(stock.getStatusMessage(), capped.getStatusMessage())) wrong.add(label + ": message");
      if (!java.util.Objects.equals(stock.getHeaderValue("Content-Type"), capped.getHeaderValue("Content-Type"))) {
        wrong.add(label + ": Content-Type " + capped.getHeaderValue("Content-Type"));
      }
      if (!java.util.Objects.equals(stock.getHeaderValue("Location"), capped.getHeaderValue("Location"))) {
        wrong.add(label + ": Location " + capped.getHeaderValue("Location"));
      }
      if (!java.util.Objects.equals(stock.getBody(), capped.getBody())) {
        wrong.add(label + ": body differs (stock " + length(stock.getBody()) + " chars, capped " + length(capped.getBody()) + ")");
      }
    }
    assertEquals(0, redirectTargetHits.get(), "3xx 를 따라가면 안 된다(SSRF 하드닝)");
    assertTrue(wrong.isEmpty(), () -> String.join("\n", wrong));
  }

  private static String length(String s) {
    return s == null ? "null" : String.valueOf(s.length());
  }

  /** 출력이 없는 요청(GET)도 Nimbus 와 같다 — 출력 스트림을 열지 않는다. */
  @Test void aRequestWithoutABody_isSentLikeNimbusSendsIt() throws IOException {
    reply.set(new Reply(200, utf8("{\"ok\":true}")));
    HTTPRequest get = new HTTPRequest(HTTPRequest.Method.GET,
        URI.create("http://127.0.0.1:" + server.getAddress().getPort() + "/token").toURL());
    HTTPResponse capped = CappedResponseSender.send(get, "token");
    assertEquals(200, capped.getStatusCode());
    assertEquals(get.send().getBody(), capped.getBody());
  }

  /** (2) 상한+1 이면 성공 상태든 오류 상태든 본문을 인용하지 않는 {@link CappedResponseSender.TooLarge} 다. */
  @Test void oneByteAboveTheCap_isTooLarge_forSuccessAndErrorStatuses() throws IOException {
    for (int status : new int[] {200, 400}) {
      byte[] body = padded(CAP + 1);
      reply.set(new Reply(status, body));
      IOException e = assertThrows(IOException.class, () -> CappedResponseSender.send(post(10_000), "introspection"));
      assertInstanceOf(CappedResponseSender.TooLarge.class, e);
      assertEquals("introspection response exceeds 1048576 bytes", e.getMessage());
      assertNull(e.getCause());
    }
  }

  /** 연결조차 못 하면(상태 -1) Nimbus 처럼 그 IOException 을 그대로 던진다. */
  @Test void noResponseAtAll_propagatesTheTransportFailure() throws IOException {
    int closedPort;
    try (ServerSocket s = new ServerSocket(0, 1, InetAddress.getLoopbackAddress())) {
      closedPort = s.getLocalPort();
    }
    HTTPRequest req = new HTTPRequest(HTTPRequest.Method.POST, URI.create("http://127.0.0.1:" + closedPort + "/token").toURL());
    req.setConnectTimeout(2_000);
    req.setReadTimeout(2_000);
    IOException e = assertThrows(IOException.class, () -> CappedResponseSender.send(req, "token"));
    assertFalse(e instanceof CappedResponseSender.TooLarge);
  }

  /**
   * 상태 줄을 해석할 수 없으면 {@code getInputStream} 이 던지고 {@code getResponseCode} 는 -1 이다(실측 — 「HTTP/1.1 abc」·HTTP 가
   * 아닌 줄). 그때는 Nimbus {@code send()} 처럼 첫 IOException 을 그대로 던진다 — 상태 -1 의 응답을 지어내지 않는다.
   */
  @Test void anUnparseableStatusLine_rethrowsTheFirstFailureLikeNimbus() throws Exception {
    try (ServerSocket raw = new ServerSocket(0, 5, InetAddress.getLoopbackAddress())) {
      Thread t = new Thread(() -> {
        for (int i = 0; i < 2; i++) {
          try (java.net.Socket s = raw.accept()) {
            InputStream in = s.getInputStream();
            int last4 = 0;
            for (int b = in.read(); b != -1; b = in.read()) {
              last4 = (last4 << 8) | b;
              if (last4 == 0x0d0a0d0a) break;
            }
            in.readNBytes(29); // grant_type=client_credentials
            s.getOutputStream().write("HTTP/1.1 abc Weird\r\nContent-Length: 2\r\n\r\n{}".getBytes(StandardCharsets.ISO_8859_1));
          } catch (IOException ignored) {
            // 클라이언트가 끊었다
          }
        }
      });
      t.setDaemon(true);
      t.start();
      HTTPRequest stockReq = new HTTPRequest(HTTPRequest.Method.POST, URI.create("http://127.0.0.1:" + raw.getLocalPort() + "/token").toURL());
      stockReq.setBody("grant_type=client_credentials");
      stockReq.setReadTimeout(5_000);
      IOException stock = assertThrows(IOException.class, stockReq::send);
      HTTPRequest cappedReq = new HTTPRequest(HTTPRequest.Method.POST, URI.create("http://127.0.0.1:" + raw.getLocalPort() + "/token").toURL());
      cappedReq.setBody("grant_type=client_credentials");
      cappedReq.setReadTimeout(5_000);
      IOException capped = assertThrows(IOException.class, () -> CappedResponseSender.send(cappedReq, "token"));
      assertEquals(stock.getClass(), capped.getClass());
      assertEquals(stock.getMessage().replaceAll("\\d+", "N"), capped.getMessage().replaceAll("\\d+", "N"));
    }
  }

  /** 읽기 타임아웃은 Nimbus 의 연결 설정 그대로다 — 늦은 응답은 SocketTimeoutException 이다. */
  @Test void theReadTimeoutIsKept() {
    reply.set(new Reply(200, utf8("{}"), null, 1_500));
    assertThrows(SocketTimeoutException.class, () -> CappedResponseSender.send(post(300), "token"));
  }

  // ───────────── 읽기 — 상한+1 바이트 너머를 요청하지 않는다 ─────────────

  /** 정확히 상한이면 그 바이트 전부, 상한+1 이면 null — 끝없는 본문에도 상한+1 바이트 너머를 요청하지 않는다. */
  @Test void readWithinCap_neverAsksForMoreThanCapPlusOne() throws IOException {
    byte[] atCap = padded(CAP);
    assertArrayEquals(atCap, CappedResponseSender.readWithinCap(new ByteArrayInputStream(atCap)));
    EndlessBody endless = new EndlessBody(CAP + 1L);
    assertNull(CappedResponseSender.readWithinCap(endless));
    assertEquals(CAP + 1L, endless.served, "넘침을 알아챌 한 바이트까지 읽어야 한다");
    assertArrayEquals(new byte[0], CappedResponseSender.readWithinCap(new ByteArrayInputStream(new byte[0])));
  }

  /** 끝없는 본문 — {@code limit} 바이트 너머를 요청하기만 해도 시험을 깬다(실제 소켓이라면 그만큼 읽혔을 것이다). */
  private static final class EndlessBody extends InputStream {
    private final long limit;
    long served;

    EndlessBody(long limit) {
      this.limit = limit;
    }

    @Override public int read() {
      throw new AssertionError("한 바이트씩 읽지 않는다");
    }

    @Override public int read(byte[] b, int off, int len) {
      if (len == 0) return 0;
      if (len > limit - served) {
        throw new AssertionError(served + " 바이트 뒤에서 " + len + " 바이트를 더 요청했다 — 상한+1 = " + limit);
      }
      Arrays.fill(b, off, off + len, (byte) ' ');
      served += len;
      return len;
    }
  }

  /** 쓸 수 있는 토큰 뒤를 JSON 공백으로 채워 정확히 {@code size} 바이트. */
  private static byte[] padded(int size) {
    byte[] body = new byte[size];
    Arrays.fill(body, (byte) ' ');
    byte[] head = utf8("{\"access_token\":\"AT\",\"token_type\":\"Bearer\",\"expires_in\":300}");
    System.arraycopy(head, 0, body, 0, head.length);
    return body;
  }
}
