import { KeycloakAuthError } from './errors.js'
import type { TokenSet } from './tokens.js'

/** RFC 6750 §2.1 `b64token` — ASCII 영숫자와 `-._~+/`, `=` 는 끝의 덧대기로만. */
const B64TOKEN = /^[A-Za-z0-9\-._~+/]+=*$/

/** 앞뒤에서 떼는 넷 — SP·HTAB·CR·LF. `trim()` 은 유니코드 공백·VT·FF 까지 떼므로 쓰지 않는다. */
function isEdge(code: number): boolean {
  return code === 0x20 || code === 0x09 || code === 0x0d || code === 0x0a
}

/**
 * The value admin sends as the Bearer — the same rule in all nine languages (registry
 * `bearer-token-grammar-divergent`). It strips only SP, HTAB, CR and LF from both ends (the trailing newline of a
 * token read from a file); if what remains is a non-empty `b64token` it returns the **stripped value**, otherwise
 * it throws a {@link KeycloakAuthError} that carries no token, with no cause — that request is not sent. The places
 * that send (the facade's `admin/http.ts` · the provider registered on `raw()` · the token acquisition at
 * creation) and the place that caches ({@link ClientCredentialsTokenProvider}) all use this one function. The
 * stripping is a linear scan (for the same reason as `stripTrailingSlashes` in `config.ts`). Length is not checked
 * — the request-header limit is the server's to set (Keycloak 26.6 accepts a 65,459-byte Bearer).
 */
export function sendableBearer(token: string): string {
  const text = String(token)
  let start = 0
  let end = text.length
  while (start < end && isEdge(text.charCodeAt(start))) start += 1
  while (end > start && isEdge(text.charCodeAt(end - 1))) end -= 1
  const trimmed = text.slice(start, end)
  if (!B64TOKEN.test(trimmed)) {
    throw new KeycloakAuthError(
      'admin access token cannot be sent: it is not an RFC 6750 bearer token (b64token)',
    )
  }
  return trimmed
}

/** Supplier interface for the access tokens admin consumes (the only glue between auth and admin). */
export interface TokenProvider {
  getAccessToken(): Promise<string>
}

/** A source that can issue client-credentials tokens (implemented by AuthClient). */
export interface TokenSource {
  clientCredentialsToken(): Promise<TokenSet>
}

/**
 * The default TokenProvider: obtains, caches and renews tokens automatically with client-credentials.
 * Before expiry it reuses the cache, and concurrent requests are collapsed into a single issuance (single-flight).
 * What it caches is the value {@link sendableBearer} returned — a token that fails that check is not cached and
 * the call fails with `KeycloakAuthError`, so the next call asks the source again.
 */
export class ClientCredentialsTokenProvider implements TokenProvider {
  #cached?: { token: string; expiresAt: number }
  #inflight?: Promise<string>

  constructor(
    private readonly source: TokenSource,
    private readonly skewSeconds = 30,
  ) {}

  async getAccessToken(): Promise<string> {
    const cached = this.#cached
    if (cached && Date.now() < cached.expiresAt) return cached.token
    if (this.#inflight) return this.#inflight
    this.#inflight = this.#fetch()
    try {
      return await this.#inflight
    } finally {
      this.#inflight = undefined
    }
  }

  async #fetch(): Promise<string> {
    const ts = await this.source.clientCredentialsToken()
    // 캐시하기 **전에** 거른다 — 던지면 `#cached` 는 그대로라 거부한 토큰이 캐시에 남지 않는다.
    const token = sendableBearer(ts.accessToken)
    this.#cached = {
      token,
      expiresAt: Date.now() + Math.max(0, ts.expiresIn - this.skewSeconds) * 1000,
    }
    return token
  }
}
