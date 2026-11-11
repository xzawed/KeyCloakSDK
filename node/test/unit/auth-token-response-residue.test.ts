/**
 * 끝까지 온 토큰 · introspection 응답을 쓸 수 없는 남은 두 자리 — 등록부 `token-response-class-residue`(판정 2026-11-11).
 *
 * - Q2: JSON 의 짝 없는 서로게이트 이스케이프(`\ud800` — 값 · 확장 멤버 · 멤버 이름 · 토큰 자체)는 본문 어디에 있든 응답
 *   전체를 쓸 수 없다. 수정 전(실측 · main 13846912): `JSON.parse` 가 홀로 선 서로게이트를 그대로 두어 세 그랜트 ·
 *   introspection 이 **성공**했다. 짝을 이룬 것은 받는다(대조군).
 * - Q1: 풀 수 없는 content-coding(gzip 아님 · 깨진 deflate · CRC · 멤버 뒤의 바이트)은 바이트가 다 온 것이라 상태와
 *   무관하게 `KeycloakAuthError`. 수정 전: undici 가 본문을 `TypeError('terminated')`(원인 zlib `Z_DATA_ERROR`)로 끝내
 *   `KeycloakTransportError` 였다. 꼬리(CRC · 길이)만 없는 gzip 은 undici 가 아무 신호 없이 받아들인다 — 그대로다
 *   (기록 칸).
 */
import { createServer, type Server } from 'node:http'
import type { AddressInfo } from 'node:net'
import { deflateRawSync, gzipSync } from 'node:zlib'
import { afterAll, beforeAll, describe, expect, it } from 'vitest'
import { KeycloakAuthError, KeycloakClient, KeycloakTransportError } from '../../src/index.js'
import { holdsUnpairedSurrogate } from '../../src/token-response-cap.js'

/** `cut` 이면 Content-Length 를 본문보다 100 바이트 길게 적고, 본문을 쓴 뒤 연결을 끊는다 — 다 오지 않은 응답. */
type Answer = { status: number; body: Buffer; encoding?: string; cut?: boolean }

const json = 'application/json'
const U = '\\u'
const GOOD_TOKEN = '{"access_token":"a","token_type":"Bearer","expires_in":60}'
const GOOD_INTROSPECTION = '{"active":true,"username":"svc"}'
/** JSON 객체 끝에 멤버 하나를 더한다. */
const withMember = (body: string, member: string): string => `${body.slice(0, -1)},${member}}`
const ok = (body: string): Answer => ({ status: 200, body: Buffer.from(body) })
const gzipped = (body: string): Buffer => gzipSync(Buffer.from(body))
/** gzip 머리 열 바이트 뒤에 deflate 가 아닌 바이트(길이가 맞지 않는 stored 블록). */
const CORRUPT_DEFLATE = Buffer.concat([
  Buffer.from([0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 0xff]),
  Buffer.alloc(30, 'x'),
])
const badCrc = (body: string): Buffer => {
  const out = Buffer.from(gzipped(body))
  out[out.length - 6] = (out[out.length - 6] ?? 0) ^ 0xff
  return out
}

let token: Answer = ok(GOOD_TOKEN)
let introspection: Answer = ok(GOOD_INTROSPECTION)
/** 있으면 discovery 문서 대신 이것을 보낸다. */
let discovery: Answer | undefined
let server: Server
let origin = ''

