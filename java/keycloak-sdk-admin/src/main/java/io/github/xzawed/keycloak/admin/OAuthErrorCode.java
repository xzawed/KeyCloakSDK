package io.github.xzawed.keycloak.admin;

import java.util.List;

/**
 * admin 자기 그랜트의 {@code KeycloakAuthException.getError()} 가 싣는 IdP 의 {@code error} — {@code [a-z_]{1,64}} 이고 그 요청이
 * 보낸 비어 있지 않은 비밀 어느 것과도 겹치지 않을 때(어느 쪽도 다른 쪽을 품지 않을 때 — ASCII 대소문자는 무시한다)만. auth 레인
 * {@code io.github.xzawed.keycloak.auth.OAuthErrorCode} 의 쌍둥이다 — 두 모듈은 서로를 모르고(§4) core 에 두면 공개 API 가 된다
 * ({@link TokenResponseGuard#isUtf8} 와 같은 까닭). 규칙은 아홉 언어가 함께 움직이므로 바꾸면 둘을 함께 바꾼다 — 같은 공유 행이
 * 둘을 고정한다({@code OAuthErrorCodeTest} 둘).
 *
 * <p>⚠️ {@code error} 도 응답 본문이다 — 보낸 것을 되울리는 IdP(나 그 앞의 프록시)는 Basic 자격의 client secret · refresh token 을
 * 거기 싣는다. 쓰는 자리는 둘이다 — 성공 상태로 온 OAuth 오류 응답({@link TokenResponseGuard.OAuthErrorResponse} — 등록부
 * auth-2xx-error-code-divergent)과 오류 상태의 응답({@link TokenResponseGuard#codeOf} — 등록부 oauth-error-code-surface-divergent).
 * 빈 비밀은 비교하지 않는다 — 빈 문자열은 모든 코드의 조각이다.
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
      if (secret == null || secret.isEmpty()) continue;
      String folded = asciiLower(secret);
      if (value.contains(folded) || folded.contains(value)) return null;
    }
    return value;
  }

  /**
   * A–Z → a–z, every other char as it is, so the nine languages agree — a Unicode lowercase maps U+212A KELVIN SIGN to
   * {@code k}.
   */
  private static String asciiLower(String s) {
    char[] out = s.toCharArray();
    for (int i = 0; i < out.length; i++) {
      if (out[i] >= 'A' && out[i] <= 'Z') out[i] = (char) (out[i] + ('a' - 'A'));
    }
    return new String(out);
  }
}
