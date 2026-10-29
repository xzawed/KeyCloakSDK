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
 * 관리(Admin) API 파사드 진입점. 리소스 접근자({@link users}/{@link clients}/{@link realms}/{@link roles}/{@link groups})와
 * 탈출구 {@link raw}(공식 `@keycloak/keycloak-admin-client`)를 노출한다.
 *
 * ⚠️ 파사드의 다섯 리소스는 admin-client 메서드를 부르지 않는다 — admin-client 가 보내는 것과 같은 요청을 직접 보낸다
 * (`http.ts`). admin-client 26.8 은 2xx 가 아닌 응답의 본문을 통째로 읽고(`fetchWithError`) 쓰기의 2xx 본문도 끝까지
 * 읽는데(`parseResponse`), 파사드는 오류 본문을 1 MiB 까지만 비우고 쓰기의 2xx 본문은 읽지 않는다. 같은 요청인지는
 * `test/unit/admin-response-body.test.ts` 가 고치기 전 위임 코드와 와이어로 대조한다 — admin-client 를 올릴 때마다 돌 것.
 *
 * 결합 규칙: admin은 auth 모듈에 의존하지 않는다 — core의 {@link TokenProvider} 인터페이스(유일 접착제)로
 * 토큰을 주입받는다. 파사드가 캐싱 client-credentials provider를 주입하고, 그 provider가 만료 시
 * client_credentials로 재인증한다(admin-client 내장 TokenManager에 위임하지 않는다 — 그 경로는 만료 시
 * refresh_token만 시도해 client-credentials에서 영구 실패하기 때문).
 *
 * 생성 인자·토큰 배선은 `admin.test.ts`가 admin-client 를 목킹해, 실호출은 통합테스트가 검증한다.
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
   * 파사드가 감싸지 않은 엔드포인트에 접근하기 위한 탈출구 — 공식 admin-client 그 자체다.
   *
   * ⚠️ 이 경로는 admin-client 그대로라 2xx 가 아닌 응답의 본문을 상한 없이 끝까지 읽어 `NetworkError.responseData` 에
   * 싣고, 쓰기의 2xx 본문도 끝까지 읽는다(파사드와 다르다 — 등록부 `admin-response-body-unbounded`). 그 자리는
   * `test/unit/admin-response-body.test.ts` 의 「남긴 자리」 시험이 고정한다. `setConfig()` 로 바꾼 주소·요청 옵션은 이
   * 경로에만 걸린다.
   */
  raw(): KcAdminClient {
    return this.#kc
  }

  /**
   * 자원 정리 훅. 파사드와 admin-client 는 전역 `fetch` 기반이라 보유 연결이 없어 현재 no-op이지만,
   * {@link KeycloakClient} close 프로토콜과 대칭을 이루기 위해 유지한다.
   */
  async close(): Promise<void> {
    return undefined
  }
}
