package io.github.xzawed.keycloak.admin;

import static org.junit.jupiter.api.Assertions.*;

import io.github.xzawed.keycloak.core.KeycloakConfig;
import io.github.xzawed.keycloak.core.exception.KeycloakTransportException;
import jakarta.ws.rs.client.Client;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.io.PrintWriter;
import java.io.StringWriter;
import java.lang.management.ManagementFactory;
import java.lang.reflect.Field;
import java.net.InetAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.concurrent.atomic.AtomicInteger;
import org.apache.http.client.config.RequestConfig;
import org.apache.http.config.MessageConstraints;
import org.apache.http.impl.conn.PoolingHttpClientConnectionManager;
import org.jboss.resteasy.client.jaxrs.ResteasyClient;
import org.jboss.resteasy.client.jaxrs.engines.ApacheHttpClient43Engine;
import org.junit.jupiter.api.Assumptions;
import org.junit.jupiter.api.Test;

/**
 * admin 레인의 응답 <b>틀</b> — RESTEasy 가 쓰는 HttpCore 는 응답 머리 줄·헤더 수·트레일러에 한도가 없었다(기본
 * {@code MessageConstraints} -1). 짧은 청크 본문 뒤 4 KiB 트레일러 줄 32 MiB 를 토큰 응답이 달고 오면 토큰은 받아들여지고 호출
 * 하나가 66–89 MiB 를 더 할당했다(등록부 {@code jvm-chunked-trailers-unbounded}). 그리고 HttpCore 의 틀 오류는 응답 바이트를 메시지에
 * 싣는다(「Bad chunk header: &lt;줄&gt;」 · 「Invalid footer: Invalid header: &lt;줄&gt;」 — {@code jvm-admin-token-guard-residuals}
 * (3)).
 *
 * <p>계약: (1) {@link AdminClient#buildTimeoutClient} 의 엔진은 auth 레인과 같은 줄·헤더 수 한도를 건다 — 풀 크기(50)와
 * 타임아웃은 그대로다. (2) 트레일러가 한도를 넘는 응답은 토큰이든 admin 자원이든 {@link KeycloakTransportException} 으로 실패하고
 * 호출 스레드의 할당이 묶인다. (3) 틀이 깨진 응답의 거부는 그 줄을 인용하지 않는다. 네트워크는 로컬 루프백만 쓴다.
 */
class AdminResponseFramingTest {
  private static final int CAP = 1_048_576;
  private static final String REALM = "r";
  private static final String TOKEN_PATH = "/realms/" + REALM + "/protocol/openid-connect/token";
  private static final String MARKER = "ZadminFrameMARKER0123";
  private static final byte[] TOKEN = utf8("{\"access_token\":\"good\",\"token_type\":\"Bearer\",\"expires_in\":300}");
  private static final byte[] USER = utf8("{\"id\":\"x\",\"username\":\"alice\"}");
  /** 32 MiB 트레일러를 거부하는 admin 호출 하나가 써도 되는 할당(클라이언트 조립 밖) — 상한의 16 배. 수정 전 66–89 MiB 를 더 썼다. */
  private static final long FRAMING_BOUND = 16L * CAP;

  @FunctionalInterface
  private interface Reply {
    void write(OutputStream out) throws IOException;
  }

  private static byte[] utf8(String s) {
    return s.getBytes(StandardCharsets.UTF_8);
  }

  private static byte[] latin1(String s) {
    return s.getBytes(StandardCharsets.ISO_8859_1);
  }

  private static Reply lengthDelimited(byte[] body) {
    return out -> {
      out.write(latin1("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: " + body.length + "\r\n\r\n"));
      out.write(body);
    };
  }

  private static void chunkedHead(OutputStream out, byte[] body) throws IOException {
    out.write(latin1("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n"
        + Integer.toHexString(body.length) + "\r\n"));
    out.write(body);
    out.write(latin1("\r\n"));
  }

