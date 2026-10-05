/**
 * admin 의 Bearer 가 HTTP 헤더에 실릴 수 없을 때 — §4(하위·런타임 예외가 공개 API 로 새지 않는다)와 보안 기본선
 * (오류의 메시지·원인 사슬·스택에 토큰이 없다). 진짜 admin-client 를 프로세스 안 가짜 IdP(`fake-idp.ts`)에 붙인다.
 *
 * 수정 전(실측 2026-10-05, header-case.mjs): 토큰 엔드포인트가 준 access token 에 LF·CR·NUL 이 있으면 모든 admin
 * 호출이 raw `TypeError: Headers.append: "Bearer <토큰 전체>" is an invalid header value.` 를 냈고 — 메시지·스택·
 * `inspect` 가 토큰을 통째로 인용했다 — U+00FF 를 넘는 문자(U+0100 · 짝 없는 서로게이트 · 잘못된 UTF-8 이 풀린
 * U+FFFD)면 raw `TypeError: Cannot convert argument to a ByteString …` 였다. 요청은 나가지 않았다(admin 0 건).
 * `call()` 은 원인 없는 `TypeError` 를 전송 오류가 아니라 보고 그대로 다시 던졌다.
 *
 * 고친 자리: admin-client 가 헤더를 짓기 직전의 SDK 쪽 마지막 자리 — `AdminClient.create` 가 등록하는 토큰
 * 공급자(요청마다)와 생성 때의 토큰 확보. 같은 플랫폼 `Headers` 로 먼저 물어 실을 수 없으면 토큰을 담지 않은
 * `KeycloakAuthError` 로 거부한다. 거르는 것은 **플랫폼이 거부하는 것과 정확히 같다** — 플랫폼이 실어 보내는 값
 * (U+00E9 같은 Latin-1, 끝의 공백·LF 는 플랫폼이 다듬어 보낸다)은 지금처럼 보낸다. 값은 고쳐 쓰지 않는다.
 */
import { inspect } from 'node:util'
import { afterAll, afterEach, beforeAll, describe, expect, it } from 'vitest'
import {
  AdminClient,
  defineConfig,
  KeycloakAuthError,
  KeycloakClient,
  KeycloakError,
} from '../../src/index.js'
import { startFakeIdp, tokenResponse, type FakeIdp } from './fake-idp.js'

const REFUSED =
  'admin access token cannot be sent: an HTTP header cannot carry it (it holds CR, LF, NUL or a character above U+00FF)'

let idp: FakeIdp

beforeAll(async () => {
  idp = await startFakeIdp()
})

afterAll(async () => {
  await idp.close()
})

afterEach(() => {
  idp.token = { head: tokenResponse('access') }
})

function client(): KeycloakClient {
  return KeycloakClient.create({
    serverUrl: idp.origin,
    realm: 'r',
    clientId: 'c',
    clientSecret: 's',
  })
}

/** 토큰 엔드포인트가 이 JSON 문자열 리터럴(이스케이프 그대로)을 access_token 으로 돌려준다. */
function serveToken(jsonLiteral: string, expiresIn = 300): void {
  idp.token = {
    head: `{"access_token":${jsonLiteral},"token_type":"Bearer","expires_in":${expiresIn}}`,
  }
}

/** 오류의 메시지·스택·원인 사슬(메시지·스택)·깊이 무제한 inspect — 어디에도 `secret` 이 없어야 한다. */
function renderings(e: Error): string[] {
  const out = [e.message, e.stack ?? '', inspect(e, { depth: Infinity })]
  for (let c: unknown = e.cause, i = 0; c instanceof Error && i < 10; c = c.cause, i += 1) {
    out.push(c.message, c.stack ?? '')
  }
  return out
}

async function refusal(call: Promise<unknown>): Promise<Error> {
  const outcome = await call.then(
    () => undefined,
    (e: unknown) => e,
  )
  if (!(outcome instanceof Error)) throw new Error('expected a refusal, got success')
  return outcome
}

/** JSON 문자열 리터럴 → 헤더에 실을 수 없는 access token. 전부 `SECRET` 으로 시작한다(누출 검사의 카나리아). */
const UNSENDABLE: ReadonlyArray<readonly [label: string, jsonLiteral: string]> = [
  ['LF 가 안에 있다', '"SECRETabc\\ndef"'],
  ['CR 이 안에 있다', '"SECRETabc\\rdef"'],
  ['NUL 이 있다', '"SECRETabc\\u0000def"'],
  ['U+0100(> U+00FF)', '"SECRETabc\\u0100def"'],
  ['짝 없는 서로게이트 U+D800', '"SECRETabc\\ud800def"'],
  ['U+FFFD(잘못된 UTF-8 이 풀린 값)', '"SECRETabc\\ufffddef"'],
]

