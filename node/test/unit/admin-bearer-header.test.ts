/**
 * admin 이 보낼 수 없는 Bearer — §4(하위·런타임 예외가 공개 API 로 새지 않는다)와 보안 기본선
 * (오류의 메시지·원인 사슬·스택에 토큰이 없다). 진짜 admin-client 를 프로세스 안 가짜 IdP(`fake-idp.ts`)에 붙인다.
 *
 * 수정 전(실측 2026-10-05, header-case.mjs): 토큰 엔드포인트가 준 access token 에 LF·CR·NUL 이 있으면 모든 admin
 * 호출이 raw `TypeError: Headers.append: "Bearer <토큰 전체>" is an invalid header value.` 를 냈고 — 메시지·스택·
 * `inspect` 가 토큰을 통째로 인용했다 — U+00FF 를 넘는 문자(U+0100 · 짝 없는 서로게이트 · 잘못된 UTF-8 이 풀린
 * U+FFFD)면 raw `TypeError: Cannot convert argument to a ByteString …` 였다. 요청은 나가지 않았다(admin 0 건).
 * `call()` 은 원인 없는 `TypeError` 를 전송 오류가 아니라 보고 그대로 다시 던졌다.
 *
 * 지금(결정 2026-10-29, 등록부 `bearer-token-grammar-divergent` — 아홉 언어 같은 규칙): `sendableBearer`
 * (`src/token-provider.ts`)가 앞뒤의 SP·HTAB·CR·LF 만 떼고, 남은 값이 RFC 6750 `b64token` 이 아니면 토큰을 담지
 * 않은 `KeycloakAuthError` 로 요청 없이 거부한다. 지나는 자리 — 파사드의 요청(`http.ts`) · `AdminClient.create` 가
 * `raw()` 에 등록하는 공급자(요청마다) · 생성 때의 토큰 확보 · 공개 provider 의 캐시. 플랫폼이 실어 보내던 Latin-1·
 * 안쪽 공백도 이제 거부하고, 끝 개행은 undici 가 아니라 SDK 가 떼어 보낸다(뗀 값을 보낸다).
 */
import { inspect } from 'node:util'
import { SignJWT } from 'jose'
import { afterAll, afterEach, beforeAll, describe, expect, it, vi } from 'vitest'
import {
  AdminClient,
  AuthClient,
  ClientCredentialsTokenProvider,
  defineConfig,
  KeycloakAuthError,
  KeycloakClient,
  KeycloakError,
  TokenSet,
  type TokenProvider,
} from '../../src/index.js'
import { startFakeIdp, tokenResponse, type FakeIdp } from './fake-idp.js'

const REFUSED = 'admin access token cannot be sent: it is not an RFC 6750 bearer token (b64token)'

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

/**
 * 아홉 언어 같은 표(결정 2026-10-29, 등록부 `bearer-token-grammar-divergent`) — 앞뒤의 SP·HTAB·CR·LF 넷만 떼고,
 * 남은 값이 RFC 6750 `b64token`(`^[A-Za-z0-9\-._~+/]+=*$`)이면 **뗀 값**을 Bearer 로 보내고, 아니면 요청 없이
 * `KeycloakAuthError` 다. 경로 다섯 — 파사드 · `raw()` · 생성 때의 토큰 확보 · 공개 provider(소비자 소스) · SDK
 * provider(AuthClient · 가짜 IdP). 마지막 둘은 거부한 토큰을 캐시하지 않는다.
 */
const JWS = await new SignJWT({ sub: 'u1' })
  .setProtectedHeader({ alg: 'HS256', typ: 'JWT' })
  .sign(new TextEncoder().encode('bearer-grammar-test-key-0123456789'))

/** [id, 입력, 서버가 받는 Bearer 값(거부면 `null`), 오류 메시지에 없어야 할 글자(없으면 `''`)] */
const GRAMMAR: ReadonlyArray<
  readonly [id: string, token: string, sent: string | null, canary: string]
