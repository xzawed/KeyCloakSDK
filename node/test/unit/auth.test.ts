import { createHash } from 'node:crypto'
import { describe, it, expect, vi, beforeAll, beforeEach } from 'vitest'

// openid-client는 네트워크 경계 — 함수형 API를 목킹해 매핑/PKCE/예외변환을 격리 검증한다.
vi.mock('openid-client', () => ({
  discovery: vi.fn(),
  clientCredentialsGrant: vi.fn(),
  authorizationCodeGrant: vi.fn(),
  refreshTokenGrant: vi.fn(),
  tokenIntrospection: vi.fn(),
  allowInsecureRequests: vi.fn(),
  customFetch: Symbol('customFetch'),
}))

import { generateKeyPair, exportJWK, SignJWT, createLocalJWKSet, type JWTVerifyGetKey } from 'jose'
import * as oidc from 'openid-client'
import { AuthClient } from '../../src/auth.js'
import { defineConfig, type KeycloakConfigInput } from '../../src/config.js'
import {
  KeycloakAuthError,
  KeycloakError,
  KeycloakTokenValidationError,
  KeycloakTransportError,
} from '../../src/errors.js'
import { JwtValidator } from '../../src/jwt.js'
import { TokenSet } from '../../src/tokens.js'

const cfg = defineConfig({
  serverUrl: 'https://kc.example.com',
  realm: 'demo',
  clientId: 'app',
  clientSecret: 'sekret',
})

const AUTH_EP = 'https://kc.example.com/realms/demo/protocol/openid-connect/auth'
const LOGOUT_EP = 'https://kc.example.com/realms/demo/protocol/openid-connect/logout'

beforeEach(() => {
  vi.clearAllMocks()
  // 대부분의 토큰 연산은 discovery 결과(Configuration)를 필요로 한다. timeout은 setter 가능.
  vi.mocked(oidc.discovery).mockResolvedValue({ timeout: 0 } as never)
})

describe('discovery 실패 경계 변환 (§4 — 원시 하위 오류 누출 금지)', () => {
  it('전송 실패(undici fetch failed)는 KeycloakTransportError로 변환한다', async () => {
    vi.mocked(oidc.discovery).mockRejectedValue(
      new TypeError('fetch failed', {
        cause: Object.assign(new Error('connect ECONNREFUSED'), { code: 'ECONNREFUSED' }),
      }),
    )
    await expect(new AuthClient(cfg).clientCredentialsToken()).rejects.toBeInstanceOf(
      KeycloakTransportError,
    )
  })

  it('타임아웃(AbortError)은 KeycloakTransportError로 변환한다', async () => {
    vi.mocked(oidc.discovery).mockRejectedValue(
      Object.assign(new Error('aborted'), { name: 'AbortError' }),
    )
    await expect(new AuthClient(cfg).refresh('rt')).rejects.toBeInstanceOf(KeycloakTransportError)
  })

  it('비전송 실패(불량 메타데이터 등)는 KeycloakAuthError로 변환한다', async () => {
    vi.mocked(oidc.discovery).mockRejectedValue(new Error('bad OIDC metadata'))
    await expect(new AuthClient(cfg).introspect('tok')).rejects.toBeInstanceOf(KeycloakAuthError)
  })

  it('readTimeoutMs(초)를 discovery 옵션 timeout으로 전달한다(최초 well-known 페치에 적용)', async () => {
    const c = defineConfig({
      serverUrl: 'https://kc',
      realm: 'r',
      clientId: 'c',
      clientSecret: 's',
      readTimeoutMs: 5000,
    })
    vi.mocked(oidc.clientCredentialsGrant).mockResolvedValue({
      access_token: 'x',
      expires_in: 1,
    } as never)
    await new AuthClient(c).clientCredentialsToken()
    expect(vi.mocked(oidc.discovery).mock.calls.at(-1)?.[4]).toMatchObject({ timeout: 5 })
  })
})

/**
 * `#discover` 의 single-flight — 진행 중인 discovery 가 있으면 뒤의 첫 호출은 새로 페치하지 않고 그 Promise 에 합류한다(단위
 * 미도달 장부의 합류 갈래 — coverage-omit-hides-security-paths). 합류가 없으면 동시에 시작한 첫 호출마다 well-known 을 따로 페치한다.
 */
describe('discovery single-flight', () => {
  it('discovery 가 끝나기 전에 시작한 두 번째 첫 호출은 그 discovery 에 합류한다 — discovery 는 한 번이다', async () => {
    let finish!: (config: never) => void
    vi.mocked(oidc.discovery).mockReturnValue(
      new Promise<never>((resolve) => {
        finish = resolve
      }),
    )
    vi.mocked(oidc.clientCredentialsGrant).mockResolvedValue({
      access_token: 'AT-cc',
      expires_in: 60,
    } as never)
    vi.mocked(oidc.refreshTokenGrant).mockResolvedValue({
      access_token: 'AT-rt',
      expires_in: 60,
    } as never)
    const auth = new AuthClient(cfg)
    const first = auth.clientCredentialsToken()
    const second = auth.refresh('rt')
    // 둘 다 시작했고 discovery 는 아직 끝나지 않았다 — 두 번째는 새 discovery 를 부르지 않았다.
    expect(oidc.discovery).toHaveBeenCalledTimes(1)
    const config = { timeout: 0 }
    finish(config as never)
    await expect(first).resolves.toMatchObject({ accessToken: 'AT-cc' })
    await expect(second).resolves.toMatchObject({ accessToken: 'AT-rt' })
    expect(oidc.discovery).toHaveBeenCalledTimes(1)
    // 둘 다 그 한 discovery 의 Configuration 으로 그랜트를 보냈다.
    expect(vi.mocked(oidc.clientCredentialsGrant).mock.calls[0]?.[0]).toBe(config)
    expect(vi.mocked(oidc.refreshTokenGrant).mock.calls[0]?.[0]).toBe(config)
  })
})

