package io.github.xzawed.keycloak.admin;

import io.github.xzawed.keycloak.core.ResponseLimits;
import jakarta.ws.rs.client.Invocation;
import jakarta.ws.rs.core.Response;
import java.io.IOException;
import java.io.InputStream;
import org.apache.http.HttpConnection;
import org.apache.http.client.methods.HttpRequestBase;
import org.apache.http.client.protocol.HttpClientContext;
import org.apache.http.protocol.HttpContext;
import org.jboss.resteasy.client.jaxrs.engines.ApacheHttpClient43Engine;
import org.jboss.resteasy.client.jaxrs.engines.HttpContextProvider;
import org.jboss.resteasy.client.jaxrs.internal.ClientInvocation;
import org.jboss.resteasy.client.jaxrs.internal.ClientResponse;
import org.jboss.resteasy.client.jaxrs.internal.ClientResponseContextImpl;

/**
 * admin 레인의 RESTEasy 엔진 — RESTEasy 가 지은 엔진({@code ClientHttpEngineBuilder43} — 타임아웃·풀·응답 틀의 한도)의 HttpClient 를
 * 그대로 쓰고, 교환마다 그 교환을 <b>읽지 않고 끊을</b> 손잡이({@link Exchange})를 요청 속성 {@link #EXCHANGE} 에 단다. 응답 필터와
 * ReaderInterceptor 가 같은 속성을 본다({@link TokenResponseGuard} 가 거부할 때 쓴다). 응답마다 엔티티 스트림을 {@link Settled} 로
 * 감싸 결과를 얻은 뒤의 닫기도 같은 손잡이로 끝낸다({@link #invoke}).
 *
 * <p>왜: 응답의 스트림을 닫으면 HttpCore 의 닫기({@code ContentLengthInputStream}·{@code ChunkedInputStream.close})가 나머지를 EOF 까지
 * 비운다 — 거부한 64 MiB 토큰 본문을 서버가 끝까지 썼고, 1 바이트 청크면 할당이 비운 양을 따라 자랐고(8 MiB 에 207 MB), 멈춘
 * 서버 앞에서 거부가 읽기 타임아웃을 기다렸다(실측 {@code AdminRejectedResponseCutTest}). 자원 응답도 같았다 — RESTEasy 가 결과를 얻은
 * 응답을 닫아 쓰지 않는 나머지(create 의 201 본문 · JSON 뒤 · 미디어 타입 없는 2xx)를 끝까지 읽었고, 결과 뒤 멈춘 서버 앞에서는 쓸 수
 * 있던 응답이 읽기 타임아웃 끝에 전송 실패가 됐다(실측 {@code AdminResourceResponseCutTest}). auth 레인({@code BoundedTransport.cut})과
 * 같은 규칙으로 바꾼다: EOF 까지 읽은 본문만 연결을 풀로 돌려주고, 그 밖의 끝은 읽기 타임아웃을 0 으로 둔 채 요청을 중단한다 —
 * HttpClient 가 연결을 SO_LINGER 0 으로 닫고 풀에서 뺀다({@code ConnectionHolder.abortConnection}). 끊긴 연결은 다시 쓰이지 않는다.
 *
 * <p>⚠️ 엔진을 새로 짓지 않는다 — RESTEasy 가 지은 엔진({@code owner})의 HttpClient 를 넘겨받고 설정 넷(응답 버퍼 · 검증기 · TLS 근원 ·
 * 리다이렉트)을 옮긴다. HttpClient 를 닫는 것은 그 엔진의 몫이다({@link #close}). 손잡이가 쥘 문맥은 RESTEasy 가 교환마다 묻는
 * {@code HttpContextProvider}(이 엔진 자신 — {@link #getContext})로 건넨다 — {@link #loadHttpMethod} 가 만든 것을 같은 스레드의 바로
 * 다음 물음({@code invoke} 안, {@code httpClient.execute} 직전)이 가져간다.
 */
