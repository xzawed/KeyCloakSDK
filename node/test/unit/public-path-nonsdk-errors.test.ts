/**
 * 공개 경로는 SDK 오류만 던진다(§4) — 등록부 `node-nonsdk-error-escapes`.
 *
 * 실측(2026-11-17, 고치기 전): 아래 넷이 SDK 오류 계층 밖의 오류를 공개 API 로 그대로 냈다.
 *   - admin 쓰기의 표현을 JSON 으로 쓸 수 없으면(순환 · BigInt) `JSON.stringify` 의 `TypeError` — 다섯 리소스의
 *     create · update 전부, admin 요청 0. python · ruby · .NET 은 같은 입력을 transport 오류로 낸다(.NET #714 의 문구).
 *   - 생성의 2xx 에 `Location` 이 없거나 마지막 조각이 비면 admin-client 와 같은 문구의 맨 `Error`.
 *   - 경로 인자의 짝 없는 서로게이트는 `encodeURIComponent` 의 `URIError`.
 *   - `exchangeCode` 의 `redirectUri` 가 URL 이 아니면 `new URL` 의 `TypeError: Invalid URL`(discovery 를 부른 뒤).
 *     rust · kotlin(· java 의 인가 요청)은 `invalid redirect_uri: …` 설정 오류로 낸다.
 * 넷 다 요청을 보낼 수 없는 것은 그대로다 — 바뀌는 것은 오류의 계급이다. 그리고 보낼 수 없는 요청은 **네트워크를 타기
 * 전에** 거부한다(토큰 · discovery 요청 0).
 */
import { describe, expect, it } from 'vitest'
import { createServer, type Server } from 'node:http'
import type { AddressInfo } from 'node:net'
import { AdminClient } from '../../src/admin/index.js'
import { AuthClient } from '../../src/auth.js'
import { defineConfig } from '../../src/config.js'
import {
  KeycloakAdminError,
  KeycloakConfigError,
  KeycloakError,
  KeycloakTransportError,
} from '../../src/errors.js'

interface Fake {
  url: string
  seen: string[]
  reply: (method: string, url: string) => { status: number; headers?: Record<string, string> }
  close: () => Promise<void>
}

async function fake(): Promise<Fake> {
  const f: Partial<Fake> = { seen: [] }
  f.reply = () => ({ status: 204 })
  const server: Server = createServer((req, res) => {
    f.seen!.push(`${req.method} ${req.url}`)
    req.resume()
    req.on('end', () => {
      const r = f.reply!(req.method ?? '', req.url ?? '')
      res.writeHead(r.status, r.headers ?? {})
      res.end()
    })
  })
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve))
  f.url = `http://127.0.0.1:${(server.address() as AddressInfo).port}`
  f.close = () => new Promise<void>((resolve) => server.close(() => resolve()))
  return f as Fake
}

function adminOn(url: string, tokens: { n: number }): Promise<AdminClient> {
  return AdminClient.create(
    defineConfig({ serverUrl: url, realm: 'r', clientId: 'c', clientSecret: 's' }),
    {
      getAccessToken: () => {
        tokens.n += 1
        return Promise.resolve('AT')
      },
    },
  )
}

async function failure(p: Promise<unknown>): Promise<unknown> {
  try {
    await p
  } catch (e) {
    return e
  }
  throw new Error('성공했다 — 실패해야 했다')
}

const circular = (): Record<string, unknown> => {
  const o: Record<string, unknown> = { name: 'x' }
  o['self'] = o
  return o
}
const bigint = (): Record<string, unknown> => ({ name: 'x', attributes: { n: [10n] } })

/** 표현을 싣는 쓰기 열 — 다섯 리소스의 create · update. */
const WRITES: ReadonlyArray<
  readonly [string, (a: AdminClient, rep: Record<string, unknown>) => Promise<unknown>]
> = [
  ['users.create', (a, rep) => a.users.create(rep)],
  ['users.update', (a, rep) => a.users.update('u1', rep)],
  ['clients.create', (a, rep) => a.clients.create(rep)],
  ['clients.update', (a, rep) => a.clients.update('c1', rep)],
  ['groups.create', (a, rep) => a.groups.create(rep)],
  ['groups.update', (a, rep) => a.groups.update('g1', rep)],
  ['realms.create', (a, rep) => a.realms.create(rep)],
  ['realms.update', (a, rep) => a.realms.update('r', rep)],
  ['roles.create', (a, rep) => a.roles.create(rep)],
  ['roles.update', (a, rep) => a.roles.update('role1', rep)],
]

