/**
 * The OAuth `error` code an SDK error carries is a code, never a value the request sent (registry
 * `node-auth-error-no-oauth-code` — the other eight lanes' `token-error-code-secret-echo` · `oauth-error-field-echo-unmasked`;
 * java `OAuthErrorCodeEchoTest` · dotnet `OAuthErrorCodeEchoTests` 의 이식).
 *
 * 고치기 전(main 9b1c92b1): node 의 `KeycloakAuthError` 에는 코드 필드가 없었고 `scrubCause` 가 원인의 name · message · code ·
 * stack 만 남겨, `invalid_grant` 를 공개 API 로 가를 길이 없었다. 이제 `oauthError` 가 싣는다 — 단 IdP 의 `error` 도 응답
 * 본문이라, 받은 것을 되울리는 IdP(나 그 앞의 프록시)는 client secret · refresh token · code · verifier · introspect 한
 * 토큰을 거기 싣는다. 규칙은 아홉 언어의 하나다: `[a-z_]{1,64}` 이고 그 요청이 보낸 비어 있지 않은 비밀 어느 것과도
 * 겹치지 않을 때만(`src/oauth-error-code.ts`). 값은 아래에 고정한다 — 비밀이 등록 코드의 조각이면(`client`) 그 코드를 잃는다.
 *
 * 진짜 openid-client 를 루프백 가짜 IdP 에 붙인다. 오류 본문의 `error` 를 싣는 openid-client 오류는 `ResponseBodyError`
 * 하나다(4xx · `application/json` · 비어 있지 않은 문자열 `error` — 401 도). `WWW-Authenticate` 가 붙은 401 은 본문을 읽기
 * 전에 `WWWAuthenticateChallengeError` 로 끝나 코드가 없다(아래 고정). 메시지는 그대로다 — 이 변경의 범위는 필드다.
 */
import { createServer, type Server } from 'node:http'
import type { AddressInfo } from 'node:net'
import { format, inspect } from 'node:util'
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest'
import {
  ClientCredentialsTokenProvider,
  KeycloakAuthError,
  KeycloakClient,
  KeycloakTransportError,
} from '../../src/index.js'
import { discoveryDocument } from './fake-idp.js'

// Code-shaped on purpose (the shape alone cannot withhold them), and no two share a piece — an echo of one value must
// be withheld by comparing against THAT value, not a sibling's prefix.
const SECRET = 'zebrasecretjk'
const REFRESH = 'yakrefreshvq'
const TOKEN = 'walrustokenpx'
const CODE = 'vulturecodeby'
const VERIFIER = `${'ocelotverifier'.repeat(3)}xx`

/** What one request sent — its form, plus the client secret from `Authorization: Basic` when it went there. */
type Sent = Record<string, string>

let server: Server
let origin = ''
const sent: Sent[] = []
let status = 400
let headers: Record<string, string> = {}
let errorOf: (s: Sent) => unknown = () => 'invalid_request'
/** Bytes of JSON whitespace after the error body — past the 1,048,576-byte cap the response never fully arrives. */
let padding = 0
/** The path of every request but discovery, in order — the token and admin hits are counted from it. */
const paths: string[] = []
/** When set, each endpoint's whole body instead of `{"error": …}` — the success-status cases send more than that. */
let bodies: { token: string; introspect: string; admin: string } | undefined

