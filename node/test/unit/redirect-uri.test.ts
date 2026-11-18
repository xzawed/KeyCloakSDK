/**
 * 인가 요청과 토큰 요청이 같은 redirect_uri 를 보낸다 — 등록부 `node-authz-request-redirect-unvalidated`.
 *
 * Keycloak 은 토큰 요청의 redirect_uri 를 인가 요청 때 저장한 값과 문자열로 비교한다(26.6.9
 * `AuthorizationCodeGrantType` — 다르면 invalid_grant 「Incorrect redirect_uri」). openid-client 6.8.8 은 토큰 요청의
 * redirect_uri 를 `currentUrl` 에서 쿼리와 fragment 를 지운 WHATWG 직렬화로 만든다(`stripParams`).
 *
 * 실측(2026-11-17, 고치기 전): `createAuthorizationRequest` 는 받은 문자열을 그대로 실어, 그 직렬화와 다른 입력이면 두
 * 요청이 갈렸다 — 맨 origin `http://localhost:3000`(토큰 요청은 `…3000/`) · 대문자 호스트 · 기본 포트 · `..` · 공백 ·
 * 쿼리(토큰 요청에서 사라진다) · fragment. 그 입력으로는 코드 흐름이 끝날 수 없었다. URL 이 아닌 값도 그대로
 * 실었다(`exchangeCode` 는 #1129 부터 거부한다 — java · kotlin · rust 는 인가 요청에서 거부한다).
 */
import { describe, expect, it } from 'vitest'
import { createServer, type Server } from 'node:http'
import type { AddressInfo } from 'node:net'
import { AuthClient } from '../../src/auth.js'
import { defineConfig } from '../../src/config.js'
import { KeycloakConfigError } from '../../src/errors.js'
import { passesR3, passesR4 } from '../../src/redirect-uri.js'

interface Idp {
  url: string
  seen: string[]
  tokenBodies: string[]
  close: () => Promise<void>
}

/** discovery 는 정상으로, 토큰 엔드포인트는 invalid_grant 로 답하고 그 요청 본문을 적는다. */
async function idp(): Promise<Idp> {
  const f: Partial<Idp> = { seen: [], tokenBodies: [] }
  const server: Server = createServer((req, res) => {
    f.seen!.push(`${req.method} ${req.url}`)
    let body = ''
    req.on('data', (c: Buffer) => (body += c.toString('utf8')))
    req.on('end', () => {
      const base = `${f.url}/realms/r`
      if (req.url === '/realms/r/.well-known/openid-configuration') {
        res.writeHead(200, { 'content-type': 'application/json' })
        res.end(
          JSON.stringify({
            issuer: base,
            authorization_endpoint: `${base}/protocol/openid-connect/auth`,
            token_endpoint: `${base}/protocol/openid-connect/token`,
            jwks_uri: `${base}/protocol/openid-connect/certs`,
            response_types_supported: ['code'],
            subject_types_supported: ['public'],
            id_token_signing_alg_values_supported: ['RS256'],
          }),
        )
        return
      }
      if (req.url === '/realms/r/protocol/openid-connect/token') {
        f.tokenBodies!.push(body)
        res.writeHead(400, { 'content-type': 'application/json' })
        res.end(JSON.stringify({ error: 'invalid_grant', error_description: 'stop' }))
        return
      }
      res.writeHead(404)
      res.end()
    })
  })
  await new Promise<void>((r) => server.listen(0, '127.0.0.1', r))
  f.url = `http://127.0.0.1:${(server.address() as AddressInfo).port}`
  f.close = () => new Promise<void>((r) => server.close(() => r()))
  return f as Idp
}

function client(serverUrl: string): AuthClient {
  return new AuthClient(defineConfig({ serverUrl, realm: 'r', clientId: 'c', clientSecret: 's' }))
}

async function failure(p: Promise<unknown>): Promise<unknown> {
  try {
    await p
  } catch (e) {
    return e
  }
  throw new Error('expected a rejection')
}

function thrown(fn: () => unknown): unknown {
  try {
    fn()
  } catch (e) {
    return e
  }
  throw new Error('expected a throw')
}

const VERIFIER = 'v'.repeat(43)

