package io.github.xzawed.keycloak.auth;

import static org.junit.jupiter.api.Assertions.*;

import java.io.IOException;
import java.net.ConnectException;
import java.net.InetAddress;
import java.net.SocketTimeoutException;
import java.net.URI;
import org.apache.http.HttpHost;
import org.apache.http.MalformedChunkCodingException;
import org.apache.http.MessageConstraintException;
import org.apache.http.NoHttpResponseException;
import org.apache.http.ProtocolException;
import org.apache.http.client.ClientProtocolException;
import org.apache.http.conn.ConnectTimeoutException;
import org.apache.http.conn.HttpHostConnectException;
import org.junit.jupiter.api.Test;

/** {@link BoundedTransport} 의 작은 규칙들 — 예외 보호막·제한 헤더·HttpURLConnection 의 기본 요청 머리. 네트워크가 없다. */
class BoundedTransportTest {
  private static final String MARKER = "ZshieldMARKER";

  /** JDK 의 예외(그리고 SDK 의 것)는 그대로 — 같은 인스턴스다. */
  @Test void shield_keepsTheJdksOwnExceptions() {
    for (IOException e : new IOException[] {new SocketTimeoutException("Read timed out"), new ConnectException("refused"),
        new IOException("plain"), new CappedResponseSender.TooLarge("token")}) {
      assertSame(e, BoundedTransport.shield(e));
    }
  }

  /** HttpClient 가 JDK 의 연결 실패를 감싼 것 — HttpURLConnection 이 던지는 바로 그 원인을 돌려준다. */
  @Test void shield_unwrapsTheConnectFailuresHttpClientWraps() throws Exception {
    HttpHost host = new HttpHost("127.0.0.1", 1);
    ConnectException refused = new ConnectException("Connection refused");
    SocketTimeoutException timedOut = new SocketTimeoutException("Connect timed out");
    InetAddress loopback = InetAddress.getLoopbackAddress();
    assertSame(refused, BoundedTransport.shield(new HttpHostConnectException(refused, host, loopback)));
    assertSame(timedOut, BoundedTransport.shield(new ConnectTimeoutException(timedOut, host, loopback)));
  }

  /** 틀 오류는 상수 메시지 — 응답의 줄을 싣지 않고 원인도 달지 않는다. 한도 초과는 그렇다고 말한다. */
  @Test void shield_replacesFramingFailuresWithConstantMessages() {
    IOException[] quoting = {new MalformedChunkCodingException("Bad chunk header: " + MARKER),
        new ClientProtocolException(new ProtocolException("Invalid header: " + MARKER)), new NoHttpResponseException(MARKER)};
    for (IOException e : quoting) {
      IOException shielded = BoundedTransport.shield(e);
      assertEquals(IOException.class, shielded.getClass());
      assertEquals(BoundedTransport.INVALID_RESPONSE, shielded.getMessage());
      assertNull(shielded.getCause());
    }
    IOException limit = BoundedTransport.shield(new MessageConstraintException("Maximum line length limit exceeded"));
    assertEquals(BoundedTransport.OVER_LIMITS, limit.getMessage());
    assertEquals("HTTP response framing exceeds 8192-byte lines or 100 header fields", limit.getMessage());
  }

  /** HttpURLConnection 의 제한 헤더 — {@code Connection: close} 만 예외, {@code Sec-*} 는 버린다. 대소문자는 가리지 않는다. */
  @Test void restricted_followsHttpURLConnection() {
    for (String name : new String[] {"Content-Length", "host", "TRANSFER-ENCODING", "Origin", "Keep-Alive", "Via", "Upgrade",
        "Trailer", "Content-Transfer-Encoding", "Access-Control-Request-Method", "Access-Control-Request-Headers", "Sec-Fetch-Mode"}) {
      assertTrue(BoundedTransport.restricted(name, "x"), name);
    }
    assertTrue(BoundedTransport.restricted("Connection", "keep-alive"));
    assertFalse(BoundedTransport.restricted("Connection", "Close"));
    for (String name : new String[] {"Authorization", "Content-Type", "Accept", "User-Agent", "Cookie", "DPoP"}) {
      assertFalse(BoundedTransport.restricted(name, "x"), name);
    }
  }