  /** 짧은 청크 본문 뒤 4 KiB 트레일러 줄 32 MiB. */
  private static Reply manyTrailers(byte[] body) {
    return out -> {
      chunkedHead(out, body);
      out.write(latin1("0\r\n"));
      byte[] line = new byte[4096];
      Arrays.fill(line, (byte) 'A');
      System.arraycopy(latin1("X-Trail-x: "), 0, line, 0, 11);
      line[4094] = '\r';
      line[4095] = '\n';
      for (int i = 0; i < 8192; i++) out.write(line);
      out.write(latin1("\r\n"));
    };
  }

  /** 짧은 청크 본문 뒤 둘째 청크 크기 줄 자리에 표식. */
  private static Reply badChunkHeader(byte[] body) {
    return out -> {
      chunkedHead(out, body);
      out.write(latin1(MARKER + "\r\nxx\r\n0\r\n\r\n"));
    };
  }

  /** 짧은 청크 본문 뒤 콜론 없는 트레일러 줄에 표식. */
  private static Reply badTrailer(byte[] body) {
    return out -> {
      chunkedHead(out, body);
      out.write(latin1("0\r\n" + MARKER + "\r\n\r\n"));
    };
  }

  /** 응답 머리에 콜론 없는 헤더 줄(표식) — 그 뒤는 멀쩡한 Content-Length 본문. */
  private static Reply colonlessHeader(byte[] body) {
    return out -> {
      out.write(latin1("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" + MARKER + "\r\nContent-Length: " + body.length
          + "\r\n\r\n"));
      out.write(body);
    };
  }

  /** 상태 코드 자리에 표식. */
  private static Reply badStatusLine(byte[] body) {
    return out -> {
      out.write(latin1("HTTP/1.1 " + MARKER + " OK\r\nContent-Type: application/json\r\nContent-Length: " + body.length
          + "\r\n\r\n"));
      out.write(body);
    };
  }

  /** 미디어 타입 없는 2xx 청크 본문 뒤 둘째 청크 크기 줄 자리에 표식(등록부의 후보 — extractResult 의 finally close). */
  private static Reply untypedBadChunkHeader(byte[] body) {
    return out -> {
      out.write(latin1("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n" + Integer.toHexString(body.length) + "\r\n"));
      out.write(body);
      out.write(latin1("\r\n" + MARKER + "\r\nxx\r\n0\r\n\r\n"));
    };
  }

  /** 원시 HTTP 서버 — 토큰 엔드포인트와 admin 사용자 엔드포인트에 각자의 응답을 낸다. 연결마다 응답 하나 뒤 닫는다. */
  private static final class RawServer implements AutoCloseable {
    final ServerSocket socket;
    final AtomicInteger adminHits = new AtomicInteger();
    volatile Reply token = lengthDelimited(TOKEN);
    volatile Reply users = lengthDelimited(USER);
    volatile boolean stop;

    RawServer() throws IOException {
      socket = new ServerSocket(0, 50, InetAddress.getLoopbackAddress());
      Thread t = new Thread(this::serve, "raw-admin-framing-server");
      t.setDaemon(true);
      t.start();
    }

    int port() {
      return socket.getLocalPort();
    }

    private void serve() {
      while (!stop) {
        Socket s;
        try {
          s = socket.accept();
        } catch (IOException closed) {
          return;
        }
        Thread t = new Thread(() -> answer(s), "raw-admin-framing-exchange");
        t.setDaemon(true);
        t.start();
      }
    }

    private void answer(Socket s) {
      try (s) {
        s.setSoTimeout(10_000);
        InputStream in = s.getInputStream();
        ByteArrayOutputStream head = new ByteArrayOutputStream();
        int last4 = 0;
        for (int b = in.read(); b != -1; b = in.read()) {
          head.write(b);
          last4 = (last4 << 8) | b;
          if (last4 == 0x0d0a0d0a) break;
        }
        String[] lines = head.toString(StandardCharsets.ISO_8859_1).split("\r\n");
        int contentLength = 0;
        for (String line : lines) {
          if (line.regionMatches(true, 0, "Content-Length:", 0, 15)) contentLength = Integer.parseInt(line.substring(15).trim());
        }
        in.readNBytes(contentLength);
        String path = lines[0].split(" ")[1];
        OutputStream out = s.getOutputStream();
        if (path.equals(TOKEN_PATH)) {
          token.write(out);
        } else if (path.startsWith("/admin/realms/" + REALM + "/users")) {
          adminHits.incrementAndGet();
          users.write(out);
        } else {
          out.write(latin1("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n"));
        }
        out.flush();
        s.shutdownOutput();
        while (in.read() >= 0) { /* 클라이언트가 닫을 때까지 */ }
      } catch (IOException clientLeft) {
        // 클라이언트가 끊었다 — 거부의 정상 결말이다
      }
    }