describe('같은 redirectUri 의 인가 요청과 토큰 요청은 같은 redirect_uri 를 싣는다', () => {
  // 앞의 일곱은 고치기 전에 갈렸다(실측). 마지막 둘은 대조 — 이미 직렬화 그대로인 값.
  for (const value of [
    'http://localhost:3000',
    'https://App.Example/cb',
    'https://app.example:443/cb',
    'https://app.example/a/../cb',
    'https://app.example/c b',
    'https://app.example/cb?',
    'https://app.example/cb#',
    'https://app.example/cb',
    'http://localhost:3000/',
  ]) {
    it(JSON.stringify(value), async () => {
      const srv = await idp()
      try {
        const auth = client(srv.url)
        const authz = new URL(auth.createAuthorizationRequest(value).url).searchParams.get(
          'redirect_uri',
        )
        await failure(auth.exchangeCode('the-code', value, VERIFIER))
        expect(srv.tokenBodies).toHaveLength(1)
        expect(new URLSearchParams(srv.tokenBodies[0]).get('redirect_uri')).toBe(authz)
      } finally {
        await srv.close()
      }
    })
  }
})

describe('URL 이 아닌 redirectUri 는 인가 요청에서도 KeycloakConfigError 다', () => {
  for (const bad of ['not a url', '', '/callback', 'relative/callback']) {
    it(JSON.stringify(bad), () => {
      const e = thrown(() => client('http://127.0.0.1:1').createAuthorizationRequest(bad))
      expect(e).toBeInstanceOf(KeycloakConfigError)
      expect((e as Error).message).toBe('invalid redirect_uri: Invalid URL')
      expect(((e as Error).cause as Error).name).toBe('TypeError')
    })
  }
})

/**
 * WHATWG 가 받지만 Keycloak 은 받지 않는 값 — 등록부 `redirect-uri-r3-narrower-than-keycloak` ·
 * `redirect-uri-create-residuals`.
 *
 * Keycloak 은 받은 redirect_uri 를 `java.net.URI.create` 로 파싱한다(`RedirectUtils.toUri`). WHATWG URL 은 경로의 `[` · `]` 를
 * 그대로 두고 비특수 scheme 의 빈 값(`myapp:`)과 빈 authority(`myapp://`)도 받아, SDK 가 보내는 `href` 를 Keycloak 이
 * 거부했다(JDK 21.0.8: "Illegal character in path" · "Expected scheme-specific part" · "Expected authority"). R4 가 보내는
 * `href` 를 본다 — (R4a) scheme 의 `:` 뒤가 비면 거부, `:` 뒤가 `/` 로 시작하면 `?` 앞에서 — `//` 로 시작하면 (R4c) `:` 뒤가
 * `//` 뿐이면 거부, 다음 `/` 까지(없으면 끝까지)가 authority 이고 거기 `[` · `]` 는 (R4d) 괄호 친 IPv6 호스트 하나로만 올 수
 * 있고 (R4e) 그 포트는 2147483647 이하다, (R4b) 그 밖(경로)의 `[` · `]` 는 거부. 불투명한 값과 쿼리는 괄호를 가져도 된다.
 * 문구는 다른 언어의 R3 와 같다. 인가 요청과 교환이 같은 `href` 를 보내므로 둘 다 요청 없이 거부한다.
 */
