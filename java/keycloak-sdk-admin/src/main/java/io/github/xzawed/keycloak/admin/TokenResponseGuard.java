package io.github.xzawed.keycloak.admin;

import com.fasterxml.jackson.core.JsonFactory;
import com.fasterxml.jackson.core.JsonParser;
import com.fasterxml.jackson.core.JsonToken;
import jakarta.ws.rs.HttpMethod;
import jakarta.ws.rs.client.ClientRequestContext;
import jakarta.ws.rs.client.ClientResponseContext;
import jakarta.ws.rs.client.ClientResponseFilter;
import jakarta.ws.rs.core.Response;
import jakarta.ws.rs.ext.ReaderInterceptor;
import jakarta.ws.rs.ext.ReaderInterceptorContext;
import java.io.ByteArrayInputStream;
import java.io.IOException;
import java.io.InputStream;

/**
 * admin 레인의 토큰 응답 검사 — 토큰 엔드포인트의 성공 응답이 <b>비어 있지 않은 JSON 문자열</b> {@code access_token} 을
 * 싣지 않으면 그 응답을 거부한다.
 *
 * <p>왜 여기인가: admin 은 토큰을 자체 소유하고(§4) keycloak-admin-client 내장 TokenManager 가 토큰 응답을 Jackson 으로
 * {@code AccessTokenResponse} 에 결합한다. Jackson 의 스칼라 강제변환이 숫자·불리언을 문자열로 바꾸고 빈 문자열은 그대로
 * 둬서, admin API 가 {@code Bearer 12345}·{@code Bearer true}·{@code Bearer } 로 불렸다(실측 — {@code AdminTokenResponseTest}).
 * 결합 뒤에는 원래 JSON 타입이 남지 않으므로 결합 <b>앞</b>의 바이트를 본다. TokenManager 의 부여·갱신 요청도
 * {@link AdminClient#buildTimeoutClient} 의 클라이언트로 나가므로 거기에 등록한다.
 *
 * <p>범위는 POST · 경로 꼬리 {@value #TOKEN_PATH_SUFFIX} · 2xx 응답뿐이다 — 응답 필터가 정한다. admin 자원 응답의
 * 역직렬화는 건드리지 않는다. 오류 상태는 그대로 넘긴다 — 갱신이 400 이면 TokenManager 가 {@code BadRequestException} 을 받아
 * client_credentials 로 다시 부여하는 복구 경로가 있다.
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
 * <p>⚠️ <b>판정은 본문을 상한({@link #MAX_BODY_BYTES})까지만 읽고 쥔다.</b> 통째로 읽던 때는 힙보다 큰 2xx 본문이
 * {@code OutOfMemoryError} 를 냈다 — RESTEasy 가 감싸 결과는 거부였어도 그 순간 JVM 전체가 메모리를 잃었고, JSON 공백으로
 * 부풀린 <b>쓸 수 있는</b> 토큰도 그랬다(가드 없는 결합은 그것을 스트리밍으로 통과시킨다). 상한+1 바이트까지 읽어 넘침을
 * 알아채면 쓸 수 없는 토큰과 같은 거부를 던지고 나머지는 읽지 않는다. 버퍼는 본문 크기와 무관하게 하나다.
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
  /**
   * 판정이 읽고 쥐는 본문의 상한(바이트) — JWKS 응답 상한과 같은 수다: keycloak-sdk-auth 의 {@code NoRedirectResourceRetriever}
   * 가 Nimbus 에 넘기는 {@code JWKSourceBuilder.DEFAULT_HTTP_SIZE_LIMIT}. admin 아티팩트는 Nimbus 에 의존하지 않으므로 같은 값을
   * 리터럴로 두고, {@code TokenResponseGuardTest} 의 경계 시험이 그 상수와 대조한다(한 바이트만 어긋나도 깨진다).
   */
  static final int MAX_BODY_BYTES = 51_200;
  private static final String ACCESS_TOKEN = "access_token";
  private static final JsonFactory JSON = new JsonFactory();

  @Override
  public void filter(ClientRequestContext request, ClientResponseContext response) throws IOException {
    if (!HttpMethod.POST.equals(request.getMethod())
        || !request.getUri().getRawPath().endsWith(TOKEN_PATH_SUFFIX)
        || response.getStatusInfo().getFamily() != Response.Status.Family.SUCCESSFUL) {
      return;
    }
    if (response.getMediaType() != null) {
      request.setProperty(JUDGE_ENTITY, Boolean.TRUE); // 결합이 읽는 바이트(해제 뒤)는 aroundReadFrom 이 판정한다
      return;
    }
    response.setEntityStream(usableOrReject(response.getEntityStream()));
  }

  @Override
  public Object aroundReadFrom(ReaderInterceptorContext context) throws IOException {
    if (!Boolean.TRUE.equals(context.getProperty(JUDGE_ENTITY))) {
      return context.proceed();
    }
    context.setInputStream(usableOrReject(context.getInputStream()));
    return context.proceed();
  }

  /** 상한+1 바이트까지만 읽는다(넘침을 알아챌 한 바이트) — 넘치거나 쓸 수 없으면 거부, 통과하면 읽은 바이트를 사본 없이 넘긴다. */
  private static ByteArrayInputStream usableOrReject(InputStream in) throws IOException {
    byte[] buf = new byte[MAX_BODY_BYTES + 1];
    int n = in == null ? 0 : in.readNBytes(buf, 0, buf.length);
    if (n > MAX_BODY_BYTES || !carriesUsableAccessToken(buf, n)) {
      throw new IOException(REJECTED);
    }
    return new ByteArrayInputStream(buf, 0, n);
  }

  /**
   * {@code body} 의 앞 {@code length} 바이트가 최상위 JSON 객체이고 그 {@code access_token} 이 하나 이상이며 전부 비어 있지
   * 않은 문자열이다. 형식이 틀리면 false.
   */
  static boolean carriesUsableAccessToken(byte[] body, int length) {
    try (JsonParser p = JSON.createParser(body, 0, length)) {
      if (p.nextToken() != JsonToken.START_OBJECT) return false;
      boolean found = false;
      while (p.nextToken() == JsonToken.FIELD_NAME) {
        boolean accessToken = ACCESS_TOKEN.equals(p.currentName());
        JsonToken value = p.nextToken();
        if (!accessToken) {
          p.skipChildren();
        } else if (value != JsonToken.VALUE_STRING || p.getTextLength() == 0) {
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
}
