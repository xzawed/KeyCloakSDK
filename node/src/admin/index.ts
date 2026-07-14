import KcAdminClient from '@keycloak/keycloak-admin-client'
import type { KeycloakConfig } from '../config.js'
import { KeycloakConfigError } from '../errors.js'
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
 * 결합 규칙: admin은 auth 모듈에 의존하지 않는다 — 자체 client-credentials grant로 인증한다.
 * admin-client의 내장 TokenManager가 토큰을 자동 획득·갱신한다.
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
   * admin-client를 생성하고 client-credentials로 인증한다. `config`의 read 타임아웃을 주입해
   * admin 호출이 무한 대기하지 않게 한다(미주입=스레드 고갈 DoS). clientSecret이 없으면
   * 네트워크 접근 전에 {@link KeycloakConfigError}로 실패한다.
   */
  static async create(config: KeycloakConfig): Promise<AdminClient> {
    if (config.clientSecret === undefined) {
      throw new KeycloakConfigError('clientSecret is required for admin client-credentials')
    }
    const kc = new KcAdminClient({
      baseUrl: config.serverUrl,
      realmName: config.realm,
      // ms 단위 — admin-client가 요청마다 AbortSignal.timeout(ms)로 적용한다.
      timeout: config.readTimeoutMs,
    })
    // 초기 client-credentials 인증도 call()로 감싼다 — 401·전송 실패가 raw NetworkError/fetch 오류로
    // 누출되지 않고 SDK 예외(KeycloakAdminError/KeycloakTransportError)로 변환되도록(§4 경계).
    await call(() =>
      kc.auth({
        grantType: 'client_credentials',
        clientId: config.clientId,
        clientSecret: config.clientSecret,
      }),
    )
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
