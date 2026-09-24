package io.github.xzawed.keycloak.auth;
import static org.junit.jupiter.api.Assertions.*;
import com.nimbusds.oauth2.sdk.http.HTTPRequest;
import io.github.xzawed.keycloak.core.KeycloakConfig;
import io.github.xzawed.keycloak.core.exception.KeycloakConfigException;
import java.net.URI;
import org.junit.jupiter.api.Test;

// 퍼블릭/PKCE 클라이언트(clientSecret 미설정)가 기밀 클라이언트 전용 흐름을 호출했을 때, 예전처럼
// new String((char[]) null)의 맨 NPE가 아니라 SDK 예외 + 조치 가능한 메시지가 나오는지 검증한다.
// 예외 타입은 KeycloakConfigException으로 고정한다 — IdP 거절이 아니라 로컬 구성 미비라서 요청이
// 전송조차 되지 않으며, admin AdminClient.requireClientSecret()이 같은 조건에 쓰는 타입과 같다
// (배포 후에는 taxonomy가 얼어붙으므로 이 계약을 테스트로 못박는다).
// 전부 send() 이전에 실패하므로 네트워크 불필요.
class AuthClientPublicClientTest {
  // RFC 7636 code_verifier는 43~128자여야 한다(Nimbus CodeVerifier가 강제).
  private static final String REFRESH_TOKEN = "some-refresh-token";
  private static final String ACCESS_TOKEN = "some-access-token";
  private static final String VERIFIER = "verifier-value-that-is-at-least-43-characters-long";

  private AuthClient publicClient() {
    KeycloakConfig c = KeycloakConfig.builder()
        .serverUrl("https://kc.example.com").realm("r").clientId("public-app").build();
    return new AuthClient(c, OidcMetadata.forRealm(c));
  }

  // 메시지는 (1) 어떤 작업이 기밀 클라이언트를 요구하는지 (2) 퍼블릭/PKCE 클라이언트는 쓸 수 없다는 사실
  // (3) 무엇을 고쳐야 하는지를 모두 담아야 한다 — NPE 대비 이 픽스의 실질 가치가 메시지에 있다.
  private static void assertActionable(KeycloakConfigException e, String operation) {
    String m = e.getMessage();
    assertTrue(m.contains(operation), m);
    assertTrue(m.contains("Public/PKCE clients cannot use this operation"), m);
    assertTrue(m.contains("clientSecret"), m);
  }

  @Test void clientCredentialsToken_publicClient_throwsActionableConfigException() {
    AuthClient a = publicClient();
    KeycloakConfigException e = assertThrows(KeycloakConfigException.class, a::clientCredentialsToken);
    assertActionable(e, "client_credentials grant");
  }

  // ⚠️ refresh·logout 은 **거부 대상이 아니다** — 이 두 테스트가 예전엔 거부를 의도로 고정하고
  // 있었다. 실측(2026-09-24, KC 26.6): 공개 클라이언트의 refresh_token 그랜트 200 · logout 204
  // (이후 같은 토큰은 "Session not active"). 서버가 거부하는 것은 client_credentials(401)와
  // introspect(403)뿐이라 그 둘만 로컬에서 먼저 막는다. 실서버 대조는 AuthFlowIT.
  @Test void buildRefreshRequest_publicClient_sendsClientIdInBody_noAuthHeader() {
    HTTPRequest req = publicClient().buildRefreshRequest(REFRESH_TOKEN);
    assertNull(req.getAuthorization());
    assertTrue(req.getBody().contains("client_id=public-app"), req.getBody());
    assertTrue(req.getBody().contains("grant_type=refresh_token"), req.getBody());
  }

  @Test void buildLogoutRequest_publicClient_sendsClientIdInBody_noAuthHeader() {
    HTTPRequest req = publicClient().buildLogoutRequest(REFRESH_TOKEN);
    assertNull(req.getAuthorization());
    assertTrue(req.getBody().contains("client_id=public-app"), req.getBody());
    assertTrue(req.getBody().contains("refresh_token=" + REFRESH_TOKEN), req.getBody());
  }

  @Test void introspect_publicClient_throwsActionableConfigException() {
    AuthClient a = publicClient();
    KeycloakConfigException e =
        assertThrows(KeycloakConfigException.class, () -> a.introspect(ACCESS_TOKEN));
    assertActionable(e, "token introspection");
  }

  // 요청 조립 헬퍼도 동일하게 실패해야 한다(introspect 의 send()는 이 지점을 넘지 못한다).
  @Test void buildIntrospectionRequest_publicClient_throwsBeforeAssemblingRequest() {
    AuthClient a = publicClient();
    assertThrows(KeycloakConfigException.class, () -> a.buildIntrospectionRequest(ACCESS_TOKEN));
  }

  // 인자 검증(null)은 clientAuth() 가드보다 먼저다 — 퍼블릭 클라이언트라도 계약 위반이 우선 보고된다.
  @Test void nullArgumentValidationStillPrecedesConfidentialClientGuard() {
    AuthClient a = publicClient();
    assertThrows(IllegalArgumentException.class, () -> a.logout(null));
    assertThrows(IllegalArgumentException.class, () -> a.refresh(null));
    assertThrows(IllegalArgumentException.class, () -> a.introspect(null));
  }

  // 가드가 과잉 발동하지 않는지: 문서화된 퍼블릭/PKCE 경로(인가 URL 생성 + 코드 교환 요청 조립)는
  // clientSecret 없이도 그대로 동작해야 한다.
  @Test void publicClientPkceFlowStillWorksWithoutSecret() {
    AuthClient a = publicClient();
    assertNotNull(a.createAuthorizationRequest(URI.create("https://app/cb")).getAuthorizationUrl());
    HTTPRequest req = a.buildExchangeCodeRequest("auth-code", URI.create("https://app/cb"), VERIFIER);
    assertNull(req.getAuthorization());
    assertTrue(req.getBody().contains("client_id=public-app"), req.getBody());
  }
}
