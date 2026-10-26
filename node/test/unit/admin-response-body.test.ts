/**
 * admin 파사드가 응답 본문을 얼마나 읽는가 — 등록부 `admin-response-body-unbounded`(node).
 *
 * `@keycloak/keycloak-admin-client` 26.8 은 2xx 가 아니면 `fetchWithError` 가 본문을 통째로 `text()` 로 읽어
 * `NetworkError.responseData` 에 싣고, 쓰기(`update`·`del`)의 2xx 본문도 `parseResponse` 로 끝까지 읽는다(생성은
 * `Location` 만 보고 본문을 그대로 둔다). 파사드는 오류를 상태로 고르고 메시지만 본문에서 꺼내므로, admin-client
 * 메서드를 부르지 않고 같은 요청을 직접 보낸다(`src/admin/http.ts`). 여기서 재는 것:
 *
 * - 오류 본문을 읽지 않는다 — 상태 열 × 호출 다섯, 64 MiB 를 알린 본문.
 * - 머리 뒤에서 멈춘 오류 본문도 상태로 끝난다.
 * - 상한(1,048,576 바이트)까지는 비워 연결을 다시 쓴다 — 정확히 상한이면 연결 하나, 한 바이트 넘으면 둘.
 * - 상한은 푼 바이트를 센다 — 상한 너머로 풀린 gzip 오류 본문이 멈춰도 기다리지 않는다.
 * - 쓰기의 2xx 본문은 읽지 않고 그 연결을 끊는다 — 본문 없는 2xx 는 연결을 다시 쓴다.
 * - ⚠️ `raw()` 는 admin-client 그대로 오류 본문을 끝까지 읽는다 — 남긴 자리다.
 * - 전송 실패의 모양은 전과 같다. `raw().setConfig()` 는 파사드의 목적지와 리다이렉트 금지를 바꾸지 않는다.
 * - 파사드가 admin-client 와 **같은 요청**(메서드 · 요청 대상 · 머리 줄 전부와 그 순서 · 본문 바이트)을 보내고 **같은
 *   결과**(값 · 오류 클래스 · 메시지 · 원인)를 낸다 — 기준은 고치기 전 파사드 코드(main 6a3f8bc 의 `src/admin/*.ts`,
 *   admin-client 위임)를 그대로 옮긴 쌍둥이다.
 *
 * 가짜 서버는 원시 TCP 다 — 서버가 소켓에 넘긴 본문 바이트 · 받은 연결 수 · 첫 연결이 닫혔는지를 센다. 큰 본문은
 * 만들지 않고 정적 공백 버퍼를 조각내 흘려보낸다. 사례마다 새 서버(새 포트)를 쓴다. `TC_PRINT=1` 이면 잰 값을 찍는다.
 */
import { createServer, type AddressInfo, type Socket } from 'node:net'
import { constants as zlibConstants, gzipSync } from 'node:zlib'
import type KcAdminClient from '@keycloak/keycloak-admin-client'
import type ClientRepresentation from '@keycloak/keycloak-admin-client/lib/defs/clientRepresentation.js'
import type GroupRepresentation from '@keycloak/keycloak-admin-client/lib/defs/groupRepresentation.js'
import type RealmRepresentation from '@keycloak/keycloak-admin-client/lib/defs/realmRepresentation.js'
import type RoleRepresentation from '@keycloak/keycloak-admin-client/lib/defs/roleRepresentation.js'
import type UserRepresentation from '@keycloak/keycloak-admin-client/lib/defs/userRepresentation.js'
import { describe, expect, it } from 'vitest'
import { call, requireFound } from '../../src/admin/call.js'
import { AdminClient } from '../../src/admin/index.js'
import { defineConfig } from '../../src/config.js'
import {
  KeycloakAdminError,
  KeycloakConflictError,
  KeycloakForbiddenError,
  KeycloakNotFoundError,
  KeycloakTransportError,
} from '../../src/errors.js'

const CAP = 1_048_576
const MIB = 1024 * 1024
const HUGE = 64 * MIB
const PAD = Buffer.alloc(64 * 1024, 0x20)

const sleep = (ms: number): Promise<void> => new Promise((resolve) => setTimeout(resolve, ms))

function note(line: string): void {
  if (process.env['TC_PRINT'] === '1') console.log(line)
}

// ── 원시 TCP 서버 ────────────────────────────────────────────────────────────────────────

/** 응답 하나. */
interface Reply {
  readonly status: number
  /** 덧붙일 머리 줄(CRLF 없이). */
  readonly headers?: readonly string[]
  /** 본문 — 공백 바이트 수이거나 정해진 바이트(기본 0). */
  readonly body?: number | Buffer
  readonly chunked?: boolean
  /** 멈추기 전에 쓸 본문 바이트(기본 전부). */
  readonly write?: number
  /** `write` 바이트 뒤에 멈출 시간. 청크 본문을 다 썼으면 종결 청크는 그 뒤에 쓰고, 덜 쓴 본문이면 그 뒤 끊는다. */
  readonly holdMs?: number
  /** 머리도 보내지 않는다. */
  readonly silent?: boolean
}

/** 서버가 받은 요청 하나 — 요청 줄의 메서드·대상, 머리 줄(받은 그대로 · 받은 순서), 본문(바이트를 latin1 로). */
interface Seen {
  readonly method: string
  readonly target: string
  readonly head: readonly string[]
  readonly body: string
}

interface Server {
  readonly url: string
  readonly seen: Seen[]
  /** 받은 연결 수. */
  conns(): number
  /** 첫 응답의 본문 바이트 중 소켓이 받아 간 양. */
  wrote(): number
  /** 첫 연결이 닫혔는가. */
  firstClosed(): boolean
  close(): Promise<void>
}

const NOT_FOUND: Reply = { status: 404, body: Buffer.from('{}') }

