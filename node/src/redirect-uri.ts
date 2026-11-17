import { KeycloakConfigError } from './errors.js'

/**
 * The redirect URI of the authorization-code flow, in the one form both of its requests send. `createAuthorizationRequest`
 * puts its `href` in the authorization URL and `exchangeCode` hands it to openid-client, which builds the token request's
 * `redirect_uri` by serializing it with the query and fragment removed. Keycloak compares the two strings exactly
 * (`Incorrect redirect_uri` otherwise), so a URI that differs from its own serialization — a bare origin without the
 * trailing slash, an upper-case host, a default port, `..`, a space — is normalized here, and a query or a fragment,
 * which the token request would drop, is refused.
 *
 * A value that does not parse as a URL, or carries a query or a fragment, is a `KeycloakConfigError`
 * (`invalid redirect_uri: <reason>`) before any request — the same class as Rust's `redirect_url` and Kotlin's
 * `redirectUri`. It used to escape the SDK's error hierarchy as `new URL`'s `TypeError` (§4). So is a serialization
 * Keycloak's parser (`java.net.URI`) refuses although WHATWG accepts it — nothing after the scheme, or a `[` or `]`
 * outside one bracketed host (`invalid redirect_uri: not a valid URI (RFC 3986 §2)`).
 *
 * It lives outside `auth.ts` on purpose: `auth.ts` is a network boundary excluded from unit coverage, and the
 * integration run never takes these failure branches, so there they hid from both gates.
 */
export function redirectUrl(value: string): URL {
  let url: URL
  try {
    url = new URL(value)
  } catch (e) {
    throw new KeycloakConfigError(`invalid redirect_uri: ${(e as Error).message}`, { cause: e })
  }
  // 빈 `?` · `#` 는 값이 아니라 표기라 아래에서 지운다(`search` · `hash` 가 빈 문자열이다). 값이 있는 것만 거부한다 —
  // fragment 는 RFC 6749 §3.1.2 가 금하고, 쿼리는 openid-client 6 이 토큰 요청에서 떼어 내(`stripParams`) 교환이 맞을 수 없다.
  if (url.hash !== '') {
    throw new KeycloakConfigError(
      'invalid redirect_uri: a fragment is not allowed (RFC 6749 §3.1.2)',
    )
  }
  if (url.search !== '') {
    throw new KeycloakConfigError(
      'invalid redirect_uri: a query is not supported (the code exchange sends the redirect URI without it)',
    )
  }
  url.search = ''
  url.hash = ''
  if (!passesR4(url.href)) {
    throw new KeycloakConfigError('invalid redirect_uri: not a valid URI (RFC 3986 §2)')
  }
  return url
}

// 괄호 호스트 하나 — 사용자 정보 · 포트는 있어도 된다. 괄호 안의 내용은 보지 않는다(`[zz]` · IPvFuture 는 남은 일이다).
const BRACKETED_HOST = /^([^@[\]/]*@)?\[[^[\]/]+\](:[0-9]*)?$/

// R4 — WHATWG 는 받지만 Keycloak 의 `java.net.URI.create`(RedirectUtils.toUri)는 거부하는 직렬화(실측 JDK 21.0.8: 「Expected
// scheme-specific part」 · 「Illegal character in path」). (R4a) scheme 의 `:` 뒤가 비면(`myapp:`) 아니다. (R4b) `:` 뒤가 `/` 로
// 시작하면 `?` 앞을 본다 — `//` 로 시작하면 다음 `/` 까지(없으면 끝까지)가 authority 이고 거기 `[` · `]` 는 괄호 호스트 하나로만
// 올 수 있다. 그 밖(경로)의 `[` · `]` 는 아니다. 불투명한 값(`myapp:c[b` · `urn:x[y]`)과 쿼리는 괄호를 가져도 된다. 다른 언어의
// R4 와 같은 판정이고, 그 언어들이 보내는 문자열 대신 node 가 보내는 `href` 를 본다. WHATWG 의 `href` 는 호스트 밖의 `[` · `]` 를
// 이미 퍼센트 인코딩하므로 authority 갈래는 `redirectUrl` 로는 닿지 않는다 — 판정 전체는 시험이 이 함수로 직접 잰다.
export function passesR4(href: string): boolean {
  const rest = href.slice(href.indexOf(':') + 1)
  if (rest === '') return false
  if (!rest.startsWith('/')) return true
  const beforeQuery = rest.split('?', 1)[0]!
  let path = beforeQuery
  if (beforeQuery.startsWith('//')) {
    const slash = beforeQuery.indexOf('/', 2)
    const authority = slash === -1 ? beforeQuery.slice(2) : beforeQuery.slice(2, slash)
    if (/[[\]]/.test(authority) && !BRACKETED_HOST.test(authority)) return false
    path = slash === -1 ? '' : beforeQuery.slice(slash)
  }
  return !/[[\]]/.test(path)
}
