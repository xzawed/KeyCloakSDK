package io.github.xzawed.keycloak.admin;

import com.fasterxml.jackson.core.JsonFactory;
import com.fasterxml.jackson.core.JsonParser;
import com.fasterxml.jackson.core.JsonToken;
import io.github.xzawed.keycloak.core.ResponseLimits;
import jakarta.ws.rs.HttpMethod;
import jakarta.ws.rs.client.ClientRequestContext;
import jakarta.ws.rs.client.ClientResponseContext;
import jakarta.ws.rs.client.ClientResponseFilter;
import jakarta.ws.rs.core.Response;
import jakarta.ws.rs.ext.ReaderInterceptor;
import jakarta.ws.rs.ext.ReaderInterceptorContext;
import java.io.ByteArrayInputStream;
import java.io.FilterInputStream;
import java.io.IOException;
import java.io.InputStream;

/**
 * admin 레인의 토큰 응답 검사 — 토큰 엔드포인트의 성공 응답이 <b>HTTP 필드 값이 실을 수 있는 비어 있지 않은 JSON 문자열</b>
 * {@code access_token} 을 싣지 않으면({@link #fieldValueSafe}) 그 응답을 거부한다.
 *
 * <p>왜 여기인가: admin 은 토큰을 자체 소유하고(§4) keycloak-admin-client 내장 TokenManager 가 토큰 응답을 Jackson 으로
 * {@code AccessTokenResponse} 에 결합한다. Jackson 의 스칼라 강제변환이 숫자·불리언을 문자열로 바꾸고 빈 문자열은 그대로
 * 둬서, admin API 가 {@code Bearer 12345}·{@code Bearer true}·{@code Bearer } 로 불렸다(실측 — {@code AdminTokenResponseTest}).
 * 결합 뒤에는 원래 JSON 타입이 남지 않으므로 결합 <b>앞</b>의 바이트를 본다. TokenManager 의 부여·갱신 요청도
 * {@link AdminClient#buildTimeoutClient} 의 클라이언트로 나가므로 거기에 등록한다.
 *
 * <p>범위는 POST · 경로 꼬리 {@value #TOKEN_PATH_SUFFIX} · 2xx 응답뿐이다 — 응답 필터가 정한다. admin 자원 응답의
 * 역직렬화는 건드리지 않는다. 오류 상태는 상한 안이면 그대로 넘긴다 — 갱신이 400 이면 TokenManager 가 {@code BadRequestException} 을
 * 받아 client_credentials 로 다시 부여하는 복구 경로가 있다. ⚠️ 그래도 오류 본문은 상한까지만 읽는다 — RESTEasy 는 오류 상태의 본문을
 * 통째로 버퍼에 담아(32 MiB 오류 본문에 약 107 MB 할당, 실측 — {@code TokenResponseCapTest}) 상한을 넘으면 같은 거부를 던진다.
 *
 * <p>⚠️ <b>판정은 결합이 읽을 바이트로 한다</b> — 응답 필터가 보는 원시 엔티티가 아니다. RESTEasy 는 엔티티를
 * ReaderInterceptor 사슬을 거쳐 결합에 넘기고, 그 사슬이 바이트를 바꿀 수 있다: 소비자가 {@code resteasy.allowGzip=true} 를
 * 켜면 GZIPDecodingInterceptor 가 {@code Content-Encoding: gzip} 을 푼다. 원시 바이트를 판정하던 때는 gzip 으로 온 쓸 수 있는
 * 토큰을 거부해 admin 이 통째로 멈췄다(실측 — 가드 없이는 성공). 그래서 범위 안의 응답은 이 객체를 <b>가장 안쪽</b>
 * ReaderInterceptor 로도 등록해({@link #READ_PRIORITY}) 결합 직전의 스트림을 판정한다. 예외는 하나 — 미디어 타입이 없는
 * 2xx 는 결합이 아예 읽지 않으므로(RESTEasy {@code ClientInvocation.extractResult} 는 200 이면 ResponseProcessingException 을
 * 던지고 그 밖의 2xx 면 null 을 돌려줘 TokenManager 가 NPE 로 멈춘다 — 그 사슬은 ProcessingException 이 그대로다) 응답
 * 필터에서 원시 바이트로 판정한다.
 *
 * <p>거부는 상수 메시지의 {@link IOException} 이다. 응답 필터에서 던지면 RESTEasy 가 {@code ResponseProcessingException} 으로,
 * 엔티티 읽기에서 던지면 {@code ProcessingException} 을 거쳐 {@code ResponseProcessingException} 으로 감싸고(그래서 TokenManager
 * 갱신의 {@code BadRequestException} 복구에도 닿지 않는다 — 실측), 그것이 BearerAuthFilter(요청 필터) 밖으로 나가므로 admin
 * 요청은 보내지지 않고, {@link AdminExceptions} 가 {@code KeycloakTransportException} 으로 바꾼다 — null·객체·배열·누락이
 * 이미 실패하던 타입이다. 메시지는 상수다(응답을 인용하지 않는다).
 *
 * <p>⚠️ <b>판정은 본문을 상한({@link ResponseLimits#MAX_TOKEN_RESPONSE_BYTES} — auth 레인과 함께 쓰는 값)까지만 읽고
 * 쥔다.</b> 통째로 읽던 때는 힙보다 큰 2xx 본문이
 * {@code OutOfMemoryError} 를 냈다 — RESTEasy 가 감싸 결과는 거부였어도 그 순간 JVM 전체가 메모리를 잃었고, JSON 공백으로
 * 부풀린 <b>쓸 수 있는</b> 토큰도 그랬다(가드 없는 결합은 그것을 스트리밍으로 통과시킨다). {@code readNBytes(상한+1)} 로 읽어
 * 넘침을 알아채면 나머지는 읽지 않고 그 연결을 끊은 뒤({@link #release} — {@link AdminEngine}) 쓸 수 없는 토큰과 같은 거부를 던진다.
 * 그 메서드(JDK 17·21 의 {@code InputStream} 기본 구현 — RESTEasy·HttpCore 의 스트림은 재정의하지 않는다)는 남은 길이 너머를
 * 요청하지 않고 JDK 기본 조각(17: 8 KiB · 21: 16 KiB)으로 <b>읽은 만큼만</b> 할당한다 — 작은 본문은 작은 배열이고, 넘치는 본문도
 * 상한의 약 두 배(읽은 조각 + 그것을 이은 배열)다. 상한만 한 버퍼를 미리 잡지 않는다(그러면 토큰 요청 하나하나가 상한을 할당한다).
 * ⚠️ 끊지 않고 닫기만 하면 HttpCore 가 나머지를 EOF 까지 비운다 — 받는 바이트에 상한이 없었고, 1 바이트 청크면 청크 머리마다 문자열을
 * 만들어 할당이 비운 양을 따라 자랐다(실측 {@code AdminRejectedResponseCutTest}).
 *
 * <p>검사는 Jackson <b>스트리밍</b> 파서다 — 데이터 결합·다형 타입이 없고 자체 ObjectMapper 도 아니다(보안 불변식,
 * {@code .claude/rules/java.md}). 최상위 {@code access_token} 은 <b>전부</b> 본다 — 결합은 중복 키의 마지막 값을 쓰므로 첫
 * 값만 보면 {@code {"access_token":"ok","access_token":1}} 이 통과한다. 통과한 바이트는 그대로 되돌려 결합이 refresh_token·
 * expires_in 을 잃지 않게 한다.
 */
