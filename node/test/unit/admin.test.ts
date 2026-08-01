import { describe, it, expect, vi, beforeEach } from 'vitest'

// @keycloak/keycloak-admin-client는 네트워크 경계 — 목킹해 타임아웃 주입/위임/예외변환을 격리 검증한다.
const h = vi.hoisted(() => {
  const kc = {
    baseUrl: '',
    realmName: '',
    timeout: undefined as number | undefined,
    auth: vi.fn().mockResolvedValue(undefined),
    registerTokenProvider: vi.fn(),
    users: { create: vi.fn(), findOne: vi.fn(), find: vi.fn(), update: vi.fn(), del: vi.fn() },
    clients: { create: vi.fn(), findOne: vi.fn(), find: vi.fn(), update: vi.fn(), del: vi.fn() },
    realms: { create: vi.fn(), findOne: vi.fn(), del: vi.fn() },
    roles: { create: vi.fn(), findOneByName: vi.fn(), find: vi.fn(), delByName: vi.fn() },
    groups: { create: vi.fn(), findOne: vi.fn(), find: vi.fn(), del: vi.fn() },
  }
  const ctor = vi.fn((config: Record<string, unknown>) => {
    Object.assign(kc, config)
    return kc
  })
  return { kc, ctor }
})

vi.mock('@keycloak/keycloak-admin-client', () => ({ default: h.ctor }))

import { AdminClient } from '../../src/admin/index.js'
import { defineConfig } from '../../src/config.js'
import {
  KeycloakNotFoundError,
  KeycloakConflictError,
  KeycloakForbiddenError,
  KeycloakAdminError,
  KeycloakConfigError,
  KeycloakTransportError,
} from '../../src/errors.js'

const cfg = defineConfig({
  serverUrl: 'https://kc.example.com',
  realm: 'demo',
  clientId: 'svc',
  clientSecret: 'sekret',
  readTimeoutMs: 12345,
})

// admin은 core의 TokenProvider 인터페이스로 토큰을 주입받는다(파사드가 캐싱 provider를 배선).
// 여기서는 provider를 목킹해 admin의 등록/초기획득/경계변환 배선을 격리 검증한다.
const provider = { getAccessToken: vi.fn() }

/** NetworkError(admin-client) 형태의 에러를 만든다. */
function networkError(status: number, errorMessage = 'boom'): Error {
  const err = new Error(errorMessage) as Error & {
    response: { status: number }
    responseData: { errorMessage: string }
  }
  err.response = { status }
  err.responseData = { errorMessage }
  return err
}

beforeEach(() => {
  // resetAllMocks: 호출 기록 + 구현 모두 초기화(테스트 간 mockRejectedValue 오염 방지).
  // 이후 ctor/auth 기본 구현을 재확립한다.
  vi.resetAllMocks()
  h.ctor.mockImplementation((config: Record<string, unknown>) => {
    Object.assign(h.kc, config)
    return h.kc
  })
  h.kc.auth.mockResolvedValue(undefined)
  provider.getAccessToken.mockResolvedValue('access-token')
})

describe('AdminClient.create — 생성/인증/타임아웃 주입', () => {
  it('baseUrl/realmName/timeout(ms)+리다이렉트 차단을 주입하고 SDK TokenProvider를 등록한다(내장 auth 미사용)', async () => {
    await AdminClient.create(cfg, provider)
    expect(h.ctor).toHaveBeenCalledWith({
      baseUrl: 'https://kc.example.com',
      realmName: 'demo',
      timeout: 12345, // ms — admin-client가 AbortSignal.timeout(ms)로 적용(무한대기 방지)
      // SSRF 하드닝 — admin REST가 3xx를 따라가면 **Authorization 헤더를 리다이렉트 대상까지
      // 들고 가고**(실측) 호출은 성공으로 resolve된다. 이 옵션은 admin-client가 모든 리소스
      // fetch에 전달한다. 여기서 함께 고정하지 않으면 생성자 옵션 리팩터에서 조용히 사라진다.
      requestOptions: { redirect: 'manual' },
    })
    // 만료 시 재인증하는 SDK provider를 등록하고, 크래시·refresh-only 만료버그의 원인인 kc.auth()는
    // 호출하지 않는다.
    expect(h.kc.registerTokenProvider).toHaveBeenCalledOnce()
    expect(h.kc.auth).not.toHaveBeenCalled()
    // 초기 토큰 확보(fail-fast + 캐시 워밍)로 provider에서 한 번 이상 토큰을 얻는다.
    expect(provider.getAccessToken).toHaveBeenCalled()
  })

  it('clientSecret이 없으면 KeycloakConfigError(네트워크 접근 없음)', async () => {
    const noSecret = defineConfig({ serverUrl: 'https://kc', realm: 'r', clientId: 'c' })
    await expect(AdminClient.create(noSecret, provider)).rejects.toBeInstanceOf(KeycloakConfigError)
    expect(h.ctor).not.toHaveBeenCalled()
    expect(provider.getAccessToken).not.toHaveBeenCalled()
  })

  it('raw()는 하위 admin-client(탈출구)를 노출한다', async () => {
    const admin = await AdminClient.create(cfg, provider)
    expect(admin.raw()).toBe(h.kc)
  })

  it('초기 토큰 획득 전송 실패는 KeycloakTransportError로 변환한다(raw 누출 금지)', async () => {
    provider.getAccessToken.mockRejectedValue(
      new TypeError('fetch failed', {
        cause: Object.assign(new Error('connect ECONNREFUSED'), { code: 'ECONNREFUSED' }),
      }),
    )
    await expect(AdminClient.create(cfg, provider)).rejects.toBeInstanceOf(KeycloakTransportError)
  })
})

