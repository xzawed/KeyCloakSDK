package io.github.xzawed.keycloak.core.exception;

import java.util.ArrayDeque;
import java.util.Collections;
import java.util.Deque;
import java.util.IdentityHashMap;
import java.util.Set;

/**
 * {@link KeycloakSdkException} 생성자가 원인 사슬을 거르는 자리.
 *
 * <p>⚠️ 응답 **파서**의 예외는 메시지에 응답을 인용한다 — json-smart 는 JSON 이 아닌 토큰 본문을 「Unexpected token
 * &lt;본문&gt; at position N」으로, Nimbus 는 「Unsupported token_type: &lt;값&gt;」으로, admin 의 Jackson 은 「from
 * String "&lt;값&gt;"」으로 싣고, 로거가 찍는 printStackTrace 의 「Caused by:」 줄이 그 토큰을 원문으로 남겼다(실측
 * 2026-09-26, {@code MalformedIdpResponseTest}). 사슬 어디에 파서 예외가 있으면 사슬 **전체**를 타입 이름과 프레임만
 * 남긴 사본으로 바꾼다 — 감싼 쪽(RESTEasy)도 원인의 메시지를 제 메시지에 복사한다. 메시지는 길이와 무관하게 보류한다
 * (20 자 이하 본문도 인용된다). 파서가 없는 사슬(연결 거부·타임아웃·Nimbus 값 검사)은 그대로 둔다 — 응답을 싣지 않는
 * 진단이다. 생성자 한 곳이라 모든 감싸기 자리를 덮는다(Node {@code scrubCause} 와 같은 자리).
 *
 * <p>⚠️ <b>{@code jakarta.ws.rs.ProcessingException} 아래의 {@code WebApplicationException} 도 같다</b> — 메시지가 아니라 쥔
 * {@code Response} 가 응답을 낸다. admin-client 의 내장 TokenManager 가 BearerAuthFilter(요청 필터) 안에서 토큰 엔드포인트의 오류를
 * 받으면 RESTEasy 는 그 본문을 bufferEntity 한 {@code Response} 를 {@code NotAuthorizedException} 등에 쥐여 {@code ProcessingException}
 * 으로 감싸고, 그 {@code Response} 는 {@code close()} 뒤에도 {@code readEntity(String.class)} 가 본문을 그대로 돌려준다(버퍼된 엔티티는
 * 닫힘 검사를 건너뛴다 — 닫기로는 막지 못한다, 실측). 그 본문은 그 요청의 Basic 시크릿을 되울릴 수 있다({@code AdminTokenEchoTest}).
 * 뿌리가 {@code WebApplicationException} 자신인 사슬(admin 자원 오류 — {@code AdminExceptions.translate})은 그대로 둔다: 그 본문은
 * {@code KeycloakAdminException.getKeycloakError()} 가 이미 싣는 레인이다.
 *
 * <p>⚠️ 따로 둔 이유: 예외 클래스에 정적 초기화를 더하면 기본 {@code serialVersionUID} 가 바뀐다(japicmp 가 알렸다).
 */
final class WithheldCauses {
  private WithheldCauses() {}

  private static final Set<String> RESPONSE_PARSERS = Set.of(
      "com.nimbusds.oauth2.sdk.ParseException",            // Nimbus OAuth 응답 파서(auth)
      "net.minidev.json.parser.ParseException",            // Nimbus 아래 json-smart
      "jakarta.ws.rs.client.ResponseProcessingException",  // JAX-RS: 응답 엔티티를 못 읽었다(admin)
      "com.fasterxml.jackson.core.JacksonException",       // admin-client 의 Jackson(2.12+)
      "com.fasterxml.jackson.core.JsonProcessingException",
      // admin 의 HttpCore(RESTEasy) — 틀 오류가 응답의 줄을 싣는다: 「Invalid header: <줄>」·「Status line contains invalid status
      // code: <줄>」(머리 — ProtocolException, RESTEasy 가 그 사슬을 ProcessingException 으로 감싼다)·「Bad chunk header: <줄>」(본문
      // — 미디어 타입 없는 2xx 를 닫을 때). 실측 AdminResponseFramingTest. HttpCore 의 ParseException 은 늘 ProtocolException 안에
      // 실려 와 따로 적지 않는다(변이: 그 이름을 빼도 시험이 통과했다). auth 레인은 운송이 먼저 상수 메시지로 바꾼다(BoundedTransport.shield).
      "org.apache.http.HttpException",
      "org.apache.http.MalformedChunkCodingException");
  /** 전송 실패의 감싸개 — 이것이 뿌리일 때 그 아래의 HTTP 오류는 admin 토큰 요청의 것이다. */
  private static final Set<String> TRANSPORT_WRAPPER = Set.of("jakarta.ws.rs.ProcessingException");
  /** 응답(버퍼된 본문)을 쥔 HTTP 오류. */
  private static final Set<String> HTTP_ERROR = Set.of("jakarta.ws.rs.WebApplicationException");

  static Throwable scrub(Throwable cause) {
    return cause != null && quotesResponse(cause)
        ? withheld(cause, Collections.newSetFromMap(new IdentityHashMap<>())) : cause;
  }

  private static boolean quotesResponse(Throwable root) {
    boolean wrapped = isA(root, TRANSPORT_WRAPPER);
    Set<Throwable> seen = Collections.newSetFromMap(new IdentityHashMap<>());
    Deque<Throwable> todo = new ArrayDeque<>();
    todo.push(root);
    while (!todo.isEmpty()) {
      Throwable t = todo.pop();
      if (!seen.add(t)) continue;
      if (isA(t, RESPONSE_PARSERS) || (wrapped && isA(t, HTTP_ERROR))) return true;
      if (t.getCause() != null) todo.push(t.getCause());
      for (Throwable s : suppressed(t)) todo.push(s);
    }
    return false;
  }

  /** {@code t} 의 타입이나 그 상위 타입 중 하나가 {@code names} 에 있다(하위 라이브러리를 이름으로만 안다 — core 는 그것에 의존하지 않는다). */
  private static boolean isA(Throwable t, Set<String> names) {
    for (Class<?> k = t.getClass(); k != null; k = k.getSuperclass()) {
      if (names.contains(k.getName())) return true;
    }
    return false;
  }

  /** 타입 이름과 프레임만 남긴 사본 — 원인·suppressed 도 같은 사본으로(순환은 한 번만). */
  private static Throwable withheld(Throwable t, Set<Throwable> seen) {
    seen.add(t);
    Exception copy = new Exception(t.getClass().getName() + " (message withheld: it can quote the response)");
    StackTraceElement[] frames = t.getStackTrace();
    if (frames != null) copy.setStackTrace(frames);
    Throwable cause = t.getCause();
    if (cause != null && !seen.contains(cause)) copy.initCause(withheld(cause, seen));
    for (Throwable s : suppressed(t)) {
      if (!seen.contains(s)) copy.addSuppressed(withheld(s, seen));
    }
    return copy;
  }

  // ⚠️ 오류 경로의 생성자는 던지면 안 된다(원래 실패를 가린다). 실제 Throwable 은 null 을 안 주지만 목(Mockito 가
  // final 메서드까지 대신한다)은 준다 — AdminExceptionsTest 의 목 WebApplicationException 이 여기서 NPE 를 냈다.
  private static Throwable[] suppressed(Throwable t) {
    Throwable[] s = t.getSuppressed();
    return s == null ? new Throwable[0] : s;
  }
}
