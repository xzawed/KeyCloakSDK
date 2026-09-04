import { jwtVerify, createRemoteJWKSet, type JWTVerifyGetKey, type RemoteJWKSet } from 'jose'
import { KeycloakTokenValidationError, KeycloakTransportError } from './errors.js'
import type { ValidatedToken } from './tokens.js'

/**
 * 실패한 JWKS fetch 의 백오프 — `jwksMinRefetchSeconds`(30초)와 **다른 축**이다.
 *
 * jose 의 `cooldownDuration` 은 *캐시가 찬 뒤* 미해결 kid 재조회만 상한한다. 캐시가 비어 있으면
 * `getKey` 가 매번 `reload()` 를 부르고, `reload()` 는 실패 시 타임스탬프를 남기지 않으므로
 * 쿨다운에 **닿지도 못한다** — 측정상 20회 검증이 IdP 요청 20건을 그대로 냈다
 * (2026-09-04 · 7개 언어 동일. jose v6.2.9 `RemoteJWKSetImpl.getKey`/`reload` 실측).
 *
 * ⚠️ 여기에 30초를 재사용하면 안 된다 — 일시적 503 한 번이 「30초간 어떤 토큰도 검증 불가」가
 * 된다. 짧게 시작해 지수적으로 늘리고 상한을 둔다. **sleep 하지 않는다**(negative cache).
 */
const FAILURE_BACKOFF_BASE_MS = 200
const FAILURE_BACKOFF_CAP_MS = 5_000

/**
 * 시계·jitter 이음매 — 테스트가 창을 결정적으로 넘길 수 있어야 한다(sleep 금지).
 *
 * ⚠️ **export 하지 않는다.** 이것이 공개 시그니처에 오르면 방출 `.d.ts` 가 바뀌고
 * `api-extractor` 게이트가 「직전 릴리스의 공개 API 줄이 바뀌었다」로 막는다(실측). 이음매는
 * `@internal` 팩토리로만 닿는다 — `forKeySource` 와 같은 자리.
 */
interface BackoffSeams {
  readonly now?: () => number
  readonly jitter?: () => number
}

/**
 * 키 소스를 감싸 **콜드 캐시일 때만** 실패 백오프를 건다.
 *
 * ⚠️ 조건이 「콜드 캐시」인 것이 핵심이다. 웜 캐시의 미해결 kid 경로는 jose 의 쿨다운이 이미
 * 상한한다(실측 `== 1`), 그리고 그 경로의 `JWKSNoMatchingKey` 는 **fetch 실패가 아니다** —
 * 그것을 실패로 세면 위조 kid 홍수가 백오프를 올려 정상 토큰까지 막는다.
 */
// ⚠️ **export 하지 않는다** — 시그니처에 jose 의 `RemoteJWKSet`/`JWTVerifyGetKey` 가 들어 있어
// export 하면 방출 `.d.ts` 가 그 타입을 다시 import 하고 §4(b) 은닉이 깨진다(가드 실측:
// `check-node-public-surface.mjs` 누출 1건). 배선은 `forJwksUri` 를 통해서만 닿는다.
function withColdCacheBackoff(remote: RemoteJWKSet, seams: BackoffSeams = {}): JWTVerifyGetKey {
  const now = seams.now ?? (() => Date.now())
  const jitter = seams.jitter ?? (() => 0.5 + Math.random() / 2)
  let failures = 0
  let lastFailure: number | null = null

  const delayMs = () =>
    Math.min(FAILURE_BACKOFF_BASE_MS * 2 ** (Math.max(failures, 1) - 1), FAILURE_BACKOFF_CAP_MS) *
    jitter()
  const remainingMs = () =>
    lastFailure === null ? 0 : Math.max(0, delayMs() - (now() - lastFailure))

  return async (protectedHeader, token) => {
    const remaining = remainingMs()
    if (remaining > 0) {
      throw new KeycloakTransportError(
        `JWKS fetch backing off after ${failures} consecutive failures ` +
          `(retry in ${(remaining / 1000).toFixed(2)}s)`,
      )
    }
    try {
      const key = await remote(protectedHeader, token)
      failures = 0
      lastFailure = null
      return key
    } catch (e) {
      // ⚠️ **이 조건이 콜드 캐시 한정의 유일한 근거다.** 캐시가 여전히 비어 있으면 fetch 가
      // 실패한 것이다. 캐시가 찼는데 던졌다면 그것은 미해결 kid(`JWKSNoMatchingKey`)이지 전송
      // 실패가 아니므로 세지 않는다 — 세면 위조 kid 홍수가 백오프를 올려 정상 토큰까지 막는다.
      //
      // ⚠️ 진입부에 `if (cold)` 게이트를 **다시 넣지 말 것**. 넣으면 두 검사가 서로를 가려
      // (한쪽만 지워도 동작이 안 변해) 변이검증이 **양쪽 다 통과**한다 — 실측으로 겪었다.
      // 여기가 유일한 검사여야 대조군이 실제로 무언가를 겨눈다.
      if (remote.jwks() === undefined) {
        failures += 1
        lastFailure = now()
      }
      throw e
    }
  }
}

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

  /**
   * 원격 JWKS URI로 검증기를 만든다. `createRemoteJWKSet`은 kid 미해결 시에만 재조회하고
   * cooldownDuration으로 rate-limit → 서명 위조로 인한 미인증 DoS 증폭을 차단한다.
   *
   * ⚠️ 그 쿨다운은 **캐시가 찬 뒤에만** 걸린다 — 콜드 캐시 + IdP 장애는 실패 백오프가 막는다
   * (측정 20 → 1).
   */
  static forJwksUri(jwksUri: string, opts: JwtValidatorOptions): JwtValidator {
    return JwtValidator.forJwksUriWithSeams(jwksUri, opts, {})
  }

  /**
   * `forJwksUri` 에 시계·jitter 이음매를 주입한다 — **테스트 전용**.
   *
   * ⚠️ `@internal` 이라 `stripInternal` 이 방출 `.d.ts` 에서 이 멤버를 지운다. 이음매를
   * `forJwksUri` 의 세 번째 파라미터로 두면 **공개 시그니처가 바뀌어** `api-extractor` 게이트가
   * 막는다(실측: 「공개 API 줄 1개가 바뀌었다」). `forKeySource` 와 같은 처리다.
   *
   * @internal
   */
  static forJwksUriWithSeams(
    jwksUri: string,
    opts: JwtValidatorOptions,
    seams: BackoffSeams,
  ): JwtValidator {
    const remote = createRemoteJWKSet(new URL(jwksUri), {
      cooldownDuration: opts.jwksMinRefetchSeconds * 1000,
      cacheMaxAge: 600_000,
    })
    return new JwtValidator(withColdCacheBackoff(remote, seams), opts)
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