describe('Keycloak 의 java.net.URI 가 거부하는 redirectUri 는 두 호출 모두 요청 없이 거부한다(R4)', () => {
  const NOT_URI = 'invalid redirect_uri: not a valid URI (RFC 3986 §2)'
  for (const value of [
    'myapp:',
    'https://app/c[b',
    'https://app/c]b',
    'myapp:/c[b',
    'https://[::1]/c[b',
    'myapp://[::1]/c[b',
    // R4c — 빈 `?` · `#` 는 지워져 셋 다 `myapp://` 를 보낼 뻔했다.
    'myapp://',
    'myapp://?',
    'myapp://#',
  ]) {
    it(JSON.stringify(value), async () => {
      const srv = await idp()
      try {
        const auth = client(srv.url)
        const atAuthz = thrown(() => auth.createAuthorizationRequest(value))
        expect(atAuthz).toBeInstanceOf(KeycloakConfigError)
        expect((atAuthz as Error).message).toBe(NOT_URI)
        const atExchange = await failure(auth.exchangeCode('the-code', value, VERIFIER))
        expect(atExchange).toBeInstanceOf(KeycloakConfigError)
        expect((atExchange as Error).message).toBe(NOT_URI)
        expect(srv.seen).toEqual([])
      } finally {
        await srv.close()
      }
    })
  }

  // 같은 목록의 나머지는 WHATWG 가 먼저 거부한다 — 오늘의 파싱 문구 그대로다(`https:/` 는 java.net.URI 가 받는다 — WHATWG 가
  // 더 엄격한 자리다).
  for (const value of [
    'https:',
    'https://app[1]/cb',
    'https://[::1]]/cb',
    'https:/',
    // zone id 셋 — java.net.URI 는 받지만 다른 언어는 R3 로 거부한다(`%` 뒤에 16진 두 자리가 없다 — RFC 6874 §2 는 URI 안의
    // zone id 구분자를 `%25` 로 쓰라고 한다). node 는 파서가 zone id 를 아예 받지 않는다(`%25` 로 써도).
    'https://[fe80::1%eth0]/cb',
    'https://[::1%1]/cb',
    'https://[::1%zz]/cb',
    'https://[fe80::1%25eth0]/cb',
  ]) {
    it(`${JSON.stringify(value)} 는 파서가 먼저 거부한다`, () => {
      const e = thrown(() => client('http://127.0.0.1:1').createAuthorizationRequest(value))
      expect(e).toBeInstanceOf(KeycloakConfigError)
      expect((e as Error).message).toBe('invalid redirect_uri: Invalid URL')
    })
  }

  // 순서 — 앞 규칙에도 걸리는 값은 앞 규칙의 문구다.
  for (const [value, message] of [
    ['https://app/c[b#f', 'invalid redirect_uri: a fragment is not allowed (RFC 6749 §3.1.2)'],
    [
      'https://app/c[b?x=1',
      'invalid redirect_uri: a query is not supported (the code exchange sends the redirect URI without it)',
    ],
  ] as const) {
    it(`${JSON.stringify(value)} 는 앞 규칙의 문구다`, () => {
      const e = thrown(() => client('http://127.0.0.1:1').createAuthorizationRequest(value))
      expect(e).toBeInstanceOf(KeycloakConfigError)
      expect((e as Error).message).toBe(message)
    })
  }

  // 판정 그 자체 — `java.net.URI.create`(JDK 21.0.8)로 잰 표 그대로. WHATWG 가 먼저 거부하는 값과 authority 갈래(WHATWG 의
  // href 로는 닿지 않는다)도 여기서 잰다.
  it('R4 는 java.net.URI 가 거부한 값을 거부하고 받은 값을 받는다', () => {
    const refused = [
      'https:',
      'myapp:',
      'https://app/c[b',
      'https://app/c]b',
      'myapp:/c[b',
      'https://[::1]/c[b',
      'https://app[1]/cb',
      'https://[::1]]/cb',
      'myapp://a]b',
    ]
    const accepted = [
      'https://[::1]/cb',
      'https://[::1]:8443/cb',
      'https://u@[::1]:8443/cb',
      'https://app/cb?x=[1]',
      'myapp:c[b',
      'urn:x[y]',
      'https:/',
      'myapp://[::1]',
    ]
    expect(refused.filter(passesR4)).toEqual([])
    expect(accepted.filter((v) => !passesR4(v))).toEqual([])
  })

  // `java.net.URI.create` 실측 표 전부(JDK 21.0.8, 83 값 — 빈 authority · 괄호 호스트의 내용 · zone id · 포트 · 사용자 정보 ·
  // 괄호 없는 호스트). 줄 끝은 JDK 의 거부 문구다. R4 만 보는 판정이라 zone id 의 맨 `%`(`%eth0` · `%1` · `%zz`)는 Java 처럼
  // 받는다 — 그 셋을 거부하는 것은 다른 언어에서 R3 이고, node 에서는 파서다(위).
  const JDK_REFUSED = [
    'https://', // Expected authority
    'myapp://', // Expected authority
    'https://[zz]/cb', // Malformed IPv6 address
    'https://[v1.x]/cb', // Malformed IPv6 address
    'https://[::1::2]/cb', // Expected hex digits or IPv4 address
    'https://[1:2:3:4:5:6:7:8:9]/cb', // IPv6 address too long
    'https://[1:2:3:4:5:6:7:8::]/cb', // Malformed IPv6 address
    'https://[::1:2:3:4:5:6:7:8]/cb', // Malformed IPv6 address
    'https://[1:2:3:4:5:6:7]/cb', // IPv6 address too short
    'https://[:]/cb', // Malformed IPv6 address
    'https://[:::]/cb', // Expected hex digits or IPv4 address
    'https://[1:::2]/cb', // Expected hex digits or IPv4 address
    'https://[::1:]/cb', // Expected digits for an IPv6 address
    'https://[:1::2]/cb', // Malformed IPv6 address
    'https://[1::2:]/cb', // Expected digits for an IPv6 address
    'https://[12345::]/cb', // IPv6 hexadecimal digit sequence too long
    'https://[1.2.3.4]/cb', // Malformed IPv6 address
    'https://[::ffff:256.2.3.4]/cb', // Malformed IPv4 address
    'https://[::ffff:1.2.3]/cb', // Malformed IPv4 address
    'https://[::ffff:1.2.3.4.5]/cb', // Malformed IPv4 address
    'https://[::ffff:1.2.3.]/cb', // Malformed IPv4 address
    'https://[::ffff:.1.2.3]/cb', // Expected digits for an IPv6 address
    'https://[::ffff:1..2.3]/cb', // Malformed IPv4 address
    'https://[1:2:3:4:5:6:7:1.2.3.4]/cb', // IPv6 address too long
    'https://[1:2:3:4:5:1.2.3.4]/cb', // IPv6 address too short
    'https://[1:2:3:4:5:6::1.2.3.4]/cb', // Malformed IPv6 address
    'https://[::1.2.3.4:5]/cb', // Expected hex digits or IPv4 address
    'https://[1.2.3.4::]/cb', // Malformed IPv6 address
    'https://[::99999999999.2.3.4]/cb', // NumberFormatException
    'https://[::1.2.3.9999999999999]/cb', // NumberFormatException
    'https://[fe80::1%]/cb', // scope id expected
    'https://[fe80::1%25en-1]/cb', // Illegal character in scope id
    'https://[fe80::1%25a%25b]/cb', // Illegal character in scope id
    'https://[fe80::1%25a~b]/cb', // Illegal character in scope id
    'https://[fe80::1%25é]/cb', // Illegal character in scope id
    'https://[%25::1]/cb', // Malformed IPv6 address
    'https://[::1]:2147483648/cb', // Malformed port number
    'https://[::1]:99999999999/cb', // Malformed port number
    'https://a@b@[::1]/cb', // Illegal character in hostname
    'myapp://[zz]/cb', // Malformed IPv6 address
  ]
  const JDK_ACCEPTED = [
    'https:///',
    'https:///cb',
    'https://?x=1',
    'https://u@/cb',
    'https://:80/cb',
    'https://@/cb',
    'https:/',
    'https://[::1]/cb',
    'https://[1:2:3:4:5:6:7:8]/cb',
    'https://[1:2:3:4:5:6:7::]/cb',
    'https://[::1:2:3:4:5:6:7]/cb',
    'https://[::]/cb',
    'https://[ABCD::EF]/cb',
    'https://[abcd:EF01::]/cb',
    'https://[0001:2:3:4:5:6:7:8]/cb',
    'https://[::ffff:1.2.3.4]/cb',
    'https://[::1.2.3.4]/cb',
    'https://[::ffff:01.2.3.4]/cb',
    'https://[::ffff:0001.2.3.4]/cb',
    'https://[::ffff:00000000255.2.3.4]/cb',
    'https://[1:2:3:4:5:6:1.2.3.4]/cb',
    'https://[1::1.2.3.4]/cb',
    'https://[1:2:3:4:5::1.2.3.4]/cb',
    'https://[fe80::1%eth0]/cb',
    'https://[fe80::1%25eth0]/cb',
    'https://[fe80::1%25]/cb',
    'https://[fe80::1%25a_b.c]/cb',
    'https://[::1%1]/cb',
    'https://[::1%zz]/cb',
    'https://[::1]:/cb',
    'https://[::1]:8443/cb',
    'https://[::1]:2147483647/cb',
    'https://[::1]:00000000000000000080/cb',
    'https://h:99999999999/cb',
    'https://u@[::1]:8443/cb',
    'https://u:p@[::1]/cb',
    'https://[::1]',
    'https://[::1]?x=[1]',
    'myapp://[::1]/cb',
    'https://my_host/cb',
    'https://999.1.1.1/cb',
    'https://host:abc/cb',
    'https://hé/cb',
  ]

  it('R4 는 java.net.URI 의 실측 표와 같다(redirect-uri-create-residuals)', () => {
    expect([JDK_REFUSED.length, JDK_ACCEPTED.length]).toEqual([40, 43])
    expect(JDK_REFUSED.filter(passesR4)).toEqual([])
    expect(JDK_ACCEPTED.filter((v) => !passesR4(v))).toEqual([])
  })

  // 같은 표를 공개 경로로 — Keycloak 이 거부한 값은 하나도 그대로 나가지 않는다(파서가 먼저 거부하거나 R4 가 거부한다). 하나는
  // 파서가 고쳐 쓴다: `https://a@b@[::1]/cb` 의 사용자 정보 `@` 가 `%40` 이 되어 Keycloak 이 받는 값이 나간다(#1133 의 정규화 —
  // 두 요청이 같은 문자열).
  it('Keycloak 이 거부한 표의 값은 그대로 나가지 않는다', () => {
    const auth = client('http://127.0.0.1:1')
    const sent: [string, string | null][] = []
    for (const value of JDK_REFUSED) {
      let url: string
      try {
        url = auth.createAuthorizationRequest(value).url
      } catch (e) {
        expect(e, value).toBeInstanceOf(KeycloakConfigError)
        continue
      }
      sent.push([value, new URL(url).searchParams.get('redirect_uri')])
    }
    expect(sent).toEqual([['https://a@b@[::1]/cb', 'https://a%40b@[::1]/cb']])
  })

  // 그리고 Keycloak 이 받은 값은 R4 의 문구로 거부되지 않는다 — 파서가 받으면 그 직렬화가 나가고(괄호 호스트는 WHATWG 의 IPv6
  // 직렬화다 — `[::ffff:102:304]` · `[1:2:3:4:5:6:7:0]` 도 R4d 를 지난다), 파서가 거부하면(WHATWG 가 더 엄격한 자리) 파싱
  // 문구, 쿼리가 있으면 쿼리 문구다.
  it('Keycloak 이 받은 표의 값은 R4 의 문구로 거부되지 않는다', () => {
    const auth = client('http://127.0.0.1:1')
    const refusedAsNotUri = JDK_ACCEPTED.filter((value) => {
      try {
        auth.createAuthorizationRequest(value)
        return false
      } catch (e) {
        expect(e, value).toBeInstanceOf(KeycloakConfigError)
        return (e as Error).message === NOT_URI
      }
    })
    expect(refusedAsNotUri).toEqual([])
  })

  // 대조군 — java.net.URI 가 받는 값은 그대로 실린다(인가 URL 의 redirect_uri 와 토큰 요청의 redirect_uri 가 같은 href).
  for (const value of [
    'https://[::1]/cb',
    'https://[::1]:8443/cb',
    'https://u@[::1]:8443/cb',
    'myapp:c[b',
    'urn:x[y]',
    'myapp://[::1]/cb',
    'myapp://[::1]',
  ]) {
    it(`${JSON.stringify(value)} 는 받는다`, async () => {
      const srv = await idp()
      try {
        const auth = client(srv.url)
        const authz = new URL(auth.createAuthorizationRequest(value).url).searchParams.get(
          'redirect_uri',
        )
        expect(authz).toBe(value)
        await failure(auth.exchangeCode('the-code', value, VERIFIER))
        expect(srv.tokenBodies).toHaveLength(1)
        expect(new URLSearchParams(srv.tokenBodies[0]).get('redirect_uri')).toBe(value)
      } finally {
        await srv.close()
      }
    })
  }
})

