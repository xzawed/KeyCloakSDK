import { mask } from './masking.js'

const INSPECT = Symbol.for('nodejs.util.inspect.custom')

/** 토큰 엔드포인트 응답을 감싼 불변 값 타입. `accessToken`은 로그/직렬화에서 마스킹된다. */
export class TokenSet {
  constructor(
    readonly accessToken: string,
    readonly tokenType: string,
    readonly expiresIn: number,
    readonly refreshToken?: string,
    readonly scope?: string,
  ) {}

  private masked(): string {
    return `TokenSet(tokenType=${this.tokenType}, expiresIn=${this.expiresIn}, accessToken=${mask(this.accessToken)})`
  }
  toString(): string {
    return this.masked()
  }
  toJSON(): Record<string, unknown> {
    return { tokenType: this.tokenType, expiresIn: this.expiresIn, accessToken: mask(this.accessToken) }
  }
  [INSPECT](): string {
    return this.masked()
  }
}

/** OIDC 토큰 응답(snake_case)을 `TokenSet`으로 매핑한다. */
export function tokenSetFromResponse(json: Record<string, unknown>): TokenSet {
  const at = json['access_token']
  if (typeof at !== 'string' || at.length === 0) {
    throw new Error('token response missing access_token')
  }
  return new TokenSet(
    at,
    typeof json['token_type'] === 'string' ? json['token_type'] : 'Bearer',
    typeof json['expires_in'] === 'number' ? json['expires_in'] : Number(json['expires_in'] ?? 0),
    typeof json['refresh_token'] === 'string' ? json['refresh_token'] : undefined,
    typeof json['scope'] === 'string' ? json['scope'] : undefined,
  )
}

/** 강화 검증을 통과한 액세스 토큰의 신뢰 가능한 클레임. */
export interface ValidatedToken {
  readonly subject: string
  readonly audience: readonly string[]
  readonly issuer: string
  readonly claims: Readonly<Record<string, unknown>>
}

/** 토큰 introspection 결과. */
export interface IntrospectionResult {
  readonly active: boolean
  readonly claims: Readonly<Record<string, unknown>>
}
