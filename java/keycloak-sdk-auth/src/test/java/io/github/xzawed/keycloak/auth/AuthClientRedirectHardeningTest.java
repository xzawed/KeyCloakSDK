package io.github.xzawed.keycloak.auth;
import static org.junit.jupiter.api.Assertions.*;
import com.nimbusds.oauth2.sdk.http.HTTPRequest;
import io.github.xzawed.keycloak.core.KeycloakConfig;
import java.net.URI;
import org.junit.jupiter.api.Test;

/**
 * SSRF 하드닝 — SDK가 **스스로 보내는** back-channel 요청(token·refresh·introspect·logout)은
 * 3xx를 따라가면 안 된다. Nimbus {@code HTTPRequest}의 기본값은 추종이다.
 *
 * <p>왜 심각한가(실측): 이 SDK의 5개 {@code send()} 호출부가 전부 {@link AuthClient#applyTimeouts}를
 * 지나므로 한 곳이 뚫리면 전부 뚫린다. 그리고 이 클래스의 위험은 "엉뚱한 URL을 가져온다"에 그치지
 * 않는다 — <b>logout이 302를 따라가 무관한 200을 받으면 정상 반환</b>한다. 호출자는 세션이
 * 폐기됐다고 믿지만 실제로는 살아 있다. 예외보다 나쁜 실패 모드다.
 *
 * <p>⚠️ 이것은 SDK가 보내는 요청에 대한 것이다. OIDC authorization-code의 {@code redirect_uri}는
 * 브라우저 front-channel 개념이라 무관하다 — 이름이 비슷해 혼동하기 쉽다.
 *
 * <p>네트워크 불필요: {@code applyTimeouts}가 모든 전송의 단일 병목이므로 그 산출물의 플래그를
 * 직접 확인하는 것이 가장 좁고 확실한 계약이다. Kotlin 자매 SDK도 같은 지점을 같은 방식으로 막는다.
 */
class AuthClientRedirectHardeningTest {

  private static AuthClient client() {
    KeycloakConfig c = KeycloakConfig.builder()
        .serverUrl("https://kc.example.com").realm("r").clientId("app").build();
    return new AuthClient(c, OidcMetadata.forRealm(c));
  }

  @Test void applyTimeouts_disablesRedirectFollowing() throws Exception {
    HTTPRequest req = new HTTPRequest(HTTPRequest.Method.POST,
        URI.create("https://kc.example.com/realms/r/protocol/openid-connect/token").toURL());
    // 전제 확인: Nimbus 기본값은 추종이다. 이 단언이 깨지면 상류가 기본값을 바꿨다는 뜻이고,
    // 그때는 아래 하드닝이 불필요해졌는지 재검토해야 한다(무의미해진 코드를 남기지 않도록).
    assertTrue(req.getFollowRedirects(),
        "Nimbus HTTPRequest의 기본값이 더 이상 '추종'이 아니라면 이 하드닝의 전제를 재검토할 것");

    assertFalse(client().applyTimeouts(req).getFollowRedirects(),
        "SSRF 하드닝: back-channel 요청은 3xx를 따라가면 안 된다");
  }
}
