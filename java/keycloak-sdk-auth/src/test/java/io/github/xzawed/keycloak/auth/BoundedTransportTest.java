package io.github.xzawed.keycloak.auth;

import static org.junit.jupiter.api.Assertions.*;

import java.io.IOException;
import java.io.InterruptedIOException;
import java.lang.reflect.Proxy;
import java.net.ConnectException;
import java.net.InetAddress;
import java.net.SocketTimeoutException;
import java.net.URI;
import java.util.ArrayList;
import java.util.List;
import javax.net.ssl.HostnameVerifier;
import javax.net.ssl.SSLSocketFactory;
import org.apache.http.HttpClientConnection;
import org.apache.http.HttpConnectionMetrics;
import org.apache.http.HttpHost;
import org.apache.http.MalformedChunkCodingException;
import org.apache.http.MessageConstraintException;
import org.apache.http.NoHttpResponseException;
import org.apache.http.ProtocolException;
import org.apache.http.client.ClientProtocolException;
import org.apache.http.conn.ConnectTimeoutException;
import org.apache.http.conn.ConnectionPoolTimeoutException;
import org.apache.http.conn.HttpHostConnectException;
import org.apache.http.impl.execchain.RequestAbortedException;
import org.junit.jupiter.api.Test;

/**
 * {@link BoundedTransport} 의 작은 규칙들 — 예외 보호막·제한 헤더·HttpURLConnection 의 기본 요청 머리·틀 예산 스트림·풀의 쉬는
 * 수명과 연결 표식. 네트워크가 없다.
 */
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
   * 의 지적), 그 사이 받은 바이트가 예산을 넘으면 상수 메시지로 거부하며 연결의 읽기 타임아웃을 0 으로 둔다(곧 닫힐 TLS 연결에서 JSSE 가
   * 더 읽지 않게). 예산 안은 그대로 지나간다.
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
    List<Integer> timeouts = new ArrayList<>();
    HttpClientConnection connection = connection(() -> received[0], timeouts);
    java.io.InputStream within = BoundedTransport.wireBounded(socket, connection, 1_048_576);
    assertEquals(100, within.read(new byte[100], 0, 100));
    assertEquals('x', within.read());
    assertEquals(List.of(), timeouts, "예산 안에서는 연결을 건드리지 않는다");
    java.io.InputStream over = BoundedTransport.wireBounded(socket, connection, 1_000);
    IOException e = assertThrows(IOException.class, () -> over.read(new byte[1_000_000], 0, 1_000_000));
    assertEquals("HTTP response body framing exceeds 1000 bytes on the wire", e.getMessage());
    assertEquals(BoundedTransport.MAX_READ, largestAsk[0], "읽기 한 번이 소켓에 요청한 길이");
    assertEquals(List.of(0), timeouts, "거부하며 읽기 타임아웃을 0 으로");
    assertThrows(IOException.class, over::read, "예산을 넘은 뒤의 한 바이트 읽기도 거부한다");
  }

  /**
   * 길이 0 의 읽기는 소켓에 닿지 않는다 — HttpCore 의 버퍼는 비었을 때 길이 0 도 기다리고, JDK 의 {@code readNBytes} 는 버퍼를 다 채운
   * 뒤 길이 0 으로 한 번 더 묻는다(그래서 상한+1 바이트 뒤 멈춘 서버 앞에서 넘침을 읽기 타임아웃까지 알아채지 못했다).
   */
  @Test void wireBounded_aZeroLengthReadNeverReachesTheSocket() throws IOException {
    java.io.InputStream socket = new java.io.InputStream() {
      @Override public int read() {
        throw new AssertionError("한 바이트 읽기가 소켓에 닿았다");
      }

      @Override public int read(byte[] b, int off, int len) {
        throw new AssertionError("길이 " + len + " 의 읽기가 소켓에 닿았다");
      }
    };
    assertEquals(0, BoundedTransport.wireBounded(socket, connection(() -> 0, new ArrayList<>()), 1_000).read(new byte[4], 4, 0));
  }

  /** 읽기가 실패하면(읽기 타임아웃 등) 그 예외 그대로 — 연결의 읽기 타임아웃은 0 으로(HttpClient 가 곧 닫는다). */
  @Test void wireBounded_aFailedReadQuietsTheConnection() {
    SocketTimeoutException timedOut = new SocketTimeoutException("Read timed out");
    java.io.InputStream socket = new java.io.InputStream() {
      @Override public int read() throws IOException {
        throw timedOut;
      }

      @Override public int read(byte[] b, int off, int len) throws IOException {
        throw timedOut;
      }
    };
    List<Integer> timeouts = new ArrayList<>();
    java.io.InputStream body = BoundedTransport.wireBounded(socket, connection(() -> 0, timeouts), 1_000);
    assertSame(timedOut, assertThrows(IOException.class, () -> body.read(new byte[8], 0, 8)));
    assertSame(timedOut, assertThrows(IOException.class, body::read));
    assertEquals(List.of(0, 0), timeouts);
  }

  /** 이미 풀로 돌아간 연결(대리자가 떨어져 나가 던진다)은 건드리지 않는다 — 그 실패를 삼킨다. */
  @Test void quiet_leavesAReturnedConnectionAlone() {
    HttpClientConnection detached = (HttpClientConnection) Proxy.newProxyInstance(HttpClientConnection.class.getClassLoader(),
        new Class<?>[] {HttpClientConnection.class}, (proxy, method, args) -> {
          throw new org.apache.http.impl.conn.ConnectionShutdownException();
        });
    assertDoesNotThrow(() -> BoundedTransport.quiet(detached));
  }

  /** 지표와 읽기 타임아웃만 아는 연결 — 나머지 메서드는 부르면 실패한다. */
  private static HttpClientConnection connection(java.util.function.LongSupplier received, List<Integer> timeouts) {
    HttpConnectionMetrics metrics = new org.apache.http.impl.HttpConnectionMetricsImpl(null, null) {
      @Override public long getReceivedBytesCount() {
        return received.getAsLong();
      }
    };
    return (HttpClientConnection) Proxy.newProxyInstance(HttpClientConnection.class.getClassLoader(),
        new Class<?>[] {HttpClientConnection.class}, (proxy, method, args) -> switch (method.getName()) {
          case "getMetrics" -> metrics;
          case "setSocketTimeout" -> {
            timeouts.add((Integer) args[0]);
            yield null;
          }
          default -> throw new UnsupportedOperationException(method.getName());
        });
  }

  /** 풀의 기다림이 끝난 것 — 응답과 무관한 JDK 의 타임아웃·인터럽트 예외로(원인을 달지 않는다). */
  @Test void shield_mapsPoolWaitsToTheJdksTimeoutAndInterrupt() {
    IOException timedOut = BoundedTransport.shield(new ConnectionPoolTimeoutException("Timeout waiting for connection from pool"));
    assertEquals(SocketTimeoutException.class, timedOut.getClass());
    assertEquals(BoundedTransport.POOL_TIMEOUT, timedOut.getMessage());
    IOException interrupted = BoundedTransport.shield(new RequestAbortedException("Request aborted", new InterruptedException()));
    assertEquals(InterruptedIOException.class, interrupted.getClass());
    assertEquals(BoundedTransport.INTERRUPTED, interrupted.getMessage());
    assertNull(interrupted.getCause());
  }

  /** 쉬는 연결의 수명 — 서버의 {@code Keep-Alive: timeout} 이 더 짧으면 그것, 없거나 길면 5 초, 0 이면 곧 닫는다. */
  @Test void idleMillis_capsTheServersKeepAlive() {
    assertEquals(5_000, BoundedTransport.idleMillis(-1));
    assertEquals(1, BoundedTransport.idleMillis(0));
    assertEquals(1_000, BoundedTransport.idleMillis(1_000));
    assertEquals(5_000, BoundedTransport.idleMillis(5_000));
    assertEquals(5_000, BoundedTransport.idleMillis(3_600_000));
  }

  /**
   * 풀의 연결 표식 — 같은 팩토리·같은 검증기(정체)일 때만 같다(같은 일을 하는 다른 객체는 다르다). 없는 근원(null)은 하나의 표지로
   * 센다. 문자열 표현은 상수다(근원을 찍지 않는다).
   */
  @Test void tlsKey_isTheIdentityOfTheFactoryAndTheVerifier() {
    SSLSocketFactory factory = (SSLSocketFactory) SSLSocketFactory.getDefault();
    HostnameVerifier verifier = (host, session) -> "a.example".equals(host);
    HostnameVerifier other = (host, session) -> "a.example".equals(host);
    BoundedTransport.TlsKey key = new BoundedTransport.TlsKey(factory, verifier);
    assertEquals(key, key);
    assertEquals(key, new BoundedTransport.TlsKey(factory, verifier));
    assertEquals(key.hashCode(), new BoundedTransport.TlsKey(factory, verifier).hashCode());
    assertNotEquals(key, new BoundedTransport.TlsKey(factory, other));
    assertNotEquals(key, new BoundedTransport.TlsKey(new BoundedTransportTestFactory(factory), verifier));
    assertNotEquals(key, "TlsKey");
    assertEquals(new BoundedTransport.TlsKey(null, null), new BoundedTransport.TlsKey(null, null));
    assertNotEquals(new BoundedTransport.TlsKey(null, verifier), new BoundedTransport.TlsKey(factory, verifier));
    assertEquals("TlsKey", key.toString());
  }

  /**
   * 근원을 붙잡지 않는다 — 팩토리나 검증기가 수거되면 그 표식은 (자기 자신 말고는) 무엇과도 같지 않다: 그 연결은 다시 쓰이지 않는다.
   * 수거는 GC 가 정하므로, 이 JVM 이 약한 참조를 비우지 않으면 확인을 건너뛴다.
   */
  @Test void tlsKey_doesNotKeepItsSourcesAlive() throws InterruptedException {
    SSLSocketFactory factory = (SSLSocketFactory) SSLSocketFactory.getDefault();
    HostnameVerifier keptVerifier = (host, session) -> "a.example".equals(host);
    // 잡는 것이 없는 람다는 JVM 이 호출 자리마다 하나를 캐시해 수거되지 않는다 — 새 객체여야 한다
    HostnameVerifier verifier = new HostnameVerifier() {
      @Override public boolean verify(String host, javax.net.ssl.SSLSession session) {
        return "b.example".equals(host);
      }
    };
    BoundedTransportTestFactory doomedFactory = new BoundedTransportTestFactory(factory);
    BoundedTransport.TlsKey deadFactory = new BoundedTransport.TlsKey(doomedFactory, keptVerifier);
    BoundedTransport.TlsKey deadFactoryTwin = new BoundedTransport.TlsKey(doomedFactory, keptVerifier);
    BoundedTransport.TlsKey deadVerifier = new BoundedTransport.TlsKey(factory, verifier);
    BoundedTransport.TlsKey deadVerifierTwin = new BoundedTransport.TlsKey(factory, verifier);
    java.lang.ref.WeakReference<Object> factoryGone = new java.lang.ref.WeakReference<>(doomedFactory);
    java.lang.ref.WeakReference<Object> verifierGone = new java.lang.ref.WeakReference<>(verifier);
    doomedFactory = null;
    verifier = null;
    for (int i = 0; i < 50 && (factoryGone.get() != null || verifierGone.get() != null); i++) {
      System.gc();
      Thread.sleep(20);
    }
    org.junit.jupiter.api.Assumptions.assumeTrue(factoryGone.get() == null && verifierGone.get() == null,
        "이 JVM 의 GC 가 약한 참조를 비우지 않았다");
    assertNotEquals(deadFactory, deadFactoryTwin);
    assertNotEquals(deadVerifier, deadVerifierTwin);
    assertEquals(deadFactory, deadFactory);
  }

  /** 정체만 다른 팩토리 — 같은 일을 하지만 다른 객체다. */
  private static final class BoundedTransportTestFactory extends SSLSocketFactory {
    private final SSLSocketFactory delegate;

    BoundedTransportTestFactory(SSLSocketFactory delegate) {
      this.delegate = delegate;
    }

    @Override public String[] getDefaultCipherSuites() {
      return delegate.getDefaultCipherSuites();
    }

    @Override public String[] getSupportedCipherSuites() {
      return delegate.getSupportedCipherSuites();
    }

    @Override public java.net.Socket createSocket(java.net.Socket s, String host, int port, boolean autoClose) throws IOException {
      return delegate.createSocket(s, host, port, autoClose);
    }

    @Override public java.net.Socket createSocket(String host, int port) throws IOException {
      return delegate.createSocket(host, port);
    }

    @Override public java.net.Socket createSocket(String host, int port, InetAddress local, int localPort) throws IOException {
      return delegate.createSocket(host, port, local, localPort);
    }

    @Override public java.net.Socket createSocket(InetAddress host, int port) throws IOException {
      return delegate.createSocket(host, port);
    }

    @Override public java.net.Socket createSocket(InetAddress host, int port, InetAddress local, int localPort)
        throws IOException {
      return delegate.createSocket(host, port, local, localPort);
    }
  }

  /** {@code https.protocols}·{@code https.cipherSuites} 는 HttpURLConnection 처럼 쉼표로만 나눈다 — 없거나 비면 걸지 않는다. */
  @Test void tokens_splitLikeHttpsClient() {
    assertArrayEquals(new String[0], BoundedTransport.tokens(null));
    assertArrayEquals(new String[0], BoundedTransport.tokens(""));
    assertArrayEquals(new String[] {"TLSv1.2"}, BoundedTransport.tokens("TLSv1.2"));
    assertArrayEquals(new String[] {"TLSv1.2", " TLSv1.3"}, BoundedTransport.tokens("TLSv1.2, TLSv1.3"));
  }
}
