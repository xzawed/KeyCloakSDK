import { afterAll, beforeAll, describe, expect, it } from 'vitest'
import { KeycloakClient, KeycloakNotFoundError } from '../../src/index.js'
import { startKeycloak, type KeycloakHarness } from './support.js'

/**
 * 전 계층 E2E — 실제 Keycloak 26.6 컨테이너 대상(Java `AuthFlowIT`/`AdminOpsIT`/`SmokeIT`와 동형).
 * client-credentials → validate(다중 aud) → introspect → user CRUD → 삭제 후 NotFound → raw().
 *
 * Docker 필요. `npm run test:it`로 실행한다(단위 커버리지 게이트와 분리).
 */
describe('Keycloak E2E (testcontainers · 실제 Keycloak 26.6)', () => {
  let harness: KeycloakHarness
  let client: KeycloakClient

  beforeAll(async () => {
    harness = await startKeycloak()
    client = KeycloakClient.create({
      serverUrl: harness.url,
      realm: 'it-realm',
      clientId: 'it-client',
      clientSecret: 'it-secret',
    })
  }, 240_000)

  afterAll(async () => {
    await client.close()
    await harness.stop()
  })

  it('client-credentials 토큰을 발급한다', async () => {
    const token = await client.auth.clientCredentialsToken()
    expect(token.accessToken).toBeTruthy()
    expect(token.expiresIn).toBeGreaterThan(0)
    // 보안 불변식: 토큰 문자열 표현은 마스킹된다(접두 노출 없음).
    expect(String(token)).not.toContain(token.accessToken)
    expect(String(token)).toContain('***')
  })

  it('validate가 실제 다중 aud 토큰을 수용하고 issuer/subject를 반환한다', async () => {
    const token = await client.auth.clientCredentialsToken()
    const validated = await client.auth.validate(token.accessToken)
    expect(validated.issuer).toMatch(/\/realms\/it-realm$/)
    // it-client audience 매퍼가 aud에 it-client를 추가 → 포함검사로 통과해야 한다.
    expect(validated.audience).toContain('it-client')
    expect(validated.subject).toBeTruthy()
  })

  it('introspect가 active=true를 보고한다', async () => {
    const token = await client.auth.clientCredentialsToken()
    const result = await client.auth.introspect(token.accessToken)
    expect(result.active).toBe(true)
  })

  it('user CRUD: 생성 → 조회 → 검색 → 수정 → 삭제 → 삭제 후 NotFound', async () => {
    const admin = await client.admin()
    const id = await admin.users.create({
      username: 'bob',
      email: 'bob@example.com',
      enabled: true,
    })
    expect(id).toBeTruthy()

    const created = await admin.users.get(id)
    expect(created.username).toBe('bob')

    const found = await admin.users.search('bob')
    expect(found.length).toBeGreaterThanOrEqual(1)

    await admin.users.update(id, { ...created, firstName: 'Bob' })
    expect((await admin.users.get(id)).firstName).toBe('Bob')

    await admin.users.delete(id)
    await expect(admin.users.get(id)).rejects.toBeInstanceOf(KeycloakNotFoundError)
  })

  it('raw()로 파사드가 감싸지 않은 엔드포인트에 접근한다', async () => {
    const admin = await client.admin()
    const realm = await admin.raw().realms.findOne({ realm: 'it-realm' })
    expect(realm?.realm).toBe('it-realm')
  })

  // ⚠️ update 셋은 전부 **경로(주소)와 body(새 값)를 분리**해 넘긴다 — 그래야 rename이 된다.
  // 경로 인자를 body의 이름으로 덮어쓰면 rename이 조용한 no-op이 된다.
  it('roles/groups/realms의 list·update가 실서버에 반영된다', async () => {
    const admin = await client.admin()

    await admin.roles.create({ name: 'e2e-role' })
    await admin.roles.update('e2e-role', { name: 'e2e-role', description: 'updated by e2e' })
    expect((await admin.roles.get('e2e-role')).description).toBe('updated by e2e')
    await admin.roles.delete('e2e-role')

    const gid = await admin.groups.create({ name: 'e2e-group' })
    await admin.groups.update(gid, { name: 'e2e-group-renamed' })
    expect((await admin.groups.get(gid)).name).toBe('e2e-group-renamed')
    await admin.groups.delete(gid)

    // 서비스 계정은 보통 자기 렐름만 본다 — 전체 목록을 가정하지 않고 포함 여부만 본다.
    const realms = await admin.realms.list()
    expect(realms.some((r) => r.realm === 'it-realm')).toBe(true)

    await admin.realms.update('it-realm', { realm: 'it-realm', displayName: 'updated by e2e' })
    expect((await admin.realms.get('it-realm')).displayName).toBe('updated by e2e')
  })
})