    @Override public void close() throws IOException {
      stop = true;
      socket.close();
    }
  }

  private static KeycloakConfig config(int port) {
    return KeycloakConfig.builder().serverUrl("http://127.0.0.1:" + port).realm(REALM).clientId("app")
        .clientSecret("s3cr3t".toCharArray()).connectTimeout(Duration.ofSeconds(5)).readTimeout(Duration.ofSeconds(20)).build();
  }

  /** admin 호출 하나의 결과 — 던진 것(없으면 null)과 호출 스레드의 할당(클라이언트 조립은 잰 구간 밖). */
  private record Outcome(Throwable thrown, long allocated) {
    String describe() {
      return (thrown == null ? "accepted" : thrown.getClass().getName() + ": " + thrown.getMessage()) + " · allocated "
          + allocated + " B";
    }
  }

  private static Outcome call(RawServer server) {
    com.sun.management.ThreadMXBean threads = allocationCounter();
    try (AdminClient admin = new AdminClient(config(server.port()))) {
      long before = threads.getCurrentThreadAllocatedBytes();
      Throwable thrown = null;
      try {
        admin.users().get("x");
      } catch (Throwable t) {
        thrown = t;
      }
      return new Outcome(thrown, threads.getCurrentThreadAllocatedBytes() - before);
    }
  }

  private static com.sun.management.ThreadMXBean allocationCounter() {
    java.lang.management.ThreadMXBean bean = ManagementFactory.getThreadMXBean();
    Assumptions.assumeTrue(bean instanceof com.sun.management.ThreadMXBean t && t.isThreadAllocatedMemorySupported()
        && t.isThreadAllocatedMemoryEnabled(), "스레드 할당 계수기가 없는 JVM");
    return (com.sun.management.ThreadMXBean) bean;
  }

  private static String trace(Throwable t) {
    StringWriter out = new StringWriter();
    t.printStackTrace(new PrintWriter(out, true));
    return out.toString();
  }

  /** (2) 토큰 응답의 트레일러가 한도를 넘으면 그 토큰으로 admin 요청을 보내지 않고 실패한다 — 할당이 묶인다. */
  @Test void tokenResponseWithHugeTrailers_isRejectedBeforeAnyAdminRequest() throws IOException {
    try (RawServer server = new RawServer()) {
      call(server); // 예열 — 클래스 적재·JIT 를 잰 구간 밖으로
      server.adminHits.set(0);
      server.token = manyTrailers(TOKEN);
      Outcome o = call(server);
      System.out.println("[AdminResponseFramingTest] 토큰 응답 32 MiB 트레일러 → " + o.describe() + " · admin "
          + server.adminHits.get());
      assertInstanceOf(KeycloakTransportException.class, o.thrown(), o::describe);
      assertEquals(0, server.adminHits.get(), "한도를 넘는 토큰 응답으로 admin 요청이 나갔다");
      assertTrue(o.allocated() < FRAMING_BOUND, o::describe);
    }
  }

  /** (2) admin 자원 응답도 같은 한도다 — 사용자 조회의 트레일러가 한도를 넘으면 전송 실패다. */
  @Test void adminResponseWithHugeTrailers_isRejected() throws IOException {
    try (RawServer server = new RawServer()) {
      call(server);
      server.users = manyTrailers(USER);
      Outcome o = call(server);
      System.out.println("[AdminResponseFramingTest] 사용자 응답 32 MiB 트레일러 → " + o.describe());
      assertInstanceOf(KeycloakTransportException.class, o.thrown(), o::describe);
      assertTrue(o.allocated() < FRAMING_BOUND, o::describe);
    }
  }

