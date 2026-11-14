/**
 * Location 없는 3xx 는 admin 파사드 호출의 성공이 아니다 — 등록부 `go-admin-3xx-read-as-success` 의 부류 재스캔(node).
 *
 * 그 항목에서 go 는 파사드 호출 25 중 24 가 Location 없는 3xx 에 영값을 돌려줬고, php 는 302 에 User 를 돌려줬다. node 의
 * 3xx 는 `admin-response-body.test.ts` 의 오류 본문 열(64 MiB 공백 본문 · 호출 다섯)에서만 쟀다 — 성공 본문 모양이 아니었다.
 *
 * 계약: 파사드 호출 스물다섯(users · clients · realms · roles · groups × 생성 · 단건 · 목록/검색 · 갱신 · 삭제 — 통합 admin
 * 표면 스위트가 도는 그 스물다섯) 각각이 300 · 302(Location 없음) · 399 에 **그 호출의 성공 본문 모양인 JSON**(목록 · 검색은
 * 배열, 나머지는 객체)을 받으면 `KeycloakAdminError` 그 자체로 실패하고 그 상태를 필드 `status` 에 싣고 메시지가
 * `HTTP <그 상태>:` 로 시작한다(`mapHttpError` — 필드는 등록부 node-admin-error-no-status 가 더했다). 값 · null · 빈 목록 · id 를 돌려주면 그
 * 칸은 실패다. 다른 클래스(전송 · 인증 · 404 의 `KeycloakNotFoundError` …)도 실패다 — 본문 모양이 어긋나 난 해석 오류를
 * 「오류」로 받으면 상태를 안 보고도 초록이 된다.
 *
 * 토큰은 SDK 기본 경로(`KeycloakClient.admin()` 의 client-credentials provider)가 가짜 IdP(`fake-idp.ts`)의 토큰
 * 엔드포인트에서 정상으로 받는다. 칸마다 admin 요청이 정확히 하나 나갔는지도 본다 — 요청 없이 난 오류는 그 응답의 판정이
 * 아니다. 전제(서버의 3xx 에 `Location` 이 없다)는 리다이렉트를 따르지 않는 `fetch` 로 상태마다 한 번 잰다. `TC_PRINT=1`
 * 이면 상태마다 통과 수와 칸마다의 결과를 찍는다.
 */
import { afterAll, beforeAll, describe, expect, it } from 'vitest'
import { type AdminClient, KeycloakAdminError, KeycloakClient } from '../../src/index.js'
import { startFakeIdp, type FakeIdp } from './fake-idp.js'

const STATUSES = [300, 302, 399] as const

// 성공 본문 — 리소스 모양의 객체(단건 · 생성 · 갱신 · 삭제)와 그 배열(목록 · 검색).
const USER = { id: 'u1', username: 'alice', enabled: true }
const CLIENT = { id: 'c1', clientId: 'app', enabled: true }
const REALM = { id: 'r', realm: 'r', enabled: true }
const ROLE = { id: 'role-1', name: 'reader', composite: false }
const GROUP = { id: 'g1', name: 'staff', path: '/staff' }

/** 파사드 호출 스물다섯 — 이름 · 그 호출의 성공 본문 · 호출. */
const OPS: ReadonlyArray<readonly [string, unknown, (a: AdminClient) => Promise<unknown>]> = [
  ['users.create', USER, (a) => a.users.create({ username: 'alice' })],
  ['users.get', USER, (a) => a.users.get('u1')],
  ['users.search', [USER], (a) => a.users.search('alice')],
  ['users.update', USER, (a) => a.users.update('u1', { firstName: 'Alice' })],
  ['users.delete', USER, (a) => a.users.delete('u1')],
  ['clients.create', CLIENT, (a) => a.clients.create({ clientId: 'app' })],
  ['clients.get', CLIENT, (a) => a.clients.get('c1')],
  ['clients.findByClientId', [CLIENT], (a) => a.clients.findByClientId('app')],
  ['clients.update', CLIENT, (a) => a.clients.update('c1', { enabled: false })],
  ['clients.delete', CLIENT, (a) => a.clients.delete('c1')],
  ['realms.create', REALM, (a) => a.realms.create({ realm: 'r2' })],
  ['realms.get', REALM, (a) => a.realms.get('r')],
  ['realms.list', [REALM], (a) => a.realms.list()],
  ['realms.update', REALM, (a) => a.realms.update('r', { enabled: true })],
  ['realms.delete', REALM, (a) => a.realms.delete('r2')],
  ['roles.create', ROLE, (a) => a.roles.create({ name: 'reader' })],
  ['roles.get', ROLE, (a) => a.roles.get('reader')],
  ['roles.list', [ROLE], (a) => a.roles.list()],
  ['roles.update', ROLE, (a) => a.roles.update('reader', { description: 'd' })],
  ['roles.delete', ROLE, (a) => a.roles.delete('reader')],
  ['groups.create', GROUP, (a) => a.groups.create({ name: 'staff' })],
  ['groups.get', GROUP, (a) => a.groups.get('g1')],
  ['groups.list', [GROUP], (a) => a.groups.list()],
  ['groups.update', GROUP, (a) => a.groups.update('g1', { name: 'staff2' })],
  ['groups.delete', GROUP, (a) => a.groups.delete('g1')],
]