describe('createAuthorizationRequest (동기·네트워크 없음)', () => {
  it('PKCE S256 인가 URL을 모든 필수 파라미터와 함께 조립한다', () => {
    const req = new AuthClient(cfg).createAuthorizationRequest('https://app.example.com/cb')
    const u = new URL(req.url)
    expect(u.origin + u.pathname).toBe(AUTH_EP)
    expect(u.searchParams.get('response_type')).toBe('code')
    expect(u.searchParams.get('client_id')).toBe('app')
    expect(u.searchParams.get('redirect_uri')).toBe('https://app.example.com/cb')
    expect(u.searchParams.get('scope')).toBe('openid')
    expect(u.searchParams.get('code_challenge_method')).toBe('S256')
    expect(u.searchParams.get('state')).toBe(req.state)
    expect(u.searchParams.get('nonce')).toBe(req.nonce)
    // code_challenge === base64url(sha256(code_verifier)) — RFC 7636 S256
    const expected = createHash('sha256').update(req.codeVerifier).digest().toString('base64url')
    expect(u.searchParams.get('code_challenge')).toBe(expected)
  })

  it('설정된 scopes가 있으면 그대로 사용한다', () => {
    const c = defineConfig({
      serverUrl: 'https://kc',
      realm: 'r',
      clientId: 'c',
      scopes: ['openid', 'profile'],
    })
    const req = new AuthClient(c).createAuthorizationRequest('https://x/cb')
    expect(new URL(req.url).searchParams.get('scope')).toBe('openid profile')
  })

  it('호출마다 verifier/state/nonce가 서로 다르다(재사용 금지)', () => {
    const auth = new AuthClient(cfg)
    const a = auth.createAuthorizationRequest('https://x/cb')
    const b = auth.createAuthorizationRequest('https://x/cb')
    expect(a.codeVerifier).not.toBe(b.codeVerifier)
    expect(a.state).not.toBe(b.state)
    expect(a.nonce).not.toBe(b.nonce)
  })
})

describe('clientCredentialsToken', () => {
  it('토큰 응답(snake_case)을 TokenSet으로 매핑한다', async () => {
    vi.mocked(oidc.clientCredentialsGrant).mockResolvedValue({
      access_token: 'AT',
      token_type: 'Bearer',
      expires_in: 300,
      refresh_token: 'RT',
      scope: 'openid',
    } as never)
    const ts = await new AuthClient(cfg).clientCredentialsToken()
    expect(ts).toBeInstanceOf(TokenSet)
    expect(ts.accessToken).toBe('AT')
    expect(ts.expiresIn).toBe(300)
    expect(ts.refreshToken).toBe('RT')
  })

  it('설정된 scopes를 grant에 전달한다', async () => {
    const c = defineConfig({
      serverUrl: 'https://kc',
      realm: 'r',
      clientId: 'c',
      clientSecret: 's',
      scopes: ['a', 'b'],
    })
    vi.mocked(oidc.clientCredentialsGrant).mockResolvedValue({
      access_token: 'x',
      expires_in: 1,
    } as never)
    await new AuthClient(c).clientCredentialsToken()
    expect(vi.mocked(oidc.clientCredentialsGrant).mock.calls.at(-1)?.[1]).toEqual({ scope: 'a b' })
  })

  it('grant 실패를 KeycloakAuthError로 변환한다(하위 타입 은닉)', async () => {
    vi.mocked(oidc.clientCredentialsGrant).mockRejectedValue(new Error('invalid_client'))
    await expect(new AuthClient(cfg).clientCredentialsToken()).rejects.toBeInstanceOf(
      KeycloakAuthError,
    )
  })
})

describe('exchangeCode', () => {
  it('code+verifier로 토큰을 교환하고, 콜백 URL에 code+iss를 붙여 넘긴다', async () => {
    vi.mocked(oidc.authorizationCodeGrant).mockResolvedValue({
      access_token: 'AT2',
      expires_in: 60,
    } as never)
    const ts = await new AuthClient(cfg).exchangeCode('the-code', 'https://app/cb', 'verifier')
    expect(ts.accessToken).toBe('AT2')
    const [, currentUrl, checks] = vi.mocked(oidc.authorizationCodeGrant).mock.calls.at(-1)!
    expect((currentUrl as URL).searchParams.get('code')).toBe('the-code')
    expect((currentUrl as URL).searchParams.get('iss')).toBe('https://kc.example.com/realms/demo')
    expect(checks).toEqual({ pkceCodeVerifier: 'verifier' })
  })

  it('nonce를 넘기면 expectedNonce로 전달하고 id_token을 SDK 검증기에 태운다', async () => {
    vi.mocked(oidc.authorizationCodeGrant).mockResolvedValue({
      access_token: 'AT2',
      expires_in: 60,
      id_token: 'the-id-token',
    } as never)
    const validate = vi.fn()
    const idValidate = vi.fn().mockResolvedValue({})
    const withAudience = vi.fn(() => ({ validate: idValidate }))
    await new AuthClient(cfg, { validate, withAudience } as unknown as JwtValidator).exchangeCode(
      'c',
      'https://app/cb',
      'verifier',
      'the-nonce',
    )
    const [, , checks] = vi.mocked(oidc.authorizationCodeGrant).mock.calls.at(-1)!
    expect(checks).toEqual({ pkceCodeVerifier: 'verifier', expectedNonce: 'the-nonce' })
    // openid-client 는 토큰 엔드포인트 id_token 의 서명을 안 본다 — 서명·alg 핀은 SDK 검증기의 몫이다.
    // id_token 은 clientId 로 파생한 검증기에 탄다(액세스 토큰용 검증기가 아니다).
    expect(withAudience).toHaveBeenCalledWith('app')
    expect(idValidate).toHaveBeenCalledWith('the-id-token')
    expect(validate).not.toHaveBeenCalled()
  })

  it('nonce 없이 교환하면 id_token 을 검증하지 않는다(다른 언어와 같은 계약)', async () => {
    vi.mocked(oidc.authorizationCodeGrant).mockResolvedValue({
      access_token: 'AT2',
      expires_in: 60,
    } as never)
    const validate = vi.fn()
    await new AuthClient(cfg, { validate } as unknown as JwtValidator).exchangeCode(
      'c',
      'https://app/cb',
      'verifier',
    )
    expect(validate).not.toHaveBeenCalled()
  })

  it('실패를 KeycloakAuthError로 변환한다', async () => {
    vi.mocked(oidc.authorizationCodeGrant).mockRejectedValue(new Error('invalid_grant'))
    await expect(
      new AuthClient(cfg).exchangeCode('c', 'https://app/cb', 'v'),
    ).rejects.toBeInstanceOf(KeycloakAuthError)
  })
})