beforeAll(async () => {
  server = createServer((req, res) => {
    req.on('end', () => {
      const path = new URL(req.url ?? '/', origin).pathname
      const isDiscovery = path.endsWith('/.well-known/openid-configuration')
      if (isDiscovery && discovery !== undefined) {
        res.setHeader('content-type', json)
        if (discovery.encoding !== undefined) res.setHeader('content-encoding', discovery.encoding)
        res.end(discovery.body)
        return
      }
      if (isDiscovery) {
        const issuer = `${origin}/realms/r`
        res.setHeader('content-type', json)
        res.end(
          JSON.stringify({
            issuer,
            token_endpoint: `${issuer}/protocol/openid-connect/token`,
            introspection_endpoint: `${issuer}/protocol/openid-connect/token/introspect`,
            jwks_uri: `${issuer}/protocol/openid-connect/certs`,
            response_types_supported: ['code'],
          }),
        )
        return
      }
      if (path.startsWith('/admin/')) {
        res.setHeader('content-type', json)
        res.end('[]')
        return
      }
      const answer = path.endsWith('/token/introspect') ? introspection : token
      res.statusCode = answer.status
      res.setHeader('content-type', json)
      if (answer.encoding !== undefined) res.setHeader('content-encoding', answer.encoding)
      if (answer.cut === true) {
        res.setHeader('content-length', answer.body.length + 100)
        res.write(answer.body, () => res.socket?.destroy())
        return
      }
      res.end(answer.body)
    })
    req.resume()
  })
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve))
  origin = `http://127.0.0.1:${(server.address() as AddressInfo).port}`
})

afterAll(async () => {
  await new Promise<void>((resolve) => server.close(() => resolve()))
})

async function outcome(
  run: (kc: KeycloakClient) => Promise<unknown>,
  answers: { token?: Answer; introspection?: Answer },
): Promise<unknown> {
  const kc = KeycloakClient.create({
    serverUrl: origin,
    realm: 'r',
    clientId: 'c',
    clientSecret: 's',
  })
  try {
    token = ok(GOOD_TOKEN)
    introspection = ok(GOOD_INTROSPECTION)
    await kc.auth.clientCredentialsToken() // discovery 를 먼저 끝낸다 — 재는 것은 그 뒤의 요청이다
    token = answers.token ?? token
    introspection = answers.introspection ?? introspection
    return await run(kc)
  } catch (e) {
    return e
  } finally {
    await kc.close()
  }
}

const LANES: Array<[string, (kc: KeycloakClient) => Promise<unknown>]> = [
  ['client credentials', (kc) => kc.auth.clientCredentialsToken()],
  ['refresh', (kc) => kc.auth.refresh('r')],
  ['admin 의 자기 토큰 부여', async (kc) => (await kc.admin()).realms.list()],
]

const UNUSABLE_TOKENS: Array<[string, Answer, string]> = [
  [
    '확장 멤버의 짝 없는 서로게이트',
    ok(withMember(GOOD_TOKEN, `"x_ext":"${U}d800"`)),
    'unpaired surrogate escape',
  ],
  [
    '멤버 이름의 짝 없는 서로게이트',
    ok(withMember(GOOD_TOKEN, `"${U}dc00":1`)),
    'unpaired surrogate escape',
  ],
  [
    '토큰 자체가 짝 없는 서로게이트',
    ok(`{"access_token":"${U}dbff","token_type":"Bearer","expires_in":60}`),
    'unpaired surrogate escape',
  ],
  [
    'gzip 이 아닌 본문',
    { status: 200, body: Buffer.alloc(40, 'x'), encoding: 'gzip' },
    'could not be decoded',
  ],
  [
    '깨진 deflate',
    { status: 200, body: CORRUPT_DEFLATE, encoding: 'gzip' },
    'could not be decoded',
  ],
  [
    'CRC 가 틀린 gzip',
    { status: 200, body: badCrc(GOOD_TOKEN), encoding: 'gzip' },
    'could not be decoded',
  ],
  [
    '멤버 뒤의 머리 아닌 바이트',
    {
      status: 200,
      body: Buffer.concat([gzipped(GOOD_TOKEN), Buffer.alloc(40, 'x')]),
      encoding: 'gzip',
    },
    'could not be decoded',
  ],
  [
    '오류 상태의 깨진 gzip',
    { status: 400, body: CORRUPT_DEFLATE, encoding: 'gzip' },
    'could not be decoded',
  ],
  // 상태와 무관하다 — 401 · 500 도(실행 레그: 상태로 자르는 편집이 살아남았다)
  [
    '401 의 깨진 gzip',
    { status: 401, body: CORRUPT_DEFLATE, encoding: 'gzip' },
    'could not be decoded',
  ],
  [
    '500 의 깨진 gzip',
    { status: 500, body: CORRUPT_DEFLATE, encoding: 'gzip' },
    'could not be decoded',
  ],
  // brotli 의 형식 오류(ERR__ERROR_FORMAT_*)와 사전이 필요한 zlib(Z_NEED_DICT)도 바이트의 판정이다 — 실행 레그가 찾음
  ['깨진 br', { status: 200, body: Buffer.alloc(40, 'x'), encoding: 'br' }, 'could not be decoded'],
  [
    '사전이 필요한 deflate',
    {
      status: 200,
      body: Buffer.concat([
        Buffer.from([0x78, 0x20, 0, 0, 0, 1]),
        deflateRawSync(GOOD_TOKEN),
        Buffer.alloc(4),
      ]),
      encoding: 'deflate',
    },
    'could not be decoded',
  ],
]