final class TokenResponseGuard implements ClientResponseFilter, ReaderInterceptor {
  static final String TOKEN_PATH_SUFFIX = "/protocol/openid-connect/token";
  /** ReaderInterceptor 로서의 우선순위 — 오름차순으로 도므로 가장 큰 값이 결합(MessageBodyReader) 바로 앞이다. */
  static final int READ_PRIORITY = Integer.MAX_VALUE;
  /** 응답 필터가 범위 안의 교환에 다는 요청 속성 — ReaderInterceptor 가 이것이 있는 엔티티만 판정한다. */
  static final String JUDGE_ENTITY = TokenResponseGuard.class.getName() + ".judgeEntity";
  static final String REJECTED = "token endpoint response carries no usable access_token";
  /** 오류 상태의 본문이 상한을 넘을 때의 거부 — 응답을 인용하지 않는다. */
  static final String TOO_LARGE = "token endpoint response exceeds " + ResponseLimits.MAX_TOKEN_RESPONSE_BYTES + " bytes";
  private static final String ACCESS_TOKEN = "access_token";
  private static final JsonFactory JSON = new JsonFactory();

  @Override
  public void filter(ClientRequestContext request, ClientResponseContext response) throws IOException {
    if (!HttpMethod.POST.equals(request.getMethod())
        || !request.getUri().getRawPath().endsWith(TOKEN_PATH_SUFFIX)) {
      return;
    }
    Object exchange = request.getProperty(AdminEngine.EXCHANGE);
    if (response.getStatusInfo().getFamily() != Response.Status.Family.SUCCESSFUL) {
      // 오류 상태 — 상한 안이면 같은 바이트를 그대로 넘기고(TokenManager 의 복구 경로), 넘치면 거부한다.
      InputStream in = response.getEntityStream();
      if (in != null) response.setEntityStream(withinCapOrReject(in, exchange));
      return;
    }
    if (response.getMediaType() != null) {
      request.setProperty(JUDGE_ENTITY, Boolean.TRUE); // 결합이 읽는 바이트(해제 뒤)는 aroundReadFrom 이 판정한다
      return;
    }
    response.setEntityStream(usableOrReject(response.getEntityStream(), exchange));
  }

