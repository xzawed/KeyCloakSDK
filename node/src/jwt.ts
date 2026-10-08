import {
  errors as joseErrors,
  jwtVerify,
  createRemoteJWKSet,
  customFetch,
  type FetchImplementation,
  type JWTVerifyGetKey,
  type RemoteJWKSet,
} from 'jose'
import { KeycloakTokenValidationError, KeycloakTransportError } from './errors.js'
import type { ValidatedToken } from './tokens.js'

/**
 * JWKS 응답 본문의 바이트 상한. 51200 은 Nimbus `JWKSourceBuilder.DEFAULT_HTTP_SIZE_LIMIT` 이고
 * go(`jwksMaxBytes`)·rust·php·ruby 가 같은 수를 쓴다.
 *
 * ⚠️ **jose 에는 상한이 없다.** 실측(2026-09-11 · jose 6.2.12 ·
 * `node_modules/jose/dist/webapi/jwks/remote.js:10-26`): `fetchJwks` 는 `GET` → status 200
 * 확인 → `response.json()` 이 전부다. `Content-Length` 검사도, 최대 바이트 옵션도, 읽기를
 * 끊는 스트리밍도 없다 — 유일한 중단은 시간(`AbortSignal.timeout`, 기본 5초)이다. 즉 손상된
 * IdP 하나가 검증 경로를 메모리로 죽일 수 있었다.
 */
export const JWKS_MAX_BYTES = 51_200

/**
 * 상한을 건 JWKS fetch. `createRemoteJWKSet` 의 `[customFetch]` 이음매로 주입한다 —
 * **JWKS 전용**이라 토큰·introspect·logout 경로에는 영향이 없다.
 *
 * ⚠️ `Content-Length` 로만 판정하면 그 헤더가 없거나(chunked) 거짓인 응답을 놓친다. 청크를
 * 받으며 누적치가 상한을 넘는 순간 **스트림을 취소**한다 — 다 읽고 나서 길이를 재면 이미
 * 메모리를 내준 뒤다.
 */
const fetchJwksBounded: FetchImplementation = async (url, options) => {
  const response = await fetch(url, options)
  const stream = response.body
  if (stream === null) return response
  const reader = stream.getReader()
  const chunks: Uint8Array[] = []
  let total = 0
  for (;;) {
    const { done, value } = await reader.read()
    if (done) break
    total += value.byteLength
    if (total > JWKS_MAX_BYTES) {
      await reader.cancel()
      throw new KeycloakTransportError(`JWKS response exceeds ${JWKS_MAX_BYTES} bytes`)
    }
    chunks.push(value)
  }
  const body = new Uint8Array(total)
  let offset = 0
  for (const chunk of chunks) {
    body.set(chunk, offset)
    offset += chunk.byteLength
  }
  // ⚠️ 200 `{"keys":[]}` 를 넘기면 jose 가 좋은 캐시를 빈 셋으로 덮는다. `reload` 는
  // `fetchJwks` 가 성공한 뒤 `.then` 안에서만 캐시를 대입하므로, 여기서 던지면 옛 키가
  // 남는다. JSON 파싱 실패는 던지지 않는다 — 그 판정은 jose 몫이다.
  if (response.status === 200) {
    let parsed: unknown
    try {
      parsed = JSON.parse(new TextDecoder().decode(body))
    } catch {
      parsed = undefined
    }
    const keys = (parsed as { keys?: unknown } | null)?.keys
    if (Array.isArray(keys) && keys.length === 0) {
      throw new KeycloakTransportError('JWKS response contains no keys')
    }
  }
  // 상태·헤더를 보존해 되돌려 준다 — 비-200 판정은 jose 가 그대로 수행한다.
  return new Response(body, {
    status: response.status,
    statusText: response.statusText,
    headers: response.headers,
  })
}

