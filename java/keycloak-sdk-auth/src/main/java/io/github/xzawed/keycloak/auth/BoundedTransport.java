package io.github.xzawed.keycloak.auth;

import io.github.xzawed.keycloak.core.ResponseLimits;
import java.io.FilterInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.InterruptedIOException;
import java.lang.ref.WeakReference;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.net.SocketException;
import java.net.SocketTimeoutException;
import java.net.URL;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.StringTokenizer;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicLong;
import javax.net.ssl.HostnameVerifier;
import javax.net.ssl.SSLParameters;
import javax.net.ssl.SSLSession;
import javax.net.ssl.SSLSocket;
import javax.net.ssl.SSLSocketFactory;
import org.apache.http.Header;
import org.apache.http.HttpClientConnection;
import org.apache.http.HttpConnection;
import org.apache.http.HttpConnectionMetrics;
import org.apache.http.HttpEntity;
import org.apache.http.HttpException;
import org.apache.http.HttpHost;
import org.apache.http.HttpRequest;
import org.apache.http.HttpRequestInterceptor;
import org.apache.http.HttpResponse;
import org.apache.http.MessageConstraintException;
import org.apache.http.NoHttpResponseException;
import org.apache.http.ProtocolException;
import org.apache.http.client.HttpRequestRetryHandler;
import org.apache.http.client.config.RequestConfig;
import org.apache.http.client.methods.HttpRequestBase;
import org.apache.http.client.protocol.HttpClientContext;
import org.apache.http.config.ConnectionConfig;
import org.apache.http.config.MessageConstraints;
import org.apache.http.config.Registry;
import org.apache.http.config.RegistryBuilder;
import org.apache.http.conn.ConnectionKeepAliveStrategy;
import org.apache.http.conn.ConnectionPoolTimeoutException;
import org.apache.http.conn.ConnectionRequest;
import org.apache.http.conn.DnsResolver;
import org.apache.http.conn.HttpConnectionFactory;
import org.apache.http.conn.ManagedHttpClientConnection;
import org.apache.http.conn.routing.HttpRoute;
import org.apache.http.conn.routing.RouteInfo;
import org.apache.http.conn.socket.ConnectionSocketFactory;
import org.apache.http.conn.socket.LayeredConnectionSocketFactory;
import org.apache.http.conn.socket.PlainConnectionSocketFactory;
import org.apache.http.conn.ssl.DefaultHostnameVerifier;
import org.apache.http.entity.BasicHttpEntity;
import org.apache.http.impl.DefaultConnectionReuseStrategy;
import org.apache.http.impl.client.CloseableHttpClient;
import org.apache.http.impl.client.DefaultConnectionKeepAliveStrategy;
import org.apache.http.impl.client.HttpClientBuilder;
import org.apache.http.impl.conn.DefaultHttpResponseParser;
import org.apache.http.impl.conn.DefaultManagedHttpClientConnection;
import org.apache.http.impl.conn.PoolingHttpClientConnectionManager;
import org.apache.http.impl.conn.SystemDefaultRoutePlanner;
import org.apache.http.io.BufferInfo;
import org.apache.http.io.HttpMessageParserFactory;
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
 * {@link ResponseLimits#MAX_HEADER_COUNT} — 상태 줄·헤더·청크 크기 줄·트레일러 모두)를 건다 · (2) 본문을 EOF 까지 읽지 않은 교환의
 * 연결은 <b>비우지 않고 끊는다</b>({@link #cut} — 풀에 돌려주지 않는다) · (3) 첫 줄이 상태 줄이 아니면 곧바로 거부하고
 * (HttpURLConnection 처럼 — HttpClient 는 쓰레기 줄을 한도 없이 건너뛴다) 1xx 중간 응답은 {@value #MAX_INTERIM_RESPONSES} 개까지만
 * 받는다 · (4) 연결은 프로세스에 하나인 풀에서 다시 쓴다(아래) · (5) 하위 운송의 예외는 응답을 인용할 수 있으므로({@code Bad chunk
 * header: <줄>}) 상수 메시지의 {@link IOException} 으로 바꾼다({@link #shield}) · (6) 본문을 읽는 동안 받는 틀의 바이트를 본문 상한의
 * {@value #WIRE_FACTOR} 배로 묶는다({@link #wireBounded}) · (7) 거부하며 닫는 TLS 연결이 더 읽지 않게 한다 — JSSE 는 TLS 1.3 을 닫을 때
 * 도착한 바이트가 없으면 읽기 타임아웃만큼 한 번 더 읽어 기다린다(실측: 상태 줄 뒤 조용한 서버에 읽기 타임아웃 8 초면 거부가 8,025
 * ms) — 끊기 전에 그 타임아웃을 0 으로 둔다({@link #quiet}) · (8) 다시 쓰려는 연결에 아무도 묻지 않은 바이트가 와 있으면(앞 응답 뒤에
 * 서버가 더 보냈다) 그 연결을 버린다 — 다음 요청이 그것을 제 응답으로 읽는다(실측: 204 뒤에 붙인 200 「EVIL」을 다음 호출이 받았다.
 * HttpURLConnection 은 응답마다 새 버퍼로 읽어 버퍼에 남은 것을 버렸다). TLS 에서 늦게 도착해 아직 풀리지 않은 바이트는 보이지 않는다
 * — 같은 서버가 같은 연결로 보낸 것이다.
 *
 * <p><b>풀</b>({@link #POOL}): HttpURLConnection 의 keep-alive 캐시처럼 프로세스에 하나다. AuthClient 는 닫히지 않으므로(AutoCloseable
 * 이 아니다) 클라이언트마다 풀을 두면 그 연결을 닫을 자리가 없고, 클라이언트를 호출마다 만드는 소비자에게 소켓이 클라이언트 수만큼
 * 쌓인다. 경로(호스트·포트·프록시)마다 {@value #MAX_PER_ROUTE} 개까지 — admin 레인의 RESTEasy 풀과 같은 수이고, 넘는 동시 호출은 연결
 * 타임아웃만큼 연결을 기다린다. 백그라운드 스레드가 없다: 쉰 지 {@value #IDLE_MILLIS} ms(서버의 {@code Keep-Alive: timeout} 이 더
 * 짧으면 그것 — {@link #idleMillis})가 지난 연결은 다음 교환이 닫고, {@value #VALIDATE_AFTER_MILLIS} ms 넘게 쉰 연결은 빌려줄 때 살아
 * 있는지 본다. 다시 쓴 연결이 응답 바이트 하나 없이 끊기면(쉬는 동안 서버가 닫았다) 한 번 다시 보낸다 — HttpURLConnection 도
 * 그랬다(그쪽은 새 연결의 실패도 다시 보낸다). 연결에는 맺을 때의 TLS 근원({@link TlsKey})을 달아 같은 근원의 교환만 다시 쓴다 —
 * HttpURLConnection 은 소켓 팩토리만 가려 검증기가 다른 교환도 검증 없이 다시 썼다.
 *
 * <p>⚠️ <b>HttpURLConnection 과 같아야 하는 것</b>(실측 대조 — {@code TransportParityTest}): 요청 머리(User-Agent ·
 * Accept · Host · Connection — 아래 상수들), 제한 헤더를 버리는 규칙({@link #restricted}), 리다이렉트를 따르지 않음, 내용 코딩을
 * 요청하지도 풀지도 않음(상한은 받은 바이트를 센다), 시스템 프록시({@code http(s).proxyHost} — {@code ProxySelector}), 거절된
 * CONNECT 는 응답이 아니라 IOException, TLS 단계({@link HucTls}), 연결 재사용, 요청·응답을 로그에 찍지 않음. <b>따라하지 않는
 * 것</b>(JVM 전역 훅 — 키클록의 정상 응답에는 닿지 않는다): {@code CookieHandler} · {@code ResponseCache} ·
 * {@code java.net.Authenticator}(401·407 도전에 답하지 않는다),
 * 새 연결의 한 번 재시도, {@code http.keepAlive=false} 의 {@code Connection: close}, {@code http.maxConnections}(쉬는 연결 5 개).
 */
final class BoundedTransport {
  private BoundedTransport() {}

  /** 1xx 중간 응답을 이보다 많이 받으면 거부한다 — 끝없이 보내는 서버에 시간이 묶이도록(HttpURLConnection 은 재귀하다 넘쳤다). */
  static final int MAX_INTERIM_RESPONSES = 8;
  /** 본문을 읽는 동안 연결에서 받아도 되는 바이트 — 본문 상한의 이 배수({@link #wireBounded}). */
  static final int WIRE_FACTOR = 8;
  /** 본문 읽기 한 번이 소켓에 요청하는 최대 바이트 — 그 사이에 받은 바이트를 센다({@link #wireBounded}). */
  static final int MAX_READ = 16 * 1024;
  /** 경로(호스트·포트·프록시) 하나에 동시에 여는 연결의 상한 — admin 레인의 RESTEasy 풀(경로당 50)과 같다. 넘는 호출은 기다린다. */
  static final int MAX_PER_ROUTE = 50;
  /** 쉬는 연결의 수명 — HttpURLConnection 의 기본(KeepAliveCache 5 초). */
  static final long IDLE_MILLIS = 5_000;
  /** 이보다 오래 쉰 연결은 빌려줄 때 1 ms 읽기로 살아 있는지 본다(HttpClient 의 기본값). */
  static final int VALIDATE_AFTER_MILLIS = 2_000;
  /** 하위 운송이 응답을 해석하지 못했다 — HttpURLConnection 이 같은 경우에 쓰는 말 그대로. 응답을 인용하지 않는다. */
  static final String INVALID_RESPONSE = "Invalid Http response";
  /** 응답 머리·청크 줄·트레일러가 한도를 넘었다. 응답을 인용하지 않는다. */
  static final String OVER_LIMITS = "HTTP response framing exceeds " + ResponseLimits.MAX_LINE_LENGTH + "-byte lines or "
      + ResponseLimits.MAX_HEADER_COUNT + " header fields";
  /** 프록시가 CONNECT 를 거절했다(HttpURLConnection 처럼 응답이 아니라 IOException — 프록시의 응답은 인용하지 않는다). */
  static final String TUNNEL_REFUSED = "Unable to tunnel through proxy";
  /** 경로의 연결이 모두 쓰이는 동안 연결 타임아웃이 지났다. */
  static final String POOL_TIMEOUT = "Timed out waiting for a pooled connection";
  /** 연결을 기다리던 스레드가 인터럽트됐다. */
  static final String INTERRUPTED = "Interrupted while waiting for a pooled connection";
  /** HttpURLConnection 의 기본 User-Agent — 그 클래스처럼 초기화 때 한 번 읽는다. */
  static final String USER_AGENT = userAgent(System.getProperty("http.agent"), System.getProperty("java.version"));
  /** HttpURLConnection 의 기본 Accept — JDK 21 부터 {@code *}{@code /*} 다(17 은 옛 목록). */
  static final String ACCEPT = acceptFor(Runtime.version().feature());

  private static final String APACHE = "org.apache.http.";
  private static final String TLS_FACTORY = BoundedTransport.class.getName() + ".tlsFactory";
  private static final String TLS_VERIFIER = BoundedTransport.class.getName() + ".tlsVerifier";
  /** 교환의 읽기 타임아웃 — 풀의 소켓 설정은 교환마다 다르지 않으므로 소켓을 맺는 자리(아래 팩토리들)가 이것으로 건다. */
  private static final String READ_TIMEOUT = BoundedTransport.class.getName() + ".readTimeout";
  /** 본문을 읽는 동안 받아도 되는 바이트 — 실행기가 본문 스트림에 건다. */
  private static final String WIRE_BUDGET = BoundedTransport.class.getName() + ".wireBudget";
  /** 이 시도가 연결을 새로 맺었다 — 다시 보내기는 다시 쓴 연결에만 한다. */
  private static final String FRESH = BoundedTransport.class.getName() + ".fresh";
  /** 이 시도의 요청에 응답 바이트가 하나도 오지 않았다. */
  private static final String UNANSWERED = BoundedTransport.class.getName() + ".unanswered";
  /** 연결의 속성 — 다시 쓰려는 연결에 아무도 묻지 않은 바이트가 와 있다({@link #CONNECTIONS}). */
  static final String UNSOLICITED = BoundedTransport.class.getName() + ".unsolicited";

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
  private static final HttpMessageParserFactory<HttpResponse> STATUS_LINE_FIRST = (buffer, constraints) ->
      new DefaultHttpResponseParser(buffer, null, null, constraints) {
        @Override protected boolean reject(CharArrayBuffer line, int count) {
          return true;
        }
      };

  private static final AtomicLong CONNECTION_IDS = new AtomicLong();

  /**
   * 연결 — HttpCore 의 기본 연결에, 다시 쓰기 전에 묻지 않은 바이트가 와 있는지 답하는 문맥 속성 하나를 더했다({@link #UNSOLICITED} —
   * 풀의 대리자가 그대로 넘긴다). ⚠️ HttpClient 의 기본 공장({@code ManagedHttpClientConnectionFactory})은 쓰지 않는다 — 그 연결은
   * DEBUG 에서 요청 머리(Authorization 의 Basic 자격 포함)와 오가는 바이트(토큰)를 그대로 찍는다.
   */
  static final HttpConnectionFactory<HttpRoute, ManagedHttpClientConnection> CONNECTIONS = (route, config) ->
      new DefaultManagedHttpClientConnection("keycloak-sdk-" + CONNECTION_IDS.incrementAndGet(), config.getBufferSize(),
          config.getFragmentSizeHint(), null, null, config.getMessageConstraints(), null, null, null, STATUS_LINE_FIRST) {
        @Override public Object getAttribute(String id) {
          return UNSOLICITED.equals(id) ? unsolicited() : super.getAttribute(id);
        }

        /** 입력 버퍼에 남은 바이트, 또는 소켓에 와 있는 바이트(TLS 면 JSSE 가 이미 푼 것만 보인다). 요청을 보내기 전이니 묻지 않은 것이다. */
        private boolean unsolicited() {
          try {
            return ((BufferInfo) getSessionInputBuffer()).length() > 0 || getSocket().getInputStream().available() > 0;
          } catch (IOException gone) {
            return true;
          }
        }
      };

  /** HttpURLConnection 처럼 이름의 첫 주소 하나에만 붙는다(HttpClient 의 기본은 주소마다 연결 타임아웃을 다시 쓴다). */
  private static final DnsResolver FIRST_ADDRESS = host -> new InetAddress[] {InetAddress.getByName(host)};

  /** 평문 소켓 — 맺은 뒤 교환의 읽기 타임아웃을 건다(프록시의 CONNECT 응답도 그 아래에서 읽는다). */
  private static final ConnectionSocketFactory PLAIN = new ConnectionSocketFactory() {
    @Override public Socket createSocket(HttpContext context) {
      return new Socket();
    }

    @Override public Socket connectSocket(int connectTimeout, Socket socket, HttpHost host, InetSocketAddress remote,
                                          InetSocketAddress local, HttpContext context) throws IOException {
      Socket connected = PlainConnectionSocketFactory.getSocketFactory()
          .connectSocket(connectTimeout, socket, host, remote, local, context);
      connected.setSoTimeout(readTimeout(context));
      return connected;
    }
  };

  private static final Registry<ConnectionSocketFactory> SOCKETS = RegistryBuilder.<ConnectionSocketFactory>create()
      .register("http", PLAIN)
      .register("https", HucTls.INSTANCE)
      .build();

  /** HttpURLConnection 처럼 {@code keep-alive} — 평문 프록시를 지날 때는 {@code Proxy-Connection} 이다. 이미 있으면 둔다. */
  private static final HttpRequestInterceptor CONNECTION = (request, context) -> {
    RouteInfo route = HttpClientContext.adapt(context).getHttpRoute();
    String name = route.getProxyHost() != null && !route.isTunnelled() ? "Proxy-Connection" : "Connection";
    if (!request.containsHeader(name)) request.addHeader(name, "keep-alive");
  };

  /**
   * 1xx 를 세고, 거절된 CONNECT 를 IOException 으로 바꾸고, 본문에 틀 예산을 걸고({@link #wireBounded}), 실패한 시도가 응답 바이트를
   * 받았는지 적는 실행기 — 상태가 없어 모든 교환이 함께 쓴다. 응답을 받다 실패하면 HttpCore 가 곧 연결을 닫으므로 그 전에 읽기
   * 타임아웃을 0 으로 둔다({@link #quiet} — 요청을 쓰다 실패한 연결은 이미 죽어 JSSE 가 기다릴 것이 없다).
   */
  private static final HttpRequestExecutor EXECUTOR = new HttpRequestExecutor() {
    @Override
    public HttpResponse execute(HttpRequest request, HttpClientConnection conn, HttpContext context)
        throws IOException, HttpException {
      long before = conn.getMetrics().getReceivedBytesCount();
      HttpResponse response;
      try {
        response = super.execute(request, conn, context);
      } catch (IOException e) {
        if (conn.getMetrics().getReceivedBytesCount() == before) context.setAttribute(UNANSWERED, Boolean.TRUE);
        throw e;
      }
      // HttpClient 는 거절된 CONNECT 의 응답(본문까지 통째로 버퍼에 담아)을 호출자에게 돌려준다 — 받기 전에 끊는다.
      if ("CONNECT".equals(request.getRequestLine().getMethod()) && response.getStatusLine().getStatusCode() != 200) {
        throw new IOException(TUNNEL_REFUSED);
      }
      return response;
    }

    @Override
    protected HttpResponse doReceiveResponse(HttpRequest request, HttpClientConnection conn, HttpContext context)
        throws HttpException, IOException {
      try {
        for (int interim = 0; ; interim++) {
          HttpResponse response = conn.receiveResponseHeader();
          if (response.getStatusLine().getStatusCode() >= 200) {
            if (canResponseHaveBody(request, response)) {
              conn.receiveResponseEntity(response);
              // HttpCore 가 만든 그대로의 엔티티(BHttpConnectionBase.prepareInput) — 그 스트림 위에, EOF 를 알아채 연결을 놓는 HttpClient 의
              // 감싸개 아래에 건다: 마지막 읽기(트레일러 포함)까지 연결을 쥔 채로 센다.
              BasicHttpEntity entity = (BasicHttpEntity) response.getEntity();
              entity.setContent(wireBounded(entity.getContent(), conn, (Long) context.getAttribute(WIRE_BUDGET)));
            }
            return response;
          }
          if (interim >= MAX_INTERIM_RESPONSES) throw new ProtocolException("too many interim responses");
        }
      } catch (IOException | HttpException | RuntimeException e) {
        quiet(conn);
        throw e;
      }
    }
  };

  /** 서버가 {@code Keep-Alive: timeout} 으로 준 시간과 {@link #IDLE_MILLIS} 중 짧은 것 — {@link #idleMillis}. */
  private static final ConnectionKeepAliveStrategy KEEP_ALIVE =
      (response, context) -> idleMillis(DefaultConnectionKeepAliveStrategy.INSTANCE.getKeepAliveDuration(response, context));

  /**
   * 한 번만 다시 보낸다 — 풀에서 꺼낸(다시 쓰는) 연결이 응답 바이트 하나 없이 끊겼을 때만(쉬는 동안 서버가 닫은 연결). 새 연결의 실패와
   * 응답이 오다 끊긴 것은 다시 보내지 않는다 — 서버가 처리한 요청(인가 코드·회전하는 refresh 토큰)을 두 번 보내지 않게. 다시 보내기
   * 전에 쉬는 연결을 모두 닫는다 — 하나가 죽었으면 함께 쉬던 것들도 그럴 수 있어(서버가 다시 떴다) 다시 보내기가 또 죽은 연결을 빌리지
   * 않게, 새 연결로 간다(HttpURLConnection 도 다시 보낼 때 새 연결을 열었다). 시도 수의 한도는 그 사이 다른 교환이 죽은 연결을 돌려준
   * 경우를 묶는다.
   */
  private static final HttpRequestRetryHandler STALE_ONCE = (failure, attempt, context) -> {
    boolean stale = attempt == 1 && context.getAttribute(FRESH) == null && context.getAttribute(UNANSWERED) != null
        && (failure instanceof NoHttpResponseException || failure instanceof SocketException);
    if (stale) BoundedTransport.POOL.closeIdleConnections(0, TimeUnit.MILLISECONDS);
    return stale;
  };

  /** 교환들이 함께 쓰는 연결 풀 — 프로세스에 하나(클래스 설명). */
  static final PoolingHttpClientConnectionManager POOL = pool();
  private static final CloseableHttpClient CLIENT = HttpClientBuilder.create()
      .setConnectionManager(POOL)
      .setConnectionManagerShared(true)
      .setRoutePlanner(new SystemDefaultRoutePlanner(null))
      .setRequestExecutor(EXECUTOR)
      .setUserAgent(USER_AGENT)
      .addInterceptorFirst(CONNECTION)
      .setConnectionReuseStrategy(DefaultConnectionReuseStrategy.INSTANCE)
      .setKeepAliveStrategy(KEEP_ALIVE)
      .setRetryHandler(STALE_ONCE)
      .disableRedirectHandling()
      .disableContentCompression()
      .disableCookieManagement()
      .build();

  private static PoolingHttpClientConnectionManager pool() {
    PoolingHttpClientConnectionManager pool = new PoolingHttpClientConnectionManager(SOCKETS, CONNECTIONS, null, FIRST_ADDRESS,
        -1, TimeUnit.MILLISECONDS) {
      @Override
      public void connect(HttpClientConnection conn, HttpRoute route, int connectTimeout, HttpContext context)
          throws IOException {
        context.setAttribute(FRESH, Boolean.TRUE);
        super.connect(conn, route, connectTimeout, context);
      }

      @Override
      public ConnectionRequest requestConnection(HttpRoute route, Object state) {
        ConnectionRequest lease = super.requestConnection(route, state);
        return new ConnectionRequest() {
          @Override
          public HttpClientConnection get(long timeout, TimeUnit unit)
              throws InterruptedException, ExecutionException, ConnectionPoolTimeoutException {
            HttpClientConnection conn = lease.get(timeout, unit);
            // 다시 쓰려는 연결에 묻지 않은 바이트가 와 있다(앞 응답 뒤에 서버가 더 보냈다) — 다음 요청이 그것을 제 응답으로 읽는다.
            // 닫으면 HttpClient 가 같은 자리에 새 소켓을 맺는다(그 시도는 새 연결이다). HttpURLConnection 은 응답마다 새 버퍼로 읽어
            // 버퍼에 남은 것을 버렸다(실측).
            if (conn.isOpen() && Boolean.TRUE.equals(((HttpContext) conn).getAttribute(UNSOLICITED))) discard(conn);
            return conn;
          }

          @Override
          public boolean cancel() {
            return lease.cancel();
          }
        };
      }

      @Override
      public void shutdown() {
        // 닫지 않는다 — HttpClient 는 교환 중에 Error 가 나면 관리자를 닫는데, 이 풀은 프로세스에 하나라 그러면 이 JVM 의 auth·JWKS
        // 레인이 끝난다. 그 교환이 쥔 연결은 exchange 의 끝(cut)이 끊는다.
      }
    };
    pool.setDefaultConnectionConfig(BOUNDED_HEAD);
    pool.setDefaultMaxPerRoute(MAX_PER_ROUTE);
    pool.setMaxTotal(Integer.MAX_VALUE); // 경로마다의 상한이 묶는다 — 경로는 소비자의 설정이 정한다(응답이 만들지 못한다)
    pool.setValidateAfterInactivity(VALIDATE_AFTER_MILLIS);
    return pool;
  }

  /** 응답의 상태·머리를 받아 본문 스트림에서 결과를 만든다. ⚠️ 본문 스트림을 닫지 않는다 — 닫기는 나머지를 비운다(HttpCore). */
  @FunctionalInterface
  interface Reader<T> {
    T read(HttpResponse head, InputStream body) throws IOException;
  }

  /**
   * 교환 하나 — 풀의 연결로 {@code request} 를 보내고 상태와 머리가 오면 {@code reader} 에 넘긴다. 본문을 EOF 까지 읽었으면 연결은
   * 그때 이미 풀로 돌아갔고(재사용), 아니면(넘침·거부·실패) {@link #cut} 이 그 연결을 읽지 않고 끊는다. 실패는 {@link #shield} 를 거친
   * IOException 이다. TLS 근원은 HttpURLConnection 이 쓰는 소켓 팩토리와 검증기다({@link HucTls}) — 그 근원이 연결의 표식이다
   * ({@link TlsKey}).
   *
   * <p>본문을 읽는 동안 연결에서 받은 바이트(청크 머리·확장·트레일러 포함)는 {@code bodyCap} 의 {@value #WIRE_FACTOR} 배까지다
   * ({@link #wireBounded}) — 본문 상한은 본문만 세서, 한 바이트짜리 청크마다 크기 줄을 줄 한도(8,192)까지 채우면(「0000…01」) 상한
   * 안의 본문에 8 GB 의 틀을 실을 수 있었다(실측: 청크 200,000 개에 1.6 GB 를 받아 할당하고 4.0 초 — 그리고 받아들였다. 예전 운송도
   * 청크 머리 2,050 바이트 한도로 같은 부류였다). 1 바이트 청크의 틀은 본문의 6 배라 그 응답도 본문 상한에 먼저 닿는다.
   */
  static <T> T exchange(HttpRequestBase request, SSLSocketFactory tlsFactory, HostnameVerifier verifier,
                        int connectTimeoutMillis, int readTimeoutMillis, int bodyCap, Reader<T> reader) throws IOException {
    POOL.closeExpiredConnections(); // 스레드 없이 — 수명이 지난 쉬는 연결은 다음 교환이 닫는다
    request.setConfig(RequestConfig.custom()
        .setConnectTimeout(connectTimeoutMillis)
        .setConnectionRequestTimeout(connectTimeoutMillis)
        .setSocketTimeout(readTimeoutMillis)
        .setAuthenticationEnabled(false)
        .build());
    HttpClientContext context = HttpClientContext.create();
    context.setAttribute(TLS_FACTORY, tlsFactory);
    context.setAttribute(TLS_VERIFIER, verifier);
    context.setAttribute(READ_TIMEOUT, readTimeoutMillis);
    context.setAttribute(WIRE_BUDGET, (long) WIRE_FACTOR * bodyCap);
    context.setUserToken(new TlsKey(tlsFactory, verifier));
    try {
      HttpResponse head = CLIENT.execute(request, context);
      HttpEntity entity = head.getEntity();
      return reader.read(head, entity == null ? InputStream.nullInputStream() : entity.getContent());
    } catch (IOException e) {
      throw shield(e);
    } finally {
      cut(request, context);
    }
  }

  /**
   * 교환의 끝. 본문을 EOF 까지 읽은 연결은 그때 이미 풀로 돌아갔다 — 여기서는 아무것도 하지 않는다(이 교환의 연결 대리자는 그때 떨어져
   * 나갔다). 그 밖의 끝(넘침·거부·실패)은 그 연결을 <b>읽지 않고</b> 끊는다 — 읽기 타임아웃을 0 으로 두고({@link #quiet}) 요청을
   * 중단하면 HttpClient 가 연결을 SO_LINGER 0 으로 닫고 풀에서 뺀다({@code ConnectionHolder.abortConnection}). ⚠️ 본문 스트림을 닫거나
   * {@code EntityUtils.consume}·{@code consumeContent} 로 「놓지」 말 것 — HttpCore 의 닫기는 나머지를 EOF 까지 비우고,
   * {@code consumeContent} 는 다 읽지 않은 연결을 풀에 돌려준다(다음 교환이 남은 본문을 응답으로 읽는다).
   */
  private static void cut(HttpRequestBase request, HttpClientContext context) {
    HttpConnection connection = context.getConnection();
    if (connection != null) quiet(connection);
    request.abort();
  }

  /**
   * 곧 닫을 연결의 읽기 타임아웃을 0 으로 — JSSE 는 TLS 1.3 을 닫을 때 받은 바이트가 없으면 읽기 타임아웃만큼 한 번 더 읽어 기다리고
   * (타임아웃이 0 이면 읽지 않는다 — {@code SSLSocketImpl.readLockedDeplete}), 조용한 서버 앞에서 거부가 그만큼 늦었다. 이미 풀로
   * 돌아간 연결(이 교환의 대리자가 떨어져 나갔다)은 건드리지 않는다.
   */
  static void quiet(HttpConnection connection) {
    try {
      connection.setSocketTimeout(0);
    } catch (RuntimeException returned) {
      // 이미 풀로 돌아갔다 — 이 교환의 것이 아니다
    }
  }

  /** 빌린 연결을 다시 쓰지 않고 닫는다 — 읽지 않는다({@link #quiet}). 닫기의 실패는 버린다(어차피 쓰지 않는다). */
  static void discard(HttpConnection connection) {
    quiet(connection);
    try {
      connection.close();
    } catch (IOException ignored) {
      // 쓰지 않을 연결이다
    }
  }

  /**
   * 본문 스트림 — 읽기마다 이 연결이 받은 바이트(소켓에서 버퍼로 — HttpCore 의 연결 지표)를 세어, 본문을 읽기 시작한 뒤 {@code budget}
   * 을 넘으면 상수 메시지로 거부한다. 한 번의 읽기가 넘는 양은 {@value #MAX_READ} 바이트(HttpCore 는 큰 요청을 버퍼를 거치지 않고
   * 소켓에서 바로 읽는다 — 그래서 요청 길이를 자른다)와 청크 머리 한 줄, 트레일러 한 묶음(줄·헤더 수 한도 안)까지다. 길이 0 의 읽기는
   * 소켓에 닿지 않고 0 이다 — HttpCore 의 버퍼는 비었을 때 그것도 기다리고, JDK 의 {@code readNBytes} 는 다 채운 뒤 길이 0 으로 한 번 더
   * 묻는다(실측: 상한+1 바이트 뒤 멈춘 서버 앞에서 넘침을 읽기 타임아웃까지 알아채지 못했다). 거부하거나 읽기가 실패하면 연결의 읽기
   * 타임아웃을 0 으로 둔다({@link #quiet}) — HttpClient 가 곧 그 연결을 닫는다.
   */
  static InputStream wireBounded(InputStream body, HttpClientConnection connection, long budget) {
    HttpConnectionMetrics metrics = connection.getMetrics();
    long start = metrics.getReceivedBytesCount();
    String overBudget = "HTTP response body framing exceeds " + budget + " bytes on the wire";
    return new FilterInputStream(body) {
      @Override public int read() throws IOException {
        try {
          int b = super.read();
          check();
          return b;
        } catch (IOException e) {
          quiet(connection);
          throw e;
        }
      }

      @Override public int read(byte[] buffer, int offset, int length) throws IOException {
        if (length == 0) return 0;
        try {
          int n = super.read(buffer, offset, Math.min(length, MAX_READ));
          check();
          return n;
        } catch (IOException e) {
          quiet(connection);
          throw e;
        }
      }

      private void check() throws IOException {
        if (metrics.getReceivedBytesCount() - start > budget) throw new IOException(overBudget);
      }
    };
  }

  /**
   * 하위 운송의 예외를 응답을 인용하지 않는 것으로 — JDK 의 예외(타임아웃·연결 거부·TLS·DNS)와 SDK 의 것은 그대로 두고, HttpClient
   * 가 JDK 의 예외를 감싼 것(연결 실패)은 그 원인을 꺼내고(HttpURLConnection 이 던지는 바로 그것), 풀의 기다림이 끝난 것은 JDK 의
   * 타임아웃·인터럽트 예외로, 나머지(틀 오류 · 한도 초과)는 상수 메시지의 IOException 이다 — 원인을 달지 않는다(HttpCore 의 메시지는
   * 응답의 줄을 싣는다: {@code Bad chunk header: <줄>}).
   */
  static IOException shield(IOException e) {
    if (!e.getClass().getName().startsWith(APACHE)) return e;
    if (e.getCause() instanceof IOException cause) return shield(cause);
    if (e instanceof ConnectionPoolTimeoutException) return new SocketTimeoutException(POOL_TIMEOUT);
    if (e instanceof InterruptedIOException) return new InterruptedIOException(INTERRUPTED);
    return new IOException(e instanceof MessageConstraintException ? OVER_LIMITS : INVALID_RESPONSE);
  }

  /** 서버가 준 쉬는 시간(없으면 음수)을 풀의 쉬는 수명으로 — {@link #IDLE_MILLIS} 를 넘지 않고, 0 이면 곧 닫는다(1 ms). */
  static long idleMillis(long serverMillis) {
    return serverMillis < 0 ? IDLE_MILLIS : Math.max(1, Math.min(serverMillis, IDLE_MILLIS));
  }

  private static int readTimeout(HttpContext context) {
    return (Integer) context.getAttribute(READ_TIMEOUT);
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
   * 풀의 연결에 다는 표식 — 그 연결을 맺은 TLS 근원(소켓 팩토리·검증기)의 정체. 풀은 같은 표식의 교환에만 그 연결을 빌려준다
   * ({@code RouteSpecificPool.getFree(state)}). 근원을 붙잡지 않는다(약한 참조) — 근원이 사라진 표식은 자기 자신 말고는 무엇과도 같지
   * 않아 그 연결은 다시 쓰이지 않고 수명이 지나면 닫힌다(빌리는 교환은 제 근원을 쥐고 있으므로 살아 있다). 없는 근원(null)은 하나의
   * 표지로 센다. 비밀을 쥐지 않고, 문자열 표현은 상수다.
   */
  static final class TlsKey {
    /** 없는 근원 — 약한 참조의 null(사라진 근원)과 가르려고 강하게 쥔 표지다. */
    private static final Object NONE = new Object();
    private final WeakReference<Object> factory;
    private final WeakReference<Object> verifier;
    private final int hash;

    TlsKey(SSLSocketFactory factory, HostnameVerifier verifier) {
      Object f = factory == null ? NONE : factory;
      Object v = verifier == null ? NONE : verifier;
      this.factory = new WeakReference<>(f);
      this.verifier = new WeakReference<>(v);
      this.hash = 31 * System.identityHashCode(f) + System.identityHashCode(v);
    }

    @Override public boolean equals(Object o) {
      if (o == this) return true;
      if (!(o instanceof TlsKey other)) return false;
      Object f = factory.get();
      Object v = verifier.get();
      return f != null && v != null && f == other.factory.get() && v == other.verifier.get();
    }

    @Override public int hashCode() {
      return hash;
    }

    @Override public String toString() {
      return "TlsKey";
    }
  }

  /**
   * HttpURLConnection 의 TLS 단계({@code sun.net.www.protocol.https.HttpsClient.afterConnect}) — 근원(소켓 팩토리·검증기)은 교환의
   * 문맥에서 받는다(상태가 없다). {@code https.protocols}·{@code https.cipherSuites} 를 그대로 걸고, 검증기가 JDK 기본이면 핸드셰이크
   * 안에서 RFC 2818 검사를 하고(그래서 불일치는 HttpURLConnection 과 같은 SSLHandshakeException 이다), 아니면 핸드셰이크 뒤 엄격한
   * 검사 → 검증기 순서로 묻는다. ⚠️ 그 기본 검증기를 Apache 의 검증기로 그냥 넘기면 모든 HTTPS 호출이 깨진다 — JDK 의 기본 검증기
   * 객체는 늘 거짓을 돌려주고, HttpURLConnection 이 이름으로 알아보아 따로 처리한다(실측). 핸드셰이크는 교환의 읽기 타임아웃 아래에서
   * 한다(풀의 소켓 설정은 교환마다 다르지 않다).
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
      socket.setSoTimeout(readTimeout(context));
      SSLSocket tls = (SSLSocket) factory.createSocket(socket, target, port, true);
      try {
        handshake(tls, target, verifier);
      } catch (IOException | RuntimeException failed) {
        // 넘기기 전의 실패 — 이 소켓을 여기서 닫는다(autoClose 라 그 아래 평문 소켓도). 핸드셰이크 전이라 읽을 것이 없거나 이미
        // 닫혔다(검증기 거부 · JSSE 의 핸드셰이크 실패) — 닫기가 기다리지 않는다.
        try {
          tls.close();
        } catch (IOException ignored) {
          // 실패한 연결이다 — 처음의 실패를 던진다
        }
        throw failed;
      }
      return tls;
    }

    /** HttpURLConnection 처럼 규약·암호 묶음을 걸고, 이름 검사를 정해 핸드셰이크한다(검사가 뒤에 오면 {@link #checkHostname}). */
    private static void handshake(SSLSocket tls, String target, HostnameVerifier verifier) throws IOException {
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
    }

    /**
     * HttpsClient.checkURLSpoofing — 엄격한 검사가 맞으면 통과, 아니면 검증기에 묻고, 둘 다 아니면 닫고 던진다(닫기 전에 읽기
     * 타임아웃을 0 으로 — 조용한 서버 앞에서 JSSE 가 기다리지 않게).
     */
    private static void checkHostname(SSLSocket tls, String target, HostnameVerifier verifier) throws IOException {
      String host = target.replaceFirst("^\\[(.*)]$", "$1");
      SSLSession session = tls.getSession();
      if (STRICT.verify(host, session) || verifier.verify(host, session)) return;
      tls.setSoTimeout(0);
      tls.close();
      session.invalidate();
      throw new IOException("HTTPS hostname wrong:  should be <" + target + ">");
    }
  }
}
