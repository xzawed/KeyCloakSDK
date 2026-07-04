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
  readonly connectTimeoutMs: number
  readonly readTimeoutMs: number
  readonly clockSkewSeconds: number
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
  const config: KeycloakConfig = {
    serverUrl: input.serverUrl.replace(/\/+$/, ''),
    realm: input.realm,
    clientId: input.clientId,
    clientSecret: input.clientSecret,
    scopes: input.scopes ?? [],
    connectTimeoutMs: input.connectTimeoutMs ?? 10_000,
    readTimeoutMs: input.readTimeoutMs ?? 30_000,
    clockSkewSeconds: input.clockSkewSeconds ?? 30,
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