describe('refresh', () => {
  it('refresh_token grant 결과를 TokenSet으로 매핑한다', async () => {
    vi.mocked(oidc.refreshTokenGrant).mockResolvedValue({
      access_token: 'AT3',
      expires_in: 120,
      refresh_token: 'RT3',
    } as never)
    const ts = await new AuthClient(cfg).refresh('old-rt')
    expect(ts.accessToken).toBe('AT3')
    expect(ts.refreshToken).toBe('RT3')
    expect(vi.mocked(oidc.refreshTokenGrant).mock.calls.at(-1)?.[1]).toBe('old-rt')
  })
})

describe('introspect', () => {
  it('introspection 응답을 {active, username, clientId, claims}로 매핑한다', async () => {
    vi.mocked(oidc.tokenIntrospection).mockResolvedValue({
      active: true,
      sub: 'u1',
      username: 'bob',
      client_id: 'it-client',
    } as never)
    const r = await new AuthClient(cfg).introspect('tok')
    expect(r.active).toBe(true)
    expect(r.username).toBe('bob')
    expect(r.clientId).toBe('it-client')
    expect(r.claims['username']).toBe('bob')
  })

  it('active=false를 그대로 반영한다', async () => {
    vi.mocked(oidc.tokenIntrospection).mockResolvedValue({ active: false } as never)
    const r = await new AuthClient(cfg).introspect('tok')
    expect(r.active).toBe(false)
  })
})

describe('logout (백채널 — refresh_token revoke)', () => {
  it('end_session 엔드포인트에 refresh_token+client 인증을 POST한다', async () => {
    const fetchSpy = vi
      .spyOn(globalThis, 'fetch')
      .mockResolvedValue(new Response(null, { status: 204 }))
    await new AuthClient(cfg).logout('RT')
    const [url, init] = fetchSpy.mock.calls[0]!
    expect(String(url)).toBe(LOGOUT_EP)
    expect(init?.method).toBe('POST')
    const body = init!.body as URLSearchParams
    expect(body.get('refresh_token')).toBe('RT')
    expect(body.get('client_id')).toBe('app')
    expect(body.get('client_secret')).toBe('sekret')
    fetchSpy.mockRestore()
  })

  // 공개 클라이언트(clientSecret 없음)의 폼에는 client_secret 키가 없다 — 그 갈래가 `set` 을 건너뛰지 않으면 URLSearchParams 가
  // `undefined` 를 문자열 "undefined" 로 싣는다(단위 미도달 장부의 logout 갈래 — coverage-omit-hides-security-paths).
  it('공개 클라이언트(clientSecret 없음)는 client_id · refresh_token 만 POST 하고 client_secret 키를 싣지 않는다', async () => {
    const fetchSpy = vi
      .spyOn(globalThis, 'fetch')
      .mockResolvedValue(new Response(null, { status: 204 }))
    const publicClient = defineConfig({
      serverUrl: 'https://kc.example.com',
      realm: 'demo',
      clientId: 'app',
    })
    await new AuthClient(publicClient).logout('RT')
    const [url, init] = fetchSpy.mock.calls[0]!
    expect(String(url)).toBe(LOGOUT_EP)
    expect([...(init!.body as URLSearchParams).entries()]).toEqual([
      ['client_id', 'app'],
      ['refresh_token', 'RT'],
    ])
    fetchSpy.mockRestore()
  })

  it('비정상 응답(HTTP 4xx/5xx)을 KeycloakAuthError로 변환한다', async () => {
    const fetchSpy = vi
      .spyOn(globalThis, 'fetch')
      .mockResolvedValue(new Response(null, { status: 400 }))
    await expect(new AuthClient(cfg).logout('RT')).rejects.toBeInstanceOf(KeycloakAuthError)
    fetchSpy.mockRestore()
  })

  // SSRF 하드닝 회귀 — admin 경로는 admin.test.ts가 이미 `requestOptions.redirect`를 고정하는데
  // auth 경로만 비어 있었다(같은 위험, 한쪽만 게이트).
  it("SSRF 하드닝 — fetch init에 redirect:'manual'을 싣는다", async () => {
    const fetchSpy = vi
      .spyOn(globalThis, 'fetch')
      .mockResolvedValue(new Response(null, { status: 204 }))
    await new AuthClient(cfg).logout('RT')
    // ⚠️ 이 단언이 실제 게이트다. 옵션이 빠지면 fetch 기본값 'follow'로 돌아가고, 302를 따라가
    // 받은 무관한 200이 `response.ok`를 참으로 만들어 **logout이 조용히 성공을 반환**한다
    // (호출자는 세션이 폐기됐다고 믿지만 살아 있다 — src/auth.ts의 주석이 실측이라 적은 그 실패 모드).
    expect(fetchSpy.mock.calls[0]![1]?.redirect).toBe('manual')
    fetchSpy.mockRestore()
  })

  // Keycloak 의 성공은 204 뿐이다 — `response.ok`(2xx 전부)는 가로챈 200 로그인 페이지도 성공으로 봤다(등록부
  // logout-2xx-html-false-success, 2026-11-12 판정: 204 밖은 전부 KeycloakAuthError, 상태를 메시지에).
  it.each([
    ['200 빈 본문', new Response(null, { status: 200 })],
    [
      '200 {}',
      new Response('{}', { status: 200, headers: { 'content-type': 'application/json' } }),
    ],
    [
      '200 로그인 페이지',
      new Response('<html><body><form action="/login"></form></body></html>', {
        status: 200,
        headers: { 'content-type': 'text/html' },
      }),
    ],
    ['201', new Response(null, { status: 201 })],
    ['202', new Response(null, { status: 202 })],
    // 205 · 206 · 3xx · 4xx · 5xx 와 정확한 문구 — 실행 레그가 살린 편집(205 수용 · 502 · 504 를 transport 로 ·
    // 300 이상에서 문구의 상태 빼기)을 잡는다.
    ...[205, 206, 302, 400, 401, 404, 500, 502, 503, 504].map(
      (status) => [String(status), new Response(null, { status })] as [string, Response],
    ),
  ])('204 밖의 상태는 실패다 — %s', async (_cell, response) => {
    const fetchSpy = vi.spyOn(globalThis, 'fetch').mockResolvedValue(response)
    const got = await new AuthClient(cfg).logout('RT').then(
      () => undefined,
      (e: unknown) => e,
    )
    expect(got).toBeInstanceOf(KeycloakAuthError)
    expect((got as Error).message).toBe(`Logout failed (HTTP ${response.status})`)
    fetchSpy.mockRestore()
  })

  // 실패는 상태가 정한다 — 본문 스트림이 깨져도 날것의 하위 오류가 새지 않는다(§4 · 계급은 auth-incomplete-response.test.ts
  // 가 잰다). 실행 레그가 살린 편집 「상태 검사 앞에서 `await response.text()`」는 끊긴 200 본문에서 SDK 오류가 아닌
  // `TypeError: terminated` 를 냈다.
  it('204 가 아닌 답의 본문 스트림이 깨져도 SDK 오류다', async () => {
    const broken = new ReadableStream<Uint8Array>({
      start(controller) {
        controller.error(new TypeError('terminated'))
      },
    })
    const fetchSpy = vi
      .spyOn(globalThis, 'fetch')
      .mockResolvedValue(new Response(broken, { status: 200 }))
    const got = await new AuthClient(cfg).logout('RT').then(
      () => undefined,
      (e: unknown) => e,
    )
    expect(got).toBeInstanceOf(KeycloakError)
    fetchSpy.mockRestore()
  })

  it('3xx를 성공으로 오인하지 않는다 — 302는 KeycloakAuthError다', async () => {
    // 'manual'이 3xx를 그대로 표면화하면 아래 상태 검사가 실패로 처리한다는 계약을 고정한다.
    // ⚠️ fetch가 목이라 이 케이스만으로는 옵션 유무를 가리지 못한다 — 대조군은 위 단언이다.
    const fetchSpy = vi
      .spyOn(globalThis, 'fetch')
      .mockResolvedValue(new Response(null, { status: 302 }))
    await expect(new AuthClient(cfg).logout('RT')).rejects.toBeInstanceOf(KeycloakAuthError)
    fetchSpy.mockRestore()
  })
})