/**
 * WHATWG 의 직렬화가 그대로 두는 RFC 3986 §2 밖의 문자 — 등록부 `node-redirect-uri-r3-chars`.
 *
 * 다른 언어는 Keycloak 의 `java.net.URI.create` 가 던지는 문자를 R3 로 거부한다 — U+0000–U+0020 · U+007F–U+00A0 · 유니코드 공백
 * 구분자 · `" < > \ ^ ` { | }` · 16진 두 자리가 따르지 않는 `%` · 잘못된 문자열. node 는 `href` 를 보내는데 WHATWG 는 그 일부를
 * 인코딩하지 않고 둔다(실측 node v22.18.0 · v22.23.5 · v24.22.3 · v26.13.1 — 같은 표, `^` 만 다르다): 불투명 경로의 아홉과 공백,
 * 계층 경로의 `|`(비특수 scheme 은 `\` 도), 호스트의 `"` · `` ` `` · `{` · `}`, 깨진 `%`(경로 · 사용자 정보 · 비특수 호스트). 홀로
 * 선 서로게이트는 `%EF%BF%BD` 로 조용히 바뀐다. 그런 값은 두 호출 모두 요청 없이 R3 문구로 거부한다.
 */
describe('href 에 남는 R3 문자는 두 호출 모두 요청 없이 거부한다(R3)', () => {
  const NOT_URI = 'invalid redirect_uri: not a valid URI (RFC 3986 §2)'
  const HIGH = String.fromCharCode(0xd800)
  const LOW = String.fromCharCode(0xdc00)
  const r3 = (s: string): boolean => passesR3(s, s)

  // [그 자리에 남는 문자, 자리] — 실측 표(위).
  const KEPT: [string, (c: string) => string][] = [
    [' "<>\\^`{|}', (c) => `myapp:a${c}b`],
    ['|', (c) => `https://app/a${c}b`],
    ['|\\', (c) => `myapp:/a${c}b`],
    ['|\\', (c) => `myapp://app/a${c}b`],
    ['"`{}', (c) => `https://a${c}b/cb`],
    ['"`{}', (c) => `myapp://a${c}b/cb`],
  ]
  const REFUSED = [
    ...KEPT.flatMap(([chars, at]) => [...chars].map(at)),
    ...['%zz', '%', '%2'].flatMap((p) => [
      `myapp:a${p}`,
      `https://app/a${p}`,
      `myapp:/a${p}`,
      `myapp://app/a${p}`,
      `https://u${p}@app/cb`,
      `https://u:p${p}@app/cb`,
      `myapp://u${p}@app/cb`,
      `myapp://a${p}/cb`,
    ]),
    // 홀로 선 서로게이트 — 높은 것 · 낮은 것 · 끝의 것. `href` 에는 `%EF%BF%BD` 로만 남아 입력을 본다.
    `https://app/a${HIGH}b`,
    `https://app/a${LOW}b`,
    `https://app/ab${HIGH}`,
    `myapp:a${LOW}`,
  ]

  it('남는 문자 · 깨진 % · 홀로 선 서로게이트는 두 호출 모두 요청 없이 R3 문구로 거부한다', async () => {
    const srv = await idp()
    try {
      const auth = client(srv.url)
      const wrong: string[] = []
      for (const value of REFUSED) {
        let atAuthz: unknown
        try {
          auth.createAuthorizationRequest(value)
        } catch (e) {
          atAuthz = e
        }
        const atExchange = await failure(auth.exchangeCode('the-code', value, VERIFIER))
        for (const e of [atAuthz, atExchange]) {
          if (!(e instanceof KeycloakConfigError) || e.message !== NOT_URI) wrong.push(value)
        }
      }
      expect(REFUSED).toHaveLength(23 + 24 + 4)
      expect(wrong).toEqual([])
      expect(srv.seen).toEqual([])
    } finally {
      await srv.close()
    }
  })

  // 같은 문자도 인코딩되는 자리에서는 받는다 — 판정은 입력이 아니라 보내는 `href` 를 본다. 기대값은 그 문자 하나의 UTF-8 퍼센트
  // 인코딩(encodeURIComponent)을 같은 자리에 넣은 것이다. 제어 문자 · U+00A0 · 공백 구분자는 어느 자리에서나 인코딩된다.
  const SPACES_AND_CONTROLS = String.fromCodePoint(
    0x01,
    0x1f,
    0x7f,
    0x80,
    0x9f,
    0xa0,
    0x1680,
    0x2000,
    0x200a,
    0x2028,
    0x2029,
    0x202f,
    0x205f,
    0x3000,
  )
  const ENCODED: [string, (c: string) => string][] = [
    [' "<>`{}', (c) => `https://app/a${c}b`],
    [' "<>`{}', (c) => `myapp:/a${c}b`],
    [' "<>^`{|}', (c) => `https://u${c}v@app/cb`],
    [' "<>\\^`{|}', (c) => `myapp://u${c}v@app/cb`],
    [SPACES_AND_CONTROLS, (c) => `myapp:a${c}b`],
    [SPACES_AND_CONTROLS, (c) => `https://app/a${c}b`],
  ]

  it('인코딩되는 자리의 같은 문자는 인코딩된 href 로 받는다', () => {
    const auth = client('http://127.0.0.1:1')
    const wrong: [string, string | null][] = []
    for (const [chars, at] of ENCODED) {
      for (const c of chars) {
        let sent: string | null
        try {
          sent = new URL(auth.createAuthorizationRequest(at(c)).url).searchParams.get(
            'redirect_uri',
          )
        } catch (e) {
          sent = `refused: ${(e as Error).message}`
        }
        if (sent !== at(encodeURIComponent(c))) wrong.push([at(c), sent])
      }
    }
    expect(wrong).toEqual([])
  })

  // `^` 는 판에 따라 다르다 — node 22 는 계층 경로에 그대로 두고, node 24 · 26 은 인코딩한다(실측 v24.22.3 · v26.13.1 — WHATWG 가
  // path percent-encode set 에 `^` 를 더했다). 어느 쪽이든 맨 `^` 는 나가지 않는다: 남으면 R3 로 거부, 인코딩되면 `%5E` 로 받는다.
  for (const value of ['https://app/a^b', 'myapp:/a^b', 'myapp://app/a^b']) {
    it(`${JSON.stringify(value)} 는 맨 ^ 를 보내지 않는다`, () => {
      const auth = client('http://127.0.0.1:1')
      if (new URL(value).href.includes('^')) {
        const e = thrown(() => auth.createAuthorizationRequest(value))
        expect(e).toBeInstanceOf(KeycloakConfigError)
        expect((e as Error).message).toBe(NOT_URI)
      } else {
        const sent = new URL(auth.createAuthorizationRequest(value).url).searchParams.get(
          'redirect_uri',
        )
        expect(sent).toBe(value.replace('^', '%5E'))
      }
    })
  }

  // 순서 — 앞 규칙에도 걸리는 값은 앞 규칙의 문구다(fragment · 쿼리가 R3 보다 먼저).
  for (const [value, message] of [
    ['myapp:a|b#f', 'invalid redirect_uri: a fragment is not allowed (RFC 6749 §3.1.2)'],
    [
      `https://app/a${HIGH}b#f`,
      'invalid redirect_uri: a fragment is not allowed (RFC 6749 §3.1.2)',
    ],
    [
      'https://app/a%zz?x=1',
      'invalid redirect_uri: a query is not supported (the code exchange sends the redirect URI without it)',
    ],
  ] as const) {
    it(`${JSON.stringify(value)} 는 앞 규칙의 문구다`, () => {
      const e = thrown(() => client('http://127.0.0.1:1').createAuthorizationRequest(value))
      expect(e).toBeInstanceOf(KeycloakConfigError)
      expect((e as Error).message).toBe(message)
    })
  }

  // 판정 그 자체 — 다른 언어의 R3 와 같은 문자 집합 전부(U+0000–U+0020 · U+007F–U+00A0 · 공백 구분자 · ASCII 아홉)와 경계 바로
  // 밖(U+0021 · U+007E · U+00A1 · U+00AD · U+200B · U+FEFF · U+1F600 — java.net.URI 가 받는다).
  it('R3 는 다른 언어의 R3 와 같은 문자 집합을 거부한다', () => {
    const codePoints: number[] = []
    for (let n = 0; n <= 0x20; n++) codePoints.push(n)
    for (let n = 0x7f; n <= 0xa0; n++) codePoints.push(n)
    for (let n = 0x2000; n <= 0x200a; n++) codePoints.push(n)
    codePoints.push(0x1680, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000)
    for (const c of '"<>\\^`{|}') codePoints.push(c.codePointAt(0)!)
    expect(codePoints).toHaveLength(33 + 34 + 11 + 6 + 9)
    const at = (n: number): string => `https://app/c${String.fromCodePoint(n)}b`
    expect(codePoints.map(at).filter(r3)).toEqual([])
    const neighbours = [0x21, 0x7e, 0xa1, 0xad, 0x200b, 0xfeff, 0x1f600].map(at)
    expect(neighbours.filter((v) => !r3(v))).toEqual([])
  })

  it('R3 는 16진 두 자리가 따르지 않는 % 를 거부한다 — zone id 안에서도', () => {
    const broken = ['https://app/cb%', 'https://app/cb%2', 'https://app/c%2zb', 'https://app/c%z2b']
    expect(broken.filter(r3)).toEqual([])
    expect(['https://app/c%%20b', 'https://app/c%zzb'].filter(r3)).toEqual([])
    expect(
      ['https://app/c%20b', 'https://app/c%aFb', 'https://app/cb%2F'].filter((v) => !r3(v)),
    ).toEqual([])
    // 의도된 차이 — java.net.URI 는 받는 zone id 셋을 다른 언어처럼 거부한다(RFC 6874 §2: URI 안에서는 `%25`).
    const zoneIds = ['https://[fe80::1%eth0]/cb', 'https://[::1%1]/cb', 'https://[::1%zz]/cb']
    expect(zoneIds.filter(r3)).toEqual([])
    expect(r3('https://[fe80::1%25eth0]/cb')).toBe(true)
  })

  it('R3 는 홀로 선 서로게이트가 있는 입력을 거부한다 — href 에는 U+FFFD 의 인코딩으로만 남는다', () => {
    for (const value of [
      `https://app/a${HIGH}b`,
      `https://app/a${LOW}b`,
      `https://app/ab${HIGH}`,
    ]) {
      expect(passesR3(value, new URL(value).href)).toBe(false)
    }
    const pair = `https://app/a${String.fromCodePoint(0x1f600)}b`
    expect(passesR3(pair, new URL(pair).href)).toBe(true)
    expect(passesR3(`https://app/a${LOW}${HIGH}b`, 'https://app/ab')).toBe(false)
  })
})

