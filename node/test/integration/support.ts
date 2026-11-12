import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { GenericContainer, Wait, type StartedTestContainer } from 'testcontainers'
import type { TokenProvider } from '../../src/index.js'

const HERE = dirname(fileURLToPath(import.meta.url))
// Java/Python SDK의 통합 테스트 realm을 재사용한다(it-realm · it-client · it-secret,
// serviceAccounts + realm-management 권한 + it-client audience 매퍼).
const REALM_IMPORT_FILE = join(HERE, 'it-realm-realm.json')

const KEYCLOAK_IMAGE = 'quay.io/keycloak/keycloak:26.6'
const KEYCLOAK_PORT = 8080
// master 렐름 부트스트랩 관리자 — 컨테이너 환경변수와 `masterTokenProvider` 의 그랜트가 같은 값을 쓴다.
const BOOTSTRAP_ADMIN = { username: 'admin', password: 'admin' } as const

export interface KeycloakHarness {
  /** auth-server base URL (예: http://localhost:32819) */
  readonly url: string
  readonly stop: () => Promise<void>
}

/**
 * `it-realm`을 임포트한 실제 Keycloak 26.6 컨테이너를 기동한다(`start-dev --import-realm`).
 * realm well-known 엔드포인트가 200을 반환할 때까지 대기해 임포트 완료를 보장한다.
 */
export async function startKeycloak(): Promise<KeycloakHarness> {
  const container: StartedTestContainer = await new GenericContainer(KEYCLOAK_IMAGE)
    .withExposedPorts(KEYCLOAK_PORT)
    .withEnvironment({
      KC_BOOTSTRAP_ADMIN_USERNAME: BOOTSTRAP_ADMIN.username,
      KC_BOOTSTRAP_ADMIN_PASSWORD: BOOTSTRAP_ADMIN.password,
    })
    .withCopyFilesToContainer([
      { source: REALM_IMPORT_FILE, target: '/opt/keycloak/data/import/it-realm-realm.json' },
    ])
    .withCommand(['start-dev', '--import-realm'])
    .withWaitStrategy(
      Wait.forHttp(
        '/realms/it-realm/.well-known/openid-configuration',
        KEYCLOAK_PORT,
      ).forStatusCode(200),
    )
    .withStartupTimeout(180_000)
    .start()

  const url = `http://${container.getHost()}:${String(container.getMappedPort(KEYCLOAK_PORT))}`
  return {
    url,
    stop: async () => {
      await container.stop()
    },
  }
}

/**
 * master 렐름 부트스트랩 관리자의 토큰 공급자 — 공개 클라이언트 `admin-cli` 에 password 그랜트.
 * 신규 렐름 생성(`POST /admin/realms`)은 master 전용 권한이라 it-client 서비스 계정으로는 403 이다
 * (rust `MasterTokenProvider` · dotnet `MasterPasswordTokenSource` 와 같은 길). 캐시하지 않고 부를 때마다
 * 새로 받는다 — master 토큰의 수명이 지나도 낡은 토큰을 보내지 않는다.
 */
export function masterTokenProvider(serverUrl: string): TokenProvider {
  return {
    getAccessToken: async () => {
      const res = await fetch(`${serverUrl}/realms/master/protocol/openid-connect/token`, {
        method: 'POST',
        body: new URLSearchParams({
          grant_type: 'password',
          client_id: 'admin-cli',
          username: BOOTSTRAP_ADMIN.username,
          password: BOOTSTRAP_ADMIN.password,
        }),
      })
      if (!res.ok) {
        throw new Error(`master password grant failed: HTTP ${String(res.status)}`)
      }
      const body = (await res.json()) as { access_token?: unknown }
      if (typeof body.access_token !== 'string') {
        throw new Error('master token response has no access_token')
      }
      return body.access_token
    },
  }
}
