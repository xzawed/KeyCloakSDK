import { KeycloakConfigError } from './errors.js'

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

/** 입력을 검증하고 기본값을 채워 불변 `KeycloakConfig`를 만든다. 필수값 누락 시 `KeycloakConfigError`. */
export function defineConfig(input: KeycloakConfigInput): KeycloakConfig {
  for (const key of ['serverUrl', 'realm', 'clientId'] as const) {
    if (!input[key] || input[key].trim().length === 0) {
      throw new KeycloakConfigError(`Missing required config: ${key}`)
    }
  }
  return {
    serverUrl: input.serverUrl.replace(/\/+$/, ''),
    realm: input.realm,
    clientId: input.clientId,
    clientSecret: input.clientSecret,
    scopes: input.scopes ?? [],
    connectTimeoutMs: input.connectTimeoutMs ?? 10_000,
    readTimeoutMs: input.readTimeoutMs ?? 30_000,
    clockSkewSeconds: input.clockSkewSeconds ?? 30,
  }
}
