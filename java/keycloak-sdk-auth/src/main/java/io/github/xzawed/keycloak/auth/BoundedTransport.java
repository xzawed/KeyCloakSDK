package io.github.xzawed.keycloak.auth;

import io.github.xzawed.keycloak.core.ResponseLimits;
import java.io.FilterInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.net.URL;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.StringTokenizer;
import javax.net.ssl.HostnameVerifier;
import javax.net.ssl.SSLParameters;
import javax.net.ssl.SSLSession;
import javax.net.ssl.SSLSocket;
import javax.net.ssl.SSLSocketFactory;
import org.apache.http.Header;
import org.apache.http.HttpClientConnection;
import org.apache.http.HttpConnectionMetrics;
import org.apache.http.HttpEntity;
import org.apache.http.HttpException;
import org.apache.http.HttpHost;
import org.apache.http.HttpRequest;
import org.apache.http.HttpRequestInterceptor;
import org.apache.http.HttpResponse;
import org.apache.http.MessageConstraintException;
import org.apache.http.ProtocolException;
import org.apache.http.client.config.RequestConfig;
import org.apache.http.client.methods.HttpRequestBase;
import org.apache.http.client.protocol.HttpClientContext;
import org.apache.http.config.ConnectionConfig;
import org.apache.http.config.MessageConstraints;
import org.apache.http.config.Registry;
import org.apache.http.config.RegistryBuilder;
import org.apache.http.config.SocketConfig;
import org.apache.http.conn.DnsResolver;
import org.apache.http.conn.HttpConnectionFactory;
import org.apache.http.conn.ManagedHttpClientConnection;
import org.apache.http.conn.routing.HttpRoute;
import org.apache.http.conn.routing.RouteInfo;
import org.apache.http.conn.socket.ConnectionSocketFactory;
import org.apache.http.conn.socket.LayeredConnectionSocketFactory;
import org.apache.http.conn.socket.PlainConnectionSocketFactory;
import org.apache.http.conn.ssl.DefaultHostnameVerifier;
import org.apache.http.impl.NoConnectionReuseStrategy;
import org.apache.http.impl.client.CloseableHttpClient;
import org.apache.http.impl.client.HttpClientBuilder;
import org.apache.http.impl.conn.BasicHttpClientConnectionManager;
import org.apache.http.impl.conn.DefaultHttpResponseParser;
import org.apache.http.impl.conn.ManagedHttpClientConnectionFactory;
import org.apache.http.impl.conn.SystemDefaultRoutePlanner;
import org.apache.http.protocol.HttpContext;
import org.apache.http.protocol.HttpRequestExecutor;
import org.apache.http.util.CharArrayBuffer;