describe('쿼리 · fragment 가 있는 redirectUri 는 두 호출 모두 요청 없이 거부한다', () => {
  const QUERY =
    'invalid redirect_uri: a query is not supported (the code exchange sends the redirect URI without it)'
  const FRAGMENT = 'invalid redirect_uri: a fragment is not allowed (RFC 6749 §3.1.2)'
  for (const [value, message] of [
    ['https://app.example/cb?x=1', QUERY],
    ['https://app.example/cb?state=s1', QUERY],
    ['https://app.example/cb#frag', FRAGMENT],
    ['https://app.example/cb?x=1#frag', FRAGMENT],
  ] as const) {
    it(JSON.stringify(value), async () => {
      const srv = await idp()
      try {
        const auth = client(srv.url)
        const atAuthz = thrown(() => auth.createAuthorizationRequest(value))
        expect(atAuthz).toBeInstanceOf(KeycloakConfigError)
        expect((atAuthz as Error).message).toBe(message)
        const atExchange = await failure(auth.exchangeCode('the-code', value, VERIFIER))
        expect(atExchange).toBeInstanceOf(KeycloakConfigError)
        expect((atExchange as Error).message).toBe(message)
        expect(srv.seen).toEqual([])
      } finally {
        await srv.close()
      }
    })
  }
})
