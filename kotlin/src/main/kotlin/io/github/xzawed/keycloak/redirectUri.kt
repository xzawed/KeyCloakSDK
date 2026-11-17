package io.github.xzawed.keycloak

import java.net.URI

// redirectUri.kt — 인가 요청의 redirect_uri 검사(RFC 6749 §3.1.2: 리디렉션 엔드포인트 URI 는 RFC 3986 §4.3 의 절대 URI 여야 한다).
// AuthClient.createAuthorizationRequest 가 파싱 직후, 아무것도 만들기 전에 부른다 — auth.kt 는 통째로 Kover 게이트 밖이라 검사는
// 여기 산다. Nimbus 11.39 의 build() 는 fragment(빈 것도)·금지 scheme·금지 쿼리 파라미터를 이미 거부하지만 — 그 거부와 메시지는
// 그대로 둔다 — 상대 참조(빈 값·`cb`·`/cb`·`//app/cb`)는 그대로 URL 에 실었다(실측 2026-11-18). 검사만 하고 고치지 않는다 — URL 은
// 호출자 문자열 그대로다(코드 교환이 그 문자열을 그대로 보내므로 둘 중 하나만 정규화하면 두 값이 갈린다, #1133). 그래서 교환과 함께
// 쓰는 파싱(AuthClient.redirectUri)에는 두지 않는다. 메시지는 고정 문구라 입력을 싣지 않는다. Java 자매(RedirectUri.java)와 같다.

/** `URI.isAbsolute` 는 scheme 이 있는가다 — 파싱한 값에서 RFC 3986 의 `^[A-Za-z][A-Za-z0-9+.-]*:` 와 같은 판정이다. */
internal fun requireAbsoluteRedirectUri(redirect: URI) {
    if (!redirect.isAbsolute) {
        throw KeycloakConfigException("invalid redirect_uri: not an absolute URI (RFC 6749 §3.1.2)")
    }
}