/** 소켓에 쓴다 — 버퍼가 차면 비워질 때까지 기다리고, 상대가 끊었으면 `false`. */
function put(s: Socket, data: Buffer | string): Promise<boolean> {
  if (s.destroyed) return Promise.resolve(false)
  return new Promise((resolve) => {
    if (s.write(data)) return resolve(true)
    const settle = (ok: boolean) => (): void => {
      s.off('drain', onDrain)
      s.off('close', onClose)
      resolve(ok)
    }
    const onDrain = settle(true)
    const onClose = settle(false)
    s.once('drain', onDrain)
    s.once('close', onClose)
  })
}

async function respond(s: Socket, r: Reply, count: (n: number) => void): Promise<void> {
  if (r.silent === true) return
  const body = r.body ?? 0
  const total = typeof body === 'number' ? body : body.length
  const bodiless = r.status === 204 || r.status === 304
  const framing = bodiless
    ? []
    : r.chunked === true
      ? ['Transfer-Encoding: chunked']
      : [`Content-Length: ${total}`]
  const head = [`HTTP/1.1 ${r.status} X`, 'Content-Type: application/json', ...(r.headers ?? [])]
  if (!(await put(s, `${[...head, ...framing].join('\r\n')}\r\n\r\n`)) || bodiless) return
  const want = Math.min(r.write ?? total, total)
  let sent = 0
  while (sent < want) {
    const n = Math.min(PAD.length, want - sent)
    const piece = typeof body === 'number' ? PAD.subarray(0, n) : body.subarray(sent, sent + n)
    const framed =
      r.chunked === true
        ? Buffer.concat([Buffer.from(`${n.toString(16)}\r\n`), piece, Buffer.from('\r\n')])
        : piece
    if (!(await put(s, framed))) return
    sent += n
    count(n)
  }
  if (r.holdMs !== undefined) await sleep(r.holdMs)
  if (sent < total) return void s.destroy()
  if (r.chunked === true) await put(s, '0\r\n\r\n')
}

/**
 * 연결을 닫지 않고 요청마다 응답하는 서버 — 첫 요청은 `first`, 그 뒤는 `then`(함수면 요청과 순번으로 고른다).
 * 요청은 머리와 알린 길이만큼의 본문을 다 받은 뒤 응답한다.
 */
async function serve(
  first: Reply | ((req: Seen, n: number) => Reply),
  then: Reply = NOT_FOUND,
): Promise<Server> {
  const route =
    typeof first === 'function' ? first : (_req: Seen, n: number): Reply => (n === 0 ? first : then)
  const seen: Seen[] = []
  const sockets = new Set<Socket>()
  let conns = 0
  let served = 0
  let wrote = 0
  let firstClosed = false
  const server = createServer((s) => {
    const index = ++conns
    sockets.add(s)
    s.on('error', () => undefined)
    s.on('close', () => {
      sockets.delete(s)
      if (index === 1) firstClosed = true
    })
    let buf = Buffer.alloc(0)
    let busy = false
    const next = (): void => {
      if (busy) return
      const end = buf.indexOf('\r\n\r\n')
      if (end < 0) return
      const lines = buf.subarray(0, end).toString('latin1').split('\r\n')
      const [method = '', target = ''] = (lines[0] ?? '').split(' ')
      const head = lines.slice(1)
      const length = Number(/^content-length:\s*(\d+)\s*$/im.exec(head.join('\n'))?.[1] ?? 0)
      if (buf.length < end + 4 + length) return
      const req: Seen = {
        method,
        target,
        head,
        body: buf.subarray(end + 4, end + 4 + length).toString('latin1'),
      }
      buf = buf.subarray(end + 4 + length)
      seen.push(req)
      const n = served++
      busy = true
      void respond(s, route(req, n), n === 0 ? (k) => void (wrote += k) : () => undefined).then(
        () => {
          busy = false
          next()
        },
      )
    }
    s.on('data', (d: Buffer) => {
      buf = Buffer.concat([buf, d])
      next()
    })
  })
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve))
  const { port } = server.address() as AddressInfo
  return {
    url: `http://127.0.0.1:${port}`,
    seen,
    conns: () => conns,
    wrote: () => wrote,
    firstClosed: () => firstClosed,
    close: () =>
      new Promise<void>((resolve) => {
        for (const s of sockets) s.destroy()
        server.close(() => resolve())
      }),
  }
}

// ── 호출 ─────────────────────────────────────────────────────────────────────────────────

function adminAt(url: string, readTimeoutMs = 4000, realm = 'r'): Promise<AdminClient> {
  return AdminClient.create(
    defineConfig({ serverUrl: url, realm, clientId: 'c', clientSecret: 's', readTimeoutMs }),
    { getAccessToken: () => Promise.resolve('AT') },
  )
}

/** 파사드 호출 다섯 — 단건 GET · 목록 GET · PUT · POST · DELETE(다섯 리소스에 하나씩). */
const CALLS: ReadonlyArray<readonly [string, (a: AdminClient) => Promise<unknown>]> = [
  ['users.get', (a) => a.users.get('u1')],
  ['clients.findByClientId', (a) => a.clients.findByClientId('app')],
  ['realms.update', (a) => a.realms.update('r', {})],
  ['roles.create', (a) => a.roles.create({ name: 'x' })],
  ['groups.delete', (a) => a.groups.delete('g1')],
]

function kind(e: unknown): string {
  if (e instanceof KeycloakNotFoundError) return 'NotFound'
  if (e instanceof KeycloakConflictError) return 'Conflict'
  if (e instanceof KeycloakForbiddenError) return 'Forbidden'
  if (e instanceof KeycloakAdminError) return `Admin(${/^HTTP (\d+):/.exec(e.message)?.[1] ?? '?'})`
  if (e instanceof KeycloakTransportError) return 'Transport'
  return e instanceof Error ? `${e.name}: ${e.message}` : `non-Error ${String(e)}`
}