  /** Host 는 기본 포트를 적지 않는다 — HttpClient 는 URL 에 적힌 포트를 그대로 싣는다. */
  @Test void hostHeader_omitsTheDefaultPort() throws Exception {
    assertEquals("kc.example", BoundedTransport.hostHeader(URI.create("https://kc.example/x").toURL()));
    assertEquals("kc.example", BoundedTransport.hostHeader(URI.create("https://kc.example:443/x").toURL()));
    assertEquals("kc.example", BoundedTransport.hostHeader(URI.create("http://kc.example:80/x").toURL()));
    assertEquals("kc.example:8443", BoundedTransport.hostHeader(URI.create("https://kc.example:8443/x").toURL()));
  }

  /** User-Agent·Accept 는 HttpURLConnection 의 값 — {@code http.agent} 가 있으면 앞에 붙고, Accept 는 JDK 판을 따른다. */
  @Test void jdkDefaults_mirrorHttpURLConnection() {
    assertEquals("Java/21.0.1", BoundedTransport.userAgent(null, "21.0.1"));
    assertEquals("probe/1 Java/21.0.1", BoundedTransport.userAgent("probe/1", "21.0.1"));
    assertEquals("*/*", BoundedTransport.acceptFor(21));
    assertEquals("*/*", BoundedTransport.acceptFor(25));
    assertEquals("text/html, image/gif, image/jpeg, */*; q=0.2", BoundedTransport.acceptFor(17));
  }

  /**
   * 틀의 바이트 예산 — 읽기 한 번이 소켓에 요청하는 길이를 자르고(HttpCore 는 큰 요청을 버퍼 없이 소켓에서 바로 읽는다 — Grok 레그 2
   * 의 지적), 그 사이 받은 바이트가 예산을 넘으면 상수 메시지로 거부한다. 예산 안은 그대로 지나간다.
   */
  @Test void wireBounded_capsEachReadAndRefusesOverBudget() throws IOException {
    long[] received = {0};
    int[] largestAsk = {0};
    java.io.InputStream socket = new java.io.InputStream() {
      @Override public int read() {
        received[0]++;
        return 'x';
      }

      @Override public int read(byte[] b, int off, int len) {
        largestAsk[0] = Math.max(largestAsk[0], len);
        received[0] += len; // 소켓에서 바로 읽은 것처럼 — 요청한 만큼 받는다
        return len;
      }
    };
    org.apache.http.HttpConnectionMetrics metrics = new org.apache.http.impl.HttpConnectionMetricsImpl(null, null) {
      @Override public long getReceivedBytesCount() {
        return received[0];
      }
    };
    java.io.InputStream within = BoundedTransport.wireBounded(socket, metrics, 1_048_576);
    assertEquals(100, within.read(new byte[100], 0, 100));
    assertEquals('x', within.read());
    java.io.InputStream over = BoundedTransport.wireBounded(socket, metrics, 1_000);
    IOException e = assertThrows(IOException.class, () -> over.read(new byte[1_000_000], 0, 1_000_000));
    assertEquals("HTTP response body framing exceeds 1000 bytes on the wire", e.getMessage());
    assertEquals(BoundedTransport.MAX_READ, largestAsk[0], "읽기 한 번이 소켓에 요청한 길이");
    assertThrows(IOException.class, over::read, "예산을 넘은 뒤의 한 바이트 읽기도 거부한다");
  }

  /** {@code https.protocols}·{@code https.cipherSuites} 는 HttpURLConnection 처럼 쉼표로만 나눈다 — 없거나 비면 걸지 않는다. */
  @Test void tokens_splitLikeHttpsClient() {
    assertArrayEquals(new String[0], BoundedTransport.tokens(null));
    assertArrayEquals(new String[0], BoundedTransport.tokens(""));
    assertArrayEquals(new String[] {"TLSv1.2"}, BoundedTransport.tokens("TLSv1.2"));
    assertArrayEquals(new String[] {"TLSv1.2", " TLSv1.3"}, BoundedTransport.tokens("TLSv1.2, TLSv1.3"));
  }
}
