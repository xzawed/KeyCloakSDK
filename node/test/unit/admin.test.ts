import { describe, it, expect, vi, beforeEach } from 'vitest'

// @keycloak/keycloak-admin-client는 네트워크 경계 — 목킹해 타임아웃 주입/위임/예외변환을 격리 검증한다.
const h = vi.hoisted(() => {
  const kc = {
    baseUrl: '',
    realmName: '',
    timeout: undefined as number | undefined,
    auth: vi.fn().mockResolvedValue(undefined),
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
} from '../../src/errors.js'

const cfg = defineConfig({
  serverUrl: 'https://kc.example.com',
  realm: 'demo',
  clientId: 'svc',
  clientSecret: 'sekret',
  readTimeoutMs: 12345,
})

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
})

describe('AdminClient.create — 생성/인증/타임아웃 주입', () => {
  it('baseUrl/realmName/timeout(ms)을 주입하고 client_credentials로 인증한다', async () => {
    await AdminClient.create(cfg)
    expect(h.ctor).toHaveBeenCalledWith({
      baseUrl: 'https://kc.example.com',
      realmName: 'demo',
      timeout: 12345, // ms — admin-client가 AbortSignal.timeout(ms)로 적용(무한대기 방지)
    })
    expect(h.kc.auth).toHaveBeenCalledWith({
      grantType: 'client_credentials',
      clientId: 'svc',
      clientSecret: 'sekret',
    })
  })

  it('clientSecret이 없으면 KeycloakConfigError(네트워크 접근 없음)', async () => {
    const noSecret = defineConfig({ serverUrl: 'https://kc', realm: 'r', clientId: 'c' })
    await expect(AdminClient.create(noSecret)).rejects.toBeInstanceOf(KeycloakConfigError)
    expect(h.ctor).not.toHaveBeenCalled()
  })

  it('raw()는 하위 admin-client(탈출구)를 노출한다', async () => {
    const admin = await AdminClient.create(cfg)
    expect(admin.raw()).toBe(h.kc)
  })
})

describe('예외 경계 변환 (HTTP 상태 → SDK 예외)', () => {
  it('404 → KeycloakNotFoundError', async () => {
    const admin = await AdminClient.create(cfg)
    h.kc.users.update.mockRejectedValue(networkError(404))
    await expect(admin.users.update('id', {})).rejects.toBeInstanceOf(KeycloakNotFoundError)
  })
  it('409 → KeycloakConflictError', async () => {
    const admin = await AdminClient.create(cfg)
    h.kc.users.create.mockRejectedValue(networkError(409))
    await expect(admin.users.create({})).rejects.toBeInstanceOf(KeycloakConflictError)
  })
  it('403 → KeycloakForbiddenError', async () => {
    const admin = await AdminClient.create(cfg)
    h.kc.users.del.mockRejectedValue(networkError(403))
    await expect(admin.users.delete('id')).rejects.toBeInstanceOf(KeycloakForbiddenError)
  })
  it('그 외 상태 → KeycloakAdminError', async () => {
    const admin = await AdminClient.create(cfg)
    h.kc.users.find.mockRejectedValue(networkError(500))
    await expect(admin.users.search()).rejects.toBeInstanceOf(KeycloakAdminError)
  })
  it('상태 없는(비-네트워크) 에러는 그대로 전파한다', async () => {
    const admin = await AdminClient.create(cfg)
    const raw = new TypeError('bug')
    h.kc.users.find.mockRejectedValue(raw)
    await expect(admin.users.search()).rejects.toBe(raw)
  })
})

describe('UsersResource 위임', () => {
  it('create는 신규 id를 반환하고 realm으로 스코프한다', async () => {
    const admin = await AdminClient.create(cfg)
    h.kc.users.create.mockResolvedValue({ id: 'u-1' })
    const id = await admin.users.create({ username: 'bob' })
    expect(id).toBe('u-1')
    expect(h.kc.users.create).toHaveBeenCalledWith({ username: 'bob', realm: 'demo' })
  })
  it('get은 findOne에 위임하고, 없으면 KeycloakNotFoundError', async () => {
    const admin = await AdminClient.create(cfg)
    h.kc.users.findOne.mockResolvedValue({ id: 'u-1', username: 'bob' })
    expect(await admin.users.get('u-1')).toEqual({ id: 'u-1', username: 'bob' })
    h.kc.users.findOne.mockResolvedValue(undefined)
    await expect(admin.users.get('missing')).rejects.toBeInstanceOf(KeycloakNotFoundError)
  })
  it('search는 find에 username/first/max를 전달한다', async () => {
    const admin = await AdminClient.create(cfg)
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
    const admin = await AdminClient.create(cfg)
    await admin.users.update('u-1', { firstName: 'B' })
    expect(h.kc.users.update).toHaveBeenCalledWith({ id: 'u-1', realm: 'demo' }, { firstName: 'B' })
    await admin.users.delete('u-1')
    expect(h.kc.users.del).toHaveBeenCalledWith({ id: 'u-1', realm: 'demo' })
  })
})

describe('ClientsResource 위임', () => {
  it('create→id, findByClientId, get(없으면 NotFound), update, delete', async () => {
    const admin = await AdminClient.create(cfg)
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
    const admin = await AdminClient.create(cfg)
    await admin.realms.create({ realm: 'new-realm', enabled: true })
    expect(h.kc.realms.create).toHaveBeenCalledWith({ realm: 'new-realm', enabled: true })
    h.kc.realms.findOne.mockResolvedValue({ realm: 'new-realm' })
    expect(await admin.realms.get('new-realm')).toEqual({ realm: 'new-realm' })
    expect(h.kc.realms.findOne).toHaveBeenCalledWith({ realm: 'new-realm' })
    h.kc.realms.findOne.mockResolvedValue(undefined)
    await expect(admin.realms.get('nope')).rejects.toBeInstanceOf(KeycloakNotFoundError)
    await admin.realms.delete('new-realm')
    expect(h.kc.realms.del).toHaveBeenCalledWith({ realm: 'new-realm' })
  })
})

describe('RolesResource 위임 (API 편차: findOneByName/delByName)', () => {
  it('create, get(name)→findOneByName, list→find, delete→delByName', async () => {
    const admin = await AdminClient.create(cfg)
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
    const admin = await AdminClient.create(cfg)
    h.kc.groups.create.mockResolvedValue({ id: 'g-1' })
    expect(await admin.groups.create({ name: 'team' })).toBe('g-1')
    expect(h.kc.groups.create).toHaveBeenCalledWith({ name: 'team', realm: 'demo' })
    h.kc.groups.findOne.mockResolvedValue({ id: 'g-1', name: 'team' })
    expect(await admin.groups.get('g-1')).toEqual({ id: 'g-1', name: 'team' })
    h.kc.groups.findOne.mockResolvedValue(undefined)
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
    const admin = await AdminClient.create(cfg)
    await expect(admin.close()).resolves.toBeUndefined()
  })
})