describe('예외 경계 변환 (HTTP 상태 → SDK 예외)', () => {
  it('404 → KeycloakNotFoundError', async () => {
    const admin = await AdminClient.create(cfg, provider)
    h.kc.users.update.mockRejectedValue(networkError(404))
    await expect(admin.users.update('id', {})).rejects.toBeInstanceOf(KeycloakNotFoundError)
  })
  it('409 → KeycloakConflictError', async () => {
    const admin = await AdminClient.create(cfg, provider)
    h.kc.users.create.mockRejectedValue(networkError(409))
    await expect(admin.users.create({})).rejects.toBeInstanceOf(KeycloakConflictError)
  })
  it('403 → KeycloakForbiddenError', async () => {
    const admin = await AdminClient.create(cfg, provider)
    h.kc.users.del.mockRejectedValue(networkError(403))
    await expect(admin.users.delete('id')).rejects.toBeInstanceOf(KeycloakForbiddenError)
  })
  it('그 외 상태 → KeycloakAdminError', async () => {
    const admin = await AdminClient.create(cfg, provider)
    h.kc.users.find.mockRejectedValue(networkError(500))
    await expect(admin.users.search()).rejects.toBeInstanceOf(KeycloakAdminError)
  })
  it('상태 없는 프로그래밍 오류(cause 없는 TypeError)는 그대로 전파한다', async () => {
    const admin = await AdminClient.create(cfg, provider)
    const raw = new TypeError('bug')
    h.kc.users.find.mockRejectedValue(raw)
    await expect(admin.users.search()).rejects.toBe(raw)
  })
  it('전송 실패(undici fetch failed = cause 있는 TypeError)는 KeycloakTransportError로 변환한다', async () => {
    const admin = await AdminClient.create(cfg, provider)
    const fetchFailed = new TypeError('fetch failed', {
      cause: Object.assign(new Error('connect ECONNREFUSED 127.0.0.1:8080'), {
        code: 'ECONNREFUSED',
      }),
    })
    h.kc.users.find.mockRejectedValue(fetchFailed)
    await expect(admin.users.search()).rejects.toBeInstanceOf(KeycloakTransportError)
  })
  it('타임아웃(AbortError)은 KeycloakTransportError로 변환한다', async () => {
    const admin = await AdminClient.create(cfg, provider)
    const timeout = Object.assign(new Error('The operation was aborted'), { name: 'AbortError' })
    h.kc.users.find.mockRejectedValue(timeout)
    await expect(admin.users.search()).rejects.toBeInstanceOf(KeycloakTransportError)
  })
})

describe('UsersResource 위임', () => {
  it('create는 신규 id를 반환하고 realm으로 스코프한다', async () => {
    const admin = await AdminClient.create(cfg, provider)
    h.kc.users.create.mockResolvedValue({ id: 'u-1' })
    const id = await admin.users.create({ username: 'bob' })
    expect(id).toBe('u-1')
    expect(h.kc.users.create).toHaveBeenCalledWith({ username: 'bob', realm: 'demo' })
  })
  it('get은 findOne에 위임하고, 없으면 KeycloakNotFoundError', async () => {
    const admin = await AdminClient.create(cfg, provider)
    h.kc.users.findOne.mockResolvedValue({ id: 'u-1', username: 'bob' })
    expect(await admin.users.get('u-1')).toEqual({ id: 'u-1', username: 'bob' })
    // admin-client는 404에서 null을 반환한다(선언 타입은 undefined) — 둘 다 NotFound로 처리해야 한다.
    h.kc.users.findOne.mockResolvedValue(null)
    await expect(admin.users.get('missing')).rejects.toBeInstanceOf(KeycloakNotFoundError)
  })
  it('search는 find에 username/first/max를 전달한다', async () => {
    const admin = await AdminClient.create(cfg, provider)
    h.kc.users.find.mockResolvedValue([{ id: 'u-1' }])
    await admin.users.search('bob', 5, 10)
    expect(h.kc.users.find).toHaveBeenCalledWith({
      realm: 'demo',
      username: 'bob',
      first: 5,
      max: 10,
    })
  })
  it('update/delete는 id+realm으로 위임한다', async () => {
    const admin = await AdminClient.create(cfg, provider)
    await admin.users.update('u-1', { firstName: 'B' })
    expect(h.kc.users.update).toHaveBeenCalledWith({ id: 'u-1', realm: 'demo' }, { firstName: 'B' })
    await admin.users.delete('u-1')
    expect(h.kc.users.del).toHaveBeenCalledWith({ id: 'u-1', realm: 'demo' })
  })
})

