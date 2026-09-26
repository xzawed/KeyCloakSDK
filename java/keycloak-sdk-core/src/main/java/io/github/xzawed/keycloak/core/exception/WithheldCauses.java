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
 * <p>⚠️ 따로 둔 이유: 예외 클래스에 정적 초기화를 더하면 기본 {@code serialVersionUID} 가 바뀐다(japicmp 가 알렸다).
 */
final class WithheldCauses {
  private WithheldCauses() {}

  private static final Set<String> RESPONSE_PARSERS = Set.of(
      "com.nimbusds.oauth2.sdk.ParseException",            // Nimbus OAuth 응답 파서(auth)
      "net.minidev.json.parser.ParseException",            // Nimbus 아래 json-smart
      "jakarta.ws.rs.client.ResponseProcessingException",  // JAX-RS: 응답 엔티티를 못 읽었다(admin)
      "com.fasterxml.jackson.core.JacksonException",       // admin-client 의 Jackson(2.12+)
      "com.fasterxml.jackson.core.JsonProcessingException");

  static Throwable scrub(Throwable cause) {
    return cause != null && quotesResponse(cause)
        ? withheld(cause, Collections.newSetFromMap(new IdentityHashMap<>())) : cause;
  }

  private static boolean quotesResponse(Throwable root) {
    Set<Throwable> seen = Collections.newSetFromMap(new IdentityHashMap<>());
    Deque<Throwable> todo = new ArrayDeque<>();
    todo.push(root);
    while (!todo.isEmpty()) {
      Throwable t = todo.pop();
      if (!seen.add(t)) continue;
      for (Class<?> k = t.getClass(); k != null; k = k.getSuperclass()) {
        if (RESPONSE_PARSERS.contains(k.getName())) return true;
      }
      if (t.getCause() != null) todo.push(t.getCause());
      for (Throwable s : suppressed(t)) todo.push(s);
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
