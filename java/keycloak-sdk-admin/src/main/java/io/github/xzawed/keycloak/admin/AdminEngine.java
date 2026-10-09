package io.github.xzawed.keycloak.admin;

import org.apache.http.HttpConnection;
import org.apache.http.client.methods.HttpRequestBase;
import org.apache.http.client.protocol.HttpClientContext;
import org.apache.http.protocol.HttpContext;
import org.jboss.resteasy.client.jaxrs.engines.ApacheHttpClient43Engine;
import org.jboss.resteasy.client.jaxrs.engines.HttpContextProvider;
import org.jboss.resteasy.client.jaxrs.internal.ClientInvocation;

/**
 * admin 레인의 RESTEasy 엔진 — RESTEasy 가 지은 엔진({@code ClientHttpEngineBuilder43} — 타임아웃·풀·응답 틀의 한도)의 HttpClient 를
 * 그대로 쓰고, 교환마다 그 교환을 <b>읽지 않고 끊을</b> 손잡이({@link Exchange})를 요청 속성 {@link #EXCHANGE} 에 단다. 응답 필터와
 * ReaderInterceptor 가 같은 속성을 본다({@link TokenResponseGuard} 가 거부할 때 쓴다).
 *
 * <p>왜: 거부한 응답의 스트림을 닫으면 HttpCore 의 닫기({@code ContentLengthInputStream}·{@code ChunkedInputStream.close})가 나머지를
 * EOF 까지 비운다 — 거부한 64 MiB 본문을 서버가 끝까지 썼고, 1 바이트 청크면 할당이 비운 양을 따라 자랐고(8 MiB 에 207 MB), 멈춘
 * 서버 앞에서 거부가 읽기 타임아웃을 기다렸다(실측 {@code AdminRejectedResponseCutTest}). auth 레인({@code BoundedTransport.cut})과
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
      HttpConnection connection = context.getConnection();
      if (connection != null) {
        try {
          connection.setSocketTimeout(0);
        } catch (RuntimeException returned) {
          // 이미 풀로 돌아갔다 — 이 교환의 것이 아니다
        }
      }
      request.abort();
    }
  }
}