@SuppressWarnings("removal") // RESTEasy 6.2 의 기본 엔진 그 자체를 잇는다(AdminClient.buildTimeoutClient 설명)
final class AdminEngine extends ApacheHttpClient43Engine implements HttpContextProvider {
  /** 교환의 끊기 손잡이({@link Exchange})를 담는 요청 속성. */
  static final String EXCHANGE = AdminEngine.class.getName() + ".exchange";
  /**
   * 자원 응답의 오류 본문을 쥐는 상한 — 그 본문은 진단({@code keycloakError})에만 쓰여 토큰 응답의 상한을 빌린다. 성공 본문(사용자 목록
   * 등)에는 걸지 않는다 — 정당하게 크다. 토큰 엔드포인트의 오류 본문은 {@link TokenResponseGuard} 가 같은 상한으로 따로 거부한다.
   */
  static final int ERROR_BODY_CAP = ResponseLimits.MAX_TOKEN_RESPONSE_BYTES;
  /** 닫을 때 끝인지 엿보는 읽기의 소켓 기다림 — 0 은 「끝없이」라 가장 짧은 양수다. */
  static final int PEEK_MILLIS = 1;
  private static final ThreadLocal<HttpClientContext> NEXT_CONTEXT = new ThreadLocal<>();
  private final ApacheHttpClient43Engine owner;

  AdminEngine(ApacheHttpClient43Engine owner) {
    super(owner.getHttpClient(), false);
    this.owner = owner;
    setResponseBufferSize(owner.getResponseBufferSize());
    setHostnameVerifier(owner.getHostnameVerifier());
    setSslContext(owner.getSslContext());
    setFollowRedirects(owner.isFollowRedirects());
    // 람다를 두지 않는다 — 그 숨은 클래스는 이름으로 적재되지 않아 파사드를 걷는 시험(HostilePathMatrixTest)이 실패했다
    this.httpContextProvider = this;
  }

  @Override
  protected void loadHttpMethod(ClientInvocation request, HttpRequestBase httpMethod) throws Exception {
    super.loadHttpMethod(request, httpMethod);
    HttpClientContext context = HttpClientContext.create();
    request.getMutableProperties().put(EXCHANGE, new Exchange(httpMethod, context));
    NEXT_CONTEXT.set(context);
  }

  /** {@link #loadHttpMethod} 가 둔 문맥을 가져가고 지운다 — RESTEasy 가 같은 교환에서 곧바로 묻는다. */
  @Override
  public HttpContext getContext() {
    HttpClientContext context = NEXT_CONTEXT.get();
    NEXT_CONTEXT.remove();
    return context;
  }

  /**
   * 응답의 엔티티 스트림을 필터·결합이 보기 전에 {@link Settled} 로 감싼다. 오류 상태(3xx 이상)의 본문은 {@link #ERROR_BODY_CAP} 에서
   * 끝난 것처럼 보인다 — RESTEasy 는 그 본문을 예외에 담으려고 통째로 버퍼에 읽었다({@code ClientInvocation.extractResult} 의
   * {@code bufferEntity} — 64 MiB 오류 본문에 호출 하나 475 MB, 그 전부가 {@code keycloakError} 로). 토큰 엔드포인트는 빼고 그대로 둔다 —
   * {@link TokenResponseGuard} 가 상한+1 바이트로 넘침을 알아채 거부한다.
   */
  @Override
  public Response invoke(Invocation inv) {
    ClientInvocation request = (ClientInvocation) inv;
    Response response = super.invoke(inv);
    ClientResponseContextImpl entity = new ClientResponseContextImpl((ClientResponse) response);
    InputStream in = entity.getEntityStream();
    if (in != null) {
      long limit = response.getStatus() < 300 || TokenResponseGuard.inScope(request.getMethod(), request.getUri())
          ? Long.MAX_VALUE : ERROR_BODY_CAP;
      entity.setEntityStream(new Settled(in, (Exchange) request.getMutableProperties().get(EXCHANGE), limit));
    }
    return response;
  }

  @Override
  public void close() {
    try {
      super.close();
    } finally {
      owner.close();
    }
  }

  /** 교환 하나의 끊기 손잡이 — 그 요청과, 실행이 연결을 적는 문맥. */
  static final class Exchange {
    private final HttpRequestBase request;
    private final HttpClientContext context;

    Exchange(HttpRequestBase request, HttpClientContext context) {
      this.request = request;
      this.context = context;
    }