/**
 * auth 레인({@link CappedResponseSender})과 JWKS 레인({@link NoRedirectResourceRetriever})의 운송 — Apache HttpClient 4.5 /
 * HttpCore 4.4(admin 레인의 RESTEasy 가 이미 가져오는 판)를 <b>HttpURLConnection 처럼</b> 쓴다.
 *
 * <p>왜 바꿨나: JDK 의 운송({@code sun.net.www})은 응답의 틀에 한도가 없는 자리가 있었다 — 짧은 청크 본문 뒤 EOF 까지 읽으면
 * 트레일러를 한도 없이 담았고(4 KiB 줄 32 MiB → 토큰 수락 · 호출 하나 170 MB, 한 줄 1 MiB → 17.2 GB · 4–6 초 — 실측
 * {@code ResponseFramingBoundsTest}), 상한을 넘은 청크 본문을 닫으면 쌓인 바이트를 제곱 비용으로 풀었고(리눅스 1 바이트 청크 68.8 GB ·
 * 7.7 초), 1xx 를 끝없이 받으면 재귀하다 {@code StackOverflowError} 가 공개 API 로 나갔다. 그 운송에는 이것들을 끌 노브가 없다.
 *
 * <p>그래서 여기서는: (1) 응답 머리의 줄·헤더 수 한도({@link ResponseLimits#MAX_LINE_LENGTH} ·
 * {@link ResponseLimits#MAX_HEADER_COUNT} — 상태 줄·헤더·청크 크기 줄·트레일러 모두)를 건다 · (2) 본문을 다 읽지 않은 교환은
 * <b>비우지 않고 끊는다</b>(교환의 클라이언트를 닫으면 연결 하나를 shutdown 한다 — 평문은 그 자리에서 끝나고, HTTPS 는 JSSE 가 닫으며
 * 이미 도착한 바이트를 버린다) ·
 * (3) 첫 줄이 상태 줄이 아니면 곧바로 거부하고(HttpURLConnection 처럼 — HttpClient 는 쓰레기 줄을 한도 없이 건너뛴다) 1xx 중간
 * 응답은 {@value #MAX_INTERIM_RESPONSES} 개까지만 받는다 · (4) 교환마다 연결 하나짜리 새 클라이언트를 만든다(공유 풀은 호스트당 2
 * 연결이라 동시 호출이 줄을 선다 — 실측 10 개 병렬 2,540 ms 대 510 ms) — 백그라운드 스레드가 없다 · (5) 하위 운송의 예외는 응답을
 * 인용할 수 있으므로({@code Bad chunk header: <줄>}) 상수 메시지의 {@link IOException} 으로 바꾼다({@link #shield}) · (6) 본문을
 * 읽는 동안 받는 틀의 바이트를 본문 상한의 {@value #WIRE_FACTOR} 배로 묶는다({@link #exchange}).
 *
 * <p>⚠️ <b>HttpURLConnection 과 같아야 하는 것</b>(실측 대조 — {@code CappedResponseSenderTest}): 요청 머리(User-Agent ·
 * Accept · Host · Connection — 아래 상수들), 제한 헤더를 버리는 규칙({@link #restricted}), 리다이렉트를 따르지 않음, 내용 코딩을
 * 요청하지도 풀지도 않음(상한은 받은 바이트를 센다), 시스템 프록시({@code http(s).proxyHost} — {@code ProxySelector}), 거절된
 * CONNECT 는 응답이 아니라 IOException, TLS 단계({@link HucTls}). <b>따라하지 않는 것</b>(JVM 전역 훅 — 키클록의 정상 응답에는
 * 닿지 않는다): {@code CookieHandler} · {@code ResponseCache} · {@code java.net.Authenticator}(401·407 도전에 답하지 않는다),
 * 상태 줄을 받기 전 끊긴 연결의 한 번 재시도, {@code http.keepAlive=false} 의 {@code Connection: close}.
 */
final class BoundedTransport {
  private BoundedTransport() {}

  /** 1xx 중간 응답을 이보다 많이 받으면 거부한다 — 끝없이 보내는 서버에 시간이 묶이도록(HttpURLConnection 은 재귀하다 넘쳤다). */
  static final int MAX_INTERIM_RESPONSES = 8;
  /** 본문을 읽는 동안 연결에서 받아도 되는 바이트 — 본문 상한의 이 배수({@link #exchange}). */
  static final int WIRE_FACTOR = 8;
  /** 하위 운송이 응답을 해석하지 못했다 — HttpURLConnection 이 같은 경우에 쓰는 말 그대로. 응답을 인용하지 않는다. */
  static final String INVALID_RESPONSE = "Invalid Http response";
  /** 응답 머리·청크 줄·트레일러가 한도를 넘었다. 응답을 인용하지 않는다. */
  static final String OVER_LIMITS = "HTTP response framing exceeds " + ResponseLimits.MAX_LINE_LENGTH + "-byte lines or "
      + ResponseLimits.MAX_HEADER_COUNT + " header fields";
  /** 프록시가 CONNECT 를 거절했다(HttpURLConnection 처럼 응답이 아니라 IOException — 프록시의 응답은 인용하지 않는다). */
  static final String TUNNEL_REFUSED = "Unable to tunnel through proxy";
  /** HttpURLConnection 의 기본 User-Agent — 그 클래스처럼 초기화 때 한 번 읽는다. */
  static final String USER_AGENT = userAgent(System.getProperty("http.agent"), System.getProperty("java.version"));
  /** HttpURLConnection 의 기본 Accept — JDK 21 부터 {@code *}{@code /*} 다(17 은 옛 목록). */
  static final String ACCEPT = acceptFor(Runtime.version().feature());

  private static final String APACHE = "org.apache.http.";
  private static final String TLS_FACTORY = BoundedTransport.class.getName() + ".tlsFactory";
  private static final String TLS_VERIFIER = BoundedTransport.class.getName() + ".tlsVerifier";