function classOf(status: number): string {
  switch (status) {
    case 404:
      return 'NotFound'
    case 409:
      return 'Conflict'
    case 403:
      return 'Forbidden'
    default:
      return `Admin(${status})`
  }
}

/** 호출 하나를 재며 부른다 — 성공이면 `ok`, 실패면 그 분류. */
async function timed(run: () => Promise<unknown>): Promise<{ got: string; ms: number }> {
  const start = performance.now()
  const got = await run().then(() => 'ok', kind)
  return { got, ms: Math.round(performance.now() - start) }
}

/** 첫 연결이 닫힐 때까지 `ms` 동안 기다린다. */
async function closedWithin(srv: Server, ms: number): Promise<boolean> {
  for (let t = 0; t < ms && !srv.firstClosed(); t += 20) await sleep(20)
  return srv.firstClosed()
}

// ── 시험 ─────────────────────────────────────────────────────────────────────────────────

describe('admin 파사드의 응답 본문 — 등록부 admin-response-body-unbounded', () => {
  /**
   * 오류 상태(404 · 409 · 403 · 500 · 3xx 셋 · 그리고 전용 클래스가 없는 400 · 401 · 429)의 본문은 읽지 않는다 —
   * 분류는 상태 그대로이고(`mapHttpError`), 64 MiB 를 알린 본문을 서버가 다 쓰지 못한다. 3xx 는 `redirect: 'manual'`
   * 이라 오류다(따라가지 않는다).
   *
   * 한도 8 MiB(서버가 쓴 양)는 소켓 버퍼 몫이다 — 읽지 않은 응답이라도 커널 버퍼와 undici 의 읽기는 찬다.
   */
  it('오류 본문을 읽지 않는다 — 64 MiB 를 알린 본문, 상태 열 × 호출 다섯', async () => {
    const wrong: string[] = []
    for (const status of [404, 409, 403, 500, 300, 302, 399, 400, 401, 429]) {
      for (const [name, run] of CALLS) {
        const srv = await serve({ status, body: HUGE })
        const a = await adminAt(srv.url)
        const { got, ms } = await timed(() => run(a))
        await sleep(100) // 서버가 끊긴 쓰기를 마치게 한다
        const sent = srv.wrote()
        await srv.close()
        note(`[error] ${name} ${status}: ${ms} ms · server wrote ${sent} · ${got}`)
        if (got !== classOf(status) || sent >= 8 * MIB)
          wrong.push(`${name} ${status}: ${got} · server wrote ${sent} · ${ms} ms`)
      }
    }
    expect(wrong, wrong.join('\n')).toEqual([])
  }, 180_000)

  /**
   * 오류 본문이 머리 뒤에서 멈춰도 **상태로** 끝난다 — 고치기 전에는 admin-client 의 `text()` 가 기한 끝에 실패해
   * `NotFound` 가 아니라 `Transport` 였다.
   *
   * - 상한보다 **한 바이트** 길다고 알린 본문: 읽지 않으므로 기한(4 s)을 기다리지 않는다.
   * - 상한 안이라고 알린 본문(64 KiB): 연결을 다시 쓰려고 비우다 기한(1 s)에 걸린다 — 그래도 분류는 상태다.
   */
  it('머리 뒤에서 멈춘 오류 본문도 상태로 끝난다', async () => {
    const rows: ReadonlyArray<readonly [string, Reply, number, number | undefined]> = [
      [
        '상한보다 한 바이트 길다고 알린 본문',
        { status: 404, body: CAP + 1, write: 65_536, holdMs: 6000 },
        4000,
        2000,
      ],
      [
        '상한 안이라고 알린 본문(64 KiB)',
        { status: 404, body: 65_536, write: 1024, holdMs: 3000 },
        1000,
        undefined,
      ],
    ]
    const wrong: string[] = []
    for (const [row, reply, timeoutMs, maxMs] of rows) {
      for (const [name, run] of CALLS) {
        const srv = await serve(reply)
        const a = await adminAt(srv.url, timeoutMs)
        const { got, ms } = await timed(() => run(a))
        await srv.close()
        note(`[stall] ${row} · ${name}: ${ms} ms · ${got}`)
        if (got !== 'NotFound' || (maxMs !== undefined && ms >= maxMs))
          wrong.push(`${row} · ${name}: ${got} after ${ms} ms`)
      }
    }
    expect(wrong, wrong.join('\n')).toEqual([])
  }, 120_000)

  /**
   * 오류 본문은 상한까지는 **비운다** — 그래야 HTTP/1.1 연결을 다음 요청이 다시 쓴다. 정확히 상한(1,048,576 바이트)이면
   * 두 호출이 연결 하나를 쓰고, 한 바이트 넘으면 둘을 쓴다 — 알린 길이면 읽지 않고, 청크면 상한을 넘는 순간 버린다.
   * 「읽지 않고 버린다」만으로 바꾸면 「연결 하나」 행들이 깨진다. 비우기는 상태와 무관하다(409 · 302 행).
   *
   * 「끝을 늦춘」 행은 종결 청크를 2 s 늦춘다 — 정확히 상한인 본문은 끝까지 기다려 비우고(연결 하나 · 2 s), 한 바이트
   * 넘는 본문은 기다리지 않는다(연결 둘 · 곧바로).
   */
  it('오류 본문은 상한까지 비워 연결을 다시 쓴다 — 정확히 상한이면 연결 하나, 한 바이트 넘으면 둘', async () => {
    const lateEnd = 2000
    const rows: ReadonlyArray<readonly [string, Reply, number, number | undefined]> = [
      ['정확히 상한 · Content-Length', { status: 404, body: CAP }, 1, undefined],
      ['정확히 상한 · Content-Length · 409', { status: 409, body: CAP }, 1, undefined],
      ['정확히 상한 · Content-Length · 302', { status: 302, body: CAP }, 1, undefined],
      ['정확히 상한 · 청크', { status: 404, body: CAP, chunked: true }, 1, undefined],
      [
        '정확히 상한 · 청크, 끝을 늦춘다',
        { status: 404, body: CAP, chunked: true, holdMs: lateEnd },
        1,
        lateEnd - 200,
      ],
      ['한 바이트 넘는다 · Content-Length', { status: 404, body: CAP + 1 }, 2, undefined],
      [
        '한 바이트 넘는다 · 청크, 끝을 늦춘다',
        { status: 404, body: CAP + 1, chunked: true, holdMs: lateEnd },
        2,
        undefined,
      ],
    ]
    const wrong: string[] = []
    for (const [row, reply, wantConns, waitsMs] of rows) {
      const srv = await serve(reply)
      const a = await adminAt(srv.url)
      const { got: first, ms } = await timed(() => a.users.get('u1'))
      // 끝까지 읽은 연결이 풀로 돌아갈 틈을 준다 — 곧장 다음 요청을 내면 새 연결을 맺을 수 있다.
      await sleep(200)
      const { got: second } = await timed(() => a.users.get('u2'))
      const conns = srv.conns()
      await srv.close()
      note(`[drain] ${row}: ${first} in ${ms} ms / ${second} · ${conns} connection(s)`)
      const timingOk = waitsMs !== undefined ? ms >= waitsMs : ms < 1000
      if (
        first !== classOf(reply.status) ||
        second !== 'NotFound' ||
        conns !== wantConns ||
        !timingOk
      )
        wrong.push(
          `${row}: ${first} in ${ms} ms / ${second} · ${conns} connection(s), want ${classOf(reply.status)} · ${wantConns}`,
        )
    }
    expect(wrong, wrong.join('\n')).toEqual([])
  }, 60_000)

  /**
   * 상한은 **푼** 바이트를 센다 — undici 의 fetch 가 `Content-Encoding` 을 푼 뒤의 본문을 읽는다. 압축 스트림을 끝내지
   * 않으므로(SYNC_FLUSH) 받은 만큼은 풀리지만 끝은 오지 않는다 — 다 읽으려는 구현은 기한(4 s)까지 기다린다.
   */
  it('상한은 푼 바이트를 센다 — 상한 너머로 풀린 gzip 오류 본문이 멈춰도 기다리지 않는다', async () => {
    const packed = gzipSync(Buffer.alloc(CAP + 1, 0x20), {
      finishFlush: zlibConstants.Z_SYNC_FLUSH,
    })
    const wrong: string[] = []
    for (const [name, run] of CALLS) {
      const srv = await serve({
        status: 404,
        headers: ['Content-Encoding: gzip'],
        body: packed,
        chunked: true,
        holdMs: 6000,
      })
      const a = await adminAt(srv.url)
      const { got, ms } = await timed(() => run(a))
      await srv.close()
      note(`[gzip] ${name}: ${packed.length} bytes on the wire · ${ms} ms · ${got}`)
      if (got !== 'NotFound' || ms >= 2000) wrong.push(`${name}: ${got} after ${ms} ms`)
    }
    expect(wrong, wrong.join('\n')).toEqual([])
  }, 60_000)

  /**
   * 쓰기(생성 · 갱신 · 삭제)의 2xx 본문은 읽지 않는다 — 생성은 `Location` 의 마지막 조각을 id 로 돌려준다. 64 MiB 를
   * 알린 본문을 서버가 다 쓰지 못하고, 그 연결은 곧바로 끊긴다(쓰지 않는 본문을 쥔 채 두지 않는다). 본문이 오지 않아도
   * 기한(4 s)을 기다리지 않는다.
   */
  it('쓰기의 2xx 본문은 읽지 않고 그 연결을 끊는다', async () => {
    const loc = 'Location: http://kc/admin/realms/r/users/abc-1'
    const rows: ReadonlyArray<
      readonly [string, Reply, (a: AdminClient) => Promise<unknown>, unknown, number | undefined]
    > = [
      [
        'users.create 201 + Location + 64 MiB',
        { status: 201, headers: [loc], body: HUGE },
        (a) => a.users.create({ username: 'x' }),
        'abc-1',
        undefined,
      ],
      [
        'groups.create 201 + Location + 청크 64 MiB',
        { status: 201, headers: [loc], body: HUGE, chunked: true },
        (a) => a.groups.create({ name: 'g' }),
        'abc-1',
        undefined,
      ],
      [
        'realms.create 201 + Location + 64 MiB',
        { status: 201, headers: [loc], body: HUGE },
        (a) => a.realms.create({ realm: 'n' }),
        undefined,
        undefined,
      ],
      [
        'users.update 200 + 64 MiB',
        { status: 200, body: HUGE },
        (a) => a.users.update('u1', {}),
        undefined,
        undefined,
      ],
      [
        'roles.update 200 + 청크 64 MiB',
        { status: 200, body: HUGE, chunked: true },
        (a) => a.roles.update('x', {}),
        undefined,
        undefined,
      ],
      [
        'clients.delete 200 + 64 MiB',
        { status: 200, body: HUGE },
        (a) => a.clients.delete('c1'),
        undefined,
        undefined,
      ],
      [
        'users.create 201 + Location + 알린 1 MiB 뒤 멈춤',
        { status: 201, headers: [loc], body: MIB, write: 0, holdMs: 6000 },
        (a) => a.users.create({ username: 'x' }),
        'abc-1',
        2000,
      ],
      [
        'users.update 200 + 알린 1 MiB 뒤 멈춤',
        { status: 200, body: MIB, write: 0, holdMs: 6000 },
        (a) => a.users.update('u1', {}),
        undefined,
        2000,
      ],
    ]
    const wrong: string[] = []
    for (const [row, reply, run, want, maxMs] of rows) {
      const srv = await serve(reply)
      const a = await adminAt(srv.url)
      const start = performance.now()
      const got = await run(a).then(
        (v) => ({ v }),
        (e: unknown) => ({ e: kind(e) }),
      )
      const ms = Math.round(performance.now() - start)
      const closed = await closedWithin(srv, 1000)
      const sent = srv.wrote()
      await srv.close()
      note(
        `[write] ${row}: ${JSON.stringify(got)} in ${ms} ms · server wrote ${sent} · closed ${closed}`,
      )
      if (
        !('v' in got) ||
        got.v !== want ||
        sent >= 8 * MIB ||
        !closed ||
        (maxMs !== undefined && ms >= maxMs)
      )
        wrong.push(
          `${row}: ${JSON.stringify(got)} in ${ms} ms · server wrote ${sent} · closed ${closed}`,
        )
    }
    expect(wrong, wrong.join('\n')).toEqual([])
  }, 60_000)

  /** 성공 본문에는 상한을 걸지 않는다(정책 — 목록은 정당하게 크다) — 상한의 두 배가 넘는 목록도 다 읽는다. */
  it('성공 본문은 상한 없이 읽는다', async () => {
    const users = Array.from({ length: 100_000 }, (_, i) => ({
      id: `u-${i}`,
      username: `user-${i}`,
    }))
    const body = Buffer.from(JSON.stringify(users))
    const srv = await serve({ status: 200, body })
    const a = await adminAt(srv.url)
    const got = await a.users.search()
    await srv.close()
    expect({ bytes: body.length > 2 * CAP, got: got.length, last: got.at(-1) }).toEqual({
      bytes: true,
      got: users.length,
      last: users.at(-1),
    })
  })

  /** 본문 없는 2xx(Keycloak 26.6 의 쓰기 응답 — `Content-Length: 0` 인 201 · 204)는 끊지 않아 연결을 다시 쓴다. */
  it('본문 없는 2xx 쓰기는 연결을 다시 쓴다', async () => {
    const srv = await serve((_req, n) =>
      n === 0
        ? { status: 201, headers: ['Location: http://kc/admin/realms/r/users/abc-1'] }
        : { status: 204 },
    )
    const a = await adminAt(srv.url)
    const id = await a.users.create({ username: 'x' })
    await sleep(200)
    await a.users.update('u1', {})
    await sleep(200)
    await a.users.delete('u1')
    const conns = srv.conns()
    await srv.close()
    expect({ id, conns }).toEqual({ id: 'abc-1', conns: 1 })
  })

  /**
   * ⚠️ **남긴 자리** — `raw()` 는 admin-client 그대로라 오류 본문을 끝까지 읽어 `NetworkError.responseData` 에 싣는다
   * (`findOne` 의 404 는 다 읽은 뒤 `null`). 상한(1 MiB)을 넘는 2 MiB 도 전부다. 막으려면 `raw()` 의 반환 타입을 바꾸거나
   * 그 요청에 디스패처를 끼워야 한다. 이 시험이 깨지면 admin-client 의 동작이 바뀐 것이니 CHANGELOG 와
   * `src/admin/index.ts` 의 `raw()` 문서를 고친다.
   */
  it('⚠️ 남긴 자리 — raw() 는 admin-client 그대로 오류 본문을 끝까지 읽는다', async () => {
    const found = await serve({ status: 404, body: 2 * MIB })
    const a = await adminAt(found.url)
    const got = await a.raw().users.findOne({ id: 'u1', realm: 'r' })
    await sleep(100)
    const foundWrote = found.wrote()
    await found.close()

    const failed = await serve({ status: 500, body: 2 * MIB })
    const b = await adminAt(failed.url)
    const err = await b
      .raw()
      .users.update({ id: 'u1', realm: 'r' }, {})
      .then(
        () => undefined,
        (e: unknown) => e,
      )
    await failed.close()
    const data = (err as { responseData?: unknown } | undefined)?.responseData
    note(`[raw] findOne 404 + 2 MiB → ${String(got)} · server wrote ${foundWrote}`)
    expect({
      got,
      foundWrote,
      responseDataLength: typeof data === 'string' ? data.length : -1,
    }).toEqual({ got: null, foundWrote: 2 * MIB, responseDataLength: 2 * MIB })
  })

  it('전송 실패는 전처럼 KeycloakTransportError("admin transport failure") 다', async () => {
    const gone = await serve(NOT_FOUND)
    await gone.close() // 닫힌 포트 — 연결 거부
    const mute: Reply = { status: 200, silent: true }
    const silent = await serve(mute, mute) // 머리가 오지 않는다 — 읽기 기한
    const wrong: string[] = []
    for (const [where, url, timeoutMs, causeName] of [
      ['닫힌 포트', gone.url, 4000, 'TypeError'],
      ['머리가 오지 않는다', silent.url, 300, 'TimeoutError'],
    ] as const) {
      const a = await adminAt(url, timeoutMs)
      for (const [name, run] of CALLS) {
        const e = await run(a).then(
          () => undefined,
          (x: unknown) => x,
        )
        const shape =
          e instanceof KeycloakTransportError
            ? `${e.message} | ${e.cause instanceof Error ? e.cause.name : '-'}`
            : kind(e)
        if (shape !== `admin transport failure | ${causeName}`)
          wrong.push(`${where} · ${name}: ${shape}`)
      }
    }
    await silent.close()
    expect(wrong, wrong.join('\n')).toEqual([])
  })

  /**
   * 파사드는 자기 설정(`serverUrl` · `readTimeoutMs` · 리다이렉트 금지)으로 보낸다 — `raw().setConfig()` 가 admin-client
   * 의 `baseUrl` 을 바꾸고 `requestOptions` 를 갈아도(그러면 그 `redirect: 'manual'` 이 빠진다) 파사드의 요청은 그대로다.
   */
  it('raw().setConfig() 는 파사드의 목적지와 리다이렉트 금지를 바꾸지 않는다', async () => {
    const elsewhere = await serve(NOT_FOUND, NOT_FOUND)
    const home = await serve(
      { status: 302, headers: [`Location: ${elsewhere.url}/moved`], body: Buffer.from('{}') },
      NOT_FOUND,
    )
    const a = await adminAt(home.url)
    a.raw().setConfig({ baseUrl: elsewhere.url, realmName: 'other', requestOptions: {} })
    const { got } = await timed(() => a.users.get('u1'))
    const seen = { home: home.seen.map((r) => r.target), elsewhere: elsewhere.seen.length }
    await home.close()
    await elsewhere.close()
    expect({ got, ...seen }).toEqual({
      got: 'Admin(302)',
      home: ['/admin/realms/r/users/u1'],
      elsewhere: 0,
    })
  })
})

