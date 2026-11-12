import { randomUUID } from 'node:crypto'
import { afterAll, beforeAll, describe, expect, it } from 'vitest'
import {
  AdminClient,
  defineConfig,
  KeycloakClient,
  KeycloakNotFoundError,
} from '../../src/index.js'
import { masterTokenProvider, startKeycloak, type KeycloakHarness } from './support.js'

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

  // admin 표면 25 연산(자원 다섯 × create·get·list·update·delete)을 **성공 경로**로 실서버에 대고 돈다 — 등록부
  // `integration-admin-surface-uneven`. 자원마다 레코드 하나: 생성(무작위 접미 이름) → 생성이 돌려준 id(없으면 넣은
  // 이름)로 조회해 넣은 필드 단언 → 목록·검색이 그것을 포함 → 필드 하나 갱신 → 다시 조회해 새 값 단언 → 삭제 → 다시
  // 조회해 KeycloakNotFoundError. 본문이 자기 delete 전에 실패하면 finally 가 레코드를 지운다 — 정리의 오류는 삼켜
  // 원래 실패를 가리지 않는다. 위의 테스트들은 그대로 둔다(고정 이름 · it-realm 갱신 · rename 경로/본문 분리).
  describe('admin 표면 25 연산 — 자원마다 레코드 하나의 수명주기', () => {
    const suffix = randomUUID().slice(0, 8)

    it('users: create → get → search → update → get → delete → NotFound', async () => {
      const admin = await client.admin()
      const username = `node-it-user-${suffix}`
      const email = `${username}@example.com`
      const id = await admin.users.create({ username, email, enabled: true })
      let deleted = false
      try {
        const created = await admin.users.get(id)
        expect(created.username).toBe(username)
        expect(created.email).toBe(email)

        // 이름이 고유하니 검색 결과는 이 레코드 하나다 — 검색어가 서버에 닿지 않으면(전체 목록) 여기서 깨진다.
        expect((await admin.users.search(username)).map((u) => u.id)).toEqual([id])

        // 부분(sparse) 갱신 — firstName 만 보낸다. 넣지 않은 신원 필드는 보존돼야 한다.
        await admin.users.update(id, { firstName: 'Updated' })
        const updated = await admin.users.get(id)
        expect(updated.firstName).toBe('Updated')
        expect(updated.username).toBe(username)

        await admin.users.delete(id)
        deleted = true
        await expect(admin.users.get(id)).rejects.toBeInstanceOf(KeycloakNotFoundError)
      } finally {
        if (!deleted) await admin.users.delete(id).catch(() => undefined)
      }
    })

    it('clients: create → get → findByClientId → update → get → delete → NotFound', async () => {
      const admin = await client.admin()
      const clientId = `node-it-cli-${suffix}`
      const id = await admin.clients.create({ clientId, description: 'created by e2e' })
      let deleted = false
      try {
        // create 가 돌려준 것은 내부 id(UUID)다 — get · update · delete 의 주소는 그것이고, 사람이 붙인
        // clientId 는 findByClientId 의 검색어다.
        const created = await admin.clients.get(id)
        expect(created.clientId).toBe(clientId)
        expect(created.description).toBe('created by e2e')

        // clientId 가 고유하니 결과는 이 클라이언트 하나다 — 검색어가 서버에 닿지 않으면(전체 목록) 여기서 깨진다.
        expect((await admin.clients.findByClientId(clientId)).map((c) => c.id)).toEqual([id])

        await admin.clients.update(id, { clientId, description: 'updated by e2e' })
        expect((await admin.clients.get(id)).description).toBe('updated by e2e')

        await admin.clients.delete(id)
        deleted = true
        await expect(admin.clients.get(id)).rejects.toBeInstanceOf(KeycloakNotFoundError)
      } finally {
        if (!deleted) await admin.clients.delete(id).catch(() => undefined)
      }
    })

    it('roles: create → get → list → update → get → delete → NotFound', async () => {
      const admin = await client.admin()
      const name = `node-it-role-${suffix}`
      // roles.create 는 아무것도 돌려주지 않는다 — 넣은 이름이 곧 주소다.
      await admin.roles.create({ name, description: 'created by e2e' })
      let deleted = false
      try {
        const created = await admin.roles.get(name)
        expect(created.name).toBe(name)
        expect(created.description).toBe('created by e2e')

        expect((await admin.roles.list()).map((r) => r.name)).toContain(name)

        await admin.roles.update(name, { name, description: 'updated by e2e' })
        expect((await admin.roles.get(name)).description).toBe('updated by e2e')

        await admin.roles.delete(name)
        deleted = true
        await expect(admin.roles.get(name)).rejects.toBeInstanceOf(KeycloakNotFoundError)
      } finally {
        if (!deleted) await admin.roles.delete(name).catch(() => undefined)
      }
    })

    it('groups: create → get → list → update → get → delete → NotFound', async () => {
      const admin = await client.admin()
      const name = `node-it-grp-${suffix}`
      const id = await admin.groups.create({ name })
      let deleted = false
      try {
        expect((await admin.groups.get(id)).name).toBe(name)

        expect((await admin.groups.list()).map((g) => g.id)).toContain(id)

        // rename — 주소는 id, 본문에 **새** 이름.
        await admin.groups.update(id, { name: `${name}-renamed` })
        expect((await admin.groups.get(id)).name).toBe(`${name}-renamed`)

        await admin.groups.delete(id)
        deleted = true
        await expect(admin.groups.get(id)).rejects.toBeInstanceOf(KeycloakNotFoundError)
      } finally {
        if (!deleted) await admin.groups.delete(id).catch(() => undefined)
      }
    })

    // 신규 렐름 생성은 master 전용 권한이다 — it-client 서비스 계정으로는 403(rust · kotlin 이 실서버로 단언).
    // 그래서 이 수명주기만 master 부트스트랩 관리자의 토큰을 꽂은 파사드로 돈다 — 공유 `it-realm` 은 건드리지
    // 않는다. 토큰은 주입한 공급자가 내므로 clientSecret 은 쓰이지 않는다. AdminClient.create 가 비밀 없는 설정을
    // 네트워크 전에 거부해 자리만 채운다(dotnet `ClientSecret = "unused"` 와 같다).
    it('realms(master 관리자): create → get → list → update → get → delete → NotFound', async () => {
      const master = await AdminClient.create(
        defineConfig({
          serverUrl: harness.url,
          realm: 'master',
          clientId: 'admin-cli',
          clientSecret: 'unused',
        }),
        masterTokenProvider(harness.url),
      )
      const name = `node-it-realm-${suffix}`
      // realms.create 는 아무것도 돌려주지 않는다 — 넣은 렐름 이름이 곧 주소다.
      await master.realms.create({ realm: name, enabled: true, displayName: 'created by e2e' })
      let deleted = false
      try {
        const created = await master.realms.get(name)
        expect(created.realm).toBe(name)
        expect(created.displayName).toBe('created by e2e')

        expect((await master.realms.list()).map((r) => r.realm)).toContain(name)

        await master.realms.update(name, { realm: name, displayName: 'updated by e2e' })
        expect((await master.realms.get(name)).displayName).toBe('updated by e2e')

        await master.realms.delete(name)
        deleted = true
        await expect(master.realms.get(name)).rejects.toBeInstanceOf(KeycloakNotFoundError)
      } finally {
        if (!deleted) await master.realms.delete(name).catch(() => undefined)
        await master.close()
      }
    })
  })
})
