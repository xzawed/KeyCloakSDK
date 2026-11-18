package io.github.xzawed.keycloak.auth;

import io.github.xzawed.keycloak.core.exception.KeycloakConfigException;
import java.net.URI;

/**
 * 인가 요청의 redirect_uri 검사 — RFC 6749 §3.1.2: 리디렉션 엔드포인트 URI 는 RFC 3986 §4.3 의 절대 URI 여야 한다.
 * {@code AuthClient.createAuthorizationRequest} 가 아무것도 만들기 전에 부른다(AuthClient 는 단위 커버리지 밖이라 검사는 여기 산다).
 *
 * <p>Nimbus 11.39 의 build() 는 fragment(빈 것도)·금지 scheme·금지 쿼리 파라미터를 이미 거부하지만 — 그 거부와 메시지는 그대로
 * 둔다 — 상대 참조(빈 값·{@code cb}·{@code /cb}·{@code //app/cb})는 그대로 URL 에 실었다(실측 2026-11-18). 그래서 Java 에 새로
 * 붙는 것은 절대성 하나다. 검사만 하고 고치지 않는다 — URL 은 호출자 URI 그대로다(코드 교환이 그 값을 그대로 보내므로 둘 중
 * 하나만 정규화하면 두 값이 갈린다, #1133). 메시지는 고정 문구라 입력을 싣지 않는다. Kotlin 자매({@code redirectUri.kt})와 같다.
 */
final class RedirectUri {
  static final String NOT_ABSOLUTE = "invalid redirect_uri: not an absolute URI (RFC 6749 §3.1.2)";

  private RedirectUri() {}

  // URI.isAbsolute() 는 scheme 이 있는가다 — java.net.URI 가 이미 파싱한 값에서 RFC 3986 의 ^[A-Za-z][A-Za-z0-9+.-]*: 와 같은 판정이다.
  static void requireAbsolute(URI redirectUri) {
    if (!redirectUri.isAbsolute()) {
      throw new KeycloakConfigException(NOT_ABSOLUTE, null);
    }
  }
}