describe('validate — expectedAudience', () => {
  let priv: Awaited<ReturnType<typeof generateKeyPair>>['privateKey']
  let keys: JWTVerifyGetKey

  beforeAll(async () => {
    const kp = await generateKeyPair('RS256')
    priv = kp.privateKey
    const jwk = await exportJWK(kp.publicKey)
    keys = createLocalJWKSet({ keys: [{ ...jwk, kid: 'k1', use: 'sig', alg: 'RS256' }] })
  })

  /** Keycloak 의 액세스 토큰 모양 — typ "Bearer"(액세스 검증은 Bearer · DPoP 만 받는다). */
  const sign = (aud: string) =>
    new SignJWT({ sub: 'u', aud, typ: 'Bearer' })
      .setProtectedHeader({ alg: 'RS256', kid: 'k1' })
      .setIssuedAt()
      .setIssuer('https://kc.example.com/realms/demo')
      .setExpirationTime('5m')
      .sign(priv)

  /** 원격 JWKS 대신 로컬 키셋을 쓰는 검증기로 조립한다 — 실제 aud 판정을 네트워크 없이 관찰. */
  const authWithLocalJwks = (input: KeycloakConfigInput): AuthClient => {
    const spy = vi
      .spyOn(JwtValidator, 'forJwksUri')
      .mockImplementation((_uri, opts) => JwtValidator.forKeySource(keys, opts))
    try {
      return new AuthClient(defineConfig(input))
    } finally {
      spy.mockRestore()
    }
  }

  const base: KeycloakConfigInput = {
    serverUrl: 'https://kc.example.com',
    realm: 'demo',
    clientId: 'app',
  }

  it('미지정이면 clientId를 기대한다(기존 동작 유지)', async () => {
    const auth = authWithLocalJwks(base)
    await expect(auth.validate(await sign('app'))).resolves.toMatchObject({ audience: ['app'] })
    await expect(auth.validate(await sign('some-api'))).rejects.toBeInstanceOf(
      KeycloakTokenValidationError,
    )
  })

  it('설정하면 그 값을 기대하고 clientId만 담긴 토큰은 거부한다', async () => {
    // 기본 realm은 client-credentials 토큰 aud에 client_id를 넣지 않는다(audience 매퍼 필요) —
    // 리소스 서버처럼 API 이름이 aud인 경우를 위한 탈출구.
    const auth = authWithLocalJwks({ ...base, expectedAudience: 'some-api' })
    await expect(auth.validate(await sign('some-api'))).resolves.toMatchObject({
      audience: ['some-api'],
    })
    await expect(auth.validate(await sign('app'))).rejects.toBeInstanceOf(
      KeycloakTokenValidationError,
    )
  })
})

/**
 * 공개 `AuthClient.validate` 의 종류 판정(등록부 access-token-typ-deny-list) — Keycloak 자신의 리소스 쪽 검사처럼 허용 목록이다:
 * payload typ 이 ASCII 대소문자를 무시하고 Bearer 나 DPoP 와 같은 문자열일 때만 받는다. 기본 설정(audience = clientId)에서
 * typ 이 없는 realm 서명 JWT — JARM 인가 응답(aud = client id) — 가 액세스 토큰으로 받아들여지던 틈이다. 검증기 칸은
 * `jwt.test.ts` 다.
 */
