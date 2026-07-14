import { jwtVerify, createRemoteJWKSet, type JWTVerifyGetKey } from 'jose'
import { KeycloakTokenValidationError } from './errors.js'
import type { ValidatedToken } from './tokens.js'

export interface JwtValidatorOptions {
  readonly issuer: string
  readonly audience: string
  readonly allowedAlgs: string[]
  readonly clockSkewSeconds: number
}

/**
 * 자체 강화 JWT 검증기. 라이브러리 기본값을 신뢰하지 않는다:
 * 알고리즘 핀(헤더 alg 불신, `none` 거부) · issuer 정확일치 · audience 포함검사(다중 aud 수용) ·
 * exp/nbf ± 클록 스큐 · JWKS 재조회 DoS-safe(kid 미해결 시에만 재조회 + 쿨다운 rate-limit).
 *
 * 키 소스는 주입형이다(테스트는 로컬 JWKS, 실사용은 `forJwksUri`의 원격 JWKS).
 */
export class JwtValidator {
  constructor(
    private readonly keys: JWTVerifyGetKey,
    private readonly opts: JwtValidatorOptions,
  ) {}

  /** 원격 JWKS URI로 검증기를 만든다. `createRemoteJWKSet`은 kid 미해결 시에만 재조회하고 cooldownDuration으로 rate-limit → 서명 위조로 인한 미인증 DoS 증폭을 차단한다. */
  static forJwksUri(jwksUri: string, opts: JwtValidatorOptions): JwtValidator {
    const keys = createRemoteJWKSet(new URL(jwksUri), {
      cooldownDuration: 30_000,
      cacheMaxAge: 600_000,
    })
    return new JwtValidator(keys, opts)
  }

  async validate(token: string): Promise<ValidatedToken> {
    try {
      const { payload } = await jwtVerify(token, this.keys, {
        algorithms: this.opts.allowedAlgs, // alg 핀 — jose는 `alg:none`을 항상 거부
        issuer: this.opts.issuer, // iss 정확일치
        audience: this.opts.audience, // aud 포함검사(배열이면 포함 여부)
        clockTolerance: this.opts.clockSkewSeconds, // exp/nbf ± skew
        requiredClaims: ['exp'], // exp 존재 강제 — jose는 exp가 있을 때만 만료검사하므로 부재 시 무만료 토큰이 통과한다(Go/Rust/Python 동형 심층방어)
      })
      const aud = payload.aud
      return {
        subject: typeof payload.sub === 'string' ? payload.sub : '',
        audience: Array.isArray(aud) ? aud.map(String) : typeof aud === 'string' ? [aud] : [],
        issuer: typeof payload.iss === 'string' ? payload.iss : '',
        expiresAt: typeof payload.exp === 'number' ? payload.exp : undefined,
        issuedAt: typeof payload.iat === 'number' ? payload.iat : undefined,
        claims: payload as Record<string, unknown>,
      }
    } catch (e) {
      throw new KeycloakTokenValidationError(`JWT 검증 실패: ${(e as Error).message}`, { cause: e })
    }
  }
}
