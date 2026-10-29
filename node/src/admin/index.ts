import KcAdminClient from '@keycloak/keycloak-admin-client'
import type { KeycloakConfig } from '../config.js'
import { KeycloakConfigError } from '../errors.js'
import { sendableBearer, type TokenProvider } from '../token-provider.js'
import { call } from './call.js'
import { ClientsResource } from './clients.js'
import { GroupsResource } from './groups.js'
import type { AdminHttp } from './http.js'
import { RealmsResource } from './realms.js'
import { RolesResource } from './roles.js'
import { UsersResource } from './users.js'

export { UsersResource } from './users.js'
export { ClientsResource } from './clients.js'
export { RealmsResource } from './realms.js'
export { RolesResource } from './roles.js'
export { GroupsResource } from './groups.js'

/**
 * Entry point of the Admin API facade. Exposes the resource accessors
 * ({@link users}/{@link clients}/{@link realms}/{@link roles}/{@link groups}) and the escape hatch {@link raw}
 * (the official `@keycloak/keycloak-admin-client`).
 *
 * ⚠️ The facade's five resources do not call admin-client methods — they themselves send the same requests
 * admin-client sends (`http.ts`). admin-client 26.8 reads the body of a non-2xx response whole (`fetchWithError`)
 * and reads a write's 2xx body to its end too (`parseResponse`), whereas the facade drains an error body only up to
 * 1 MiB and does not read a write's 2xx body. That they are the same requests is checked on the wire by
 * `test/unit/admin-response-body.test.ts` against the delegating code from before the fix — run it on every
 * admin-client bump.
 *
 * Coupling rule: admin does not depend on the auth module — it receives tokens through core's
 * {@link TokenProvider} interface (the only glue). The facade injects a caching client-credentials provider, and
 * that provider re-authenticates with client_credentials on expiry (it does not delegate to admin-client's
 * built-in TokenManager — on expiry that path only tries refresh_token, so it fails permanently under
 * client-credentials).
 *
 * `admin.test.ts` verifies the constructor arguments and the token wiring with admin-client mocked; the
 * integration tests verify the real calls.
 */
export class AdminClient {
  readonly users: UsersResource
  readonly clients: ClientsResource
  readonly realms: RealmsResource
  readonly roles: RolesResource
  readonly groups: GroupsResource
  readonly #kc: KcAdminClient

  private constructor(kc: KcAdminClient, http: AdminHttp, realm: string) {
    this.#kc = kc
    this.users = new UsersResource(http, realm)
    this.clients = new ClientsResource(http, realm)
    this.realms = new RealmsResource(http)
    this.roles = new RolesResource(http, realm)
    this.groups = new GroupsResource(http, realm)
  }

  /**
   * Creates the admin-client, registers `tokenProvider` and then obtains the initial token. It injects the read
   * timeout of `config` so admin calls never wait forever (not injected = thread-exhaustion DoS). Without a
   * clientSecret it fails with {@link KeycloakConfigError} before any network access.
   *
   * It registers the SDK's caching {@link TokenProvider} instead of admin-client's built-in TokenManager. When the
   * access token expires, the built-in TokenManager only tries the refresh_token grant (`#refreshAccessToken`), and
   * the client_credentials grant issues no refresh_token, so **after the first token expires, every admin call
   * fails permanently with "Cannot refresh token"** (fatal for a long-lived server). The SDK provider detects
   * expiry and re-authenticates with client_credentials. And because it never calls `kc.auth()`, it also avoids at
   * the root the path where admin-client 26.7.x crashes parsing the absent refresh_token of a client_credentials
   * response with `decodeToken(undefined)`.
   */
  static async create(config: KeycloakConfig, tokenProvider: TokenProvider): Promise<AdminClient> {
    if (config.clientSecret === undefined) {
      throw new KeycloakConfigError('clientSecret is required for admin client-credentials')
    }
    const kc = new KcAdminClient({
      baseUrl: config.serverUrl,
      realmName: config.realm,
      // ms 단위 — admin-client가 요청마다 AbortSignal.timeout(ms)로 적용한다.
      timeout: config.readTimeoutMs,
      // SSRF 하드닝: admin REST도 3xx를 따라가지 않는다. 이 경로가 가장 위험하다 — 실측에서
      // admin 요청이 302를 따라가며 **Authorization 헤더를 리다이렉트 대상까지 들고 갔고**
      // 호출은 성공으로 resolve됐다. requestOptions는 admin-client가 모든 리소스 fetch에
      // 전달한다. Java·Kotlin·Go·.NET·PHP·Rust·Ruby와 동형.
      requestOptions: { redirect: 'manual' },
    })
    // `raw()` 의 요청마다 admin-client는 이 provider에서 액세스 토큰을 얻는다(만료 시 provider가 재인증).
    // ⚠️ admin-client 가 그 토큰으로 헤더를 짓기 **직전**의 SDK 쪽 마지막 자리라 여기서 보낼 값으로 바꾼다
    // (`sendableBearer` — 앞뒤를 떼고, `b64token` 이 아니면 거부). 거르지 않으면 Latin-1 · 안쪽 공백은 그대로
    // 나가고, CR·LF·NUL 은 raw `TypeError` 가 토큰을 통째로 인용했고(2026-10-05), DEL·VT 는 raw
    // `TypeError: fetch failed` 였다(2026-10-29). 파사드의 요청은 `http.ts` 가 같은 함수를 지난다.
    kc.registerTokenProvider({
      getAccessToken: async () => sendableBearer(await tokenProvider.getAccessToken()),
    })
    // 초기 자격증명 검증(fail-fast) + provider 캐시 워밍. call()로 감싸 401·전송 실패가 raw fetch
    // 오류로 누출되지 않고 SDK 예외(KeycloakAdminError/KeycloakTransportError)로 변환되도록(§4 경계).
    // 보낼 수 없는 Bearer 도 여기서 거부한다 — 첫 요청까지 미루지 않는다.
    await call(async () => sendableBearer(await tokenProvider.getAccessToken()))
    // 파사드의 목적지 — admin-client 에 준 것과 같은 값. `raw().setConfig()` 는 이것을 바꾸지 않는다.
    const http: AdminHttp = {
      serverUrl: config.serverUrl,
      timeoutMs: config.readTimeoutMs,
      tokenProvider,
    }
    return new AdminClient(kc, http, config.realm)
  }

  /**
   * The escape hatch for endpoints the facade does not wrap — the official admin-client itself.
   *
   * ⚠️ This path is admin-client as is, so it reads the body of a non-2xx response to its end, with no cap, into
   * `NetworkError.responseData`, and reads a write's 2xx body to its end too (unlike the facade — registry
   * `admin-response-body-unbounded`). That spot is pinned in `test/unit/admin-response-body.test.ts` by the
   * `raw()` test marked ⚠️ there. An address or request options changed with `setConfig()` apply only
   * to this path.
   */
  raw(): KcAdminClient {
    return this.#kc
  }

  /**
   * Resource-cleanup hook. The facade and admin-client are built on the global `fetch` and hold no connections, so
   * this is currently a no-op, but it is kept for symmetry with the {@link KeycloakClient} close protocol.
   */
  async close(): Promise<void> {
    return undefined
  }
}