describe('validate — 액세스 토큰의 종류(typ 허용 목록)', () => {
  const ISSUER = 'https://kc.example.com/realms/demo'
  const NOT_ACCESS = 'not an access token (typ is not Bearer or DPoP)'
  let priv: Awaited<ReturnType<typeof generateKeyPair>>['privateKey']
  let keys: JWTVerifyGetKey

  beforeAll(async () => {
    const kp = await generateKeyPair('RS256')
    priv = kp.privateKey
    const jwk = await exportJWK(kp.publicKey)
    keys = createLocalJWKSet({ keys: [{ ...jwk, kid: 'k1', use: 'sig', alg: 'RS256' }] })
  })

  const sign = (claims: Record<string, unknown>) =>
    new SignJWT({ aud: 'app', ...claims })
      .setProtectedHeader({ alg: 'RS256', kid: 'k1' })
      .setIssuedAt()
      .setIssuer(ISSUER)
      .setExpirationTime('5m')
      .sign(priv)

  /** 로컬 키셋 검증기로 조립한다(기본 설정 — 기대 audience 는 clientId `app`). */
  const auth = (): AuthClient => {
    const spy = vi
      .spyOn(JwtValidator, 'forJwksUri')
      .mockImplementation((_uri, opts) => JwtValidator.forKeySource(keys, opts))
    try {
      return new AuthClient(
        defineConfig({ serverUrl: 'https://kc.example.com', realm: 'demo', clientId: 'app' }),
      )
    } finally {
      spy.mockRestore()
    }
  }

  const refusal = async (call: Promise<unknown>): Promise<Error> => {
    const outcome = await call.then(
      () => undefined,
      (e: unknown) => e,
    )
    if (!(outcome instanceof Error)) throw new Error('expected a refusal, got success')
    return outcome
  }

  it.each(['Bearer', 'bearer', 'DPoP', 'dpop'])('typ "%s" 인 액세스 토큰을 받는다', async (typ) => {
    await expect(auth().validate(await sign({ sub: 'u', typ }))).resolves.toMatchObject({
      subject: 'u',
      audience: ['app'],
      claims: { typ },
    })
  })

  it('JARM 인가 응답 모양(typ 없음 · code · state · iss · aud = client id · exp)을 상수 문구로 거부한다', async () => {
    const jarm = await sign({ code: 'c0de-from-the-browser-url', state: 'st-1' })
    const refused = await refusal(auth().validate(jarm))
    expect(refused).toBeInstanceOf(KeycloakTokenValidationError)
    expect(refused.message).toBe(NOT_ACCESS)
  })

  it.each([
    ['typ 없음', undefined],
    ['at+jwt', 'at+jwt'],
    ['토큰이 고른 문자열', 'CANARY-TYP-7c2e'],
    ['숫자', 1],
    ['null', null],
    ['배열', ['Bearer']],
  ])('%s → 상수 문구로 거부한다(typ 을 싣지 않는다)', async (_name, typ) => {
    const token = await sign(typ === undefined ? { sub: 'u' } : { sub: 'u', typ })
    const refused = await refusal(auth().validate(token))
    expect(refused).toBeInstanceOf(KeycloakTokenValidationError)
    expect(refused.message).toBe(NOT_ACCESS)
    expect(refused.message).not.toContain('CANARY')
  })

  it.each(['ID', 'Refresh', 'Offline', 'Logout', 'Serialized-ID'])(
    '알려진 종류 typ "%s" 는 지금의 문구다',
    async (typ) => {
      const refused = await refusal(auth().validate(await sign({ sub: 'u', typ })))
      expect(refused).toBeInstanceOf(KeycloakTokenValidationError)
      expect(refused.message).toBe(`not an access token (typ "${typ}")`)
    },
  )
})

/**
 * `expectedAudience` 재정의 아래의 코드 교환 — id_token `aud` 는 **clientId** 로 검사한다(OIDC Core §2·§3.1.3.7).
 * 재정의는 액세스 토큰(`validate`)의 리소스 서버 제한이다. openid-client 가 목이라 aud 판정은 SDK 검증기
 * 하나뿐이다(진짜 openid-client 는 client_id 로 먼저 거른다 — `auth-id-token-signature.test.ts`).
 */