  /** HttpURLConnection 이 요청 머리에서 조용히 버리는 이름(소문자) — {@code sun.net.http.allowRestrictedHeaders} 기본. */
  private static final Set<String> RESTRICTED = Set.of("access-control-request-headers", "access-control-request-method",
      "connection", "content-length", "content-transfer-encoding", "host", "keep-alive", "origin", "trailer",
      "transfer-encoding", "upgrade", "via");

  private static final ConnectionConfig BOUNDED_HEAD = ConnectionConfig.custom()
      .setMessageConstraints(MessageConstraints.custom()
          .setMaxLineLength(ResponseLimits.MAX_LINE_LENGTH)
          .setMaxHeaderCount(ResponseLimits.MAX_HEADER_COUNT)
          .build())
      .build();

  /** 첫 줄이 상태 줄이 아니면 거부하는 응답 해석기 — HttpClient 의 기본은 쓰레기 줄을 한도 없이 건너뛴다. */
  private static final HttpConnectionFactory<HttpRoute, ManagedHttpClientConnection> CONNECTIONS =
      new ManagedHttpClientConnectionFactory((buffer, constraints) ->
          new DefaultHttpResponseParser(buffer, null, null, constraints) {
            @Override protected boolean reject(CharArrayBuffer line, int count) {
              return true;
            }
          });

  /** HttpURLConnection 처럼 이름의 첫 주소 하나에만 붙는다(HttpClient 의 기본은 주소마다 연결 타임아웃을 다시 쓴다). */
  private static final DnsResolver FIRST_ADDRESS = host -> new InetAddress[] {InetAddress.getByName(host)};

  private static final Registry<ConnectionSocketFactory> SOCKETS = RegistryBuilder.<ConnectionSocketFactory>create()
      .register("http", PlainConnectionSocketFactory.getSocketFactory())
      .register("https", HucTls.INSTANCE)
      .build();

  /** HttpURLConnection 처럼 {@code keep-alive} — 평문 프록시를 지날 때는 {@code Proxy-Connection} 이다. 이미 있으면 둔다. */
  private static final HttpRequestInterceptor CONNECTION = (request, context) -> {
    RouteInfo route = HttpClientContext.adapt(context).getHttpRoute();
    String name = route.getProxyHost() != null && !route.isTunnelled() ? "Proxy-Connection" : "Connection";
    if (!request.containsHeader(name)) request.addHeader(name, "keep-alive");
  };

  /** 1xx 를 세고, 거절된 CONNECT 를 IOException 으로 바꾸는 실행기 — 상태가 없어 모든 교환이 함께 쓴다. */
  private static final HttpRequestExecutor EXECUTOR = new HttpRequestExecutor() {
    @Override
    public HttpResponse execute(HttpRequest request, HttpClientConnection conn, HttpContext context)
        throws IOException, HttpException {
      HttpResponse response = super.execute(request, conn, context);
      // HttpClient 는 거절된 CONNECT 의 응답(본문까지 통째로 버퍼에 담아)을 호출자에게 돌려준다 — 받기 전에 끊는다.
      if ("CONNECT".equals(request.getRequestLine().getMethod()) && response.getStatusLine().getStatusCode() != 200) {
        throw new IOException(TUNNEL_REFUSED);
      }
      return response;
    }

    @Override
    protected HttpResponse doReceiveResponse(HttpRequest request, HttpClientConnection conn, HttpContext context)
        throws HttpException, IOException {
      for (int interim = 0; ; interim++) {
        HttpResponse response = conn.receiveResponseHeader();
        if (response.getStatusLine().getStatusCode() >= 200) {
          if (canResponseHaveBody(request, response)) conn.receiveResponseEntity(response);
          return response;
        }
        if (interim >= MAX_INTERIM_RESPONSES) throw new ProtocolException("too many interim responses");
      }
    }
  };

  /** 응답의 상태·머리를 받아 본문 스트림에서 결과를 만든다. ⚠️ 본문 스트림을 닫지 않는다 — 닫기는 나머지를 비운다(HttpCore). */
  @FunctionalInterface
  interface Reader<T> {
    T read(HttpResponse head, InputStream body) throws IOException;
  }