beforeAll(async () => {
  server = createServer((req, res) => {
    res.on('error', () => undefined) // the client cancels the over-cap body mid-write
    const chunks: Buffer[] = []
    req.on('data', (c: Buffer) => chunks.push(c))
    req.on('end', () => {
      const path = new URL(req.url ?? '/', origin).pathname
      if (path === '/realms/r/.well-known/openid-configuration') {
        res.writeHead(200, { 'content-type': 'application/json' })
        res.end(JSON.stringify(discoveryDocument(`${origin}/realms/r`)))
        return
      }
      const form: Sent = Object.fromEntries(
        new URLSearchParams(Buffer.concat(chunks).toString('utf8')),
      )
      const auth = req.headers.authorization
      if (auth?.startsWith('Basic ')) {
        const pair = Buffer.from(auth.slice('Basic '.length), 'base64').toString('utf8')
        form['client_secret'] = decodeURIComponent(
          pair.slice(pair.indexOf(':') + 1).replace(/\+/g, ' '),
        )
      }
      sent.push(form)
      paths.push(path)
      res.writeHead(status, { 'content-type': 'application/json', ...headers })
      if (bodies !== undefined) {
        const admin = path.startsWith('/admin/')
        res.end(
          admin ? bodies.admin : path.endsWith('/introspect') ? bodies.introspect : bodies.token,
        )
        return
      }
      res.end(JSON.stringify({ error: errorOf(form) }) + ' '.repeat(padding))
    })
  })
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve))
  origin = `http://127.0.0.1:${(server.address() as AddressInfo).port}`
})

afterAll(async () => {
  await new Promise<void>((resolve) => server.close(() => resolve()))
})

beforeEach(() => {
  status = 400
  headers = {}
  errorOf = () => 'invalid_request'
  padding = 0
  bodies = undefined
})

interface Surface {
  /** The secret form fields it sends besides the client secret. */
  readonly params: readonly string[]
  /** The head of its failure message. */
  readonly prefix: string
  readonly run: (kc: KeycloakClient) => Promise<unknown>
}

/** Every public call that reads an OAuth error body — the provider and admin reach the client-credentials grant. */
const SURFACES: Readonly<Record<string, Surface>> = {
  clientCredentialsToken: {
    params: [],
    prefix: 'Client credentials grant failed',
    run: (kc) => kc.auth.clientCredentialsToken(),
  },
  provider: {
    params: [],
    prefix: 'Client credentials grant failed',
    run: (kc) => new ClientCredentialsTokenProvider(kc.auth).getAccessToken(),
  },
  admin: { params: [], prefix: 'Client credentials grant failed', run: (kc) => kc.admin() },
  refresh: {
    params: ['refresh_token'],
    prefix: 'Token refresh failed',
    run: (kc) => kc.auth.refresh(REFRESH),
  },
  exchangeCode: {
    params: ['code', 'code_verifier'],
    prefix: 'Authorization code exchange failed',
    run: (kc) => kc.auth.exchangeCode(CODE, 'https://app.example/cb', VERIFIER, 'the-nonce'),
  },
  introspect: {
    params: ['token'],
    prefix: 'Token introspection failed',
    run: (kc) => kc.auth.introspect(TOKEN),
  },
}
const NAMES = Object.keys(SURFACES)
const BODY_ERROR = 'server responded with an error in the response body'

function surface(name: string): Surface {
  const s = SURFACES[name]
  if (s === undefined) throw new Error(`no surface ${name}`)
  return s
}

/** The surface's failure — any other outcome fails the test. `secret: null` is a public client (no secret). */
async function failing(name: string, secret: string | null = SECRET): Promise<Error> {
  sent.length = 0
  paths.length = 0
  const kc = KeycloakClient.create({
    serverUrl: origin,
    realm: 'r',
    clientId: 'app',
    ...(secret === null ? {} : { clientSecret: secret }),
  })
  try {
    await surface(name).run(kc)
  } catch (e) {
    if (e instanceof Error) return e
    throw new Error(`${name}: threw a non-Error ${String(e)}`)
  } finally {
    await kc.close()
  }
  throw new Error(`${name} did not fail`)
}

async function authFailure(
  name: string,
  secret: string | null = SECRET,
): Promise<KeycloakAuthError> {
  const e = await failing(name, secret)
  expect(e, `${name}: ${String(e)}`).toBeInstanceOf(KeycloakAuthError)
  return e as KeycloakAuthError
}

