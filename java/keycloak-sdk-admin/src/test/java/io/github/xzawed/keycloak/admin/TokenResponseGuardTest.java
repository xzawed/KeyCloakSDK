package io.github.xzawed.keycloak.admin;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;

import jakarta.ws.rs.client.Client;
import jakarta.ws.rs.client.ClientRequestContext;
import jakarta.ws.rs.client.ClientResponseContext;
import jakarta.ws.rs.core.Response;
import io.github.xzawed.keycloak.core.KeycloakConfig;
import java.io.ByteArrayInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;

/**
 * {@link TokenResponseGuard} 단위 — 무엇을 쓸 수 있는 {@code access_token} 으로 보는가(JSON 모양)와 어느 응답을 보는가(범위).
 * 끝에서 끝까지의 계약(admin 요청 0 건 · 예외 타입 · 갱신)은 {@link AdminTokenResponseTest} 가 진다.
 *
 * <p>모양 표의 적대 항목 일부는 독립 레그(Grok)가 낸 것이다 — 중복 키(결합은 마지막 값), 중첩, 대소문자, UTF-16.
 */
class TokenResponseGuardTest {

  private static boolean usable(String json) {
    return TokenResponseGuard.carriesUsableAccessToken(json.getBytes(StandardCharsets.UTF_8));
  }

  @Test void usableShapes() {
    List<String> wrong = new ArrayList<>();
    for (String json : List.of(
        "{\"access_token\":\"AT\",\"token_type\":\"Bearer\",\"expires_in\":300}",
        "{\"access_token\":\"12345\"}",                         // 따옴표 친 숫자는 진짜 문자열이다
        "{\"access_token\":\" \"}",                             // 계약은 「비어 있지 않음」 — 공백 판정은 IdP 몫(Go 와 같다)
        "{\"x\":{\"access_token\":1},\"y\":[1,{\"a\":[2]}],\"access_token\":\"AT\"}", // 중첩은 결합되지 않는다
        "{\"access_token\":\"A\",\"access_token\":\"B\"}",       // 중복이어도 전부 문자열이면 된다
        "{\"access\\u005ftoken\":\"AT\"}",                      // 이스케이프된 키도 같은 이름이다
        "{\"access_token\":\"AT\"} trailing")) {                // 뒤따르는 내용은 결합(Jackson)이 판정한다
      if (!usable(json)) wrong.add("거부했다: " + json);
    }
    assertTrue(wrong.isEmpty(), () -> String.join("\n", wrong));
  }

  @Test void unusableShapes() {
    List<String> wrong = new ArrayList<>();
    for (String json : List.of(
        "{\"access_token\":12345}", "{\"access_token\":1.5}", "{\"access_token\":-0}",
        "{\"access_token\":true}", "{\"access_token\":false}", "{\"access_token\":null}",
        "{\"access_token\":\"\"}", "{\"access_token\":{\"v\":\"x\"}}", "{\"access_token\":[]}",
        "{\"access_token\":[\"x\"]}",
        "{\"token_type\":\"Bearer\",\"expires_in\":300}", "{}",                       // 누락
        "{\"x\":{\"access_token\":\"AT\"}}",                                           // 중첩만 있다 — 누락이다
        "{\"access_token\":\"AT\",\"access_token\":12345}",                           // 결합은 마지막 값(숫자)을 쓴다
        "{\"access_token\":12345,\"access_token\":\"AT\"}",                           // 어느 것이 결합될지는 파서 설정 몫
        "{\"access\\u005ftoken\":true}",
        "{\"ACCESS_TOKEN\":\"AT\"}", "{\"Access_Token\":\"AT\",\"access_token\":1}",   // 결합은 대소문자를 가린다
        "[{\"access_token\":\"AT\"}]", "\"AT\"", "12345", "null", "", "   ",          // 최상위가 객체가 아니다
        "{\"access_token\":\"AT\"", "{\"access_token\":\"AT\",", "{\"access_token\":",  // 잘린 JSON
        "Zcanary-0123456789abcdef", "{'access_token':'AT'}")) {                       // JSON 이 아니다
      if (usable(json)) wrong.add("받아들였다: " + json);
    }
    assertTrue(wrong.isEmpty(), () -> String.join("\n", wrong));
  }