/**
 * 실패한 JWKS fetch 의 백오프 — `jwksMinRefetchSeconds`(30초)와 **다른 축**이다.
 *
 * jose 의 `cooldownDuration` 은 *캐시가 찬 뒤* 미해결 kid 재조회만 상한한다. 캐시가 비어 있으면
 * `getKey` 가 매번 `reload()` 를 부르고, `reload()` 는 실패 시 타임스탬프를 남기지 않으므로
 * 쿨다운에 **닿지도 못한다** — 측정상 20회 검증이 IdP 요청 20건을 그대로 냈다
 * (2026-09-04 · 7개 언어 동일. jose v6.2.9 `RemoteJWKSetImpl.getKey`/`reload` 실측).
 * 캐시가 `cacheMaxAge` 를 넘겨 낡았을 때도 같다(2026-10-05 node: 검증 10 → IdP 요청 10).
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
 * 원격 JWKS 를 만들고 웜 캐시의 **강제 재조회**(미해결 kid) 창 — `jwksMinRefetchSeconds`(30초) — 을 건다.
 * 창은 fetch 이음매에서 **조회를 결정할 때** 찍는다.
 *
 * ⚠️ jose 의 `cooldownDuration` 은 **성공한** 조회에만 찍힌다(jose 문서 「after a successful fetch」 ·
 * `remote.js` 의 `.then` 안 `jwksTimestamp = updatedAt`). 그래서 캐시가 찬 채 IdP 가 503 이면 창이 계속 열려
 * 위조 kid 토큰마다 IdP 로 나갔다 — 실측(2026-10-05): 위조 kid 5 → /certs 5, 60 초 동안 초당 하나 → 60.
 * 자기 손으로 창을 거는 다섯(python·go·rust·php·ruby)처럼 **시도할 때** 찍으면 장애 중에도 창마다 한 번이다.
 * 실패를 아래 백오프에 세는 안은 실측으로 기각했다 — 진입부 게이트가 캐시된 kid 까지 막아 홍수 60 초 동안
 * 정상 토큰 6/6 이 거부됐다(규칙 (4) 가 막으려는 바로 그것).
 *
 * ⚠️ 그래서 jose 의 쿨다운은 **0** 이고 창은 여기 하나가 소유한다. 둘을 겹치면 정상 경로에서 이쪽이 jose 의
 * 것을 가려(시도 시각 ≤ 성공 시각) 한쪽을 지워도 동작이 안 변하고 변이검증이 조용해진다 — 아래 백오프 주석과
 * 같은 이유다.
 *
 * 「강제 재조회」 판정: 캐시가 찼고 신선하면(`jwks() !== undefined && fresh`) jose 가 fetch 를 부르는 길은 미해결
 * kid 뿐이다. 콜드 적재와 만료(`cacheMaxAge`) 갱신은 이 창에 걸지 않는다 — 걸면 그 갱신 하나가 실패하거나 직전에
 * 시도가 있었을 때 정상 토큰까지 30 초 막힌다(규칙 (1)). 그 둘의 실패는 아래 fetch 실패 백오프(0.2 → 5 초)가
 * 상한한다. 다만 그 둘도 **찍기는** 한다 — 창은 마지막 시도로부터
 * 세므로, 정상일 때는 콜드 적재 직후의 위조 kid 가 지금처럼 IdP 로 안 나간다(창마다 정확히 한 번).
 *
 * 창 안에서는 IdP 에 가지 않고 jose 가 쿨다운 안에서 던지는 것과 같은 `JWKSNoMatchingKey` 를 던진다 — 미해결
 * kid 거부이지 fetch 실패가 아니므로 아래 fetch 실패 백오프는 세지 않는다(규칙 (4)).
 */