/** The token or introspection request the surface sent — the first form the IdP saw. */
function firstSent(): Sent {
  const first = sent[0]
  if (first === undefined) throw new Error('no token request reached the IdP')
  return first
}

function sentValue(param: string): string {
  const value = firstSent()[param]
  if (value === undefined || value === '') throw new Error(`the request carried no ${param}`)
  return value
}

/** Every shape the error can take in a consumer's hands — down the cause chain. */
function renderings(e: Error): string[] {
  const out = [
    String(e),
    JSON.stringify(e),
    inspect(e, { depth: Infinity, showHidden: true }),
    format('%o', e),
  ]
  for (let link: unknown = e; link instanceof Error; link = link.cause) {
    out.push(link.message, link.stack ?? '', String(link), JSON.stringify(link))
  }
  return out
}

function assertWithheld(label: string, e: KeycloakAuthError, value: string): void {
  expect(e.oauthError, label).toBeUndefined()
  for (const text of renderings(e)) {
    expect(text.includes(value), `${label}: a rendering shows ${value}: ${text}`).toBe(false)
  }
}

/** Every piece and every padding, so each direction of the overlap is pinned. */
const ECHO_FORMS: ReadonlyArray<readonly [string, (v: string) => string]> = [
  ['whole', (v) => v],
  ['prefix', (v) => v.slice(0, 11)],
  ['suffix', (v) => v.slice(-11)],
  ['middle', (v) => v.slice(2, 11)],
  ['extended', (v) => `${v}_x`],
  ['prefixed', (v) => `x_${v}`],
  ['wrapped', (v) => `x_${v}_x`],
]

describe('오류 본문의 코드를 싣는다 — 부르는 자리마다', () => {
  it.each(NAMES)('%s — 400 invalid_grant · 메시지는 그대로', async (name) => {
    errorOf = () => 'invalid_grant'
    const e = await authFailure(name)
    expect(e.oauthError).toBe('invalid_grant')
    expect(e.message).toBe(`${surface(name).prefix}: ${BODY_ERROR}`)
    expect(firstSent()['client_secret']).toBe(SECRET)
  })

  // Keycloak 은 틀린 클라이언트 자격에 400 이 아니라 401 + JSON `{"error":"unauthorized_client",…}` 로 답한다(WWW-Authenticate
  // 없이) — openid-client 는 그것도 ResponseBodyError 로 던진다(실측).
  it.each(NAMES)('%s — 401 unauthorized_client', async (name) => {
    status = 401
    errorOf = () => 'unauthorized_client'
    const e = await authFailure(name)
    expect(e.oauthError).toBe('unauthorized_client')
    expect(e.message).toBe(`${surface(name).prefix}: ${BODY_ERROR}`)
  })

  it.each(NAMES)('%s — 등록 코드 모양 셋과 가장 긴 코드(64)', async (name) => {
    for (const code of ['invalid_client', 'slow_down', 'access_denied', 'a'.repeat(64)]) {
      errorOf = () => code
      expect((await authFailure(name)).oauthError, `${name} · ${code}`).toBe(code)
    }
  })

  it.each(NAMES)(
    '%s — WWW-Authenticate 도전이 붙은 401 은 본문을 읽기 전에 끝나 코드가 없다',
    async (name) => {
      status = 401
      headers = { 'www-authenticate': 'Basic realm="r"' }
      errorOf = () => 'unauthorized_client'
      const e = await authFailure(name)
      expect(e.oauthError).toBeUndefined()
      expect(e.message).toBe(
        `${surface(name).prefix}: server responded with a challenge in the WWW-Authenticate HTTP Header`,
      )
    },
  )
})