describe('exchangeCode — expectedAudience 재정의(id_token aud 는 clientId)', () => {
  const ISSUER = 'https://kc.example.com/realms/demo'
  let priv: Awaited<ReturnType<typeof generateKeyPair>>['privateKey']
  let keys: JWTVerifyGetKey

  beforeAll(async () => {
    const kp = await generateKeyPair('RS256')
    priv = kp.privateKey
    const jwk = await exportJWK(kp.publicKey)
    keys = createLocalJWKSet({ keys: [{ ...jwk, kid: 'k1', use: 'sig', alg: 'RS256' }] })
  })

  const now = () => Math.floor(Date.now() / 1000)
  /**
   * Keycloak 의 id_token 모양 — typ "ID" 를 싣는다(종류 규칙이 다른 검사의 판정을 가로채지 않게). `extra` 가 덮는다 —
   * `typ: undefined` 는 클레임을 뺀다(JSON 직렬화가 버린다). 액세스 토큰은 `extra: { typ: 'Bearer' }` 로 만든다.
   */
  const sign = (
    aud: string | string[],
    {
      iss = ISSUER,
      exp = now() + 300,
      extra = {},
    }: { iss?: string; exp?: number | null; extra?: Record<string, unknown> } = {},
  ) => {
    const jwt = new SignJWT({ sub: 'u', aud, nonce: 'the-nonce', typ: 'ID', ...extra })
      .setProtectedHeader({ alg: 'RS256', kid: 'k1' })
      .setIssuedAt(now() - 120)
      .setIssuer(iss)
    return (exp === null ? jwt : jwt.setExpirationTime(exp)).sign(priv)
  }

  /** 로컬 키셋 검증기로 조립한다 — 실제 aud 판정을 네트워크 없이 관찰. `expectedAudience` 가 없으면 재정의 없음. */
  const authWith = (expectedAudience?: string): AuthClient => {
    const spy = vi
      .spyOn(JwtValidator, 'forJwksUri')
      .mockImplementation((_uri, opts) => JwtValidator.forKeySource(keys, opts))
    try {
      return new AuthClient(
        defineConfig({
          serverUrl: 'https://kc.example.com',
          realm: 'demo',
          clientId: 'app',
          ...(expectedAudience === undefined ? {} : { expectedAudience }),
        }),
      )
    } finally {
      spy.mockRestore()
    }
  }
  const overridden = (): AuthClient => authWith('some-api')

  const exchangeWith = (auth: AuthClient, idToken: string) => {
    vi.mocked(oidc.authorizationCodeGrant).mockResolvedValue({
      access_token: 'AT',
      expires_in: 60,
      id_token: idToken,
    } as never)
    return auth.exchangeCode('c', 'https://app/cb', 'verifier', 'the-nonce')
  }

  /**
   * 교환이 id_token 검증에서 거부됐다 — 문구가 아니라 타입으로 가린다. cause 는 `scrubCause` 가 만든
   * 사본이라(`src/errors.ts`) 인스턴스가 아니라 이름으로 본다.
   */
  const refusedAtIdToken = async (call: Promise<unknown>): Promise<Error> => {
    const refused = await call.then(
      () => undefined,
      (e: unknown) => e,
    )
    expect(refused).toBeInstanceOf(KeycloakAuthError)
    expect(((refused as Error).cause as Error | undefined)?.name).toBe(
      KeycloakTokenValidationError.name,
    )
    return refused as Error
  }

  /** 거부의 원인이 azp 규칙이다 — 다른 id_token 검사(서명 · iss · aud · exp)의 거부가 이 초록을 대신 채우지 못하게. */
  const refusedForAzp = async (call: Promise<unknown>) => {
    const refused = await refusedAtIdToken(call)
    expect(refused.message).toBe('Authorization code exchange failed: invalid id_token')
    expect((refused.cause as Error).message).toContain('azp')
  }

  it('(A1) 재정의해도 aud 에 clientId 가 있는 id_token 의 교환은 통과한다', async () => {
    const auth = overridden()
    const single = await sign('app')
    await expect(exchangeWith(auth, single)).resolves.toMatchObject({ idToken: single })
    // Keycloak 「Add to ID token」 audience 매퍼의 모양 — [client_id, extra]. Keycloak 은 id_token 에 azp = client id 를
    // 싣는다 — aud 가 둘 이상인 id_token 은 그것이 있어야 통과한다(아래 azp 묶음).
    const multi = await sign(['app', 'some-api'], { extra: { azp: 'app' } })
    await expect(exchangeWith(auth, multi)).resolves.toMatchObject({ idToken: multi })
  })

  // 재정의 아래에서도 azp 는 client id 와 대조한다 — 재정의 값(액세스 토큰이 향하는 리소스 서버)이 아니다.
  it('(A5) 재정의 아래에서도 azp 는 clientId 와 대조한다 — 재정의 값인 azp · azp 없는 다중 aud 는 거부한다', async () => {
    const auth = overridden()
    await refusedForAzp(
      exchangeWith(auth, await sign(['app', 'some-api'], { extra: { azp: 'some-api' } })),
    )
    await refusedForAzp(exchangeWith(auth, await sign(['app', 'some-api'])))
  })

  it('(A2) aud 에 clientId 가 없는 id_token 은 거부한다 — aud 가 재정의 값과 같아도', async () => {
    const auth = overridden()
    await refusedAtIdToken(exchangeWith(auth, await sign('some-api')))
    await refusedAtIdToken(exchangeWith(auth, await sign('other')))
  })

  it('(A3) 교환 뒤에도 액세스 토큰 validate 는 재정의 값을 쓴다', async () => {
    const auth = overridden()
    await exchangeWith(auth, await sign('app'))
    const bearer = { extra: { typ: 'Bearer' } } // 액세스 토큰(Keycloak 의 typ)
    await expect(auth.validate(await sign('some-api', bearer))).resolves.toMatchObject({
      audience: ['some-api'],
    })
    await expect(auth.validate(await sign('app', bearer))).rejects.toBeInstanceOf(
      KeycloakTokenValidationError,
    )
  })

  it('(A4) 재정의 아래에서도 iss · alg 핀 · exp/스큐 · nonce 전달은 그대로다', async () => {
    const auth = overridden()
    await refusedAtIdToken(exchangeWith(auth, await sign('app', { iss: 'https://evil.example' })))
    await refusedAtIdToken(exchangeWith(auth, await sign('app', { exp: now() - 60 }))) // 스큐 30초 밖
    await refusedAtIdToken(exchangeWith(auth, await sign('app', { exp: null }))) // exp 없음
    // 스큐 안(10초 전 만료)은 통과한다 — 스큐가 0 으로 떨어지지 않았다.
    await expect(exchangeWith(auth, await sign('app', { exp: now() - 10 }))).resolves.toBeDefined()
    // alg 핀: 허용 목록(RS256) 밖의 HS256 은 서명이 맞아도 거부한다.
    const hs = await new SignJWT({ sub: 'u', aud: 'app', nonce: 'the-nonce', typ: 'ID' })
      .setProtectedHeader({ alg: 'HS256', kid: 'k1' })
      .setIssuedAt()
      .setIssuer(ISSUER)
      .setExpirationTime('5m')
      .sign(new TextEncoder().encode('a-shared-secret-of-at-least-32-bytes!!'))
    await refusedAtIdToken(exchangeWith(auth, hs))
    // nonce 대조는 openid-client 의 몫이다 — 재정의가 그 전달을 바꾸지 않는다.
    const [, , checks] = vi.mocked(oidc.authorizationCodeGrant).mock.calls.at(-1)!
    expect(checks).toEqual({ pkceCodeVerifier: 'verifier', expectedNonce: 'the-nonce' })
  })

  /**
   * id_token 의 typ · azp(SDK 층 — openid-client 는 목이다). (A) `validate` 의 typ 거부(액세스 토큰이 아닌 Keycloak
   * 토큰)는 액세스 토큰 자리에만 걸린다 — Keycloak 의 id_token 은 typ "ID" 이므로 교환에 걸리면 정상 교환이 전부 실패한다.
   * (B) OIDC Core §3.1.3.7 4·5: aud 가 둘 이상이면 azp 가 있어야 하고, azp 가 있으면 clientId 와 같은 문자열이어야 한다.
   * 아래 토큰은 전부 Keycloak 처럼 typ "ID" 를 싣는다.
   */
  it('(B1) Keycloak 모양의 id_token(typ "ID" · azp = clientId)은 교환을 통과하고, 같은 토큰을 validate 는 거부한다', async () => {
    const auth = authWith()
    const idToken = await sign('app', { extra: { typ: 'ID', azp: 'app' } })
    await expect(exchangeWith(auth, idToken)).resolves.toMatchObject({ idToken })
    const refused = await auth.validate(idToken).then(
      () => undefined,
      (e: unknown) => e,
    )
    expect(refused).toBeInstanceOf(KeycloakTokenValidationError)
    expect((refused as Error).message).toBe('not an access token (typ "ID")')
  })

  it.each([
    ['aud 하나 · azp 없음', 'app', undefined],
    ['aud 하나 · azp = clientId', 'app', 'app'],
    ['aud 둘 · azp = clientId', ['app', 'other'], 'app'],
    ['aud 둘(순서 반대) · azp = clientId', ['other', 'app'], 'app'],
  ])('(B2) %s → 교환을 통과한다', async (_name, aud, azp) => {
    const idToken = await sign(aud, { extra: { typ: 'ID', ...(azp === undefined ? {} : { azp }) } })
    await expect(exchangeWith(authWith(), idToken)).resolves.toMatchObject({ idToken })
  })

  it.each([
    ['aud 하나 · azp 가 다른 클라이언트', 'app', 'evil'],
    ['aud 둘 · azp 없음', ['app', 'evil'], undefined],
    ['aud 둘 · azp 가 다른 aud', ['app', 'evil'], 'evil'],
    ['azp 가 숫자', 'app', 42],
    ['azp 가 clientId 를 담은 배열', 'app', ['app']],
    ['azp 가 JSON null', 'app', null],
  ])('(B3) %s → invalid id_token(원인이 azp 를 말한다)', async (_name, aud, azp) => {
    const idToken = await sign(aud, { extra: { typ: 'ID', ...(azp === undefined ? {} : { azp }) } })
    await refusedForAzp(exchangeWith(authWith(), idToken))
  })

  // (B4) 종류 — 교환의 id_token 검사와 공개 `validateIdToken` 은 한 길이라, payload typ 이 정확히 "ID" 가 아닌 id_token 은 교환도
  // 거부한다(대응은 지금처럼 invalid id_token). `typ: undefined` 는 클레임을 빼는 것이다(JSON 직렬화가 버린다).
  it.each([
    ['typ 없음', { typ: undefined }],
    ['typ "Bearer"', { typ: 'Bearer' }],
    ['typ "bearer"(소문자)', { typ: 'bearer' }],
    ['typ 숫자', { typ: 1 }],
    ['typ "Logout"', { typ: 'Logout' }],
  ])('(B4) %s 인 id_token → invalid id_token(원인이 종류를 말한다)', async (_name, extra) => {
    const idToken = await sign('app', { extra: { azp: 'app', ...extra } })
    const refused = await refusedAtIdToken(exchangeWith(authWith(), idToken))
    expect(refused.message).toBe('Authorization code exchange failed: invalid id_token')
    expect((refused.cause as Error).message).toBe('not an id_token (typ is not "ID")')
  })
})