describe('끝까지 온 토큰 응답을 쓸 수 없으면 KeycloakAuthError', () => {
  for (const [lane, run] of LANES) {
    it.each(UNUSABLE_TOKENS)(`${lane} — %s`, async (_cell, answer, reason) => {
      const got = await outcome(run, { token: answer })
      expect(got).toBeInstanceOf(KeycloakAuthError)
      expect(got).not.toBeInstanceOf(KeycloakTransportError)
      expect((got as Error).message).toContain(
        `token response ${reason === 'unpaired surrogate escape' ? 'holds an ' : ''}${reason}`,
      )
    })
  }

  it.each(LANES)(
    '%s — 짝을 이룬 서로게이트 · 온전한 gzip 은 받는다(대조군)',
    async (_lane, run) => {
      const pair = ok(withMember(GOOD_TOKEN, `"scope":"a${U}d83d${U}de00b"`))
      expect(await outcome(run, { token: pair })).not.toBeInstanceOf(Error)
      const plain = { status: 200, body: gzipped(GOOD_TOKEN), encoding: 'gzip' }
      expect(await outcome(run, { token: plain })).not.toBeInstanceOf(Error)
    },
  )

  it('꼬리(CRC · 길이)만 없는 gzip — undici 가 신호 없이 받아들인다(기록 칸, 판정 Q3 「그대로」)', async () => {
    const truncated = gzipped(GOOD_TOKEN).subarray(0, -8)
    const got = await outcome((kc) => kc.auth.clientCredentialsToken(), {
      token: { status: 200, body: Buffer.from(truncated), encoding: 'gzip' },
    })
    expect(got).not.toBeInstanceOf(Error)
  })
})

/** 판정 밖 — 해제기의 판정이 아닌 실패와 토큰 응답이 아닌 응답은 전과 같다. */
describe('대조군', () => {
  it.each([
    ['평문', Buffer.from('{"access_token":"a","token'), undefined],
    ['gzip', gzipped(GOOD_TOKEN).subarray(0, 12), 'gzip'],
  ])(
    '본문 중간에 연결이 끊긴 토큰 응답(%s)은 다 오지 않았다 — transport',
    async (_cell, body, encoding) => {
      const got = await outcome((kc) => kc.auth.clientCredentialsToken(), {
        token: { status: 200, body: Buffer.from(body), encoding, cut: true },
      })
      expect(got).toBeInstanceOf(KeycloakTransportError)
      expect((got as Error).message).not.toContain('could not be decoded')
    },
  )

  it('discovery 문서의 짝 없는 서로게이트 — 토큰 응답이 아니라 판정 밖이다(받는다)', async () => {
    const issuer = `${origin}/realms/r`
    const doc = JSON.stringify({
      issuer,
      token_endpoint: `${issuer}/protocol/openid-connect/token`,
      introspection_endpoint: `${issuer}/protocol/openid-connect/token/introspect`,
      jwks_uri: `${issuer}/protocol/openid-connect/certs`,
      response_types_supported: ['code'],
    })
    discovery = { status: 200, body: Buffer.from(withMember(doc, `"x":"${U}d800"`)) }
    const kc = KeycloakClient.create({
      serverUrl: origin,
      realm: 'r',
      clientId: 'c',
      clientSecret: 's',
    })
    try {
      token = ok(GOOD_TOKEN)
      await expect(kc.auth.clientCredentialsToken()).resolves.toBeDefined()
    } finally {
      discovery = undefined
      await kc.close()
    }
  })

  it('discovery 문서의 깨진 gzip — 토큰 응답이 아니라 판정 밖이다(전처럼 transport)', async () => {
    discovery = { status: 200, body: CORRUPT_DEFLATE, encoding: 'gzip' }
    const kc = KeycloakClient.create({
      serverUrl: origin,
      realm: 'r',
      clientId: 'c',
      clientSecret: 's',
    })
    try {
      const got = await kc.auth.clientCredentialsToken().then(
        () => undefined,
        (e: unknown) => e,
      )
      expect(got).toBeInstanceOf(KeycloakTransportError)
      expect((got as Error).message).not.toContain('could not be decoded')
    } finally {
      discovery = undefined
      await kc.close()
    }
  })
})

