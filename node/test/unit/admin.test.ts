import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'

// @keycloak/keycloak-admin-client 는 `raw()` 의 탈출구로만 남았다 — 목킹해 생성 인자·토큰 배선을 격리 검증한다.
// 파사드의 요청은 전역 `fetch` 로 직접 나가므로(`src/admin/http.ts`) 그 자리를 스텁으로 갈아 요청을 본다.
// 와이어 그대로의 대조(머리 순서 · 본문 바이트)와 본문 상한은 `admin-response-body.test.ts` 가 진짜 서버로 잰다.
const h = vi.hoisted(() => {
  const kc = {
    baseUrl: '',
    realmName: '',
    timeout: undefined as number | undefined,
    auth: vi.fn().mockResolvedValue(undefined),
    registerTokenProvider: vi.fn(),
    users: { create: vi.fn(), findOne: vi.fn(), find: vi.fn(), update: vi.fn(), del: vi.fn() },
    clients: { create: vi.fn(), findOne: vi.fn(), find: vi.fn(), update: vi.fn(), del: vi.fn() },
    realms: { create: vi.fn(), findOne: vi.fn(), find: vi.fn(), update: vi.fn(), del: vi.fn() },
    roles: {
      create: vi.fn(),
      findOneByName: vi.fn(),
      find: vi.fn(),
      updateByName: vi.fn(),
      delByName: vi.fn(),
    },
    groups: { create: vi.fn(), findOne: vi.fn(), find: vi.fn(), update: vi.fn(), del: vi.fn() },
  }
  // ⚠️ vitest 4: 생성자로 쓰이는 목은 `function`/`class` 여야 한다(화살표 함수 불가).
  const ctor = vi.fn(function (config: Record<string, unknown>) {
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

const BASE = 'https://kc.example.com/admin/realms'

// admin은 core의 TokenProvider 인터페이스로 토큰을 주입받는다(파사드가 캐싱 provider를 배선).
// 여기서는 provider를 목킹해 admin의 등록/초기획득/경계변환 배선을 격리 검증한다.
const provider = { getAccessToken: vi.fn() }

const fetchMock = vi.fn<typeof fetch>()

/** 다음 fetch 하나의 응답을 정한다 — 본문이 문자열이 아니면 JSON 으로 싣는다. */
function reply(status: number, body?: unknown, headers?: Record<string, string>): void {
  const payload = body === undefined ? null : typeof body === 'string' ? body : JSON.stringify(body)
  fetchMock.mockResolvedValueOnce(new Response(payload, { status, headers }))
}

/** 마지막 fetch 의 요청 — URL · 메서드 · 본문 · 머리 · 옵션. */
function sent(): {
  url: string
  method?: string
  body: unknown
  headers: Headers
  init?: RequestInit
} {
  const last = fetchMock.mock.calls.at(-1)
  if (last === undefined) throw new Error('fetch was not called')
  const [input, init] = last
  return {
    url: String(input),
    method: init?.method,
    body: init?.body,
    headers: new Headers(init?.headers),
    init,
  }
}

beforeEach(() => {
  // resetAllMocks: 호출 기록 + 구현 모두 초기화(테스트 간 mockRejectedValue 오염 방지).
  // 이후 ctor/auth/fetch 기본 구현을 재확립한다.
  vi.resetAllMocks()
  h.ctor.mockImplementation(function (config: Record<string, unknown>) {
    Object.assign(h.kc, config)
    return h.kc
  })
  h.kc.auth.mockResolvedValue(undefined)
  provider.getAccessToken.mockResolvedValue('access-token')
  fetchMock.mockImplementation(() => Promise.resolve(new Response(null, { status: 204 })))
  vi.stubGlobal('fetch', fetchMock)
})

afterEach(() => {
  vi.unstubAllGlobals()
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
      // fetch에 전달한다(`raw()` 의 요청). 여기서 함께 고정하지 않으면 생성자 옵션 리팩터에서 조용히 사라진다.
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

describe('파사드의 요청 — admin-client 메서드를 거치지 않는다', () => {
  it('요청마다 Bearer · 리다이렉트 금지 · 읽기 기한을 싣는다', async () => {
    const admin = await AdminClient.create(cfg, provider)
    provider.getAccessToken.mockResolvedValue('fresh-token')
    await admin.users.update('u-1', { firstName: 'B' })
    const { headers, init } = sent()
    expect(headers.get('authorization')).toBe('Bearer fresh-token')
    expect(headers.get('accept')).toBe('application/json, text/plain, */*')
    expect(headers.get('content-type')).toBe('application/json')
    expect(init?.redirect).toBe('manual')
    expect(init?.signal).toBeInstanceOf(AbortSignal)
  })

  it('본문 없는 요청(GET)에는 content-type 을 싣지 않는다', async () => {
    const admin = await AdminClient.create(cfg, provider)
    reply(200, [])
    await admin.realms.list()
    expect(sent().headers.has('content-type')).toBe(false)
    expect(sent().body).toBeUndefined()
  })

  it('읽기 기한이 0 이면(손으로 지은 설정) 기한을 싣지 않는다 — admin-client 와 같다', async () => {
    const admin = await AdminClient.create({ ...cfg, readTimeoutMs: 0 }, provider)
    expect(h.ctor).toHaveBeenCalledWith(expect.objectContaining({ timeout: 0 }))
    await admin.users.delete('u-1')
    expect(sent().init?.signal).toBeUndefined()
  })

  it('본문 취소가 실패해도 결과는 그대로다 — 쓰기의 2xx · 상한보다 길다고 알린 오류 본문', async () => {
    const admin = await AdminClient.create(cfg, provider)
    const stubborn = (status: number, length: string): Response =>
      new Response(
        new ReadableStream({
          cancel() {
            throw new Error('cancel failed')
          },
        }),
        { status, headers: { 'content-length': length } },
      )
    fetchMock.mockResolvedValueOnce(stubborn(200, '10'))
    await expect(admin.users.update('u-1', {})).resolves.toBeUndefined()
    fetchMock.mockResolvedValueOnce(stubborn(404, '2000000'))
    await expect(admin.users.delete('u-1')).rejects.toBeInstanceOf(KeycloakNotFoundError)
  })

  it('다섯 리소스 어느 것도 admin-client 메서드를 부르지 않는다', async () => {
    const admin = await AdminClient.create(cfg, provider)
    await admin.users.delete('u')
    await admin.clients.delete('c')
    await admin.realms.delete('r')
    await admin.roles.delete('n')
    await admin.groups.delete('g')
    for (const resource of [h.kc.users, h.kc.clients, h.kc.realms, h.kc.roles, h.kc.groups])
      for (const method of Object.values(resource)) expect(method).not.toHaveBeenCalled()
    expect(fetchMock).toHaveBeenCalledTimes(5)
  })
})

describe('예외 경계 변환 (HTTP 상태 → SDK 예외)', () => {
  it('404 → KeycloakNotFoundError', async () => {
    const admin = await AdminClient.create(cfg, provider)
    reply(404, { errorMessage: 'boom' })
    await expect(admin.users.update('id', {})).rejects.toBeInstanceOf(KeycloakNotFoundError)
  })
  it('409 → KeycloakConflictError', async () => {
    const admin = await AdminClient.create(cfg, provider)
    reply(409, { errorMessage: 'boom' })
    await expect(admin.users.create({})).rejects.toBeInstanceOf(KeycloakConflictError)
  })
  it('403 → KeycloakForbiddenError', async () => {
    const admin = await AdminClient.create(cfg, provider)
    reply(403, { errorMessage: 'boom' })
    await expect(admin.users.delete('id')).rejects.toBeInstanceOf(KeycloakForbiddenError)
  })
  it('그 외 상태 → KeycloakAdminError', async () => {
    const admin = await AdminClient.create(cfg, provider)
    reply(500, { errorMessage: 'boom' })
    await expect(admin.users.search()).rejects.toBeInstanceOf(KeycloakAdminError)
  })
  it('상태 없는 프로그래밍 오류(cause 없는 TypeError)는 그대로 전파한다', async () => {
    const admin = await AdminClient.create(cfg, provider)
    const raw = new TypeError('bug')
    fetchMock.mockRejectedValueOnce(raw)
    await expect(admin.users.search()).rejects.toBe(raw)
  })
  it('전송 실패(undici fetch failed = cause 있는 TypeError)는 KeycloakTransportError로 변환한다', async () => {
    const admin = await AdminClient.create(cfg, provider)
    const fetchFailed = new TypeError('fetch failed', {
      cause: Object.assign(new Error('connect ECONNREFUSED 127.0.0.1:8080'), {
        code: 'ECONNREFUSED',
      }),
    })
    fetchMock.mockRejectedValueOnce(fetchFailed)
    await expect(admin.users.search()).rejects.toBeInstanceOf(KeycloakTransportError)
  })
  it('타임아웃(AbortError)은 KeycloakTransportError로 변환한다', async () => {
    const admin = await AdminClient.create(cfg, provider)
    const timeout = Object.assign(new Error('The operation was aborted'), { name: 'AbortError' })
    fetchMock.mockRejectedValueOnce(timeout)
    await expect(admin.users.search()).rejects.toBeInstanceOf(KeycloakTransportError)
  })
})

describe('UsersResource', () => {
  it('create는 realm 의 컬렉션에 POST 하고 Location 의 마지막 조각을 id 로 돌려준다', async () => {
    const admin = await AdminClient.create(cfg, provider)
    reply(201, undefined, { location: `${BASE}/demo/users/u-1` })
    expect(await admin.users.create({ username: 'bob' })).toBe('u-1')
    expect(sent()).toMatchObject({
      url: `${BASE}/demo/users/`,
      method: 'POST',
      body: '{"username":"bob"}',
    })
  })
  it('get은 id 로 GET 하고, 404 면 KeycloakNotFoundError', async () => {
    const admin = await AdminClient.create(cfg, provider)
    reply(200, { id: 'u-1', username: 'bob' })
    expect(await admin.users.get('u-1')).toEqual({ id: 'u-1', username: 'bob' })
    expect(sent()).toMatchObject({ url: `${BASE}/demo/users/u-1`, method: 'GET' })
    reply(404, { error: 'User not found' })
    await expect(admin.users.get('missing')).rejects.toThrow('User not found: missing')
    reply(404, { error: 'User not found' })
    await expect(admin.users.get('missing')).rejects.toBeInstanceOf(KeycloakNotFoundError)
  })
  it('search는 username/first/max 를 쿼리로 보낸다 — 없는 username 은 뺀다', async () => {
    const admin = await AdminClient.create(cfg, provider)
    reply(200, [{ id: 'u-1' }])
    expect(await admin.users.search('bob', 5, 10)).toEqual([{ id: 'u-1' }])
    expect(sent().url).toBe(`${BASE}/demo/users/?username=bob&first=5&max=10`)
    reply(200, [])
    await admin.users.search()
    expect(sent().url).toBe(`${BASE}/demo/users/?first=0&max=100`)
  })
  it('update/delete는 id 로 주소를 잡는다 — update 는 본문 그대로, delete 는 빈 객체', async () => {
    const admin = await AdminClient.create(cfg, provider)
    await admin.users.update('u-1', { firstName: 'B' })
    expect(sent()).toMatchObject({
      url: `${BASE}/demo/users/u-1`,
      method: 'PUT',
      body: '{"firstName":"B"}',
    })
    await admin.users.delete('u-1')
    expect(sent()).toMatchObject({ url: `${BASE}/demo/users/u-1`, method: 'DELETE', body: '{}' })
  })
})

describe('ClientsResource', () => {
  it('create→id, findByClientId, get(없으면 NotFound), update, delete', async () => {
    const admin = await AdminClient.create(cfg, provider)
    reply(201, undefined, { location: `${BASE}/demo/clients/c-1` })
    expect(await admin.clients.create({ clientId: 'app' })).toBe('c-1')
    expect(sent()).toMatchObject({ url: `${BASE}/demo/clients/`, body: '{"clientId":"app"}' })
    reply(200, [{ id: 'c-1', clientId: 'app' }])
    expect(await admin.clients.findByClientId('app')).toHaveLength(1)
    expect(sent().url).toBe(`${BASE}/demo/clients/?clientId=app`)
    reply(404, {})
    await expect(admin.clients.get('missing')).rejects.toThrow('Client not found: missing')
    await admin.clients.update('c-1', { name: 'x' })
    expect(sent()).toMatchObject({
      url: `${BASE}/demo/clients/c-1`,
      method: 'PUT',
      body: '{"name":"x"}',
    })
    await admin.clients.delete('c-1')
    expect(sent()).toMatchObject({ url: `${BASE}/demo/clients/c-1`, method: 'DELETE' })
  })
})

describe('RealmsResource', () => {
  it('create는 payload를 그대로, get/delete는 realm 이름으로 주소를 잡는다', async () => {
    const admin = await AdminClient.create(cfg, provider)
    reply(201, undefined, { location: `${BASE}/new-realm` })
    await admin.realms.create({ realm: 'new-realm', enabled: true })
    expect(sent()).toMatchObject({
      url: `${BASE}/`,
      method: 'POST',
      body: '{"realm":"new-realm","enabled":true}',
    })
    reply(200, { realm: 'new-realm' })
    expect(await admin.realms.get('new-realm')).toEqual({ realm: 'new-realm' })
    expect(sent().url).toBe(`${BASE}/new-realm`)
    reply(404, {})
    await expect(admin.realms.get('nope')).rejects.toThrow('Realm not found: nope')
    await admin.realms.delete('new-realm')
    expect(sent()).toMatchObject({ url: `${BASE}/new-realm`, method: 'DELETE' })
  })

  // ⚠️ 경로(현재 이름)와 body(새 이름)를 **분리**해 넘겨야 rename이 된다.
  it('list는 렐름 컬렉션, update는 현재 이름으로 주소를 잡고 body는 그대로 넘긴다(rename 가능)', async () => {
    const admin = await AdminClient.create(cfg, provider)
    reply(200, [{ realm: 'demo' }, { realm: 'other' }])
    expect(await admin.realms.list()).toHaveLength(2)
    expect(sent()).toMatchObject({ url: `${BASE}/`, method: 'GET' })
    await admin.realms.update('demo', { realm: 'demo-renamed', displayName: 'D' })
    expect(sent()).toMatchObject({
      url: `${BASE}/demo`,
      method: 'PUT',
      body: '{"realm":"demo-renamed","displayName":"D"}',
    })
  })
})

describe('RolesResource (API 편차: 이름으로 주소를 잡는다)', () => {
  it('create, get(name), list, delete(name)', async () => {
    const admin = await AdminClient.create(cfg, provider)
    reply(201, undefined, { location: `${BASE}/demo/roles/admin` })
    await admin.roles.create({ name: 'admin' })
    expect(sent()).toMatchObject({
      url: `${BASE}/demo/roles`,
      method: 'POST',
      body: '{"name":"admin"}',
    })
    reply(200, { name: 'admin' })
    expect(await admin.roles.get('admin')).toEqual({ name: 'admin' })
    expect(sent().url).toBe(`${BASE}/demo/roles/admin`)
    reply(404, {})
    await expect(admin.roles.get('nope')).rejects.toThrow('Role not found: nope')
    reply(200, [{ name: 'admin' }])
    expect(await admin.roles.list()).toHaveLength(1)
    expect(sent().url).toBe(`${BASE}/demo/roles`)
    await admin.roles.delete('admin')
    expect(sent()).toMatchObject({ url: `${BASE}/demo/roles/admin`, method: 'DELETE' })
  })

  // ⚠️ 경로(현재 이름)와 body(새 이름)를 **분리**해 넘겨야 rename이 된다.
  // 경로 인자를 body의 name으로 덮어쓰면 rename이 조용한 no-op이 된다(Go에서 실제로 걸린 함정).
  it('update는 현재 이름으로 주소를 잡고 body는 그대로 넘긴다(rename 가능)', async () => {
    const admin = await AdminClient.create(cfg, provider)
    await admin.roles.update('admin', { name: 'admin-renamed', description: 'x' })
    expect(sent()).toMatchObject({
      url: `${BASE}/demo/roles/admin`,
      method: 'PUT',
      body: '{"name":"admin-renamed","description":"x"}',
    })
  })
})

describe('GroupsResource', () => {
  it('create→id, get(없으면 NotFound), list(first/max), delete', async () => {
    const admin = await AdminClient.create(cfg, provider)
    reply(201, undefined, { location: `${BASE}/demo/groups/g-1` })
    expect(await admin.groups.create({ name: 'team' })).toBe('g-1')
    expect(sent()).toMatchObject({ url: `${BASE}/demo/groups/`, body: '{"name":"team"}' })
    reply(200, { id: 'g-1', name: 'team' })
    expect(await admin.groups.get('g-1')).toEqual({ id: 'g-1', name: 'team' })
    reply(404, {})
    await expect(admin.groups.get('nope')).rejects.toThrow('Group not found: nope')
    reply(200, [{ id: 'g-1' }])
    await admin.groups.list(2, 20)
    expect(sent().url).toBe(`${BASE}/demo/groups/?first=2&max=20`)
    await admin.groups.delete('g-1')
    expect(sent()).toMatchObject({ url: `${BASE}/demo/groups/g-1`, method: 'DELETE' })
  })

  it('update는 id로 주소를 잡고 body는 그대로 넘긴다(rename 가능)', async () => {
    const admin = await AdminClient.create(cfg, provider)
    await admin.groups.update('g-1', { name: 'team-renamed' })
    expect(sent()).toMatchObject({
      url: `${BASE}/demo/groups/g-1`,
      method: 'PUT',
      body: '{"name":"team-renamed"}',
    })
  })
})

describe('close', () => {
  it('resolves (자원 정리 대칭 훅)', async () => {
    const admin = await AdminClient.create(cfg, provider)
    await expect(admin.close()).resolves.toBeUndefined()
  })
})