  @Override
  public Object aroundReadFrom(ReaderInterceptorContext context) throws IOException {
    if (!Boolean.TRUE.equals(context.getProperty(JUDGE_ENTITY))) {
      return context.proceed();
    }
    context.setInputStream(usableOrReject(context.getInputStream(), context.getProperty(AdminEngine.EXCHANGE)));
    return context.proceed();
  }

  /** 상한+1 바이트까지만 읽는다(넘침을 알아챌 한 바이트) — 넘치거나 쓸 수 없으면 거부, 통과하면 읽은 바이트를 그대로 넘긴다. */
  private static ByteArrayInputStream usableOrReject(InputStream in, Object exchange) throws IOException {
    byte[] body = in == null ? new byte[0] : capPlusOne(in);
    if (body.length > ResponseLimits.MAX_TOKEN_RESPONSE_BYTES || !carriesUsableAccessToken(body)) {
      release(in, exchange);
      throw new IOException(REJECTED);
    }
    return new ByteArrayInputStream(body);
  }

  /** 오류 상태의 본문 — 상한+1 바이트까지만 읽어 넘치면 거부, 아니면 읽은 바이트를 그대로 넘긴다(판정은 하지 않는다). */
  private static ByteArrayInputStream withinCapOrReject(InputStream in, Object exchange) throws IOException {
    byte[] body = capPlusOne(in);
    if (body.length > ResponseLimits.MAX_TOKEN_RESPONSE_BYTES) {
      release(in, exchange);
      throw new IOException(TOO_LARGE);
    }
    return new ByteArrayInputStream(body);
  }

  /**
   * {@code readNBytes(상한+1)} — 다만 길이 0 의 읽기는 스트림에 넘기지 않고 0 이다. JDK 의 {@code readNBytes} 는 다 채운 뒤 길이 0 으로
   * 한 번 더 묻고, HttpCore 의 버퍼는 비었을 때 그것도 소켓에서 기다린다 — 상한+1 바이트 뒤 멈춘 서버 앞에서 거부가 읽기 타임아웃을
   * 기다렸다(실측 {@code AdminRejectedResponseCutTest} — auth 레인의 {@code BoundedTransport.wireBounded} 와 같은 처방).
   */
  private static byte[] capPlusOne(InputStream in) throws IOException {
    return new FilterInputStream(in) {
      @Override public int read(byte[] b, int off, int len) throws IOException {
        return len == 0 ? 0 : super.read(b, off, len);
      }
    }.readNBytes(ResponseLimits.MAX_TOKEN_RESPONSE_BYTES + 1);
  }