  /**
   * 교환 하나 — 연결 하나짜리 새 클라이언트로 {@code request} 를 보내고 상태와 머리가 오면 {@code reader} 에 넘긴다. 본문을 EOF 까지
   * 읽었으면 연결은 그때 이미 놓였고(정상 종료), 아니면(넘침·거부·실패) 클라이언트를 닫으며 남은 본문을 읽지 않고 끊는다. 실패는
   * {@link #shield} 를 거친 IOException 이다. TLS 근원은 HttpURLConnection 이 쓰는 소켓 팩토리와 검증기다({@link HucTls}).
   *
   * <p>본문을 읽는 동안 연결에서 받은 바이트(청크 머리·확장·트레일러 포함)는 {@code bodyCap} 의 {@value #WIRE_FACTOR} 배까지다
   * ({@link #wireBounded}) — 본문 상한은 본문만 세서, 한 바이트짜리 청크마다 크기 줄을 줄 한도(8,192)까지 채우면(「0000…01」) 상한
   * 안의 본문에 8 GB 의 틀을 실을 수 있었다(실측: 청크 200,000 개에 1.6 GB 를 받아 할당하고 4.0 초 — 그리고 받아들였다. 예전 운송도
   * 청크 머리 2,050 바이트 한도로 같은 부류였다). 1 바이트 청크의 틀은 본문의 6 배라 그 응답도 본문 상한에 먼저 닿는다.
   */
  static <T> T exchange(HttpRequestBase request, SSLSocketFactory tlsFactory, HostnameVerifier verifier,
                        int connectTimeoutMillis, int readTimeoutMillis, int bodyCap, Reader<T> reader) throws IOException {
    BasicHttpClientConnectionManager connections = new BasicHttpClientConnectionManager(SOCKETS, CONNECTIONS, null, FIRST_ADDRESS);
    connections.setConnectionConfig(BOUNDED_HEAD);
    // 프록시의 CONNECT 응답과 TLS 핸드셰이크도 읽기 타임아웃 아래에서 읽는다(HttpURLConnection 은 연결 직후 거는 값이다)
    connections.setSocketConfig(SocketConfig.custom().setSoTimeout(readTimeoutMillis).build());
    request.setConfig(RequestConfig.custom()
        .setConnectTimeout(connectTimeoutMillis)
        .setSocketTimeout(readTimeoutMillis)
        .setAuthenticationEnabled(false)
        .build());
    HttpClientContext context = HttpClientContext.create();
    context.setAttribute(TLS_FACTORY, tlsFactory);
    context.setAttribute(TLS_VERIFIER, verifier);
    try (CloseableHttpClient client = HttpClientBuilder.create()
        .setConnectionManager(connections)
        .setRoutePlanner(new SystemDefaultRoutePlanner(null))
        .setRequestExecutor(EXECUTOR)
        .setUserAgent(USER_AGENT)
        .addInterceptorFirst(CONNECTION)
        .setConnectionReuseStrategy(NoConnectionReuseStrategy.INSTANCE)
        .disableRedirectHandling()
        .disableContentCompression()
        .disableAutomaticRetries()
        .disableCookieManagement()
        .build()) {
      // 끊기는 이 클라이언트의 닫기다: 연결 하나짜리 관리자의 shutdown 이 연결을 읽지 않고 닫는다(SO_LINGER 0 —
      // BHttpConnectionBase.shutdown). 본문을 EOF 까지 읽었으면 연결은 그때 이미 정상 종료됐다. ⚠️ 본문 스트림을 닫거나
      // EntityUtils.consume 으로 「놓지」 말 것 — HttpCore 의 닫기는 나머지를 EOF 까지 비운다(끝없는 본문이면 돌아오지 않는다 —
      // ResponseFramingBoundsTest 의 끝없는 본문 시험이 잡는다). request.abort() 를 더해도 같은 shutdown 이라 아무것도 바뀌지 않았다(변이 실측).
      try {
        HttpResponse head = client.execute(request, context);
        HttpEntity entity = head.getEntity();
        return reader.read(head, entity == null ? InputStream.nullInputStream()
            : wireBounded(entity.getContent(), context.getConnection().getMetrics(), (long) WIRE_FACTOR * bodyCap));
      } catch (IOException e) {
        throw shield(e);
      }
    }
  }