// ── 파사드 ↔ admin-client 동등성 ───────────────────────────────────────────────────────────

/** 바이트 0x00–0x7F 전부 + 비ASCII — 경로 조각 인코딩이 admin-client 와 한 바이트라도 다르면 와이어가 갈린다. */
const EVERY = Array.from({ length: 0x80 }, (_, i) => String.fromCharCode(i)).join('') + 'é한😀'

const USER: UserRepresentation = { username: 'ali ce+é', enabled: true, attributes: { k: ['v 1'] } }
/** `realm` 키를 가진 생성 payload — 옛 파사드는 `{ ...rep, realm }` 으로 덮었고 admin-client 가 그 키를 뺐다. */
const USER_WITH_REALM = { username: 'u', realm: 'shadow' } as UserRepresentation
const CLIENT: ClientRepresentation = { clientId: 'c 1', redirectUris: ['https://x/cb'] }
const REALM: RealmRepresentation = { realm: 'new name', enabled: true }
const ROLE: RoleRepresentation = { name: 'new role', description: 'd' }
const GROUP: GroupRepresentation = { name: 'g 1' }

type Facade = (a: AdminClient, arg: string) => Promise<unknown>
type Twin = (kc: KcAdminClient, realm: string, arg: string) => Promise<unknown>

/** 경로·쿼리에 들어가는 인자 — 모든 바이트 · 점 조각 둘(URL 이 정규화한다) · 빈 문자열 · 평범한 값 · 짝 없는 서로게이트. */
const ARGS = [EVERY, '..', '.', '', 'plain', '\uD800']
const NO_ARG = ['-']