function remoteJwksWithRefetchWindow(
  jwksUri: string,
  minRefetchSeconds: number,
  seams: BackoffSeams,
): RemoteJWKSet {
  const now = seams.now ?? (() => Date.now())
  const windowMs = minRefetchSeconds * 1000
  let lastAttempt = Number.NEGATIVE_INFINITY
  const remote = createRemoteJWKSet(new URL(jwksUri), {
    cooldownDuration: 0,
    cacheMaxAge: 600_000,
    [customFetch]: async (url, options) => {
      const forced = remote.jwks() !== undefined && remote.fresh
      if (forced && now() - lastAttempt < windowMs) {
        throw new joseErrors.JWKSNoMatchingKey()
      }
      lastAttempt = now()
      return fetchJwksBounded(url, options)
    },
  })
  return remote
}

/**
 * 키 소스를 감싸 **신선한 캐시 없이 fetch 가 실패했을 때만** 실패 백오프를 건다. 신선한 캐시가 없으면(콜드, 또는
 * `cacheMaxAge` 가 지난 낡은 캐시) jose 가 `getKey` 첫머리에서 적재한다(`remote.js:66`). 낡은 캐시도 콜드와
 * 같다 — 갱신이 실패하면 jose 는 캐시된 kid 까지 거부하고 시각을 남기지 않아, 세지 않으면 검증마다 IdP 로 나갔다
 * (실측 2026-10-05: 601 초 · 503 · 검증 10 → /certs 10).
 *
 * ⚠️ 웜 캐시의 미해결 kid 경로는 강제 재조회 창(`remoteJwksWithRefetchWindow`)이 상한한다(실측 `== 1`, 장애 중에도),
 * 그리고 그 경로의 거부는 **fetch 실패가 아니다** — 그것을 실패로 세면 위조 kid 홍수가 백오프를 올려 정상 토큰까지
 * 막는다(규칙 (4)).
 */
