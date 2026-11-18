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
import { passesR4 } from '../../src/redirect-uri.js'

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
 * WHATWG 가 받지만 Keycloak 은 받지 않는 값 — 등록부 `redirect-uri-r3-narrower-than-keycloak`.
 *
 * Keycloak 은 받은 redirect_uri 를 `java.net.URI.create` 로 파싱한다(`RedirectUtils.toUri`). WHATWG URL 은 경로의 `[` · `]` 를
 * 그대로 두고 비특수 scheme 의 빈 값(`myapp:`)도 받아, SDK 가 보내는 `href` 를 Keycloak 이 거부했다(JDK 21.0.8: "Illegal
 * character in path" · "Expected scheme-specific part"). R4 가 보내는 `href` 를 본다 — (R4a) scheme 의 `:` 뒤가 비면 거부,
 * (R4b) `:` 뒤가 `/` 로 시작하면 `?` 앞에서 — `//` 로 시작하면 다음 `/` 까지(없으면 끝까지)가 authority 이고 거기 `[` · `]` 는
 * 괄호 호스트 하나로만 올 수 있다, 그 밖(경로)의 `[` · `]` 는 거부. 불투명한 값과 쿼리는 괄호를 가져도 된다. 문구는 다른 언어의
 * R3 와 같다. 인가 요청과 교환이 같은 `href` 를 보내므로 둘 다 요청 없이 거부한다.
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
  for (const value of ['https:', 'https://app[1]/cb', 'https://[::1]]/cb', 'https:/']) {
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
