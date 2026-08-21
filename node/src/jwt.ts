import { jwtVerify, createRemoteJWKSet, type JWTVerifyGetKey } from 'jose'
import { KeycloakTokenValidationError } from './errors.js'
import type { ValidatedToken } from './tokens.js'

export interface JwtValidatorOptions {
  readonly issuer: string
  readonly audience: string
  readonly allowedAlgs: string[]
  readonly clockSkewSeconds: number
  /** 미해결 kid로 인한 JWKS 재조회의 최소 간격(초). jose `cooldownDuration`에 배선(기본 30). */
  readonly jwksMinRefetchSeconds: number
}

/**
 * 자체 강화 JWT 검증기. 라이브러리 기본값을 신뢰하지 않는다:
 * 알고리즘 핀(헤더 alg 불신, `none` 거부) · issuer 정확일치 · audience 포함검사(다중 aud 수용) ·
 * exp/nbf ± 클록 스큐 · JWKS 재조회 DoS-safe(kid 미해결 시에만 재조회 + 쿨다운 rate-limit).
 *
 * 키 소스는 주입형이다(테스트는 로컬 JWKS, 실사용은 `forJwksUri`의 원격 JWKS).
 */
export class JwtValidator {
  /**
   * 생성은 {@link JwtValidator.forJwksUri}로 한다. `private`인 이유는 취향이 아니라 §4다 —
   * 이 생성자가 public이면 jose의 `JWTVerifyGetKey`가 방출 `.d.ts`에 올라 하위 라이브러리 타입이
   * 공개 API로 샌다. `private`면 tsc가 선언에서 파라미터를 지워 그 import가 함께 사라진다
   * (같은 파일의 `forJwksUri`는 계속 호출할 수 있다 — Java `JwtValidator`·Go `newValidator`와 동형).
   */
  private constructor(
    private readonly keys: JWTVerifyGetKey,
    private readonly opts: JwtValidatorOptions,
  ) {}

  /**
   * 주입된 키 소스로 만든다 — **테스트 전용 이음매**(로컬 JWKS로 서명 검증을 태우려면 원격
   * URI가 아닌 키 소스가 필요하다).
   *
   * ⚠️ `@internal`이라 `stripInternal`이 방출 `.d.ts`에서 이 멤버를 지운다. 생성자를 `private`로
   * 되돌린 것과 같은 이유이고(§4 — jose `JWTVerifyGetKey`가 공개 표면에 오르면 안 된다),
   * admin 리소스 5종에 이미 쓴 처리와 동형이다. 소비자에게는 `forJwksUri`만 보인다.
   *
   * @internal
   */
  static forKeySource(keys: JWTVerifyGetKey, opts: JwtValidatorOptions): JwtValidator {
    return new JwtValidator(keys, opts)
  }

  /** 원격 JWKS URI로 검증기를 만든다. `createRemoteJWKSet`은 kid 미해결 시에만 재조회하고 cooldownDuration으로 rate-limit → 서명 위조로 인한 미인증 DoS 증폭을 차단한다. */
  static forJwksUri(jwksUri: string, opts: JwtValidatorOptions): JwtValidator {
    const keys = createRemoteJWKSet(new URL(jwksUri), {
      cooldownDuration: opts.jwksMinRefetchSeconds * 1000,
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