  /**
   * 읽기마다 이 연결이 받은 바이트(소켓에서 버퍼로 — HttpCore 의 연결 지표)를 세어, 본문을 읽기 시작한 뒤 {@code budget} 을 넘으면
   * 상수 메시지로 거부한다. 한 번의 읽기가 넘는 양은 청크 머리 한 줄이나 트레일러 한 묶음(줄·헤더 수 한도 안)까지다.
   */
  static InputStream wireBounded(InputStream body, HttpConnectionMetrics metrics, long budget) {
    long start = metrics.getReceivedBytesCount();
    String overBudget = "HTTP response body framing exceeds " + budget + " bytes on the wire";
    return new FilterInputStream(body) {
      @Override public int read() throws IOException {
        int b = super.read();
        check();
        return b;
      }

      @Override public int read(byte[] buffer, int offset, int length) throws IOException {
        int n = super.read(buffer, offset, length);
        check();
        return n;
      }

      private void check() throws IOException {
        if (metrics.getReceivedBytesCount() - start > budget) throw new IOException(overBudget);
      }
    };
  }

  /**
   * 하위 운송의 예외를 응답을 인용하지 않는 것으로 — JDK 의 예외(타임아웃·연결 거부·TLS·DNS)와 SDK 의 것은 그대로 두고, HttpClient
   * 가 JDK 의 예외를 감싼 것(연결 실패)은 그 원인을 꺼내고(HttpURLConnection 이 던지는 바로 그것), 나머지(틀 오류 · 한도 초과)는 상수
   * 메시지의 IOException 이다 — 원인을 달지 않는다(HttpCore 의 메시지는 응답의 줄을 싣는다: {@code Bad chunk header: <줄>}).
   */
  static IOException shield(IOException e) {
    if (!e.getClass().getName().startsWith(APACHE)) return e;
    if (e.getCause() instanceof IOException cause) return shield(cause);
    return new IOException(e instanceof MessageConstraintException ? OVER_LIMITS : INVALID_RESPONSE);
  }

  /** HttpURLConnection 이 조용히 버리는 요청 헤더인가 — {@code Connection: close} 는 허용하고 {@code Sec-*} 는 버린다. */
  static boolean restricted(String name, String value) {
    String key = name.toLowerCase(Locale.ROOT);
    if (RESTRICTED.contains(key)) return !(key.equals("connection") && value.equalsIgnoreCase("close"));
    return key.startsWith("sec-");
  }

  /** 헤더 표를 요청에 싣는다 — HttpURLConnection 의 {@code addRequestProperty} 처럼 제한 헤더는 버린다. */
  static void addHeaders(HttpRequestBase request, Map<String, List<String>> headers) {
    for (Map.Entry<String, List<String>> header : headers.entrySet()) {
      for (String value : header.getValue()) {
        if (!restricted(header.getKey(), value)) request.addHeader(header.getKey(), value);
      }
    }
  }

  /** HttpURLConnection 이 덧붙이는 Host(기본 포트는 적지 않는다)와, 없으면 Accept. */
  static void addJdkDefaults(HttpRequestBase request, URL url) {
    request.setHeader("Host", hostHeader(url));
    if (!request.containsHeader("Accept")) request.addHeader("Accept", ACCEPT);
  }

  static String hostHeader(URL url) {
    int port = url.getPort();
    return port == -1 || port == url.getDefaultPort() ? url.getHost() : url.getHost() + ":" + port;
  }

  static String userAgent(String agent, String javaVersion) {
    return agent == null ? "Java/" + javaVersion : agent + " Java/" + javaVersion;
  }

  static String acceptFor(int jdkFeature) {
    return jdkFeature >= 21 ? "*/*" : "text/html, image/gif, image/jpeg, */*; q=0.2";
  }

  /** 응답 헤더를 이름(대소문자 그대로)별로 모은다 — 받은 순서 그대로. */
  static Map<String, List<String>> grouped(HttpResponse head) {
    Map<String, List<String>> out = new LinkedHashMap<>();
    for (Header header : head.getAllHeaders()) out.computeIfAbsent(header.getName(), k -> new ArrayList<>()).add(header.getValue());
    return out;
  }