  /**
   * (3) 틀이 깨진 응답 — 청크 크기 줄·트레일러 줄에 표식. 거부가 어디서 나든(토큰 응답 · admin 자원 응답) SDK 예외의 원인 사슬
   * 전체가 표식을 싣지 않는다.
   */
  @Test void malformedFraming_isRejectedWithoutQuotingTheResponse() throws IOException {
    List<String> table = new ArrayList<>();
    List<String> wrong = new ArrayList<>();
    try (RawServer server = new RawServer()) {
      String[] where = {"토큰 응답", "사용자 응답"};
      Reply[][] replies = {
          {badChunkHeader(TOKEN), badTrailer(TOKEN), colonlessHeader(TOKEN), badStatusLine(TOKEN), untypedBadChunkHeader(TOKEN)},
          {badChunkHeader(USER), badTrailer(USER), colonlessHeader(USER), badStatusLine(USER), untypedBadChunkHeader(USER)},
      };
      String[] kinds = {"청크 크기 줄", "트레일러 줄", "콜론 없는 헤더 줄", "상태 줄", "미디어 타입 없는 청크 크기 줄"};
      for (int w = 0; w < 2; w++) {
        for (int k = 0; k < kinds.length; k++) {
          server.token = w == 0 ? replies[0][k] : lengthDelimited(TOKEN);
          server.users = w == 1 ? replies[1][k] : lengthDelimited(USER);
          Outcome o = call(server);
          String label = where[w] + " " + kinds[k];
          table.add(label + " → " + o.describe());
          if (o.thrown() != null && trace(o.thrown()).contains(MARKER)) {
            wrong.add(label + ": 거부가 응답 바이트를 인용했다:\n" + trace(o.thrown()));
          }
        }
      }
    }
    System.out.println("[AdminResponseFramingTest 틀 오류 인용]\n  " + String.join("\n  ", table));
    assertTrue(wrong.isEmpty(), () -> wrong.size() + " 건:\n" + String.join("\n", wrong));
  }

  /**
   * (1) 엔진 구성 — 줄 8,192 바이트 · 헤더 100 개 한도, 그리고 오늘의 풀 크기(50 · 경로당 50)와 타임아웃. ⚠️ 풀 크기는
   * 빌더를 바꾸면 조용히 10 으로 준다({@code .claude/rules/java.md}) — 그래서 여기서 잰다.
   */
  @SuppressWarnings("removal") // RESTEasy 6.2 의 기본 엔진 타입 그 자체를 들여다본다(AdminClient.buildTimeoutClient 설명)
  @Test void theEngineBoundsTheResponseHead_andKeepsThePoolAndTheTimeouts() throws Exception {
    Client client = AdminClient.buildTimeoutClient(config(1));
    try {
      ApacheHttpClient43Engine engine = (ApacheHttpClient43Engine) ((ResteasyClient) client).httpEngine();
      Object http = engine.getHttpClient();
      Field cmField = http.getClass().getDeclaredField("connManager");
      cmField.setAccessible(true);
      PoolingHttpClientConnectionManager pool = (PoolingHttpClientConnectionManager) cmField.get(http);
      assertEquals(50, pool.getMaxTotal(), "풀 크기");
      assertEquals(50, pool.getDefaultMaxPerRoute(), "경로당 풀 크기");
      assertNotNull(pool.getDefaultConnectionConfig(), "연결 구성이 없다 — 응답 머리 한도가 없다(HttpCore 기본 -1)");
      MessageConstraints constraints = pool.getDefaultConnectionConfig().getMessageConstraints();
      assertEquals(8192, constraints.getMaxLineLength(), "줄 한도");
      assertEquals(100, constraints.getMaxHeaderCount(), "헤더 수 한도");
      RequestConfig rc = ((org.apache.http.client.methods.Configurable) http).getConfig();
      assertEquals(5_000, rc.getConnectTimeout(), "연결 타임아웃");
      assertEquals(20_000, rc.getSocketTimeout(), "읽기 타임아웃");
    } finally {
      client.close();
    }
  }
}