  /**
   * 거부하기 전에 그 교환을 놓는다 — 엔진이 단 손잡이({@link AdminEngine#EXCHANGE})로 연결을 <b>읽지 않고</b> 끊은 뒤 스트림을 닫는다.
   * 끊지 않고 닫으면 HttpCore 의 닫기가 나머지를 EOF 까지 비웠다(거부한 64 MiB 를 서버가 끝까지 썼다 — 실측
   * {@code AdminRejectedResponseCutTest}). 끊은 뒤의 닫기는 소켓에 닿지 못하고(이미 닫혔다) 버퍼에 남은 것만 지나간다. EOF 까지 읽고
   * 거부한 응답의 연결은 이미 풀로 돌아갔고 끊기는 그것을 건드리지 않는다. 손잡이가 없으면(다른 엔진) 닫기만 한다.
   */
  private static void release(InputStream in, Object exchange) {
    if (exchange instanceof AdminEngine.Exchange cuttable) cuttable.cut();
    closeQuietly(in);
  }

  /**
   * 거부하기 전에 스트림을 닫고, 닫기의 실패는 버린다. ⚠️ 응답 필터가 던지면 RESTEasy({@code ClientInvocation.invoke})가 응답을
   * try/catch 없이 닫는다 — 그 닫기가 실패하면(끊긴 연결에서 나머지를 읽으려다 · 끊지 못한 연결에서 청크 크기 줄 오류·잘린 본문·읽기
   * 타임아웃) 그 {@code ProcessingException} 이 이 거부를 대신해 걸러지지 않은 채 나갔고, 청크 크기 줄 오류는 응답 바이트를 메시지에
   * 실었다(실측 — {@code AdminTokenResponseTest}). 여기서 먼저 닫으면 뒤의 닫기는 아무것도 하지 않는다(BufferedInputStream·
   * EofSensorInputStream 모두 두 번째 닫기가 no-op).
   */
  private static void closeQuietly(InputStream in) {
    if (in == null) return;
    try {
      in.close();
    } catch (IOException releaseFault) {
      // 버린다 — 결과는 거부다(메시지는 응답 바이트를 인용할 수 있다)
    }
  }

  /**
   * 최상위가 JSON 객체이고 그 {@code access_token} 이 하나 이상이며 전부 HTTP 필드 값이 실을 수 있는({@link #fieldValueSafe}) 비어
   * 있지 않은 문자열이다. 형식이 틀리면 false.
   */
  static boolean carriesUsableAccessToken(byte[] body) {
    try (JsonParser p = JSON.createParser(body)) {
      if (p.nextToken() != JsonToken.START_OBJECT) return false;
      boolean found = false;
      while (p.nextToken() == JsonToken.FIELD_NAME) {
        boolean accessToken = ACCESS_TOKEN.equals(p.currentName());
        JsonToken value = p.nextToken();
        if (!accessToken) {
          p.skipChildren();
        } else if (value != JsonToken.VALUE_STRING || p.getTextLength() == 0 || !fieldValueSafe(p.getText())) {
          return false;
        } else {
          found = true;
        }
      }
      return found;
    } catch (IOException malformed) {
      return false; // 파서 메시지는 본문을 인용할 수 있다 — 버리고 거부만 한다
    }
  }

  /**
   * HTTP 필드 값이 실을 수 있는 문자열인가 — RFC 9110 §5.5 가 필드 값에서 빼는 CR·LF·NUL·HTAB 밖의 C0 와 DEL 이 없다. 그런
   * access_token 은 쓸 수 없는 토큰이다 — 캐시되지 않고(다음 호출이 다시 부여한다) admin 요청은 나가지 않는다. 수정 전 HttpCore 는 그
   * Bearer 를 조용히 고쳐 보냈다(CR·LF·VT·FF → 공백 · 그 밖의 C0·DEL → {@code ?} — {@code BasicLineFormatter}·{@code ByteArrayBuffer},
   * 실측 {@code AdminTokenResponseTest}). TokenManager 의 토큰은 모두 이 응답에서 오므로(부여·갱신 — 다른 길로 넣는 setter 가 없다) 보낼
   * 때 다시 보지 않는다. ⚠️ HTAB·SP·ASCII 밖(HttpCore 가 U+0100 위와 C1 을 {@code ?} 로 보낸다)은 여기서 판정하지 않는다 — 아홉 언어가
   * 함께 정할 일이다(등록부 {@code bearer-token-grammar-divergent}).
   */
  static boolean fieldValueSafe(String value) {
    for (int i = 0; i < value.length(); i++) {
      char c = value.charAt(i);
      if ((c < 0x20 && c != '\t') || c == 0x7f) return false;
    }
    return true;
  }
}
