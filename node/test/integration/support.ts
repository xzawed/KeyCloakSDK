import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { GenericContainer, Wait, type StartedTestContainer } from 'testcontainers'

const HERE = dirname(fileURLToPath(import.meta.url))
// Java/Python SDK의 통합 테스트 realm을 재사용한다(it-realm · it-client · it-secret,
// serviceAccounts + realm-management 권한 + it-client audience 매퍼).
const REALM_IMPORT_FILE = join(HERE, 'it-realm-realm.json')

const KEYCLOAK_IMAGE = 'quay.io/keycloak/keycloak:26.6'
const KEYCLOAK_PORT = 8080

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
      KC_BOOTSTRAP_ADMIN_USERNAME: 'admin',
      KC_BOOTSTRAP_ADMIN_PASSWORD: 'admin',
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