> = [
  ['plain', 'abc.DEF-ghi_jkl~mno+pqr/stu', 'abc.DEF-ghi_jkl~mno+pqr/stu', ''],
  ['pad', 'abc==', 'abc==', ''],
  ['jwt', JWS, JWS, ''],
  ['lf', 'abc\n', 'abc', ''],
  ['crlf', 'abc\r\n', 'abc', ''],
  ['lead-tab', ' \tabc\t ', 'abc', ''],
  ['inner-sp', 'a bc', null, 'a bc'],
  ['inner-tab', 'a\tbc', null, 'a\tbc'],
  ['inner-crlf', 'a\r\nX-Evil: 1', null, 'X-Evil'],
  ['mid-pad', 'a=bc', null, 'a=bc'],
  ['empty', '', null, ''],
  ['blank', ' \t\r\n', null, ''],
  ['latin1', 'abc\u{e9}', null, 'abc'],
  ['above-ff', 'abc\u{100}', null, 'abc'],
  ['c1', 'abc\u0085', null, 'abc'],
  ['nul', 'abc\u0000', null, 'abc'],
  ['del', 'abc\u007f', null, 'abc'],
  ['nbsp', 'abc\u{a0}', null, 'abc'],
  ['ideographic', '\u{3000}abc', null, 'abc'],
  ['vt', 'abc\u000b', null, 'abc'],
  // node 의 덤 — UTF-16 문자열이라 짝 없는 서로게이트가 들어온다.
  ['lone-surrogate', 'abc\ud800', null, 'abc'],
]

const SENT = GRAMMAR.filter(([, , sent]) => sent !== null)
const REJECTED = GRAMMAR.filter(([, , sent]) => sent === null)

type Settled = { readonly ok: true } | { readonly ok: false; readonly err: unknown }

function settle(p: Promise<unknown>): Promise<Settled> {
  return p.then(
    () => ({ ok: true }) as const,
    (err: unknown) => ({ ok: false, err }) as const,
  )
}

/** 거부 — SDK 의 그 오류(원인 없음)이고, 메시지에 토큰의 글자가 없다. */
function expectRefused(s: Settled, canary: string): void {
  expect(s.ok, '보내지 말고 거부해야 한다').toBe(false)
  if (s.ok) return
  expect(s.err).toBeInstanceOf(KeycloakAuthError)
  const e = s.err as Error
  expect(e.message).toMatch(/^admin access token cannot be sent: /)
  expect(e.cause).toBeUndefined()
  if (canary !== '') expect(e.message).not.toContain(canary)
}

function grammarConfig(): ReturnType<typeof defineConfig> {
  return defineConfig({ serverUrl: idp.origin, realm: 'r', clientId: 'c', clientSecret: 's' })
}

/** 생성은 쓸 수 있는 토큰으로 하고, 그 뒤 소비자 provider 가 표의 값을 준다. */
async function adminThenServing(token: string): Promise<AdminClient> {
  let current = 'first'
  const provider: TokenProvider = { getAccessToken: () => Promise.resolve(current) }
  const admin = await AdminClient.create(grammarConfig(), provider)
  current = token
  return admin
}