describe('admin — 헤더에 실을 수 없는 Bearer 는 토큰 없는 SDK 오류', () => {
  it.each(UNSENDABLE)(
    '%s — admin() 이 요청 없이 KeycloakAuthError 로 거부한다',
    async (_label, literal) => {
      serveToken(literal)
      const before = idp.counts.admin
      const refused = await refusal(client().admin())
      expect(refused).toBeInstanceOf(KeycloakAuthError)
      expect(refused.message).toBe(REFUSED)
      // 원인도 없다 — 플랫폼 오류를 원인으로 달면 U+0100·서로게이트·U+FFFD 의 ByteString 오류는 토큰을 인용하지
      // 않아 아래 누출 검사로는 보이지 않는다(그 변이에서 그 셋이 두 블록 모두 살아남았다).
      expect(refused.cause).toBeUndefined()
      expect(idp.counts.admin).toBe(before)
      for (const text of renderings(refused)) expect(text).not.toContain('SECRET')
    },
  )

  // 만료 뒤 다시 받은 토큰이 실을 수 없는 값이어도 같다 — 요청마다 등록된 공급자를 지난다. 수정 전에는 여기서 raw
  // `TypeError` 가 토큰을 통째로 인용했다.
  it.each(UNSENDABLE)(
    '%s — 다시 받은 토큰이면 admin 호출이 요청 없이 같은 오류',
    async (_label, literal) => {
      serveToken('"first"', 10) // expires_in ≤ skew(30 초) — provider 캐시가 곧바로 만료돼 다음 호출이 다시 받는다
      const admin = await client().admin()
      serveToken(literal)
      const before = idp.counts.admin
      for (const call of [
        () => admin.realms.list(),
        () => admin.users.search('u'),
        () => admin.raw().realms.find(),
      ]) {
        const refused = await refusal(call())
        expect(refused).toBeInstanceOf(KeycloakAuthError)
        expect(refused.message).toBe(REFUSED)
        expect(refused.cause).toBeUndefined()
        for (const text of renderings(refused)) expect(text).not.toContain('SECRET')
      }
      expect(idp.counts.admin).toBe(before)
    },
  )

  it('소비자가 주입한 TokenProvider 도 같은 자리를 지난다', async () => {
    const config = defineConfig({
      serverUrl: idp.origin,
      realm: 'r',
      clientId: 'c',
      clientSecret: 's',
    })
    const refused = await refusal(
      AdminClient.create(config, { getAccessToken: () => Promise.resolve('SECRETabc\ndef') }),
    )
    expect(refused).toBeInstanceOf(KeycloakAuthError)
    expect(refused.message).toBe(REFUSED)
    expect(refused.cause).toBeUndefined()
    for (const text of renderings(refused)) expect(text).not.toContain('SECRET')
  })
})

/**
 * 거르는 것은 플랫폼이 거부하는 것과 정확히 같다 — 그 밖은 지금처럼 보낸다(값을 고쳐 쓰지 않고, 막지도 않는다).
 * ⚠️ 이 대조군을 지우지 말 것 — 위 시험들은 「Bearer 를 전부 거부한다」로도 통과한다.
 */
describe('대조군 — 플랫폼이 실어 보내는 Bearer 는 그대로 나간다', () => {
  const sent = async (literal: string): Promise<string | undefined> => {
    serveToken(literal)
    const before = idp.counts.admin
    await (await client().admin()).realms.list()
    expect(idp.counts.admin).toBe(before + 1)
    return idp.last.adminAuthorization
  }

  it('Keycloak 26.6 의 가장 긴 기본 Bearer(65,459 바이트)', async () => {
    const token = `eyJ${'a'.repeat(65_459 - 3)}`
    expect(await sent(JSON.stringify(token))).toBe(`Bearer ${token}`)
  })

  it('U+00E9(Latin-1) — 플랫폼은 그 바이트로 보낸다', async () => {
    expect(Buffer.from((await sent('"abc\\u00e9def"')) ?? '', 'latin1').toString('hex')).toBe(
      Buffer.from('Bearer abcédef', 'latin1').toString('hex'),
    )
  })

  it('끝의 공백·LF — 플랫폼이 다듬어 보낸다(지금과 같다)', async () => {
    expect(await sent('"abcdef "')).toBe('Bearer abcdef')
    expect(await sent('"abcdef\\n"')).toBe('Bearer abcdef')
  })
})

/** 헤더 한도를 넘는 Bearer — 전송·서버가 거부하고, 그것은 이미 SDK 오류였다. 토큰을 싣지 않는지를 잰다. */
describe('헤더 한도를 넘는 Bearer', () => {
  it('200,000 바이트 — SDK 오류이고 오류 어디에도 토큰이 없다', async () => {
    serveToken(JSON.stringify(`SECRET${'a'.repeat(200_000 - 6)}`))
    const admin = await client().admin()
    const refused = await refusal(admin.realms.list())
    expect(refused).toBeInstanceOf(KeycloakError)
    // 여기는 원인이 있다 — `call()` 이 전송 실패·HTTP 오류를 원인으로 감싼다. 그래서 원인 없음이 아니라 사슬을 본다.
    for (const text of renderings(refused)) expect(text).not.toContain('SECRETaaaa')
  })
})

/**
 * 토큰을 **폼 본문**에 싣는 auth 호출(introspect · refresh · logout)은 헤더가 아니라 퍼센트 인코딩이라 LF·NUL·
 * U+0100 도 그대로 나간다(실측 header-case.mjs: 서버가 받은 바이트 0a·00·c480). 이 자리는 바꾸지 않았다 — 그대로
 * 나가는지를 고정한다.
 */
describe('폼 본문으로 토큰을 보내는 auth 호출은 바꾸지 않았다', () => {
  it.each([
    ['LF', 'SECRETabc\ndef'],
    ['NUL', 'SECRETabc\u0000def'],
    ['U+0100', 'SECRETabcĀdef'],
  ])('%s — introspect·refresh 가 그 값을 그대로 보낸다', async (_label, value) => {
    const kc = client()
    await expect(kc.auth.introspect(value)).resolves.toMatchObject({ active: true })
    expect(idp.last.introspectToken).toBe(value)
    await expect(kc.auth.refresh(value)).resolves.toMatchObject({ accessToken: 'access' })
    expect(idp.last.refreshToken).toBe(value)
    await expect(kc.auth.logout(value)).resolves.toBeUndefined()
  })
})