/**
 * 파사드 호출과 그 쌍둥이 — 쌍둥이는 고치기 전 파사드 코드(main 6a3f8bc 의 `src/admin/*.ts`)를 `raw()` 위에서 그대로
 * 부른다. 기본 인자도 그때의 것(`search` 0·100 · `list` 0·100)이다.
 */
const PAIRS: ReadonlyArray<readonly [string, readonly string[], Facade, Twin]> = [
  [
    'users.create',
    NO_ARG,
    (a) => a.users.create(USER),
    async (kc, realm) => (await call(() => kc.users.create({ ...USER, realm }))).id,
  ],
  [
    'users.create(realm 키)',
    NO_ARG,
    (a) => a.users.create(USER_WITH_REALM),
    async (kc, realm) => (await call(() => kc.users.create({ ...USER_WITH_REALM, realm }))).id,
  ],
  [
    'users.get',
    ARGS,
    (a, id) => a.users.get(id),
    async (kc, realm, id) =>
      requireFound(await call(() => kc.users.findOne({ id, realm })), `User not found: ${id}`),
  ],
  [
    'users.search',
    ARGS,
    (a, u) => a.users.search(u, 40, 25),
    (kc, realm, u) => call(() => kc.users.find({ realm, username: u, first: 40, max: 25 })),
  ],
  [
    'users.search()',
    NO_ARG,
    (a) => a.users.search(),
    (kc, realm) => call(() => kc.users.find({ realm, username: undefined, first: 0, max: 100 })),
  ],
  [
    'users.search(null) — JS',
    NO_ARG,
    (a) => a.users.search(null as never),
    (kc, realm) =>
      call(() => kc.users.find({ realm, username: null as never, first: 0, max: 100 })),
  ],
  [
    'users.update',
    ARGS,
    (a, id) => a.users.update(id, USER),
    async (kc, realm, id) => {
      await call(() => kc.users.update({ id, realm }, USER))
    },
  ],
  [
    'users.delete',
    ARGS,
    (a, id) => a.users.delete(id),
    async (kc, realm, id) => {
      await call(() => kc.users.del({ id, realm }))
    },
  ],
  [
    'clients.create',
    NO_ARG,
    (a) => a.clients.create(CLIENT),
    async (kc, realm) => (await call(() => kc.clients.create({ ...CLIENT, realm }))).id,
  ],
  [
    'clients.get',
    ARGS,
    (a, id) => a.clients.get(id),
    async (kc, realm, id) =>
      requireFound(await call(() => kc.clients.findOne({ id, realm })), `Client not found: ${id}`),
  ],
  [
    'clients.findByClientId',
    ARGS,
    (a, c) => a.clients.findByClientId(c),
    (kc, realm, c) => call(() => kc.clients.find({ realm, clientId: c })),
  ],
  [
    'clients.update',
    ARGS,
    (a, id) => a.clients.update(id, CLIENT),
    async (kc, realm, id) => {
      await call(() => kc.clients.update({ id, realm }, CLIENT))
    },
  ],
  [
    'clients.delete',
    ARGS,
    (a, id) => a.clients.delete(id),
    async (kc, realm, id) => {
      await call(() => kc.clients.del({ id, realm }))
    },
  ],
  [
    'realms.create',
    NO_ARG,
    (a) => a.realms.create(REALM),
    async (kc) => {
      await call(() => kc.realms.create(REALM))
    },
  ],
  [
    'realms.get',
    ARGS,
    (a, r) => a.realms.get(r),
    async (kc, _realm, r) =>
      requireFound(await call(() => kc.realms.findOne({ realm: r })), `Realm not found: ${r}`),
  ],
  ['realms.list', NO_ARG, (a) => a.realms.list(), (kc) => call(() => kc.realms.find())],
  [
    'realms.update',
    ARGS,
    (a, r) => a.realms.update(r, REALM),
    async (kc, _realm, r) => {
      await call(() => kc.realms.update({ realm: r }, REALM))
    },
  ],
  [
    'realms.delete',
    ARGS,
    (a, r) => a.realms.delete(r),
    async (kc, _realm, r) => {
      await call(() => kc.realms.del({ realm: r }))
    },
  ],
  [
    'roles.create',
    NO_ARG,
    (a) => a.roles.create(ROLE),
    async (kc, realm) => {
      await call(() => kc.roles.create({ ...ROLE, realm }))
    },
  ],
  [
    'roles.get',
    ARGS,
    (a, n) => a.roles.get(n),
    async (kc, realm, n) =>
      requireFound(
        await call(() => kc.roles.findOneByName({ name: n, realm })),
        `Role not found: ${n}`,
      ),
  ],
  [
    'roles.list',
    NO_ARG,
    (a) => a.roles.list(),
    (kc, realm) => call(() => kc.roles.find({ realm })),
  ],
  [
    'roles.update',
    ARGS,
    (a, n) => a.roles.update(n, ROLE),
    async (kc, realm, n) => {
      await call(() => kc.roles.updateByName({ name: n, realm }, ROLE))
    },
  ],
  [
    'roles.delete',
    ARGS,
    (a, n) => a.roles.delete(n),
    async (kc, realm, n) => {
      await call(() => kc.roles.delByName({ name: n, realm }))
    },
  ],
  [
    'groups.create',
    NO_ARG,
    (a) => a.groups.create(GROUP),
    async (kc, realm) => (await call(() => kc.groups.create({ ...GROUP, realm }))).id,
  ],
  [
    'groups.get',
    ARGS,
    (a, id) => a.groups.get(id),
    async (kc, realm, id) =>
      requireFound(await call(() => kc.groups.findOne({ id, realm })), `Group not found: ${id}`),
  ],
  [
    'groups.list',
    NO_ARG,
    (a) => a.groups.list(1, 2),
    (kc, realm) => call(() => kc.groups.find({ realm, first: 1, max: 2 })),
  ],
  [
    'groups.list()',
    NO_ARG,
    (a) => a.groups.list(),
    (kc, realm) => call(() => kc.groups.find({ realm, first: 0, max: 100 })),
  ],
  [
    'groups.update',
    ARGS,
    (a, id) => a.groups.update(id, GROUP),
    async (kc, realm, id) => {
      await call(() => kc.groups.update({ id, realm }, GROUP))
    },
  ],
  [
    'groups.delete',
    ARGS,
    (a, id) => a.groups.delete(id),
    async (kc, realm, id) => {
      await call(() => kc.groups.del({ id, realm }))
    },
  ],
  // JS 호출자 — 타입이 막는 값도 고치기 전과 같다: url-template 은 null·undefined 를 빈 조각으로 펴고, admin-client 의
  // 기본 인자는 undefined 만 `{}` 로 바꾸며, null payload 는 그 `omit` 이 TypeError 로 던진다.
  [
    'users.get(undefined) — JS',
    NO_ARG,
    (a) => a.users.get(undefined as never),
    async (kc, realm) =>
      requireFound(
        await call(() => kc.users.findOne({ id: undefined as never, realm })),
        'User not found: undefined',
      ),
  ],
  [
    'roles.get(null) — JS',
    NO_ARG,
    (a) => a.roles.get(null as never),
    async (kc, realm) =>
      requireFound(
        await call(() => kc.roles.findOneByName({ name: null as never, realm })),
        'Role not found: null',
      ),
  ],
  [
    'users.update(undefined) — JS',
    NO_ARG,
    (a) => a.users.update('u1', undefined as never),
    async (kc, realm) => {
      await call(() => kc.users.update({ id: 'u1', realm }, undefined as never))
    },
  ],
  [
    'groups.update(null) — JS',
    NO_ARG,
    (a) => a.groups.update('g1', null as never),
    async (kc, realm) => {
      await call(() => kc.groups.update({ id: 'g1', realm }, null as never))
    },
  ],
  [
    'users.create(null) — JS',
    NO_ARG,
    (a) => a.users.create(null as never),
    async (kc, realm) => {
      const representation = null as unknown as UserRepresentation
      return (await call(() => kc.users.create({ ...representation, realm }))).id
    },
  ],
  [
    'realms.create(undefined) — JS',
    NO_ARG,
    (a) => a.realms.create(undefined as never),
    async (kc) => {
      await call(() => kc.realms.create(undefined as never))
    },
  ],
  [
    'realms.create(null) — JS',
    NO_ARG,
    (a) => a.realms.create(null as never),
    async (kc) => {
      await call(() => kc.realms.create(null as never))
    },
  ],
]

