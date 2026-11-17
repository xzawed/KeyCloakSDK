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
 * `redirectUri`. It used to escape the SDK's error hierarchy as `new URL`'s `TypeError` (§4).
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
  return url
}
