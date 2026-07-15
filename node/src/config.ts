import { KeycloakConfigError } from './errors.js'
import { mask } from './masking.js'

const INSPECT = Symbol.for('nodejs.util.inspect.custom')

/** 불변 설정. `defineConfig`로만 생성한다. */
export interface KeycloakConfig {
  readonly serverUrl: string
  readonly realm: string
  readonly clientId: string
  readonly clientSecret?: string
  readonly scopes: readonly string[]
  /**
   * ⚠️ Node의 fetch/undici 스택(openid-client·admin-client)은 요청당 단일 총 타임아웃
   * ({@link readTimeoutMs})만 표현할 수 있어, 별도의 "연결(connect) 타임아웃"을 강제하지 못한다
   * (커스텀 undici dispatcher 주입이 필요하나 하위 라이브러리가 이를 노출하지 않음). 이 필드는
   * 언어 간 config 대칭을 위해 유지되나 fetch 경로에는 별도로 배선되지 않는다(문서화된 한계 —
   * sync/blocking-HTTP 언어인 Java·Go·PHP 등과 달리). 실효 타임아웃은 readTimeoutMs다.
   */
  readonly connectTimeoutMs: number
  readonly readTimeoutMs: number
  readonly clockSkewSeconds: number
  /** JWT 서명 검증 시 허용할 알고리즘 핀(기본 ['RS256']). ES256/PS256 realm을 위해 설정 가능. */
  readonly signatureAlgorithms: readonly string[]
  /**
   * 미해결 kid(키 회전)로 인한 JWKS 재조회의 최소 간격(초, 기본 30) — DoS 증폭 상한. 위조 kid를
   * 연속 주입해도 이 간격보다 자주 IdP를 때리지 못한다(jose `cooldownDuration`에 배선). 0이면 매
   * 미해결 kid마다 재조회를 허용한다(비권장).
   */
  readonly jwksMinRefetchSeconds: number
}

/** `defineConfig` 입력(선택값은 기본값으로 채워진다). */
export interface KeycloakConfigInput {
  serverUrl: string
  realm: string
  clientId: string
  clientSecret?: string
  scopes?: string[]
  connectTimeoutMs?: number
  readTimeoutMs?: number
  clockSkewSeconds?: number
  signatureAlgorithms?: string[]
  jwksMinRefetchSeconds?: number
}

/**
 * 입력을 검증하고 기본값을 채워 불변 `KeycloakConfig`를 만든다. 필수값 누락 시 `KeycloakConfigError`.
 *
 * 보안: 반환 객체는 로깅/직렬화(`console.log`·`util.inspect`·`JSON.stringify`)에서 `clientSecret`을
 * 마스킹한다(Python `KeycloakConfig.__repr__`와 동형) — 실수로 시크릿을 로그에 흘리지 않게 한다.
 * 속성 접근(`config.clientSecret`)과 스프레드는 정상 동작하며, 마스킹 훅은 비열거(non-enumerable)다.
 */
export function defineConfig(input: KeycloakConfigInput): KeycloakConfig {
  for (const key of ['serverUrl', 'realm', 'clientId'] as const) {
    if (!input[key] || input[key].trim().length === 0) {
      throw new KeycloakConfigError(`Missing required config: ${key}`)
    }
  }
  if (input.signatureAlgorithms && input.signatureAlgorithms.length === 0) {
    // 빈 집합은 알고리즘 핀을 무력화한다(핀 없이는 alg 혼동 공격에 노출).
    throw new KeycloakConfigError('signatureAlgorithms must be non-empty')
  }
  if (input.jwksMinRefetchSeconds !== undefined && input.jwksMinRefetchSeconds < 0) {
    throw new KeycloakConfigError('jwksMinRefetchSeconds must be >= 0')
  }
  const config: KeycloakConfig = {
    serverUrl: input.serverUrl.replace(/\/+$/, ''),
    realm: input.realm,
    clientId: input.clientId,
    clientSecret: input.clientSecret,
    scopes: input.scopes ?? [],
    connectTimeoutMs: input.connectTimeoutMs ?? 10_000,
    readTimeoutMs: input.readTimeoutMs ?? 30_000,
    clockSkewSeconds: input.clockSkewSeconds ?? 30,
    signatureAlgorithms: input.signatureAlgorithms ?? ['RS256'],
    jwksMinRefetchSeconds: input.jwksMinRefetchSeconds ?? 30,
  }
  const masked = (): Record<string, unknown> => ({
    ...config,
    clientSecret: config.clientSecret === undefined ? undefined : mask(config.clientSecret),
  })
  Object.defineProperties(config, {
    toJSON: { value: masked, enumerable: false },
    [INSPECT]: { value: masked, enumerable: false },
  })
  return config
}
