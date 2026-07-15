import KcAdminClient from '@keycloak/keycloak-admin-client'
import type { KeycloakConfig } from '../config.js'
import { KeycloakConfigError } from '../errors.js'
import type { TokenProvider } from '../token-provider.js'
import { call } from './call.js'
import { ClientsResource } from './clients.js'
import { GroupsResource } from './groups.js'
import { RealmsResource } from './realms.js'
import { RolesResource } from './roles.js'
import { UsersResource } from './users.js'

export { UsersResource } from './users.js'
export { ClientsResource } from './clients.js'
export { RealmsResource } from './realms.js'
export { RolesResource } from './roles.js'
export { GroupsResource } from './groups.js'

/**
 * 관리(Admin) API 파사드 진입점. 공식 `@keycloak/keycloak-admin-client`를 감싸며 수명주기를
 * 소유한다. 리소스 접근자({@link users}/{@link clients}/{@link realms}/{@link roles}/{@link groups})와
 * 탈출구 {@link raw}를 노출한다.
 *
 * 결합 규칙: admin은 auth 모듈에 의존하지 않는다 — core의 {@link TokenProvider} 인터페이스(유일 접착제)로
 * 토큰을 주입받는다. 파사드가 캐싱 client-credentials provider를 주입하고, 그 provider가 만료 시
 * client_credentials로 재인증한다(admin-client 내장 TokenManager에 위임하지 않는다 — 그 경로는 만료 시
 * refresh_token만 시도해 client-credentials에서 영구 실패하기 때문).
 *
 * 네트워크 경계라 커버리지 게이트에서 제외된다(vitest exclude); 위임/타임아웃 주입/예외변환
 * 로직은 `admin.test.ts`가 목킹으로, 실호출은 통합테스트(Task 10)가 검증한다.
 */
export class AdminClient {
  readonly users: UsersResource
  readonly clients: ClientsResource
  readonly realms: RealmsResource
  readonly roles: RolesResource
  readonly groups: GroupsResource
  readonly #kc: KcAdminClient

  private constructor(kc: KcAdminClient, realm: string) {
    this.#kc = kc
    this.users = new UsersResource(kc, realm)
    this.clients = new ClientsResource(kc, realm)
    this.realms = new RealmsResource(kc)
    this.roles = new RolesResource(kc, realm)
    this.groups = new GroupsResource(kc, realm)
  }

  /**
   * admin-client를 생성하고 `tokenProvider`를 등록한 뒤 초기 토큰을 확보한다. `config`의 read
   * 타임아웃을 주입해 admin 호출이 무한 대기하지 않게 한다(미주입=스레드 고갈 DoS). clientSecret이
   * 없으면 네트워크 접근 전에 {@link KeycloakConfigError}로 실패한다.
   *
   * admin-client의 내장 TokenManager 대신 SDK의 캐싱 {@link TokenProvider}를 등록한다. 내장
   * TokenManager는 액세스 토큰이 만료되면 refresh_token 그랜트만 시도하는데(`#refreshAccessToken`),
   * client_credentials 그랜트는 refresh_token을 발급하지 않으므로 **최초 토큰 만료 후 모든 admin
   * 호출이 "Cannot refresh token"으로 영구 실패**한다(장수명 서버에 치명적). SDK provider는 만료를
   * 감지해 client_credentials로 재인증한다. 또한 `kc.auth()`를 호출하지 않으므로 admin-client
   * 26.7.x가 client_credentials 응답의 부재한 refresh_token을 `decodeToken(undefined)`로 파싱하다
   * 크래시하는 경로도 원천 회피한다.
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
    })
    // 매 요청 admin-client는 이 provider에서 액세스 토큰을 얻는다(만료 시 provider가 재인증).
    kc.registerTokenProvider({ getAccessToken: () => tokenProvider.getAccessToken() })
    // 초기 자격증명 검증(fail-fast) + provider 캐시 워밍. call()로 감싸 401·전송 실패가 raw fetch
    // 오류로 누출되지 않고 SDK 예외(KeycloakAdminError/KeycloakTransportError)로 변환되도록(§4 경계).
    await call(() => tokenProvider.getAccessToken())
    return new AdminClient(kc, config.realm)
  }

  /** 파사드가 감싸지 않은 엔드포인트에 접근하기 위한 탈출구. */
  raw(): KcAdminClient {
    return this.#kc
  }

  /**
   * 자원 정리 훅. admin-client는 전역 `fetch` 기반이라 보유 연결이 없어 현재 no-op이지만,
   * {@link KeycloakClient} close 프로토콜과 대칭을 이루기 위해 유지한다.
   */
  async close(): Promise<void> {
    return undefined
  }
}
