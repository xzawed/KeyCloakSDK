package io.github.xzawed.keycloak.auth;

import com.nimbusds.oauth2.sdk.ErrorObject;
import com.nimbusds.oauth2.sdk.ParseException;
import com.nimbusds.oauth2.sdk.TokenErrorResponse;
import com.nimbusds.oauth2.sdk.TokenIntrospectionErrorResponse;
import com.nimbusds.oauth2.sdk.TokenIntrospectionResponse;
import com.nimbusds.oauth2.sdk.TokenResponse;
import com.nimbusds.oauth2.sdk.http.HTTPResponse;
import com.nimbusds.openid.connect.sdk.OIDCTokenResponseParser;
import java.util.Map;

/**
 * 토큰(세 그랜트) · introspection 응답의 해석 — Nimbus 의 파서 그대로이되, 성공 상태(200 — Nimbus 가 성공으로 읽는 유일한 상태)의
 * 본문이 JSON 객체이고 그 {@code error} 가 있고 null 도 "" 도 아니면 그 응답은 <b>오류 응답</b>이다(등록부
 * auth-2xx-error-code-divergent · token-response-residual-divergence A). 400 이 같은 본문을 실었을 때와 같은 길로 보낸다 — 같은
 * 타입 · 같은 메시지 꼴(설명, 없으면 상태) · 같은 코드 판정({@link OAuthErrorCode#carried} — 문자열이 아닌 {@code error} 는 코드가
 * 아니고, 보낸 비밀의 되울림은 여전히 싣지 않는다).
 *
 * <p>⚠️ 수정 전에는 그 본문의 나머지를 썼다 — {@code access_token} 이 있으면 토큰을 돌려주고(공급자는 캐시했다), {@code active} 가
 * 참이면 활성으로 읽었다. 없으면 코드 없는 「… request error」 였다(실측 — {@code TokenResponseClassTest}). 이제 그 본문에서 아무것도
 * 쓰지 않는다 — 문자열이 아닌 {@code error}(숫자 · 객체 · 배열 · 불리언)도 그렇다(예전에는 나머지가 판정해 토큰을 썼다). null 이거나
 * 비었으면 {@code error} 가 없는 것과 같다. 본문은 성공 파서가 읽는 그대로 읽는다({@code getBodyAsJSONObject} — JSON 이 아닌
 * Content-Type 이나 JSON 객체가 아닌 본문은 판정하지 않고, 성공 파서가 지금처럼 거부한다).
 *
 * <p>⚠️ {@link AuthClient} 에 두지 않는 까닭: 그 파일은 통합 실행으로 재는 경계 파일이고(scripts/integration-coverage.json) 이 갈래는
 * 실 Keycloak 이 닿지 않는다 — 여기 두면 단위 게이트가 잰다.
 */
final class TokenResponses {
  private TokenResponses() {}

  /** client_credentials · refresh 의 응답 — {@link TokenResponse#parse} 와 같되 성공 상태의 OAuth error 는 오류 응답이다. */
  static TokenResponse token(HTTPResponse response) throws ParseException {
    return carriesError(response) ? new TokenErrorResponse(ErrorObject.parse(response)) : TokenResponse.parse(response);
  }

  /** 코드 교환의 응답(id_token 을 보존하는 OIDC 파서) — 성공 상태의 OAuth error 는 오류 응답이다. */
  static TokenResponse oidcToken(HTTPResponse response) throws ParseException {
    return carriesError(response) ? new TokenErrorResponse(ErrorObject.parse(response)) : OIDCTokenResponseParser.parse(response);
  }

  /** introspection 의 응답 — 성공 상태의 OAuth error 는 오류 응답이다(활성으로 읽지 않는다). */
  static TokenIntrospectionResponse introspection(HTTPResponse response) throws ParseException {
    return carriesError(response)
        ? new TokenIntrospectionErrorResponse(ErrorObject.parse(response)) : TokenIntrospectionResponse.parse(response);
  }

  /**
   * 성공 상태(200)의 본문이 JSON 객체이고 그 {@code error} 가 있고 null 도 "" 도 아닌가(JSON null 은 파서가 null 로 둔다). 그 밖의
   * 상태는 Nimbus 가 이미 오류 응답으로 읽는다 — 상태의 수용 범위는 바꾸지 않는다. ⚠️ Nimbus 의 {@code TokenErrorResponse.parse} ·
   * {@code TokenIntrospectionErrorResponse.parse} 는 200 을 거부하므로(ensureStatusCodeNotOK) 호출부는 그 둘이 하는 일(ErrorObject.parse
   * — 문자열이 아닌 {@code error} 는 코드 없이 둔다)을 직접 한다.
   */
  static boolean carriesError(HTTPResponse response) {
    if (response.getStatusCode() != HTTPResponse.SC_OK) return false;
    Map<String, Object> body;
    try {
      body = response.getBodyAsJSONObject();
    } catch (ParseException notAJsonObject) {
      return false; // 성공 파서가 지금처럼 거부한다 — 이 예외의 메시지는 응답을 인용할 수 있어 버린다
    }
    Object error = body.get("error");
    return error != null && !"".equals(error);
  }
}
