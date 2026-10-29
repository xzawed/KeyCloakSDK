import { mask } from './masking.js'

const INSPECT = Symbol.for('nodejs.util.inspect.custom')

/**
 * Immutable value type wrapping a token-endpoint response. `accessToken`/`refreshToken` are masked in logs and
 * serialization. Isomorphic with the Java/Python SDKs: it includes `idToken` (OIDC), `expiresAt` (absolute
 * expiry, epoch seconds) and `isExpired`.
 */
export class TokenSet {
  constructor(
    readonly accessToken: string,
    readonly tokenType: string,
    /** Relative expiry (seconds). The response's `expires_in`. */
    readonly expiresIn: number,
    /** Absolute expiry time (epoch **seconds** — isomorphic with JWT `exp`/Python `expires_at`). undefined if unknown. */
    readonly expiresAt: number | undefined,
    readonly refreshToken?: string,
    /** OIDC `id_token` (authorization_code/refresh flows). Absent for client-credentials. */
    readonly idToken?: string,
    readonly scope?: string,
  ) {}

  /** Whether it is expired as of `nowSeconds`/`skewSeconds` (epoch seconds). Conservatively true if `expiresAt` is unknown. */
  isExpired(nowSeconds: number, skewSeconds: number): boolean {
    if (this.expiresAt === undefined) {
      return true
    }
    return nowSeconds + skewSeconds >= this.expiresAt
  }

  private masked(): string {
    return `TokenSet(tokenType=${this.tokenType}, expiresIn=${this.expiresIn}, accessToken=${mask(this.accessToken)}, refreshToken=${mask(this.refreshToken)})`
  }
  toString(): string {
    return this.masked()
  }
  toJSON(): Record<string, unknown> {
    return {
      tokenType: this.tokenType,
      expiresIn: this.expiresIn,
      expiresAt: this.expiresAt,
      accessToken: mask(this.accessToken),
      refreshToken: mask(this.refreshToken),
    }
  }
  [INSPECT](): string {
    return this.masked()
  }
}

/**
 * Maps an OIDC token response (snake_case) to a `TokenSet`. Computes the absolute expiry `expiresAt` (epoch
 * seconds) from `issuedAtSeconds` (default: the current time) — isomorphic with Python
 * `TokenSet.from_response(data, issued_at)`.
 */
export function tokenSetFromResponse(
  json: Record<string, unknown>,
  issuedAtSeconds: number = Math.floor(Date.now() / 1000),
): TokenSet {
  const at = json['access_token']
  if (typeof at !== 'string' || at.length === 0) {
    throw new Error('token response missing access_token')
  }
  const rawExpiresIn = json['expires_in']
  const expiresIn = typeof rawExpiresIn === 'number' ? rawExpiresIn : Number(rawExpiresIn ?? 0)
  const expiresAt = expiresIn > 0 ? issuedAtSeconds + expiresIn : undefined
  return new TokenSet(
    at,
    typeof json['token_type'] === 'string' ? json['token_type'] : 'Bearer',
    expiresIn,
    expiresAt,
    typeof json['refresh_token'] === 'string' ? json['refresh_token'] : undefined,
    typeof json['id_token'] === 'string' ? json['id_token'] : undefined,
    typeof json['scope'] === 'string' ? json['scope'] : undefined,
  )
}

/**
 * Trusted claims of an access token that passed hardened validation. Isomorphic with the Java/Python SDKs:
 * exposes `expiresAt` (`exp`) and `issuedAt` (`iat`) in epoch seconds (the original claims are also in `claims`).
 */
export interface ValidatedToken {
  readonly subject: string
  readonly audience: readonly string[]
  readonly issuer: string
  /** The `exp` claim (epoch seconds). undefined when absent. */
  readonly expiresAt: number | undefined
  /** The `iat` claim (epoch seconds). undefined when absent. */
  readonly issuedAt: number | undefined
  readonly claims: Readonly<Record<string, unknown>>
}

/**
 * Token introspection result. Isomorphic with the Java/Python SDKs, it exposes `username`/`clientId`, and Node
 * additionally exposes the full `claims` too (a superset).
 */
export interface IntrospectionResult {
  readonly active: boolean
  readonly username?: string
  readonly clientId?: string
  readonly claims: Readonly<Record<string, unknown>>
}
