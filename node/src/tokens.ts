import { mask } from './masking.js'

const INSPECT = Symbol.for('nodejs.util.inspect.custom')

/**
 * 토큰 엔드포인트 응답을 감싼 불변 값 타입. `accessToken`/`refreshToken`은 로그·직렬화에서
 * 마스킹된다. Java/Python SDK와 동형: `idToken`(OIDC), `expiresAt`(절대 만료·epoch 초),
 * `isExpired`를 포함한다.
 */
export class TokenSet {
  constructor(
    readonly accessToken: string,
    readonly tokenType: string,
    /** 상대 만료(초). 응답의 `expires_in`. */
    readonly expiresIn: number,
    /** 절대 만료 시각(epoch **초** — JWT `exp`/Python `expires_at`과 동형). 미상이면 undefined. */
    readonly expiresAt: number | undefined,
    readonly refreshToken?: string,
    /** OIDC `id_token`(authorization_code/refresh 흐름). client-credentials에는 없다. */
    readonly idToken?: string,
    readonly scope?: string,
  ) {}

  /** `nowSeconds`/`skewSeconds`(epoch 초) 기준 만료 여부. `expiresAt` 미상이면 보수적으로 true. */
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
 * OIDC 토큰 응답(snake_case)을 `TokenSet`으로 매핑한다. `issuedAtSeconds`(기본 현재 시각)로부터
 * 절대 만료 `expiresAt`(epoch 초)을 계산한다 — Python `TokenSet.from_response(data, issued_at)`와 동형.
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
 * 강화 검증을 통과한 액세스 토큰의 신뢰 가능한 클레임. Java/Python SDK와 동형:
 * `expiresAt`(`exp`)·`issuedAt`(`iat`)을 epoch 초로 노출한다(원본 클레임은 `claims`에도 있음).
 */
export interface ValidatedToken {
  readonly subject: string
  readonly audience: readonly string[]
  readonly issuer: string
  /** `exp` 클레임(epoch 초). 없으면 undefined. */
  readonly expiresAt: number | undefined
  /** `iat` 클레임(epoch 초). 없으면 undefined. */
  readonly issuedAt: number | undefined
  readonly claims: Readonly<Record<string, unknown>>
}

/**
 * 토큰 introspection 결과. Java/Python SDK와 동형으로 `username`/`clientId`를 노출하고,
 * Node는 추가로 전체 `claims`도 노출한다(상위집합).
 */
export interface IntrospectionResult {
  readonly active: boolean
  readonly username?: string
  readonly clientId?: string
  readonly claims: Readonly<Record<string, unknown>>
}
