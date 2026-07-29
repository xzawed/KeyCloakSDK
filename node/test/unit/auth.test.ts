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

  it('nonce를 넘기면 expectedNonce로 전달한다(openid-client가 id_token nonce를 검증하도록)', async () => {
    vi.mocked(oidc.authorizationCodeGrant).mockResolvedValue({
      access_token: 'AT2',
      expires_in: 60,
    } as never)
    await new AuthClient(cfg).exchangeCode('c', 'https://app/cb', 'verifier', 'the-nonce')
    const [, , checks] = vi.mocked(oidc.authorizationCodeGrant).mock.calls.at(-1)!
    expect(checks).toEqual({ pkceCodeVerifier: 'verifier', expectedNonce: 'the-nonce' })
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

  it('비정상 응답(HTTP 4xx/5xx)을 KeycloakAuthError로 변환한다', async () => {
    const fetchSpy = vi
      .spyOn(globalThis, 'fetch')
      .mockResolvedValue(new Response(null, { status: 400 }))
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

  const sign = (aud: string) =>
    new SignJWT({ sub: 'u', aud })
      .setProtectedHeader({ alg: 'RS256', kid: 'k1' })
      .setIssuedAt()
      .setIssuer('https://kc.example.com/realms/demo')
      .setExpirationTime('5m')
      .sign(priv)

  /** 원격 JWKS 대신 로컬 키셋을 쓰는 검증기로 조립한다 — 실제 aud 판정을 네트워크 없이 관찰. */
  const authWithLocalJwks = (input: KeycloakConfigInput): AuthClient => {
    const spy = vi
      .spyOn(JwtValidator, 'forJwksUri')
      .mockImplementation((_uri, opts) => new JwtValidator(keys, opts))
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

describe('validate', () => {
  it('주입된 JwtValidator에 위임한다(auth는 검증 로직을 재구현하지 않는다)', async () => {
    const validated = { subject: 'u', audience: ['app'], issuer: 'iss', claims: {} }
    const fakeValidator = { validate: vi.fn().mockResolvedValue(validated) }
    const auth = new AuthClient(cfg, fakeValidator as unknown as JwtValidator)
    await expect(auth.validate('tok')).resolves.toBe(validated)
    expect(fakeValidator.validate).toHaveBeenCalledWith('tok')
  })
})
