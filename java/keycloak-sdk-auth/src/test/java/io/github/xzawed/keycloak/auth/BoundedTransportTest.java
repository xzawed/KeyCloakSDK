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

  /** {@code https.protocols}·{@code https.cipherSuites} 는 HttpURLConnection 처럼 쉼표로만 나눈다 — 없거나 비면 걸지 않는다. */
  @Test void tokens_splitLikeHttpsClient() {
    assertArrayEquals(new String[0], BoundedTransport.tokens(null));
    assertArrayEquals(new String[0], BoundedTransport.tokens(""));
    assertArrayEquals(new String[] {"TLSv1.2"}, BoundedTransport.tokens("TLSv1.2"));
    assertArrayEquals(new String[] {"TLSv1.2", " TLSv1.3"}, BoundedTransport.tokens("TLSv1.2, TLSv1.3"));
  }
}