describe('되울린 비밀은 싣지 않는다', () => {
  it.each(NAMES)('%s — 401 에서 되울린 값', async (name) => {
    status = 401
    for (const param of ['client_secret', ...surface(name).params]) {
      errorOf = (s) => s[param] ?? ''
      const e = await authFailure(name)
      assertWithheld(`${name} · 401 · ${param}`, e, sentValue(param))
    }
  })

  it.each(NAMES)('%s — 되울린 client secret(통째 · 조각 · 덧붙음)', async (name) => {
    for (const [form, shape] of ECHO_FORMS) {
      errorOf = (s) => shape(s['client_secret'] ?? '')
      const e = await authFailure(name)
      expect(sentValue('client_secret')).toBe(SECRET)
      assertWithheld(`${name} · ${form}`, e, shape(SECRET))
    }
  })

  // 비밀을 소문자로 되울리는 IdP 나 프록시 — 겹침은 ASCII 대소문자를 무시한다.
  it.each(NAMES)('%s — 소문자로 되울린 client secret', async (name) => {
    errorOf = (s) => (s['client_secret'] ?? '').toLowerCase()
    const e = await authFailure(name, 'EchoMixedCase')
    expect(sentValue('client_secret')).toBe('EchoMixedCase')
    assertWithheld(`${name} · lowercased`, e, 'echomixedcase')
  })

  it.each(NAMES.filter((n) => surface(n).params.length > 0))(
    '%s — 되울린 그랜트 값(통째 · 조각 · 덧붙음)',
    async (name) => {
      for (const param of surface(name).params) {
        for (const [form, shape] of ECHO_FORMS) {
          errorOf = (s) => shape(s[param] ?? '')
          const e = await authFailure(name)
          assertWithheld(`${name} · ${param} · ${form}`, e, shape(sentValue(param)))
        }
      }
    },
  )

  it('공개 클라이언트(시크릿 없음)도 되울린 refresh token 을 싣지 않고, 코드는 그대로 싣는다', async () => {
    errorOf = (s) => s['refresh_token'] ?? ''
    assertWithheld('public · echo', await authFailure('refresh', null), REFRESH)
    expect(firstSent()['client_secret'] ?? '').toBe('')
    errorOf = () => 'invalid_grant'
    expect((await authFailure('refresh', null)).oauthError).toBe('invalid_grant')
  })

  // 빈 비밀은 대지 않는다 — 빈 문자열은 모든 코드의 조각이라 대면 코드를 전부 잃는다(dotnet
  // `An_empty_grant_value_is_not_compared` 의 자리). openid-client 는 빈 시크릿을 보내지 않는다(실측 — 본문에
  // client_secret 이 없다).
  it.each(['clientCredentialsToken', 'refresh'])(
    '%s — 빈 시크릿(clientSecret "")은 대지 않고, 코드를 그대로 싣는다',
    async (name) => {
      errorOf = () => 'invalid_grant'
      const e = await authFailure(name, '')
      expect(firstSent()['client_secret'] ?? '').toBe('')
      expect(e.oauthError).toBe('invalid_grant')
    },
  )

  it.each(['clientCredentialsToken', 'provider', 'admin'])(
    '%s — 값: 시크릿이 등록 코드의 조각이면(client) 그 코드를 잃는다',
    async (name) => {
      errorOf = () => 'invalid_client'
      expect((await authFailure(name, 'client')).oauthError).toBeUndefined()
    },
  )
})

describe('코드 모양이 아닌 값은 싣지 않는다', () => {
  const NOT_A_CODE: ReadonlyArray<readonly [string, string]> = [
    ['Keycloak 모양 시크릿', 'Kx7mQ2vT9pLr4WzN8bYc3FhJ6sDa1gE5'],
    ['JWT', 'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ4In0.c2lnbmF0dXJlLXZhbHVl'],
    ['대문자', 'Invalid_client'],
    ['공백', 'invalid client'],
    ['숫자 글자', 'invalid_client2'],
    ['제어 문자', `invalid_client${String.fromCharCode(0x0a)}`],
    ['65 자', 'a'.repeat(65)],
  ]
  it.each(NAMES)('%s — 문자열', async (name) => {
    for (const [label, value] of NOT_A_CODE) {
      errorOf = () => value
      assertWithheld(`${name} · ${label}`, await authFailure(name), value)
    }
  })

  // 문자열이 아니거나 빈 `error` 는 openid-client 가 오류 본문으로 보지 않는다(ClientError) — 코드는 없다.
  it.each(NAMES)('%s — 수 · 객체 · null · 빈 문자열', async (name) => {
    for (const value of [400, { code: 'invalid_client' }, null, '']) {
      errorOf = () => value
      expect((await authFailure(name)).oauthError, `${name} · ${JSON.stringify(value)}`).toBe(
        undefined,
      )
    }
  })
})