type Script = (req: Seen, origin: string) => Reply

const json = (status: number, value: unknown, headers: string[] = []): Reply => ({
  status,
  headers,
  body: Buffer.from(JSON.stringify(value)),
})
const text = (status: number, s: string, headers: string[] = []): Reply => ({
  status,
  headers,
  body: Buffer.from(s),
})

/** 성공 — GET 은 JSON, POST 는 201 + Location(요청 경로 + `/new-id`), 그 밖은 204. */
const success: Script = (req, origin) =>
  req.method === 'GET'
    ? json(200, [{ id: 'x1', name: 'n' }])
    : req.method === 'POST'
      ? {
          status: 201,
          headers: [
            `Location: ${origin}${(req.target.split('?')[0] ?? '').replace(/\/$/, '')}/new-id`,
          ],
        }
      : { status: 204 }

/** 응답 대본 — 모든 요청에 같은 응답(성공 대본과 GET 만 바꾼 둘은 메서드로 고른다). */
const SCRIPTS: ReadonlyArray<readonly [string, Script]> = [
  ['성공', success],
  ['409 errorMessage', () => json(409, { errorMessage: 'User exists with same username' })],
  // 메시지는 errorMessage 가, 원인의 메시지는 error 가 먼저다 — 둘 다 문자열일 때만 갈린다.
  ['409 둘 다', () => json(409, { errorMessage: 'first', error: 'second' })],
  ['403 error', () => json(403, { error: 'unknown_error' })],
  ['404 error', () => json(404, { error: 'Could not find user' })],
  ['500 평문', () => text(500, 'boom (not json)')],
  ['400 빈 본문', () => text(400, '')],
  ['401 errorMessage 가 숫자', () => json(401, { errorMessage: 7, error: 'x' })],
  ['302 + Location', () => json(302, { error: 'moved' }, ['Location: http://elsewhere.invalid/'])],
  ['404 null', () => text(404, 'null')],
  ['429 배열', () => json(429, ['a'])],
  [
    'GET 200 평문',
    (req, origin) => (req.method === 'GET' ? text(200, 'hello') : success(req, origin)),
  ],
  [
    'GET 200 null',
    (req, origin) => (req.method === 'GET' ? text(200, 'null') : success(req, origin)),
  ],
  ['200 빈 본문', () => text(200, '')],
  ['201 Location 이 / 로 끝난다', () => ({ status: 201, headers: ['Location: http://kc/x/'] })],
  ['201 Location 없음', () => ({ status: 201 })],
  ['204 본문 없음', () => ({ status: 204 })],
  ['304 본문 없음', () => ({ status: 304 })],
  // 본문이 없는 상태도 길이를 알릴 수 있다 — 상한보다 길다고 알려도 취소할 본문이 없다.
  ['304 + 알린 2 MB', () => ({ status: 304, headers: ['Content-Length: 2000000'] })],
]