describe('ClientsResource 위임', () => {
  it('create→id, findByClientId, get(없으면 NotFound), update, delete', async () => {
    const admin = await AdminClient.create(cfg, provider)
    h.kc.clients.create.mockResolvedValue({ id: 'c-1' })
    expect(await admin.clients.create({ clientId: 'app' })).toBe('c-1')
    h.kc.clients.find.mockResolvedValue([{ id: 'c-1', clientId: 'app' }])
    expect(await admin.clients.findByClientId('app')).toHaveLength(1)
    expect(h.kc.clients.find).toHaveBeenCalledWith({ realm: 'demo', clientId: 'app' })
    h.kc.clients.findOne.mockResolvedValue(undefined)
    await expect(admin.clients.get('missing')).rejects.toBeInstanceOf(KeycloakNotFoundError)
    await admin.clients.update('c-1', { name: 'x' })
    expect(h.kc.clients.update).toHaveBeenCalledWith({ id: 'c-1', realm: 'demo' }, { name: 'x' })
    await admin.clients.delete('c-1')
    expect(h.kc.clients.del).toHaveBeenCalledWith({ id: 'c-1', realm: 'demo' })
  })
})

describe('RealmsResource 위임', () => {
  it('create는 payload를 그대로, get/delete는 realm 이름으로 위임한다', async () => {
    const admin = await AdminClient.create(cfg, provider)
    await admin.realms.create({ realm: 'new-realm', enabled: true })
    expect(h.kc.realms.create).toHaveBeenCalledWith({ realm: 'new-realm', enabled: true })
    h.kc.realms.findOne.mockResolvedValue({ realm: 'new-realm' })
    expect(await admin.realms.get('new-realm')).toEqual({ realm: 'new-realm' })
    expect(h.kc.realms.findOne).toHaveBeenCalledWith({ realm: 'new-realm' })
    h.kc.realms.findOne.mockResolvedValue(null)
    await expect(admin.realms.get('nope')).rejects.toBeInstanceOf(KeycloakNotFoundError)
    await admin.realms.delete('new-realm')
    expect(h.kc.realms.del).toHaveBeenCalledWith({ realm: 'new-realm' })
  })
})

describe('RolesResource 위임 (API 편차: findOneByName/delByName)', () => {
  it('create, get(name)→findOneByName, list→find, delete→delByName', async () => {
    const admin = await AdminClient.create(cfg, provider)
    await admin.roles.create({ name: 'admin' })
    expect(h.kc.roles.create).toHaveBeenCalledWith({ name: 'admin', realm: 'demo' })
    h.kc.roles.findOneByName.mockResolvedValue({ name: 'admin' })
    expect(await admin.roles.get('admin')).toEqual({ name: 'admin' })
    expect(h.kc.roles.findOneByName).toHaveBeenCalledWith({ name: 'admin', realm: 'demo' })
    h.kc.roles.findOneByName.mockResolvedValue(undefined)
    await expect(admin.roles.get('nope')).rejects.toBeInstanceOf(KeycloakNotFoundError)
    h.kc.roles.find.mockResolvedValue([{ name: 'admin' }])
    expect(await admin.roles.list()).toHaveLength(1)
    await admin.roles.delete('admin')
    expect(h.kc.roles.delByName).toHaveBeenCalledWith({ name: 'admin', realm: 'demo' })
  })
})

describe('GroupsResource 위임', () => {
  it('create→id, get(없으면 NotFound), list(first/max), delete', async () => {
    const admin = await AdminClient.create(cfg, provider)
    h.kc.groups.create.mockResolvedValue({ id: 'g-1' })
    expect(await admin.groups.create({ name: 'team' })).toBe('g-1')
    expect(h.kc.groups.create).toHaveBeenCalledWith({ name: 'team', realm: 'demo' })
    h.kc.groups.findOne.mockResolvedValue({ id: 'g-1', name: 'team' })
    expect(await admin.groups.get('g-1')).toEqual({ id: 'g-1', name: 'team' })
    h.kc.groups.findOne.mockResolvedValue(null)
    await expect(admin.groups.get('nope')).rejects.toBeInstanceOf(KeycloakNotFoundError)
    h.kc.groups.find.mockResolvedValue([{ id: 'g-1' }])
    await admin.groups.list(2, 20)
    expect(h.kc.groups.find).toHaveBeenCalledWith({ realm: 'demo', first: 2, max: 20 })
    await admin.groups.delete('g-1')
    expect(h.kc.groups.del).toHaveBeenCalledWith({ id: 'g-1', realm: 'demo' })
  })
})

describe('close', () => {
  it('resolves (자원 정리 대칭 훅)', async () => {
    const admin = await AdminClient.create(cfg, provider)
    await expect(admin.close()).resolves.toBeUndefined()
  })
})