describe('KeycloakTransportError 는 코드를 싣지 않는다', () => {
  it.each(NAMES)('%s — 상한을 넘은 오류 본문(끝까지 오지 않은 응답)', async (name) => {
    errorOf = () => 'invalid_grant'
    padding = 1_048_576
    const e = await failing(name)
    expect(e).toBeInstanceOf(KeycloakTransportError)
    expect('oauthError' in e).toBe(false)
  })
})

// A token or introspection response at the status the lane takes as success (200) whose body is a JSON object with a
// non-empty string `error` is the IdP's error answer: it fails as a 400 carrying that `error` does — same error, same
// message, the code through the same rule — and nothing else in it is used (registry `auth-2xx-error-code-divergent`).
// Before the fix (main 350836b9): openid-client read B1 as "invalid response encountered" (no code) and B2 as a success —
// the token was returned, cached and sent to admin, and introspection reported active.
const AT = 'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ4In0.c2lnbmF0dXJlLXZhbHVl'
const USER = '{"id":"u1","username":"alice"}'
/** The error alone. */
const B1 = {
  token: '{"error":"invalid_grant","error_description":"d"}',
  introspect: '{"error":"invalid_token"}',
  admin: USER,
}
/** The error beside everything a success carries. */
const B2 = {
  token: `{"error":"invalid_grant","access_token":"${AT}","token_type":"Bearer","expires_in":300}`,
  introspect: '{"error":"invalid_token","active":true}',
  admin: USER,
}
/** A plain success — for the follow-up call and the controls. */
const GOOD = {
  token: '{"access_token":"freshtoken","token_type":"Bearer","expires_in":300}',
  introspect: '{"active":true}',
  admin: USER,
}
const codeOf = (name: string): string => (name === 'introspect' ? 'invalid_token' : 'invalid_grant')
const adminHits = (): string[] => paths.filter((p) => p.startsWith('/admin/'))

function newClient(secret = SECRET): KeycloakClient {
  return KeycloakClient.create({
    serverUrl: origin,
    realm: 'r',
    clientId: 'app',
    clientSecret: secret,
  })
}