describe('admin 쓰기 — JSON 으로 쓸 수 없는 표현', () => {
  for (const [label, call] of WRITES) {
    for (const [kind, rep, causeText] of [
      ['순환', circular, 'Converting circular structure to JSON'],
      ['BigInt', bigint, 'Do not know how to serialize a BigInt'],
    ] as const) {
      it(`${label}(${kind}) 는 KeycloakTransportError 이고 토큰 · admin 요청이 없다`, async () => {
        const srv = await fake()
        const tokens = { n: 0 }
        try {
          const admin = await adminOn(srv.url, tokens)
          const before = tokens.n // AdminClient.create 가 받은 것은 세지 않는다
          srv.seen.length = 0
          const e = await failure(call(admin, rep()))
          expect(e).toBeInstanceOf(KeycloakTransportError)
          expect((e as Error).message).toBe(
            'admin request failed: the request body could not be encoded as JSON',
          )
          // 원인은 남긴다 — 이름 · 메시지(값을 인용하지 않는다: 순환은 생성자 · 속성 이름만, BigInt 는 고정 문구).
          const cause = (e as Error).cause as Error
          expect(cause.name).toBe('TypeError')
          expect(cause.message).toContain(causeText)
          expect(tokens.n - before).toBe(0)
          expect(srv.seen).toEqual([])
        } finally {
          await srv.close()
        }
      })
    }
  }

  it('대조 — 쓸 수 있는 표현은 그대로 요청된다(위의 0 이 「아무것도 안 보냈다」가 아님을)', async () => {
    const srv = await fake()
    const tokens = { n: 0 }
    try {
      const admin = await adminOn(srv.url, tokens)
      const before = tokens.n
      srv.seen.length = 0
      await admin.users.update('u1', { username: 'x' })
      expect(tokens.n - before).toBe(1)
      expect(srv.seen).toEqual(['PUT /admin/realms/r/users/u1'])
    } finally {
      await srv.close()
    }
  })
})

describe('admin 생성 — 2xx 에 쓸 수 있는 Location 이 없다', () => {
  const CREATES: ReadonlyArray<readonly [string, (a: AdminClient) => Promise<unknown>, string]> = [
    ['users.create', (a) => a.users.create({ username: 'x' }), '/admin/realms/r/users/'],
    ['clients.create', (a) => a.clients.create({ clientId: 'x' }), '/admin/realms/r/clients/'],
    ['groups.create', (a) => a.groups.create({ name: 'x' }), '/admin/realms/r/groups/'],
  ]
  for (const [label, call, path] of CREATES) {
    it(`${label}: Location 없음 → KeycloakAdminError(그 상태 · 문구 그대로)`, async () => {
      const srv = await fake()
      srv.reply = () => ({ status: 201 })
      try {
        const e = await failure(call(await adminOn(srv.url, { n: 0 })))
        expect(e).toBeInstanceOf(KeycloakAdminError)
        expect((e as KeycloakAdminError).status).toBe(201)
        expect((e as Error).message).toBe(
          `location header is not found in request: ${srv.url}${path}`,
        )
      } finally {
        await srv.close()
      }
    })
    it(`${label}: Location 의 마지막 조각이 빔 → KeycloakAdminError`, async () => {
      const srv = await fake()
      srv.reply = () => ({ status: 201, headers: { location: 'http://kc/x/' } })
      try {
        const e = await failure(call(await adminOn(srv.url, { n: 0 })))
        expect(e).toBeInstanceOf(KeycloakAdminError)
        expect((e as KeycloakAdminError).status).toBe(201)
        expect((e as Error).message).toBe(
          `resourceId is not found in Location header from request: ${srv.url}${path}`,
        )
      } finally {
        await srv.close()
      }
    })
  }
})

describe('admin 경로 인자 — 짝 없는 서로게이트', () => {
  const PATHS: ReadonlyArray<readonly [string, (a: AdminClient) => Promise<unknown>]> = [
    ['users.get', (a) => a.users.get('u\ud800')],
    ['users.delete', (a) => a.users.delete('\udc00')],
    ['clients.update', (a) => a.clients.update('c\ud800', {})],
    ['roles.get', (a) => a.roles.get('r\ud800')],
    ['groups.delete', (a) => a.groups.delete('g\ud800')],
  ]
  for (const [label, call] of PATHS) {
    it(`${label} 는 KeycloakTransportError 이고 토큰 · admin 요청이 없다`, async () => {
      const srv = await fake()
      const tokens = { n: 0 }
      try {
        const admin = await adminOn(srv.url, tokens)
        const before = tokens.n
        srv.seen.length = 0
        const e = await failure(call(admin))
        expect(e).toBeInstanceOf(KeycloakTransportError)
        expect((e as Error).message).toBe(
          'admin request failed: a path segment holds an unpaired surrogate',
        )
        expect(((e as Error).cause as Error).name).toBe('URIError')
        expect(tokens.n - before).toBe(0)
        expect(srv.seen).toEqual([])
      } finally {
        await srv.close()
      }
    })
  }
})

describe('exchangeCode — URL 이 아닌 redirectUri', () => {
  for (const bad of ['not a url', '', '/callback']) {
    it(`${JSON.stringify(bad)} 는 KeycloakConfigError 이고 discovery 도 부르지 않는다`, async () => {
      const srv = await fake()
      try {
        const auth = new AuthClient(
          defineConfig({ serverUrl: srv.url, realm: 'r', clientId: 'c', clientSecret: 's' }),
        )
        const e = await failure(auth.exchangeCode('code', bad, 'verifier', 'nonce'))
        expect(e).toBeInstanceOf(KeycloakConfigError)
        expect((e as Error).message).toBe('invalid redirect_uri: Invalid URL')
        expect(srv.seen).toEqual([])
      } finally {
        await srv.close()
      }
    })
  }
})

describe('네 자리의 오류가 모두 SDK 계층이다(소비자의 catch 하나가 잡는다)', () => {
  it('KeycloakError 의 하위다', () => {
    for (const C of [KeycloakTransportError, KeycloakAdminError, KeycloakConfigError]) {
      expect(new C('x')).toBeInstanceOf(KeycloakError)
    }
  })
})