    /**
     * 읽지 않고 끊는다 — 연결의 읽기 타임아웃을 0 으로 두고(JSSE 는 TLS 1.3 을 닫을 때 받은 바이트가 없으면 읽기 타임아웃만큼 한 번
     * 더 읽어 기다린다 — 타임아웃이 0 이면 읽지 않는다) 요청을 중단한다. 본문을 EOF 까지 읽어 이미 풀로 돌아간 연결은 건드리지 않는다
     * — 그 대리자는 떨어져 나갔고(읽기 타임아웃 설정이 실패한다) 중단은 아무것도 하지 않는다(풀의 연결은 다른 교환의 것이다).
     */
    void cut() {
      readTimeout(0);
      request.abort();
    }

    /**
     * 남은 본문이 없는지 한 번만 엿본다 — 읽기 타임아웃을 {@link #PEEK_MILLIS} 로 낮추고 한 바이트를 읽는다. 끝(-1)이면 참이다. 바이트가
     * 왔거나 기다림이 다했거나 읽기가 실패하면 거짓이다. 낮춘 타임아웃은 그 연결의 다음 교환에 남지 않는다 — HttpClient 가 교환마다
     * 요청 구성의 읽기 타임아웃을 다시 건다({@code MainClientExec}). ⚠️ 읽기가 실패하면 HttpClient 가 그 연결을 이미 닫았다 — 그
     * 닫기(TLS 1.3 이면 한 번 더 읽는다)도 낮춘 타임아웃만 기다린다.
     */
    boolean endsNow(InputStream in) {
      readTimeout(PEEK_MILLIS);
      try {
        return in.read() < 0;
      } catch (IOException notTheEnd) {
        return false;
      }
    }

    private void readTimeout(int millis) {
      HttpConnection connection = context.getConnection();
      if (connection != null) {
        try {
          connection.setSocketTimeout(millis);
        } catch (RuntimeException returned) {
          // 이미 풀로 돌아갔다 — 이 교환의 것이 아니다
        }
      }
    }
  }

  /**
   * 응답 하나의 엔티티 스트림 — 닫을 때 남은 본문을 비우지 않는다. EOF 를 읽었으면 그대로 닫고(HttpClient 가 연결을 풀로 돌려준다), 아니면
   * 끝인지 한 번만 엿보고({@link Exchange#endsNow}) 끝이 아니면 그 교환을 끊은 뒤 닫는다 — 끊긴 연결에서의 닫기는 소켓에 닿지 못하고 버퍼에
   * 남은 것만 지나간다. {@code limit} 바이트를 내주면 끝난 것처럼 -1 을 돌려준다(오류 본문의 상한 — 진짜 끝이 아니므로 닫을 때 엿본다).
   * 길이 0 의 읽기는 스트림에 넘기지 않는다 — HttpCore 의 빈 버퍼는 그것도 소켓에서 기다린다({@code TokenResponseGuard.capPlusOne} 와 같은
   * 처방).
   */
  static final class Settled extends InputStream {
    private final InputStream in;
    private final Exchange exchange;
    private long left;
    private boolean eof;
    private boolean closed;

    Settled(InputStream in, Exchange exchange, long limit) {
      this.in = in;
      this.exchange = exchange;
      this.left = limit;
    }

    @Override
    public int read() throws IOException {
      if (left == 0) return -1;
      int b = in.read();
      if (b < 0) {
        eof = true;
      } else {
        left--;
      }
      return b;
    }

    @Override
    public int read(byte[] b, int off, int len) throws IOException {
      if (len == 0) return 0;
      if (left == 0) return -1;
      int n = in.read(b, off, (int) Math.min(len, left));
      if (n < 0) {
        eof = true;
      } else {
        left -= n;
      }
      return n;
    }

    @Override
    public void close() throws IOException {
      if (closed) return;
      closed = true;
      if (eof || exchange.endsNow(in)) {
        in.close();
        return;
      }
      exchange.cut();
      try {
        in.close();
      } catch (IOException cutAlready) {
        // 끊긴 연결의 닫기는 실패할 수 있다 — HttpCore 가 버퍼의 나머지를 읽은 뒤 TLS 소켓은 -1 을 돌려줘 「Premature end of
        // Content-Length delimited message body」(ConnectionClosedException — HttpClient 가 거르는 SocketException 이 아니다)가 났고
        // RESTEasy 가 그것을 ProcessingException 으로 내 결과를 얻은 호출이 전송 실패가 됐다(실측, TLS 1.3 40/40). 버린다
        // (TokenResponseGuard.closeQuietly 와 같은 처방).
      }
    }
  }
}