describe('bearer 문법 — 아홉 언어 같은 표(b64token · 앞뒤 SP·HTAB·CR·LF 만 뗀다)', () => {
  for (const [route, call] of [
    ['파사드(admin.realms.list)', (a: AdminClient) => a.realms.list()],
    ['raw()(admin.raw().realms.find)', (a: AdminClient) => a.raw().realms.find()],
  ] as const) {
    it.each(SENT)(`%s — ${route} 가 뗀 값을 보낸다`, async (_id, token, sent) => {
      const admin = await adminThenServing(token)
      const before = idp.counts.admin
      await call(admin)
      expect(idp.counts.admin).toBe(before + 1)
      expect(idp.last.adminAuthorization).toBe(`Bearer ${sent}`)
    })

    it.each(REJECTED)(`%s — ${route} 가 요청 없이 거부한다`, async (_id, token, _sent, canary) => {
      const admin = await adminThenServing(token)
      const before = idp.counts.admin
      expectRefused(await settle(call(admin)), canary)
      expect(idp.counts.admin).toBe(before)
    })
  }

  it.each(GRAMMAR)(
    '%s — 생성 때의 토큰 확보(AdminClient.create)',
    async (_id, token, sent, canary) => {
      const before = idp.counts.admin
      const s = await settle(
        AdminClient.create(grammarConfig(), { getAccessToken: () => Promise.resolve(token) }),
      )
      if (sent === null) expectRefused(s, canary)
      else expect(s.ok).toBe(true)
      expect(idp.counts.admin).toBe(before)
    },
  )

  it.each(GRAMMAR)(
    '%s — 공개 provider(소비자 TokenSource)는 뗀 값을 캐시하고, 거부한 값은 캐시하지 않는다',
    async (_id, token, sent, canary) => {
      const now = Math.floor(Date.now() / 1000)
      const source = {
        clientCredentialsToken: vi.fn(() =>
          Promise.resolve(new TokenSet(token, 'Bearer', 300, now + 300)),
        ),
      }
      const provider = new ClientCredentialsTokenProvider(source)
      if (sent === null) {
        expectRefused(await settle(provider.getAccessToken()), canary)
        expectRefused(await settle(provider.getAccessToken()), canary)
        expect(source.clientCredentialsToken).toHaveBeenCalledTimes(2)
      } else {
        expect(await provider.getAccessToken()).toBe(sent)
        expect(await provider.getAccessToken()).toBe(sent)
        expect(source.clientCredentialsToken).toHaveBeenCalledTimes(1)
      }
    },
  )

  // IdP 가 준 빈 문자열은 매퍼(`tokenSetFromResponse`)가 먼저 거부한다 — 문구가 달라 형만 본다.
  it.each(GRAMMAR)(
    '%s — SDK provider(AuthClient · 가짜 IdP)는 거부한 값을 캐시하지 않는다(IdP 에 다시 묻는다)',
    async (_id, token, sent, canary) => {
      serveToken(JSON.stringify(token))
      const auth = new AuthClient(grammarConfig())
      const provider = new ClientCredentialsTokenProvider(auth)
      const before = idp.counts.token
      try {
        if (sent === null) {
          for (let i = 0; i < 2; i += 1) {
            const s = await settle(provider.getAccessToken())
            expect(s.ok).toBe(false)
            if (s.ok) return
            expect(s.err).toBeInstanceOf(KeycloakAuthError)
            if (canary !== '') expect((s.err as Error).message).not.toContain(canary)
          }
          expect(idp.counts.token - before).toBe(2)
        } else {
          expect(await provider.getAccessToken()).toBe(sent)
          expect(await provider.getAccessToken()).toBe(sent)
          expect(idp.counts.token - before).toBe(1)
        }
      } finally {
        await auth.close()
      }
    },
  )
})

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
 * `b64token` 인 Bearer 는 그대로 나간다 — 앞뒤의 SP·HTAB·CR·LF 만 SDK 가 뗀다. U+00E9(Latin-1)는 예전에 그 바이트로
 * 나갔지만 이제 거부한다(위 표의 `latin1` 행).
 * ⚠️ 이 대조군을 지우지 말 것 — 위 시험들은 「Bearer 를 전부 거부한다」로도 통과한다.
 */
describe('대조군 — b64token 인 Bearer 는 (앞뒤만 떼어) 그대로 나간다', () => {
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

  it('끝의 공백·LF — SDK 가 떼어 보낸다(서버가 받는 값은 undici 가 다듬던 때와 같다)', async () => {
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