  /** HttpURLConnection 처럼 쉼표로 나눈 목록(공백을 다듬지 않는다) — 없거나 비면 빈 배열(그때는 걸지 않는다). */
  static String[] tokens(String value) {
    if (value == null) return new String[0];
    StringTokenizer t = new StringTokenizer(value, ",");
    String[] out = new String[t.countTokens()];
    for (int i = 0; i < out.length; i++) out[i] = t.nextToken();
    return out;
  }

  /**
   * HttpURLConnection 의 TLS 단계({@code sun.net.www.protocol.https.HttpsClient.afterConnect}) — 근원(소켓 팩토리·검증기)은 교환의
   * 문맥에서 받는다(상태가 없다). {@code https.protocols}·{@code https.cipherSuites} 를 그대로 걸고, 검증기가 JDK 기본이면 핸드셰이크
   * 안에서 RFC 2818 검사를 하고(그래서 불일치는 HttpURLConnection 과 같은 SSLHandshakeException 이다), 아니면 핸드셰이크 뒤 엄격한
   * 검사 → 검증기 순서로 묻는다. ⚠️ 그 기본 검증기를 Apache 의 검증기로 그냥 넘기면 모든 HTTPS 호출이 깨진다 — JDK 의 기본 검증기
   * 객체는 늘 거짓을 돌려주고, HttpURLConnection 이 이름으로 알아보아 따로 처리한다(실측).
   */
  static final class HucTls implements LayeredConnectionSocketFactory {
    static final HucTls INSTANCE = new HucTls();
    private static final String JDK_DEFAULT_VERIFIER = "javax.net.ssl.HttpsURLConnection.DefaultHostnameVerifier";
    private static final HostnameVerifier STRICT = new DefaultHostnameVerifier();

    private HucTls() {}

    @Override public Socket createSocket(HttpContext context) {
      return new Socket(); // JDK 의 기본 소켓 구현 — socksProxyHost 를 따른다(HttpURLConnection 과 같다)
    }

    @Override public Socket connectSocket(int connectTimeout, Socket socket, HttpHost host, InetSocketAddress remote,
                                          InetSocketAddress local, HttpContext context) throws IOException {
      try {
        socket.connect(remote, connectTimeout);
      } catch (IOException failed) {
        socket.close();
        throw failed;
      }
      return createLayeredSocket(socket, host.getHostName(), remote.getPort(), context);
    }

    @Override public Socket createLayeredSocket(Socket socket, String target, int port, HttpContext context) throws IOException {
      SSLSocketFactory factory = (SSLSocketFactory) context.getAttribute(TLS_FACTORY);
      HostnameVerifier verifier = (HostnameVerifier) context.getAttribute(TLS_VERIFIER);
      SSLSocket tls = (SSLSocket) factory.createSocket(socket, target, port, true);
      String[] protocols = tokens(System.getProperty("https.protocols"));
      if (protocols.length > 0) tls.setEnabledProtocols(protocols);
      String[] suites = tokens(System.getProperty("https.cipherSuites"));
      if (suites.length > 0) tls.setEnabledCipherSuites(suites);
      boolean checkAfter = true;
      String identification = tls.getSSLParameters().getEndpointIdentificationAlgorithm();
      if (identification != null && !identification.isEmpty()) {
        checkAfter = !identification.equalsIgnoreCase("HTTPS"); // 팩토리가 이미 핸드셰이크 안의 검사를 걸었다
      } else if (JDK_DEFAULT_VERIFIER.equals(verifier.getClass().getCanonicalName())) {
        SSLParameters parameters = tls.getSSLParameters();
        parameters.setEndpointIdentificationAlgorithm("HTTPS");
        tls.setSSLParameters(parameters);
        checkAfter = false;
      }
      tls.startHandshake();
      if (checkAfter) checkHostname(tls, target, verifier);
      return tls;
    }

    /** HttpsClient.checkURLSpoofing — 엄격한 검사가 맞으면 통과, 아니면 검증기에 묻고, 둘 다 아니면 닫고 던진다. */
    private static void checkHostname(SSLSocket tls, String target, HostnameVerifier verifier) throws IOException {
      String host = target.replaceFirst("^\\[(.*)]$", "$1");
      SSLSession session = tls.getSession();
      if (STRICT.verify(host, session) || verifier.verify(host, session)) return;
      tls.close();
      session.invalidate();
      throw new IOException("HTTPS hostname wrong:  should be <" + target + ">");
    }
  }
}