/**
 * `validateIdToken` — 공개 id_token 검증(등록부 id-token-validator-not-public). 교환이 nonce 를 대조하기 **전에** 돌리는 그
 * 검사다(같은 내부 함수): 서명(`validate` 와 같은 키 저장소) · alg 핀 · 길이 상한 · iss · aud ∋ clientId(`expectedAudience`
 * 가 아니다) · exp · 스큐 · azp(OIDC Core §3.1.3.7 4·5) · 종류(payload `typ` 이 정확히 "ID"). nonce 는 보지 않는다. 실패는
 * `validate` 와 같은 `KeycloakTokenValidationError` 다.
 */
describe('validateIdToken — 공개 id_token 검증(교환의 id_token 검사 그대로)', () => {
  const ISSUER = 'https://kc.example.com/realms/demo'
  /** 종류 거부의 문구 — 상수다(토큰이 고른 typ 를 싣지 않는다). */
  const NOT_ID_TOKEN = 'not an id_token (typ is not "ID")'
  let priv: Awaited<ReturnType<typeof generateKeyPair>>['privateKey']
  let keys: JWTVerifyGetKey

  beforeAll(async () => {
    const kp = await generateKeyPair('RS256')
    priv = kp.privateKey
    const jwk = await exportJWK(kp.publicKey)
    keys = createLocalJWKSet({ keys: [{ ...jwk, kid: 'k1', use: 'sig', alg: 'RS256' }] })
  })

  const sign = (claims: Record<string, unknown>, iss = ISSUER) =>
    new SignJWT({ sub: 'u', ...claims })
      .setProtectedHeader({ alg: 'RS256', kid: 'k1' })
      .setIssuedAt()
      .setIssuer(iss)
      .setExpirationTime('5m')
      .sign(priv)

  /** 로컬 키셋 검증기로 조립한다 — 실제 판정을 네트워크 없이 관찰. `expectedAudience` 가 없으면 재정의 없음. */
  const authWith = (expectedAudience?: string): AuthClient => {
    const spy = vi
      .spyOn(JwtValidator, 'forJwksUri')
      .mockImplementation((_uri, opts) => JwtValidator.forKeySource(keys, opts))
    try {
      return new AuthClient(
        defineConfig({
          serverUrl: 'https://kc.example.com',
          realm: 'demo',
          clientId: 'app',
          ...(expectedAudience === undefined ? {} : { expectedAudience }),
        }),
      )
    } finally {
      spy.mockRestore()
    }
  }

  /** 실패해야 하는 호출의 오류 — 성공하면 그것이 곧 실패다. */
  const refusal = async (call: Promise<unknown>): Promise<Error> => {
    const outcome = await call.then(
      () => undefined,
      (e: unknown) => e,
    )
    if (!(outcome instanceof Error)) throw new Error('expected a refusal, got success')
    return outcome
  }

  it('Keycloak 모양의 id_token(typ "ID" · aud = azp = clientId)을 받고 그 클레임을 돌려준다', async () => {
    const token = await sign({ aud: 'app', azp: 'app', typ: 'ID', nonce: 'n' })
    await expect(authWith().validateIdToken(token)).resolves.toMatchObject({
      subject: 'u',
      audience: ['app'],
      issuer: ISSUER,
      claims: { typ: 'ID', azp: 'app', nonce: 'n' },
    })
  })

  // 이 규칙이 닫는 틈: aud 에 clientId 가 있고 azp = clientId 인 액세스 토큰은 종류 말고는 id_token 검사를 전부 지난다.
  it('aud ∋ clientId · azp = clientId 인 액세스 모양 토큰(typ "Bearer")을 상수 문구로 거부한다', async () => {
    const token = await sign({ aud: ['app', 'account'], azp: 'app', typ: 'Bearer' })
    const auth = authWith()
    // 전제: 같은 토큰을 액세스 검증은 받는다 — 거부를 가르는 것은 종류뿐이다.
    await expect(auth.validate(token)).resolves.toMatchObject({ audience: ['app', 'account'] })
    const refused = await refusal(auth.validateIdToken(token))
    expect(refused).toBeInstanceOf(KeycloakTokenValidationError)
    expect(refused.message).toBe(NOT_ID_TOKEN)
  })

  it.each([
    ['typ 없음', {}],
    ['typ "bearer"(소문자)', { typ: 'bearer' }],
    ['typ "id"(소문자)', { typ: 'id' }],
    ['typ "ID "(뒤 공백)', { typ: 'ID ' }],
    ['typ 빈 문자열', { typ: '' }],
    ['typ 숫자', { typ: 1 }],
    ['typ null', { typ: null }],
    ['typ ["ID"]', { typ: ['ID'] }],
    ['typ {typ:"ID"}', { typ: { typ: 'ID' } }],
    ['typ "Refresh"', { typ: 'Refresh' }],
    ['typ "Serialized-ID"', { typ: 'Serialized-ID' }],
    ['토큰이 고른 문자열', { typ: 'CANARY-TYP-0f3a' }],
  ])('%s → 거부(문구는 상수 — typ 값을 싣지 않는다)', async (_name, extra) => {
    const token = await sign({ aud: 'app', azp: 'app', ...extra })
    const refused = await refusal(authWith().validateIdToken(token))
    expect(refused).toBeInstanceOf(KeycloakTokenValidationError)
    expect(refused.message).toBe(NOT_ID_TOKEN)
    expect(refused.cause).toBeUndefined()
  })

  it('back-channel logout 토큰 모양(typ "Logout" · aud = clientId · azp 없음 · exp 있음)을 거부한다', async () => {
    const token = await sign({
      aud: 'app',
      typ: 'Logout',
      sid: 'session-1',
      events: { 'http://schemas.openid.net/event/backchannel-logout': {} },
    })
    const refused = await refusal(authWith().validateIdToken(token))
    expect(refused).toBeInstanceOf(KeycloakTokenValidationError)
    expect(refused.message).toBe(NOT_ID_TOKEN)
  })

  it('expectedAudience 재정의 아래에서 aud 가 재정의 값뿐인 id_token 은 거부한다 — 기대 aud 는 clientId 다', async () => {
    const auth = authWith('some-api')
    const refused = await refusal(auth.validateIdToken(await sign({ aud: 'some-api', typ: 'ID' })))
    expect(refused).toBeInstanceOf(KeycloakTokenValidationError)
    expect(refused.message).toBe('JWT validation failed: unexpected "aud" claim value')
    // 대조: 같은 재정의 아래 aud = clientId 인 id_token 은 받는다(재정의가 id_token 에 걸리지 않는다).
    await expect(
      auth.validateIdToken(await sign({ aud: 'app', typ: 'ID' })),
    ).resolves.toMatchObject({ audience: ['app'] })
  })

  it('azp 규칙 · iss · exp 도 교환의 검사 그대로다', async () => {
    const auth = authWith()
    const cases: Array<[Record<string, unknown>, string, string | RegExp]> = [
      [
        { aud: ['app', 'evil'], typ: 'ID' },
        ISSUER,
        'id_token has more than one audience but no azp',
      ],
      [{ aud: 'app', azp: 'evil', typ: 'ID' }, ISSUER, 'id_token azp is not this client'],
      [
        { aud: 'app', typ: 'ID' },
        'https://evil.example',
        /^JWT validation failed: unexpected "iss"/,
      ],
    ]
    for (const [claims, iss, want] of cases) {
      const refused = await refusal(auth.validateIdToken(await sign(claims, iss)))
      expect(refused).toBeInstanceOf(KeycloakTokenValidationError)
      if (typeof want === 'string') expect(refused.message).toBe(want)
      else expect(refused.message).toMatch(want)
    }
    const expired = await new SignJWT({ sub: 'u', aud: 'app', typ: 'ID' })
      .setProtectedHeader({ alg: 'RS256', kid: 'k1' })
      .setIssuer(ISSUER)
      .setIssuedAt(Math.floor(Date.now() / 1000) - 600)
      .setExpirationTime(Math.floor(Date.now() / 1000) - 60) // 스큐(30초) 밖
      .sign(priv)
    const late = await refusal(auth.validateIdToken(expired))
    expect(late).toBeInstanceOf(KeycloakTokenValidationError)
    expect(late.message).toMatch(/^JWT validation failed: "exp" claim timestamp check failed/)
  })

  it('주입된 검증기에서 clientId 로 한 번 파생해 쓴다 — 액세스 검증기를 그대로 쓰지 않는다', async () => {
    const idValidate = vi.fn().mockResolvedValue({ subject: 'u' })
    const withAudience = vi.fn(() => ({ validate: idValidate }))
    const validate = vi.fn()
    const auth = new AuthClient(cfg, { validate, withAudience } as unknown as JwtValidator)
    await expect(auth.validateIdToken('t1')).resolves.toEqual({ subject: 'u' })
    await auth.validateIdToken('t2')
    expect(withAudience).toHaveBeenCalledTimes(1)
    expect(withAudience).toHaveBeenCalledWith('app')
    expect(idValidate.mock.calls).toEqual([['t1'], ['t2']])
    expect(validate).not.toHaveBeenCalled()
  })

  it('교환과 한 길이다 — 교환이 파생한 검증기를 공개 메서드가 이어 쓴다', async () => {
    vi.mocked(oidc.authorizationCodeGrant).mockResolvedValue({
      access_token: 'AT',
      expires_in: 60,
      id_token: 'the-id-token',
    } as never)
    const idValidate = vi.fn().mockResolvedValue({ claims: {} })
    const withAudience = vi.fn(() => ({ validate: idValidate }))
    const auth = new AuthClient(cfg, { validate: vi.fn(), withAudience } as unknown as JwtValidator)
    await auth.exchangeCode('c', 'https://app/cb', 'verifier', 'the-nonce')
    await auth.validateIdToken('later')
    expect(withAudience).toHaveBeenCalledTimes(1)
    expect(idValidate.mock.calls).toEqual([['the-id-token'], ['later']])
  })
})

describe('validate', () => {
  it('주입된 JwtValidator에 위임한다(auth는 검증 로직을 재구현하지 않는다)', async () => {
    const validated = { subject: 'u', audience: ['app'], issuer: 'iss', claims: {} }
    const fakeValidator = { validate: vi.fn().mockResolvedValue(validated) }
    const auth = new AuthClient(cfg, fakeValidator as unknown as JwtValidator)
    await expect(auth.validate('tok')).resolves.toBe(validated)
    expect(fakeValidator.validate).toHaveBeenCalledWith('tok')
  })
})
