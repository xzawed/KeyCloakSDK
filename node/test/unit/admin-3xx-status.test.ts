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
 *
 * 같은 스물다섯 · 같은 토큰 경로로 두 칸을 더 지킨다(실측 2026-11-14: A 300/300 · 대조군 50/50 · B 25/25 — 이미 옳았다).
 *  (A) 객체가 아닌 JSON 오류 본문 — 등록부 `python-admin-list-error-array-body` 의 부류 재스캔(python 은 목록 다섯이 배열
 *      본문의 4xx · 5xx 에 상태 없는 전송 오류다). 404 · 500 × 본문 일곱(대조군 `{"error":"x"}` 과 `[]` · `"boom"` · `42` ·
 *      `true` · `null` · 깊이 100000 의 배열 200,000 바이트): 404 는 `KeycloakNotFoundError` 그 자체(머리말 없음), 500 은
 *      `KeycloakAdminError` 그 자체에 `HTTP 500:` 이고 — 둘 다 필드 `status` 가 그 상태다 — admin 요청은 정확히 하나다.
 *  (B) 따를 수 있는 리다이렉트 — 등록부 `admin-followable-redirect-class-divergent`(go 는 `*TransportError` 로 갈린다).
 *      302 가 `Location: <서버>/redirected-target` 을 달고 그곳은 그 호출의 성공 본문을 200 으로 준다 — 따라가면 성공으로
 *      읽힌다. `KeycloakAdminError` 그 자체에 `status` 302 · `HTTP 302:` · admin 요청 하나 · 대상 요청 0 이어야 한다(`redirect: 'manual'`).
 * 두 칸 모두 틀린 칸을 모아 끝에 한 번 단언한다. `TC_PRINT=1` 이면 `[body]` · `[redirect]` 줄도 찍는다.
 */
import { afterAll, beforeAll, describe, expect, it } from 'vitest'
import {
  type AdminClient,
  KeycloakAdminError,
  KeycloakClient,
  KeycloakNotFoundError,
} from '../../src/index.js'
import { REDIRECTED_PATH, startFakeIdp, type FakeIdp } from './fake-idp.js'

const STATUSES = [300, 302, 399] as const

/** (A) 오류 상태와 오류 본문 — 객체 대조군과 객체가 아닌 JSON 여섯(깊이 100000 의 배열은 200,000 바이트). */
const ERROR_STATUSES = [404, 500] as const
const ERROR_BODIES: ReadonlyArray<readonly [string, string]> = [
  ['object', '{"error":"x"}'],
  ['array', '[]'],
  ['string', '"boom"'],
  ['number', '42'],
  ['boolean', 'true'],
  ['null', 'null'],
  ['deep', '['.repeat(100_000) + ']'.repeat(100_000)],
]

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

/**
 * 이 상태에 node 가 주는 admin 오류인가 — 둘 다 필드 `status` 가 그 상태다. 404 는 `KeycloakNotFoundError` 그 자체(머리말이
 * 없다 — `mapHttpError`), 그 밖은 `KeycloakAdminError` 그 자체에 머리말 `HTTP <상태>:`. 다른 하위 클래스 · 전송 오류 · 값은 아니다.
 */
function isAdminErrorFor(e: unknown, status: number): boolean {
  if (status === 404)
    return (
      e instanceof KeycloakNotFoundError &&
      e.constructor === KeycloakNotFoundError &&
      e.status === 404
    )
  return (
    e instanceof KeycloakAdminError &&
    e.constructor === KeycloakAdminError &&
    e.status === status &&
    statusOf(e) === status
  )
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

describe('객체가 아닌 JSON 오류 본문 — 등록부 python-admin-list-error-array-body 부류 재스캔', () => {
  it('파사드 호출 스물다섯 × 404 · 500 × 본문 일곱 — 그 상태의 오류 클래스로 실패한다', async () => {
    const admin = await kc.admin()
    const wrong: string[] = []
    for (const status of ERROR_STATUSES) {
      for (const [shape, body] of ERROR_BODIES) {
        // 전제 — 서버가 이 상태로 이 본문을 바이트 그대로 `application/json` 으로 보낸다.
        idp.admin = { status, head: body }
        const probe = await fetch(`${idp.origin}/admin/realms/r/users/u1`, { redirect: 'manual' })
        const answered = await probe.text()
        if (
          probe.status !== status ||
          probe.headers.get('content-type') !== 'application/json' ||
          answered !== body
        )
          wrong.push(
            `${status} ${shape} premise: the server answered ${probe.status} · ${String(probe.headers.get('content-type'))} · ${answered.length} chars`,
          )

        let passed = 0
        for (const [name, , run] of OPS) {
          const before = idp.counts.admin
          const r = await run(admin).then(
            (v: unknown) => ({ v }),
            (e: unknown) => ({ e }),
          )
          const sent = idp.counts.admin - before
          const ok = 'e' in r && isAdminErrorFor(r.e, status) && sent === 1
          const line = `${status} ${shape} ${name}: ${outcome(r)} · admin requests ${sent}`
          note(`[body] ${line}`)
          if (ok) passed += 1
          else wrong.push(line)
        }
        note(`[body] ${status} ${shape}: ${passed}/${OPS.length} cells pass`)
      }
    }
    expect(wrong, `${wrong.length} cell(s) wrong:\n${wrong.join('\n')}`).toEqual([])
  }, 60_000)
})

describe('따를 수 있는 리다이렉트 — 등록부 admin-followable-redirect-class-divergent', () => {
  it('파사드 호출 스물다섯 × Location 있는 302 — 따라가지 않고 KeycloakAdminError(302)로 실패한다', async () => {
    const admin = await kc.admin()
    const wrong: string[] = []
    const location = `${idp.origin}${REDIRECTED_PATH}`
    // 전제 — 302 에 그 `Location` 이 있고, 그곳은 200 으로 답한다(따라갔다면 성공으로 읽혔을 응답).
    idp.admin = { status: 302, head: '{}', headers: { location } }
    idp.redirected = { head: JSON.stringify([USER]) }
    const probe = await fetch(`${idp.origin}/admin/realms/r/users`, { redirect: 'manual' })
    await probe.body?.cancel()
    const target = await fetch(location, { redirect: 'manual' })
    await target.body?.cancel()
    if (probe.status !== 302 || probe.headers.get('location') !== location || target.status !== 200)
      wrong.push(
        `premise: the server answered ${probe.status} with Location ${String(probe.headers.get('location'))} · the target ${target.status}`,
      )

    let passed = 0
    for (const [name, body, run] of OPS) {
      idp.redirected = { head: JSON.stringify(body) }
      const before = idp.counts.admin
      const followedBefore = idp.counts.redirected
      const r = await run(admin).then(
        (v: unknown) => ({ v }),
        (e: unknown) => ({ e }),
      )
      const sent = idp.counts.admin - before
      const followed = idp.counts.redirected - followedBefore
      const ok = 'e' in r && isAdminErrorFor(r.e, 302) && sent === 1 && followed === 0
      const line = `302 ${name}: ${outcome(r)} · admin requests ${sent} · target requests ${followed}`
      note(`[redirect] ${line}`)
      if (ok) passed += 1
      else wrong.push(line)
    }
    note(`[redirect] 302: ${passed}/${OPS.length} cells pass`)
    expect(wrong, `${wrong.length} cell(s) wrong:\n${wrong.join('\n')}`).toEqual([])
  })
})
