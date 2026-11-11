package io.github.xzawed.keycloak.auth;

import java.util.List;

/**
 * {@code KeycloakAuthException.getError()} 가 싣는 IdP 의 {@code error} — {@code [a-z_]{1,64}} 이고(등록된 OAuth · Keycloak 코드는
 * 전부 이 모양이다) 그 요청이 보낸 비어 있지 않은 비밀 어느 것과도 겹치지 않을 때(어느 쪽도 다른 쪽을 품지 않을 때)만.
 *
 * <p>⚠️ {@code error} 도 응답 본문이다 — 보낸 것을 되울리는 IdP(나 그 앞의 프록시)는 client secret · refresh token · introspect 한
 * 토큰을 거기 싣는다. 예전에는 Nimbus 의 {@code ErrorObject.getCode()}(RFC 6749 문법 — Keycloak 모양 시크릿 · JWT 도 그 안이다)를 그대로
 * 넘겨 {@code getError()} 와 리플렉션 덤프에 찍혔다(실측 main a7d0fdf3, 등록부 token-error-code-secret-echo · oauth-error-field-echo-unmasked).
 * 겹침은 잘린 · 덧붙은 되울림도 막고, 그 값은 비밀이 등록 코드의 조각일 때({@code client}) 그 코드를 잃는 것이다. 빈 비밀은 비교하지
 * 않는다 — 빈 문자열은 모든 코드의 조각이다. 고정: {@code OAuthErrorCodeTest} · {@code OAuthErrorCodeEchoTest}.
 */
final class OAuthErrorCode {
  private OAuthErrorCode() {}

  static String carried(String value, List<String> sent) {
    if (value == null || value.isEmpty() || value.length() > 64) return null;
    for (int i = 0; i < value.length(); i++) {
      char c = value.charAt(i);
      if ((c < 'a' || c > 'z') && c != '_') return null;
    }
    for (String secret : sent) {
      if (secret != null && !secret.isEmpty() && (value.contains(secret) || secret.contains(value))) return null;
    }
    return value;
  }
}
