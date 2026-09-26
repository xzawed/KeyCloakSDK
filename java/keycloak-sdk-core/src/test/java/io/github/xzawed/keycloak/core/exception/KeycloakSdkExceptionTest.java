package io.github.xzawed.keycloak.core.exception;
import static org.junit.jupiter.api.Assertions.*;
import java.io.PrintWriter;
import java.io.StringWriter;
import java.net.ConnectException;
import org.junit.jupiter.api.Test;

class KeycloakSdkExceptionTest {
  // ⚠️ 응답 파서가 사슬에 있으면 원인 사슬은 **타입 이름과 프레임만** 남는다 — 파서 메시지가 응답(토큰)을 인용하고
  // printStackTrace 의 「Caused by:」 가 그것을 찍었다(실측: java/keycloak-sdk MalformedIdpResponseTest).
  private static final String CANARY = "CANARY-QUOTED-RESPONSE";

  private static String printed(Throwable t) {
    StringWriter sw = new StringWriter();
    t.printStackTrace(new PrintWriter(sw, true));
    return sw.toString();
  }

  @Test void parserChain_isWithheld_keepsTypeNamesFramesAndSdkMessage() {
    Exception parser = new net.minidev.json.parser.ParseException("Unexpected token " + CANARY + " at position 3");
    // 감싼 쪽도 원인 메시지를 복사한다(RESTEasy 모양) — 파서 위의 고리도 보류해야 한다.
    IllegalStateException wrapper = new IllegalStateException("wrapped: " + parser.getMessage(), parser);
    KeycloakAuthException e = new KeycloakAuthException("Client credentials request error", "x", wrapper);

    String trace = printed(e);
    assertFalse(trace.contains(CANARY), trace);
    assertTrue(trace.contains("java.lang.IllegalStateException (message withheld"), trace);
    assertTrue(trace.contains("net.minidev.json.parser.ParseException (message withheld"), trace);
    assertEquals("Client credentials request error", e.getMessage());
    assertEquals("x", e.getError());
    assertNotSame(wrapper, e.getCause());
    assertArrayEquals(wrapper.getStackTrace(), e.getCause().getStackTrace());
    assertArrayEquals(parser.getStackTrace(), e.getCause().getCause().getStackTrace());
  }

  @Test void parserSubclassOrSuppressed_isWithheld() {
    class Sub extends net.minidev.json.parser.ParseException {
      Sub() { super("sub " + CANARY); }
    }
    assertFalse(printed(new KeycloakTransportException("t", new Sub())).contains(CANARY));

    RuntimeException top = new RuntimeException("top " + CANARY);
    top.addSuppressed(new net.minidev.json.parser.ParseException("suppressed " + CANARY));
    KeycloakSdkException e = new KeycloakSdkException("s", top);
    String trace = printed(e);
    assertFalse(trace.contains(CANARY), trace);
    assertEquals(1, e.getCause().getSuppressed().length, trace);
  }

  @Test void nonParserChain_isKeptAsIs() {
    // 전송 사슬은 응답을 싣지 않는 진단이다 — 그대로(같은 인스턴스) 둔다.
    ConnectException io = new ConnectException("Connection refused");
    KeycloakTransportException e = new KeycloakTransportException("Client credentials transport failure", io);
    assertSame(io, e.getCause());
    assertTrue(printed(e).contains("Connection refused"));
    assertNull(new KeycloakConfigException("bad", null).getCause());
  }

  @Test void mockedParser_neverMakesTheConstructorThrow() {
    // 목은 final 인 getSuppressed·getStackTrace 까지 null 로 대신한다 — 오류 경로의 생성자가 NPE 로 원래 실패를 가리면 안 된다.
    net.minidev.json.parser.ParseException mocked =
        org.mockito.Mockito.mock(net.minidev.json.parser.ParseException.class);
    KeycloakAuthException e = assertDoesNotThrow(() -> new KeycloakAuthException("m", null, mocked));
    assertNotSame(mocked, e.getCause());
    assertTrue(e.getCause().getMessage().contains("(message withheld"), e.getCause().getMessage());
  }

  @Test void cyclicChains_terminate() {
    Exception a = new Exception("a " + CANARY);
    Exception b = new net.minidev.json.parser.ParseException("b " + CANARY);
    a.initCause(b);
    b.initCause(a);
    b.addSuppressed(a);
    assertFalse(printed(new KeycloakAuthException("m", null, a)).contains(CANARY));

    Exception c = new Exception("c");
    Exception d = new Exception("d", c);
    c.initCause(d);
    assertSame(c, new KeycloakAuthException("m", null, c).getCause(), "파서 없는 순환은 그대로");
  }

  @Test void adminException_carriesStatusAndError() {
    KeycloakAdminException e = new KeycloakNotFoundException(404, "User not found", null);
    assertEquals(404, e.getStatus());
    assertEquals("User not found", e.getKeycloakError());
    assertInstanceOf(KeycloakSdkException.class, e);
  }
  @Test void baseException_isRuntime() {
    assertInstanceOf(RuntimeException.class, new KeycloakConfigException("bad", null));
  }
  @Test void authException_carriesOAuthErrorCode() {
    KeycloakAuthException e = new KeycloakAuthException("bad grant", "invalid_grant", null);
    assertEquals("invalid_grant", e.getError());
    assertInstanceOf(KeycloakSdkException.class, e);
  }
  @Test void tokenValidationException_isSdkException() {
    assertInstanceOf(KeycloakSdkException.class, new TokenValidationException("invalid token", null));
  }
  @Test void transportException_isSdkException() {
    assertInstanceOf(KeycloakSdkException.class, new KeycloakTransportException("timeout", null));
  }
  @Test void conflictException_carriesStatusAndError() {
    KeycloakConflictException e = new KeycloakConflictException(409, "already exists", null);
    assertEquals(409, e.getStatus());
    assertEquals("already exists", e.getKeycloakError());
    assertInstanceOf(KeycloakAdminException.class, e);
  }
  @Test void forbiddenException_carriesStatusAndError() {
    KeycloakForbiddenException e = new KeycloakForbiddenException(403, "not allowed", null);
    assertEquals(403, e.getStatus());
    assertEquals("not allowed", e.getKeycloakError());
    assertInstanceOf(KeycloakAdminException.class, e);
  }
}