describe('끝까지 온 introspection 응답을 쓸 수 없으면 KeycloakAuthError', () => {
  it.each<[string, Answer, string]>([
    [
      '클레임의 짝 없는 서로게이트',
      ok(withMember(GOOD_INTROSPECTION, `"sub":"x${U}d800"`)),
      'holds an unpaired surrogate escape',
    ],
    [
      '깨진 deflate',
      { status: 200, body: CORRUPT_DEFLATE, encoding: 'gzip' },
      'could not be decoded',
    ],
  ])('%s', async (_cell, answer, reason) => {
    const got = await outcome((kc) => kc.auth.introspect('t'), { introspection: answer })
    expect(got).toBeInstanceOf(KeycloakAuthError)
    expect((got as Error).message).toContain(`introspection response ${reason}`)
  })

  it('짝을 이룬 서로게이트는 받는다(대조군)', async () => {
    const pair = ok(withMember(GOOD_INTROSPECTION, `"sub":"a${U}d83d${U}de00b"`))
    expect(await outcome((kc) => kc.auth.introspect('t'), { introspection: pair })).toMatchObject({
      active: true,
    })
  })
})

/** 이스케이프를 판정한다, 글자가 아니라 — JVM · python · Go 와 같은 칸이다. */
describe('holdsUnpairedSurrogate', () => {
  const cases: Array<[string, boolean]> = [
    [`{"a":"${U}d800"}`, true],
    [`{"a":"${U}dc00"}`, true],
    [`{"${U}d800":1}`, true],
    [`{"a":"x${U}D800"}`, true],
    [`{"a":"${U}d800${U}0041"}`, true],
    [`{"a":"${U}dbff"}`, true],
    [`{"a":["ok","${U}dfff"]}`, true],
    [`{"a":"${U}ZZZZ","b":"${U}DC00"}`, true], // 형식이 틀린 이스케이프 뒤도 훑는다(Grok 레그)
    [`{"x":"a\\"b","y":"${U}dc00"}`, true], // 이스케이프된 따옴표가 문자열을 닫지 않는다(JVM 실행 레그)
    [`{"a":"${U}d800${U}d800"}`, true],
    [`{"a":"${U}d800\\"`, true],
    // 실행 레그가 살린 축소 편집들 — 범위 위의 비-low · 짝 뒤 다음 문자열 · 대문자 F · 짝 앞의 `\` 와 `u`
    [`{"a":"${U}d800${U}e000"}`, true],
    [`{"a":"${U}d83d${U}de00","b":"${U}d800"}`, true],
    [`{"a":"${U}DBFF"}`, true],
    [`{"a":"${U}DFFF"}`, true],
    [`{"a":"${U}d800xudc00"}`, true],
    [`{"a":"${U}d800\\"dc00"}`, true],
    [`{"a":"${U}d800\\\\dc00"}`, true],
    [`{"a":"${U}d83d${U}de00"}`, false],
    [`{"a":"\\\\ud800"}`, false],
    [`{"a":"${U}0041"}`, false],
    [`{"a":"plain"}`, false],
    [`{"a":"${U}zz00"}`, false],
    [`{"a":1} ${U}d800`, false],
    [`{"a":"\\"${U}d83d${U}de00"}`, false],
  ]
  it.each(cases)('%s → %s', (text, expected) => {
    expect(holdsUnpairedSurrogate(new TextEncoder().encode(text))).toBe(expected)
  })
})