describe('success-status OAuth error — a 200 carrying `error` fails as a 400 does, nothing from it is used', () => {
  it.each(NAMES)('%s — success-status OAuth error, the error alone (B1)', async (name) => {
    status = 200
    bodies = B1
    const e = await authFailure(name)
    expect(e.message).toBe(`${surface(name).prefix}: ${BODY_ERROR}`)
    expect(e.oauthError).toBe(codeOf(name))
  })

  it.each(NAMES)(
    '%s — success-status OAuth error beside a token or active (B2): fails, nothing used',
    async (name) => {
      status = 200
      bodies = B2
      const e = await authFailure(name)
      expect(e.message).toBe(`${surface(name).prefix}: ${BODY_ERROR}`)
      expect(e.oauthError).toBe(codeOf(name))
      expect(adminHits()).toEqual([])
      for (const text of renderings(e)) expect(text.includes(AT), text).toBe(false)
    },
  )

  it('admin — success-status OAuth error (B2): the facade sends no admin request with that token', async () => {
    status = 200
    bodies = B2
    paths.length = 0
    const kc = newClient()
    try {
      const got = await kc
        .admin()
        .then((admin) => admin.users.get('u1'))
        .then(
          () => undefined,
          (e: unknown) => e,
        )
      expect(got).toBeInstanceOf(KeycloakAuthError)
      expect((got as KeycloakAuthError).oauthError).toBe('invalid_grant')
      expect(adminHits()).toEqual([])
    } finally {
      await kc.close()
    }
  })

  it('provider — success-status OAuth error (B2): nothing is cached, the next call asks the IdP again', async () => {
    status = 200
    bodies = B2
    paths.length = 0
    const kc = newClient()
    try {
      const provider = new ClientCredentialsTokenProvider(kc.auth)
      const first = await provider.getAccessToken().then(
        () => undefined,
        (e: unknown) => e,
      )
      expect(first).toBeInstanceOf(KeycloakAuthError)
      expect((first as KeycloakAuthError).oauthError).toBe('invalid_grant')
      bodies = GOOD
      expect(await provider.getAccessToken()).toBe('freshtoken')
      expect(paths.filter((p) => p.endsWith('/token'))).toHaveLength(2)
    } finally {
      await kc.close()
    }
  })

  it('clientCredentialsToken — success-status OAuth error: the secret echoed lowercased is not carried', async () => {
    status = 200
    bodies = { ...B1, token: '{"error":"echoedsecret","error_description":"d"}' }
    const e = await authFailure('clientCredentialsToken', 'EchoedSecret')
    expect(sentValue('client_secret')).toBe('EchoedSecret')
    expect(e.message).toBe(`${surface('clientCredentialsToken').prefix}: ${BODY_ERROR}`)
    assertWithheld('200 · lowercased secret', e, 'echoedsecret')
    for (const text of renderings(e)) expect(text.includes('EchoedSecret'), text).toBe(false)
  })

  // Controls — they pass before and after: the rule reaches neither another `error` nor another status.
  const IGNORED: Array<[string, (value: string) => string]> = [
    [
      'clientCredentialsToken',
      (v) => `{"error":${v},"access_token":"freshtoken","token_type":"Bearer"}`,
    ],
    ['introspect', (v) => `{"error":${v},"active":true}`],
  ]
  it.each(IGNORED)(
    '%s — success-status OAuth error control: an `error` that is not a non-empty string is ignored',
    async (name, body) => {
      status = 200
      for (const value of [
        '400',
        '{"code":"invalid_grant"}',
        'null',
        '""',
        '["invalid_grant"]',
        'true',
      ]) {
        bodies = { ...GOOD, token: body(value), introspect: body(value) }
        const kc = newClient()
        try {
          const got = await surface(name).run(kc)
          expect(got, `${name} · ${value}`).toMatchObject(
            name === 'introspect' ? { active: true } : { accessToken: 'freshtoken' },
          )
        } finally {
          await kc.close()
        }
      }
    },
  )

  it.each(['clientCredentialsToken', 'introspect'])(
    '%s — success-status OAuth error control: a body that is not a JSON object is judged as before',
    async (name) => {
      status = 200
      for (const body of [
        'null',
        '["invalid_grant"]',
        '"invalid_grant"',
        '5',
        '{"error":"invalid_grant"',
      ]) {
        bodies = { ...GOOD, token: body, introspect: body }
        const e = await authFailure(name)
        expect(e.oauthError, `${name} · ${body}`).toBeUndefined()
        expect(e.message, `${name} · ${body}`).not.toBe(`${surface(name).prefix}: ${BODY_ERROR}`)
      }
    },
  )

  it.each(NAMES)(
    '%s — success-status OAuth error control: a status the lane rejects (201) stays rejected as before',
    async (name) => {
      status = 201
      bodies = B2
      const e = await authFailure(name)
      expect(e.message).toBe(`${surface(name).prefix}: unexpected HTTP response status code`)
      expect(e.oauthError).toBeUndefined()
    },
  )
})
