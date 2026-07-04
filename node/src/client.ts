import { AdminClient } from './admin/index.js'
import { AuthClient } from './auth.js'
import { defineConfig, type KeycloakConfig, type KeycloakConfigInput } from './config.js'
import { KeycloakConfigError } from './errors.js'

/**
 * SDK 통합 진입점(파사드). {@link create}가 인증({@link AuthClient})을 즉시 조립한다. 관리
 * ({@link AdminClient})는 clientSecret이 없는 공개/PKCE 클라이언트도 {@link auth}만으로 SDK를
 * 사용할 수 있도록 {@link admin} 최초 호출 시점에 지연 생성된다.
 *
 * `await using client = KeycloakClient.create(...)`로 사용하면 스코프 이탈 시 {@link close}가
 * 호출된다({@link AsyncDisposable}). {@link close}는 admin이 실제로 생성된 경우에만 그 자원을
 * 정리하고, auth 세션은 항상 정리한다(대칭·누수 방지).
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

  /** `input`을 검증(`defineConfig`)하고 `AuthClient`를 즉시 조립한다. admin은 지연 생성. */
  static create(input: KeycloakConfigInput): KeycloakClient {
    const config = defineConfig(input)
    return new KeycloakClient(new AuthClient(config), config)
  }

  /**
   * Admin 클라이언트를 최초 호출 시 생성해 반환하고 이후 캐시를 재사용한다. clientSecret이 없는
   * 설정이면 네트워크 접근 전에 {@link KeycloakConfigError}로 실패한다 — {@link auth}만 쓰는
   * 공개/PKCE 클라이언트는 이 경로를 타지 않는다. 생성 실패는 캐시하지 않는다(재시도 가능).
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
    this.#adminInflight = AdminClient.create(this.#config)
    try {
      this.#admin = await this.#adminInflight
      return this.#admin
    } finally {
      this.#adminInflight = undefined
    }
  }

  /** 생성된 하위 자원을 정리한다 — auth는 항상, admin은 생성된 경우에만. */
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
