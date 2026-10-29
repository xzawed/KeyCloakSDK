import { AdminClient } from './admin/index.js'
import { AuthClient } from './auth.js'
import { defineConfig, type KeycloakConfig, type KeycloakConfigInput } from './config.js'
import { KeycloakConfigError } from './errors.js'
import { ClientCredentialsTokenProvider } from './token-provider.js'

/**
 * Unified SDK entry point (facade). {@link create} builds authentication ({@link AuthClient}) eagerly. Admin
 * ({@link AdminClient}) is created lazily, at the first call to {@link admin}, so that a public/PKCE client
 * without a clientSecret can still use the SDK through {@link auth} alone.
 *
 * With `await using client = KeycloakClient.create(...)`, {@link close} is called when the scope is exited
 * ({@link AsyncDisposable}). {@link close} releases admin's resources only if admin was actually created, and
 * always releases the auth session (symmetry, no leaks).
 */
export class KeycloakClient implements AsyncDisposable {
  #admin?: AdminClient
  #adminInflight?: Promise<AdminClient>
  readonly auth: AuthClient
  readonly #config: KeycloakConfig

  private constructor(auth: AuthClient, config: KeycloakConfig) {
    this.auth = auth
    this.#config = config
  }

  /** Validates `input` (`defineConfig`) and builds the `AuthClient` eagerly. Admin is created lazily. */
  static create(input: KeycloakConfigInput): KeycloakClient {
    const config = defineConfig(input)
    return new KeycloakClient(new AuthClient(config), config)
  }

  /**
   * Creates and returns the Admin client on the first call and reuses the cached one after that. With a
   * configuration that has no clientSecret it fails with {@link KeycloakConfigError} before any network access — a
   * public/PKCE client that only uses {@link auth} never takes this path. A creation failure is not cached (it can
   * be retried).
   */
  async admin(): Promise<AdminClient> {
    if (this.#config.clientSecret === undefined) {
      throw new KeycloakConfigError('admin API requires clientSecret (client-credentials grant)')
    }
    if (this.#admin !== undefined) {
      return this.#admin
    }
    // single-flight: 동시 최초 호출이 admin 생성(client-credentials 인증)을 중복하지 않도록
    // 진행중 Promise를 공유하고, 실패는 캐시하지 않는다(재시도 가능).
    if (this.#adminInflight !== undefined) {
      return this.#adminInflight
    }
    // admin 전용 캐싱 TokenProvider를 주입한다(§4 접착제). 토큰 소스는 facade의 AuthClient지만
    // admin은 TokenProvider 인터페이스만 알 뿐 auth 모듈에 의존하지 않는다. provider가 만료 시
    // client_credentials로 재인증하므로 장수명 서버에서 admin이 토큰 만료로 영구 실패하지 않는다.
    // ⚠️ **설정된 clockSkewSeconds 를 반드시 넘긴다.** 생략하면 provider 의 생성자 기본값(30)이
    // 쓰여, 소비자가 `clockSkewSeconds: 60` 을 줘도 admin 토큰 캐시만 30 으로 돈다. 자매 다섯이
    // 전부 config 값을 넘긴다(rust `config.clock_skew` · php `$this->config->clockSkew` ·
    // go `cfg.ClockSkew` · dotnet `_config.ClockSkewSeconds` · ruby `@config.clock_skew`) —
    // node 만 빠져 있었다(실측 2026-09-09).
    this.#adminInflight = AdminClient.create(
      this.#config,
      new ClientCredentialsTokenProvider(this.auth, this.#config.clockSkewSeconds),
    )
    try {
      this.#admin = await this.#adminInflight
      return this.#admin
    } finally {
      this.#adminInflight = undefined
    }
  }

  /** Releases the underlying resources that were created — auth always, admin only if it was created. */
  async close(): Promise<void> {
    if (this.#admin !== undefined) {
      await this.#admin.close()
    }
    await this.auth.close()
  }

  async [Symbol.asyncDispose](): Promise<void> {
    await this.close()
  }
}