  /** Jackson 결합과 같은 자동 인코딩 감지 — 다시 디코딩하지 않는다(UTF-16 본문을 UTF-8 로 읽으면 거짓 거부다). */
  @Test void detectsEncodingLikeTheBinding() {
    assertTrue(TokenResponseGuard.carriesUsableAccessToken(
        "{\"access_token\":\"AT\"}".getBytes(StandardCharsets.UTF_16LE)));
    assertFalse(TokenResponseGuard.carriesUsableAccessToken(
        "{\"access_token\":12345}".getBytes(StandardCharsets.UTF_16BE)));
  }

  // ───────────── 범위 — 어느 응답을 보는가 ─────────────

  private static ClientRequestContext request(String method, String uri) {
    ClientRequestContext req = mock(ClientRequestContext.class);
    when(req.getMethod()).thenReturn(method);
    when(req.getUri()).thenReturn(URI.create(uri));
    return req;
  }

  private static ClientResponseContext response(Response.Status status, InputStream body) {
    ClientResponseContext res = mock(ClientResponseContext.class);
    when(res.getStatusInfo()).thenReturn(status);
    when(res.getEntityStream()).thenReturn(body);
    return res;
  }

  private static InputStream bytes(String s) {
    return new ByteArrayInputStream(s.getBytes(StandardCharsets.UTF_8));
  }

  private static final String TOKEN = "http://kc/auth/realms/r/protocol/openid-connect/token";
  private static final String NUMBER = "{\"access_token\":12345}";

  @Test void leavesEveryOtherResponseUntouched() throws IOException {
    TokenResponseGuard guard = new TokenResponseGuard();
    List<Object[]> others = List.of(
        new Object[] {"GET", TOKEN, Response.Status.OK},                                       // 토큰 요청은 POST 다
        new Object[] {"POST", "http://kc/admin/realms/r/users", Response.Status.CREATED},      // admin 자원
        new Object[] {"GET", "http://kc/admin/realms/r/users/x", Response.Status.OK},
        // ⚠️ 원시 경로로 본다 — 렐름 이름의 %2F 가 경로 조각을 지어내지 못한다
        new Object[] {"POST", "http://kc/admin/realms/a%2Fprotocol%2Fopenid-connect%2Ftoken", Response.Status.OK},
        new Object[] {"POST", TOKEN, Response.Status.BAD_REQUEST},                             // 오류는 TokenManager 몫
        new Object[] {"POST", TOKEN, Response.Status.UNAUTHORIZED},
        new Object[] {"POST", TOKEN + "/introspect", Response.Status.OK});
    for (Object[] o : others) {
      ClientResponseContext res = response((Response.Status) o[2], bytes(NUMBER));
      guard.filter(request((String) o[0], (String) o[1]), res);
      verify(res, never()).getEntityStream();
      verify(res, never()).setEntityStream(any());
    }
  }

  @Test void usableTokenResponse_isHandedOnByteForByte() throws IOException {
    String body = "{\"access_token\":\"AT\",\"expires_in\":300,\"refresh_token\":\"RT\",\"x\":[1]}";
    ClientResponseContext res = response(Response.Status.OK, bytes(body));
    new TokenResponseGuard().filter(request("POST", TOKEN), res);
    ArgumentCaptor<InputStream> handed = ArgumentCaptor.forClass(InputStream.class);
    verify(res).setEntityStream(handed.capture());
    assertEquals(body, new String(handed.getValue().readAllBytes(), StandardCharsets.UTF_8));
  }

  @Test void unusableTokenResponse_isRejectedWithoutQuotingIt() {
    for (InputStream body : new InputStream[] {bytes(NUMBER), bytes("{\"access_token\":\"\"}"), null}) {
      ClientResponseContext res = response(Response.Status.OK, body);
      IOException e = assertThrows(IOException.class,
          () -> new TokenResponseGuard().filter(request("POST", TOKEN), res));
      assertEquals("token endpoint response carries no usable access_token", e.getMessage());
      assertNull(e.getCause());
      verify(res, never()).setEntityStream(any());
    }
  }

  /** 배선 — admin 의 JAX-RS 클라이언트에 등록돼 있어야 한다(TokenManager 의 토큰 요청이 그 클라이언트로 나간다). */
  @Test void timeoutClient_registersTheGuard() {
    KeycloakConfig config = KeycloakConfig.builder().serverUrl("https://kc.example.com").realm("r").clientId("app")
        .clientSecret("s3cr3t".toCharArray()).build();
    try (Client client = AdminClient.buildTimeoutClient(config)) {
      assertTrue(client.getConfiguration().isRegistered(TokenResponseGuard.class));
    }
  }
}