function note(line: string): void {
  if (process.env['TC_PRINT'] === '1') console.log(line)
}

/** 오류 메시지 머리말의 상태(`HTTP 302: …`) — 없으면 `undefined`. */
function statusOf(e: Error): number | undefined {
  const m = /^HTTP (\d+): /.exec(e.message)
  return m === null ? undefined : Number(m[1])
}

/** 칸 하나의 결과 — 값이면 그 JSON, 오류면 클래스와 머리말의 상태(머리말이 없으면 메시지). */
function outcome(r: { readonly v: unknown } | { readonly e: unknown }): string {
  if ('v' in r) return `returned ${r.v === undefined ? 'undefined' : JSON.stringify(r.v)}`
  if (!(r.e instanceof Error)) return `threw non-Error ${String(r.e)}`
  const status = statusOf(r.e)
  const field = r.e instanceof KeycloakAdminError ? ` status=${String(r.e.status)}` : ''
  return status === undefined
    ? `${r.e.constructor.name}: ${r.e.message}${field}`
    : `${r.e.constructor.name}(${status})${field}`
}

let idp: FakeIdp
let kc: KeycloakClient

beforeAll(async () => {
  idp = await startFakeIdp()
  kc = KeycloakClient.create({
    serverUrl: idp.origin,
    realm: 'r',
    clientId: 'c',
    clientSecret: 's',
  })
})

afterAll(async () => {
  await kc.close()
  await idp.close()
})

describe('Location 없는 3xx — 등록부 go-admin-3xx-read-as-success 부류 재스캔', () => {
  it('파사드 호출 스물다섯 × 300 · 302 · 399 — 성공 본문 모양이어도 KeycloakAdminError(그 상태)로 실패한다', async () => {
    const admin = await kc.admin()
    const wrong: string[] = []
    for (const status of STATUSES) {
      // 전제 — 이 상태의 응답에 `Location` 이 없다(있으면 「Location 없는 3xx」를 잰 것이 아니다).
      idp.admin = { status, head: '{}' }
      const probe = await fetch(`${idp.origin}/admin/realms/r/users/u1`, { redirect: 'manual' })
      await probe.body?.cancel()
      if (probe.status !== status || probe.headers.get('location') !== null)
        wrong.push(
          `${status} premise: the server answered ${probe.status} with Location ${String(probe.headers.get('location'))}`,
        )

      let passed = 0
      for (const [name, body, run] of OPS) {
        idp.admin = { status, head: JSON.stringify(body) }
        const before = idp.counts.admin
        const r = await run(admin).then(
          (v: unknown) => ({ v }),
          (e: unknown) => ({ e }),
        )
        const sent = idp.counts.admin - before
        // 클래스는 `KeycloakAdminError` 그 자체다 — 404 · 409 · 403 의 하위 클래스는 그 상태를 뜻하므로 3xx 에는 틀린 답이다.
        const ok =
          'e' in r &&
          r.e instanceof KeycloakAdminError &&
          r.e.constructor === KeycloakAdminError &&
          r.e.status === status &&
          statusOf(r.e) === status &&
          sent === 1
        note(`[3xx] ${status} ${name}: ${outcome(r)} · admin requests ${sent}`)
        if (ok) passed += 1
        else wrong.push(`${status} ${name}: ${outcome(r)} · admin requests ${sent}`)
      }
      note(`[3xx] ${status}: ${passed}/${OPS.length} cells pass`)
    }
    note(`[3xx] token endpoint requests: ${idp.counts.token}`)
    expect(wrong, `${wrong.length} cell(s) wrong:\n${wrong.join('\n')}`).toEqual([])
  })
})
