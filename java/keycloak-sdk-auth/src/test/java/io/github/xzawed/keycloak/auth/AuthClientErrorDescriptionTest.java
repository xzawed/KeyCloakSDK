package io.github.xzawed.keycloak.auth;
import static org.junit.jupiter.api.Assertions.*;
import com.nimbusds.oauth2.sdk.http.HTTPRequest;
import java.net.URL;
import org.junit.jupiter.api.Test;

// `AuthClient.describe` — error_description 을 메시지에 싣되, 이 요청이 보낸 비밀과 토큰 모양의 연속만 가린다.
// 끝에서 끝까지의 측정은 java/keycloak-sdk MalformedIdpResponseTest(e1·e2·e6·e7)가 한다. 여기는 규칙의 경계다.
class AuthClientErrorDescriptionTest {
  private static final String REFRESH = "rt-9f8e7d6c5b4a39281706";

  /** JWT 모양은 실행 중에 만든다 — 소스에 JWT 리터럴을 두지 않는다(비밀 스캐너가 진짜와 못 가른다). */
  private static String b64u(String json) {
    return java.util.Base64.getUrlEncoder().withoutPadding()
        .encodeToString(json.getBytes(java.nio.charset.StandardCharsets.UTF_8));
  }

  private static HTTPRequest sent(String body, String authorization) throws Exception {
    HTTPRequest req = new HTTPRequest(HTTPRequest.Method.POST, new URL("http://idp/token"));
    req.setBody(body);
    if (authorization != null) req.setAuthorization(authorization);
    return req;
  }

  @Test void keycloakProse_isKeptVerbatim() throws Exception {
    HTTPRequest req = sent("grant_type=refresh_token&refresh_token=" + REFRESH, "Basic YzpzZWNyZXQ=");
    for (String prose : new String[] {"Token is not active", "Invalid client or Invalid client credentials",
        "Missing parameter: code_challenge_method", "Invalid token issuer. Expected 'http://localhost:8080/realms/r'",
        "Maximum allowed refresh token reuse exceeded"}) {
      assertEquals(prose, AuthClient.describe(prose, req, "secret".toCharArray()));
    }
    assertNull(AuthClient.describe(null, req, null));
  }

  @Test void whatThisRequestSent_isMasked_wholeOrFragment() throws Exception {
    HTTPRequest req = sent("grant_type=refresh_token&refresh_token=" + REFRESH + "&code=short1", "Basic YzpzZWNyZXQ=");
    assertEquals("rejected ***", AuthClient.describe("rejected " + REFRESH, req, null));
    assertEquals("bad *** for ***", AuthClient.describe("bad Basic YzpzZWNyZXQ= for short1", req, null));
    assertEquals("bad client secret ***", AuthClient.describe("bad client secret s3cr", req, "s3cr".toCharArray()));
    // 잘린 되울림 — 보낸 비밀의 10 자 이상 조각. 말줄임표(.)는 조각에서 떨어진다.
    assertEquals("rejected ***...", AuthClient.describe("rejected " + REFRESH.substring(0, 12) + "...", req, null));
  }

  @Test void tokenShapedRuns_areMasked_unsentShortOnesAreNot() throws Exception {
    HTTPRequest req = sent("grant_type=client_credentials", null);
    String jwt = b64u("{\"alg\":\"RS256\"}") + "." + b64u("{\"sub\":\"u1\",\"exp\":1700000000}") + "."
        + b64u("signature-bytes");
    assertEquals("session *** expired", AuthClient.describe("session " + jwt + " expired", req, null));
    // 마디마다 20 자 미만인 JWT(19·15·3 자)도 안쪽 `.` 으로 이어 한 연속으로 잡는다(Grok 레그 h2).
    String shortPieces = b64u("{\"alg\":\"none\"}") + "." + b64u("{\"sub\":\"1\"}") + ".abc";
    assertEquals("bad ***", AuthClient.describe("bad " + shortPieces, req, null));
    assertEquals("bad ***...", AuthClient.describe("bad " + shortPieces + "...", req, null)); // 말줄임표는 남는다
    assertEquals("rejected ***", AuthClient.describe("rejected ZeF-0123456789abcdef", req, null));
    // 소문자 URL 은 산문이다 — `/` 는 토큰 표지가 아니다.
    assertEquals("Expected 'https://keycloak.example.com/realms/master'",
        AuthClient.describe("Expected 'https://keycloak.example.com/realms/master'", req, null));
    // ⚠️ 경계 — 보내지 않았고 토큰 모양도 아닌 값은 낱말과 못 가른다(MalformedIdpResponseTest KNOWN_LEAKS e6·h1·h4).
    assertEquals("rejected Ze6s0123456789", AuthClient.describe("rejected Ze6s0123456789", req, null));
    assertEquals("rejected qwertyuiopasdfghjklzxcvbnm",
        AuthClient.describe("rejected qwertyuiopasdfghjklzxcvbnm", req, null));
  }

  @Test void hugeDottedRun_neverOverflowsTheStack() throws Exception {
    // ⚠️ 적대적 IdP 가 고른 입력이다 — 그룹 반복 정규식은 반복마다 재귀해 오류 경로에서 StackOverflowError 를 냈다.
    HTTPRequest req = sent("grant_type=client_credentials", null);
    String huge = "X" + ".ab".repeat(200_000);
    assertEquals("***", assertDoesNotThrow(() -> AuthClient.describe(huge, req, null)));
  }

  @Test void echoGluedToALabel_isMasked() throws Exception {
    // 잘린 되울림이 이름표에 붙으면 연속 하나가 비밀의 부분 문자열이 아니다 — 10 자 창이 겹치면 가린다(Grok 레그 h5).
    HTTPRequest req = sent("grant_type=refresh_token&refresh_token=" + REFRESH, null);
    assertEquals("rejected ***", AuthClient.describe("rejected token=" + REFRESH.substring(0, 12), req, null));
    assertEquals("rejected ***", AuthClient.describe("rejected " + REFRESH.substring(3, 15) + "X", req, null));
  }
}