/** 결과 하나 — 값이면 그 JSON, 오류면 클래스 · 메시지 · 원인(이름 · 메시지). */
function settle(p: Promise<unknown>): Promise<string> {
  return p.then(
    (v) => `ok ${v === undefined ? 'undefined' : JSON.stringify(v)}`,
    (e: unknown) => {
      if (!(e instanceof Error)) return `non-Error ${String(e)}`
      const c: unknown = e.cause
      const cause =
        c instanceof Error ? `${c.name}: ${c.message}` : c === undefined ? '-' : String(c)
      return `${e.constructor.name}: ${e.message} | cause ${cause}`
    },
  )
}

const wire = (r: Seen): string => `${r.method} ${r.target}\n${r.head.join('\n')}\n\n${r.body}`

describe('파사드 ↔ admin-client 동등성', () => {
  /**
   * 파사드 호출(다섯 리소스 × 다섯 + 생성 payload 의 `realm` 키 · 기본 인자 둘 · 타입이 막는 JS 값 null·undefined)을 그 쌍둥이와
   * 같은 서버에 보내 와이어와 결과를 대조한다. 경로 인자 여섯은 성공 대본에서만 돌리고(인코딩은 대본과 무관하다), 나머지
   * 대본은 모든 바이트 인자로 돈다. 서버 주소에 `/auth` 를 붙이고 realm 도 모든 바이트다.
   */
  it('파사드는 admin-client 와 같은 요청을 보내고 같은 결과를 낸다 — 고치기 전 파사드가 기준', async () => {
    let script: Script = success
    let origin = ''
    const srv = await serve((req) => script(req, origin))
    origin = srv.url
    const a = await adminAt(`${srv.url}/auth`, 4000, EVERY)
    const kc = a.raw()
    const diffs: string[] = []
    let pairs = 0
    for (const [scriptName, s] of SCRIPTS) {
      script = s
      for (const [label, args, facade, twin] of PAIRS) {
        for (const arg of scriptName === '성공' ? args : args.slice(0, 1)) {
          srv.seen.length = 0
          const mine = await settle(facade(a, arg))
          const mineWire = srv.seen.splice(0).map(wire)
          const theirs = await settle(twin(kc, EVERY, arg))
          const theirsWire = srv.seen.splice(0).map(wire)
          pairs += 1
          const where = `${scriptName} · ${label}(${JSON.stringify(arg)})`
          if (mine !== theirs) diffs.push(`${where}: result\n  facade ${mine}\n  twin   ${theirs}`)
          if (JSON.stringify(mineWire) !== JSON.stringify(theirsWire))
            diffs.push(
              `${where}: wire\n  facade ${JSON.stringify(mineWire)}\n  twin   ${JSON.stringify(theirsWire)}`,
            )
          // 비어 있는 와이어끼리의 일치는 증거가 아니다 — 요청 전에 실패하는 것은 경로 조각의 서로게이트(URIError)와 JS
          // 호출자의 null 생성 payload(TypeError)뿐이다.
          if (theirsWire.length !== 1 && !/^(URIError|TypeError): /.test(theirs))
            diffs.push(`${where}: twin sent ${theirsWire.length} request(s) — ${theirs}`)
        }
      }
    }
    await srv.close()
    note(`[wire] ${pairs} pairs`)
    expect(diffs, diffs.slice(0, 12).join('\n\n')).toEqual([])
  }, 120_000)
})
