/**
 * What a `KeycloakAuthError` carries of the IdP's OAuth `error` in `oauthError` — the rule all nine languages share
 * (java `OAuthErrorCode.carried`): a string of `[a-z_]{1,64}`, the shape of every registered OAuth and Keycloak code,
 * that overlaps no non-empty secret the request sent (neither contains the other, ASCII case ignored).
 *
 * ⚠️ `error` is response body too: an IdP (or a proxy in front of it) that echoes what it got puts the client secret,
 * the refresh token, the authorization code, the PKCE verifier or the introspected token there. The overlap withholds
 * a truncated or extended echo as well; its price is a secret that is a piece of a registered code (`client`)
 * withholding that code. An empty or absent secret is not compared — the empty string is a piece of every code.
 * Pinned by `test/unit/oauth-error-code.test.ts` and `test/unit/oauth-error-code-echo.test.ts`.
 */

/**
 * The `code` of oauth4webapi's `ResponseBodyError` — what openid-client throws when the token or introspection
 * endpoint answers 4xx with a JSON body whose `error` is a non-empty string (401 included), and what the SDK's fetch
 * throws for such a body at a 2xx (`fetchTokenEndpointBounded`). Of its errors it is the only one that holds the body's
 * `error`: a 401 with a `WWW-Authenticate` challenge ends before the body is read.
 */
const RESPONSE_BODY_ERROR = 'OAUTH_RESPONSE_BODY_ERROR'

/** The longest code carried. */
const MAX_CODE_LENGTH = 64

/**
 * `value` when it may be carried as an OAuth error code, otherwise `undefined`. Each secret in `sent` is compared as
 * the string the request sent — a JavaScript caller's non-string goes out stringified (`URLSearchParams`); `null` and
 * `undefined` were not sent.
 *
 * @internal
 */
export function carriedOAuthError(
  value: unknown,
  sent: ReadonlyArray<unknown>,
): string | undefined {
  if (typeof value !== 'string' || value.length === 0 || value.length > MAX_CODE_LENGTH) {
    return undefined
  }
  for (let i = 0; i < value.length; i += 1) {
    const c = value.charCodeAt(i)
    if ((c < 0x61 || c > 0x7a) && c !== 0x5f) return undefined // [a-z_]
  }
  for (const secret of sent) {
    if (secret === undefined || secret === null) continue
    const text = asciiLower(String(secret))
    if (text.length > 0 && (value.includes(text) || text.includes(value))) return undefined
  }
  return value
}

/**
 * A–Z → a–z, every other character as it is, so the nine languages agree — a Unicode lowercase maps U+212A KELVIN
 * SIGN to `k`.
 */
function asciiLower(s: string): string {
  return s.replace(/[A-Z]/g, (c) => String.fromCharCode(c.charCodeAt(0) + 0x20))
}

/**
 * The OAuth error code an auth failure carries: the body's `error` of the `ResponseBodyError` openid-client threw,
 * through {@link carriedOAuthError} against `sent` — every secret that request carried. Any other failure carries
 * none. It reads the original error, before the SDK error scrubs its cause.
 *
 * @internal
 */
export function oauthErrorOf(error: unknown, sent: ReadonlyArray<unknown>): string | undefined {
  if (!(error instanceof Error) || (error as { code?: unknown }).code !== RESPONSE_BODY_ERROR) {
    return undefined
  }
  return carriedOAuthError((error as { error?: unknown }).error, sent)
}