// ⚠️ **export 하지 않는다** — 시그니처에 jose 의 `RemoteJWKSet`/`JWTVerifyGetKey` 가 들어 있어
// export 하면 방출 `.d.ts` 가 그 타입을 다시 import 하고 §4(b) 은닉이 깨진다(가드 실측:
// `check-node-public-surface.mjs` 누출 1건). 배선은 `forJwksUri` 를 통해서만 닿는다.
function withFetchFailureBackoff(remote: RemoteJWKSet, seams: BackoffSeams = {}): JWTVerifyGetKey {
  const now = seams.now ?? (() => Date.now())
  // jitter 는 thundering herd 를 흩는다 — 비밀이 아니다. ⚠️ 그래도 **PRNG API 를 쓰지 않고**
  // 나노초 시계에서 뽑는다: 보안 민감 코드에서 약한 PRNG 호출은 정적분석이 정당하게 막는다
  // (실측: sonar S2245 · gosec G404). 일곱 언어가 같은 관용을 쓴다.
  const jitter =
    seams.jitter ?? (() => 0.5 + Number(process.hrtime.bigint() % 1_000_000n) / 2_000_000)
  let failures = 0
  let lastFailure: number | null = null
  // 마지막으로 센 실패. jose 는 동시 적재를 한 fetch 로 합치고 그 거부 사유(**같은 객체**)를 대기자 모두에게 던진다.
  let lastCounted: unknown

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
      // ⚠️ 진입부 게이트를 `!remote.fresh` 로 **좁히지 말 것**. 결과는 같아 보이지만(좁혀도 22/22) 신선한 캐시의 호출이
      // 게이트를 안 타서, 아래를 부숴 위조 kid 를 세도 규칙 (4) 대조군이 안 운다 — 실측: 그 변이에 jwt-jwks 실패 8 → 2.
      // 두 자리가 서로를 가리는 것이고(콜드 캐시 때도 겪었다), 여기가 유일한 검사여야 대조군이 무언가를 겨눈다.
      if (remote.fresh) {
        // 신선한 캐시로 끝났다 = 마지막 적재는 성공했다. 여기서 던진 것은 미해결 kid 이거나 신선한 캐시의 강제 재조회
        // 실패라 세지 않고(규칙 (4)), 성공이 카운터를 되돌린다(규칙 (3) — 참조 구현 ruby 도 kid 와 무관하게 fetch
        // 성공에서 되돌린다). 안 되돌리면 회복 갱신을 위조 kid 가 일으켰을 때 다음 장애의 첫 창이 길어지고(실측
        // 0.2 → 0.4 초), jitter 가 검사마다 다시 뽑혀 신선한 캐시의 k1 까지 남은 창에 막혔다.
        failures = 0
        lastFailure = null
      } else if (!(e instanceof joseErrors.JWKSNoMatchingKey) && e !== lastCounted) {
        // ⚠️ **신선한 캐시 없이(콜드 · `cacheMaxAge` 뒤) fetch 가 실패했다 — 그것만 센다.**
        // - `JWKSNoMatchingKey` 는 kid 거부이거나 30 초 창이 IdP 없이 거부한 것이지 fetch 실패가 아니다(규칙 (4)).
        //   「신선한 캐시가 없다」만 보면 창의 거부가, 그 결정과 이 catch 사이에 캐시가 600 초를 넘긴 것만으로
        //   세어진다 — 실측: 정상 IdP 에서 k1 이 'backing off' 로 거부, /certs 그대로.
        // - 신선할 때 정한 강제 재조회라도 응답을 기다리는 사이 캐시가 낡고 실패했으면 센다 — 안 세면 다음 검증이
        //   또 나간다(창 전에 두 건).
        // - 같은 실패는 한 번 — 대기자마다 세면 503 한 번이 곧바로 상한 창이 된다(실측: 동시 10 → 'retry in 4.00s',
        //   정상 IdP 의 k1 거부). 참조 구현 ruby 는 mutex 로 fetch 마다 한 번 센다.
        lastCounted = e
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
  /**
   * 미해결 kid로 인한 JWKS 재조회의 최소 간격(초, 기본 30). 조회를 **시도할 때** 찍으므로 IdP 장애 중에도 창마다
   * 한 번이다(jose 의 `cooldownDuration` 은 성공에만 찍혀 쓰지 않는다 — 0 으로 둔다).
   */
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
   * 원격 JWKS URI로 검증기를 만든다. `createRemoteJWKSet`은 kid 미해결 시에만 재조회하고, 그 재조회를
   * `jwksMinRefetchSeconds` 창으로 rate-limit 한다 → 서명 위조로 인한 미인증 DoS 증폭을 차단한다.
   *
   * ⚠️ 그 창은 **캐시가 찬 뒤에만** 걸린다 — 콜드·낡은(`cacheMaxAge` 뒤) 캐시 + IdP 장애는 실패 백오프가 막는다
   * (측정 20 → 1 · 10 → 1).
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
    const remote = remoteJwksWithRefetchWindow(jwksUri, opts.jwksMinRefetchSeconds, seams)
    return new JwtValidator(withFetchFailureBackoff(remote, seams), opts)
  }

  /**
   * 기대 audience 만 바꾼 검증기 — 키 소스(`keys`)는 **같은 객체**를 넘긴다. 코드 교환이 id_token 을
   * client id 로 검증하는 데 쓴다(OIDC Core §2·§3.1.3.7 — id_token `aud` 는 client_id 를 담는다).
   * `expectedAudience` 재정의는 액세스 토큰의 몫이라 id_token 에 걸면 안 된다.
   *
   * ⚠️ 새 키 소스를 만들지 말 것 — JWKS 캐시·재조회 쿨다운·fetch 실패 백오프가 전부 `keys` 클로저 안에
   * 있어서, 둘로 나뉘면 IdP 요청과 DoS 상한이 두 배가 된다. I/O 는 하지 않는다.
   *
   * ⚠️ `@internal` — `forKeySource` 와 같은 처리다(방출 `.d.ts` 에 오르지 않는다).
   *
   * @internal
   */
  withAudience(audience: string): JwtValidator {
    return new JwtValidator(this.keys, { ...this.opts, audience })
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
