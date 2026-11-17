import { format, inspect } from 'node:util'
import { afterAll, beforeAll, describe, expect, it, vi } from 'vitest'
import {
  KeycloakAuthError,
  KeycloakClient,
  KeycloakTokenValidationError,
  type AuthorizationRequest,
  type KeycloakConfigInput,
} from '../../src/index.js'
import { browserLogin, stripNonce } from './browser-login.js'
import { startKeycloak, type KeycloakHarness } from './support.js'

/**
 * 인가 코드 교환 E2E — 실제 Keycloak 이 발급한 코드·id_token 으로(python `test_code_exchange_it.py` 이식).
 *
 * `exchangeCode` 의 nonce 대조는 지금까지 openid-client 를 목킹한 단위 테스트로만 돌았다(`auth.test.ts` 는
 * `expectedNonce` 를 **넘기는지**만 본다). 여기서는 `browserLogin` 으로 실제 로그인해 받은 코드를 교환하고,
 * **서버가 서명한** 토큰에 대고 거부 경로까지 돈다. realm 의 `it-web`(RS256 · PKCE S256 강제 · aud 매퍼)과
 * `it-web-hs256`(id_token 을 HS256 서명)이 짝이다.
 *
 * ⚠️ 거부 사유는 오류의 **원인 사슬**로 가린다 — `KeycloakError` 가 정화해 남기는 이름·메시지·code 다
 * (`src/errors.ts` 의 `scrubCause`). node 의 `KeycloakAuthError` 는 OAuth `error` 코드(`invalid_grant`)를
 * 싣지 않으므로(python 의 `.error` 에 해당하는 것이 없다), 서버의 거부는 `OAUTH_RESPONSE_BODY_ERROR`
 * (토큰 엔드포인트가 오류 본문으로 답했다)까지만 공개 표면에서 보인다.
 */

const REDIRECT_URI = 'http://localhost/it-callback'
const WEB_CLIENT_SECRETS = { 'it-web': 'it-web-secret', 'it-web-hs256': 'it-web-hs256-secret' }
type WebClientId = keyof typeof WEB_CLIENT_SECRETS
const ALICE = ['alice', 'alice-password'] as const

/** 토큰 엔드포인트가 오류 본문(`{"error": …}`)으로 답했다 — 서버의 거부. */
const SERVER_REFUSED = 'OAUTH_RESPONSE_BODY_ERROR'

function webConfig(
  serverUrl: string,
  clientId: WebClientId = 'it-web',
  signatureAlgorithms: string[] = ['RS256'],
): KeycloakConfigInput {
  return {
    serverUrl,
    realm: 'it-realm',
    clientId,
    clientSecret: WEB_CLIENT_SECRETS[clientId],
    signatureAlgorithms,
  }
}

// 서버의 id_token 클레임은 **교환이 그것을 검증하는 그 길** — 공개 `AuthClient.validateIdToken`(서명 · alg 핀 · iss · aud =
// clientId · exp · 종류 typ "ID" · azp) — 으로 읽는다. `validate` 는 액세스 토큰만 받는다: 서버의 id_token 은 typ "ID" 라
// 거부된다.

/** JWT 페이로드를 **검증 없이** 읽는다 — 서버가 보낸 것의 전제만 잰다(판정은 SDK 가 한다). */
function unverifiedPayload(token: string): Record<string, unknown> {
  return JSON.parse(Buffer.from(token.split('.')[1] ?? '', 'base64url').toString()) as Record<
    string,
    unknown
  >
}

async function login(kc: KeycloakClient): Promise<{ request: AuthorizationRequest; code: string }> {
  const request = kc.auth.createAuthorizationRequest(REDIRECT_URI)
  return { request, code: await browserLogin(request, REDIRECT_URI, ...ALICE) }
}

/** 실패해야 하는 호출의 오류 — 성공하면 그것이 곧 실패다. */
async function refusal(call: Promise<unknown>): Promise<Error> {
  const outcome = await call.then(
    () => undefined,
    (e: unknown) => e,
  )
  if (!(outcome instanceof Error)) {
    throw new Error(`expected a refusal, got ${outcome === undefined ? 'success' : typeof outcome}`)
  }
  return outcome
}

/** 원인 사슬의 고리들(바깥 → 안). */
function links(error: Error): Array<{ name: string; message: string; code: unknown }> {
  const out = []
  for (let link: unknown = error; link instanceof Error; link = link.cause) {
    out.push({ name: link.name, message: link.message, code: (link as { code?: unknown }).code })
  }
  return out
}

/** 오류가 소비자 손에서 찍힐 수 있는 모든 모양 — 원인 사슬의 각 고리까지. */
function renderings(error: Error): string {
  const out = [
    String(error),
    JSON.stringify(error),
    inspect(error, { depth: Infinity, showHidden: true }),
    format('%o', error),
  ]
  for (let link: unknown = error; link instanceof Error; link = link.cause) {
    out.push(link.message, link.stack ?? '', String(link), JSON.stringify(link))
  }
  return out.join('\n')
}

describe('인가 코드 교환 E2E (실제 Keycloak 26.6 · 브라우저 없는 로그인)', () => {
  let harness: KeycloakHarness
  let kc: KeycloakClient
  let aliceId: string

  beforeAll(async () => {
    harness = await startKeycloak()
    kc = KeycloakClient.create(webConfig(harness.url))
    // `sub` 와 대조할 **독립 원천** — admin API 가 읽은 alice 의 id.
    const service = KeycloakClient.create({
      serverUrl: harness.url,
      realm: 'it-realm',
      clientId: 'it-client',
      clientSecret: 'it-secret',
    })
    try {
      const alice = (await (await service.admin()).users.search(ALICE[0])).filter(
        (u) => u.username === ALICE[0],
      )
      expect(alice).toHaveLength(1)
      aliceId = alice[0]?.id as string
      expect(aliceId).toBeTruthy()
    } finally {
      await service.close()
    }
  }, 240_000)

  afterAll(async () => {
    await kc?.close()
    await harness?.stop()
  })

  it('교환한 토큰은 그 nonce·사용자에 묶이고, refresh·introspect·logout 이 실서버에서 돈다', async () => {
    const { request, code } = await login(kc)
    const tokens = await kc.auth.exchangeCode(
      code,
      REDIRECT_URI,
      request.codeVerifier,
      request.nonce,
    )
    expect(tokens.accessToken).toBeTruthy()
    expect(tokens.refreshToken).toBeTruthy()
    expect(tokens.idToken).toBeTruthy()
    // id_token 의 클레임은 교환이 그것을 검증하는 길 — 공개 `validateIdToken`(서명·iss·aud = clientId·exp·종류·azp)로 읽는다.
    const id = await kc.auth.validateIdToken(tokens.idToken as string)
    expect(id.claims['nonce']).toBe(request.nonce)
    expect(id.subject).toBe(aliceId)
    // 서버가 서명한 id_token 은 typ "ID" 다(실서버 측정) — validate 는 그것을 액세스 토큰 자리에서 거부한다. 이 클라이언트의
    // 기대 audience 는 clientId(it-web)라 aud 검사는 지나고, typ 만이 가른다.
    expect(id.claims['typ']).toBe('ID')
    const notAccess = await refusal(kc.auth.validate(tokens.idToken as string))
    expect(notAccess).toBeInstanceOf(KeycloakTokenValidationError)
    expect(notAccess.message).toBe('not an access token (typ "ID")')
    // 반대 방향: 서버의 액세스 토큰은 공개 id_token 검증이 거부한다. aud 에 clientId 가 있으면 종류(typ 이 "ID" 가 아니다)가,
    // 없으면 aud 가 가른다 — 어느 쪽인지는 서버가 보낸 aud 를 검증 없이 읽어 정한다(전제이지 판정이 아니다).
    const accessAud = unverifiedPayload(tokens.accessToken)['aud']
    const audiences = Array.isArray(accessAud) ? accessAud : [accessAud]
    const notId = await refusal(kc.auth.validateIdToken(tokens.accessToken))
    expect(notId).toBeInstanceOf(KeycloakTokenValidationError)
    expect(notId.message).toBe(
      audiences.includes('it-web')
        ? 'not an id_token (typ is not "ID")'
        : 'JWT validation failed: unexpected "aud" claim value',
    )

    // refresh: 새 접근 토큰을 준다 — 같은 사용자의 활성 토큰이다.
    const refreshed = await kc.auth.refresh(tokens.refreshToken as string)
    expect(refreshed.accessToken).toBeTruthy()
    expect(refreshed.accessToken).not.toBe(tokens.accessToken)
    expect(refreshed.refreshToken).toBeTruthy()
    const active = await kc.auth.introspect(refreshed.accessToken)
    expect(active.active).toBe(true)
    expect(active.username).toBe(ALICE[0])

    // logout: 세션을 끝낸다 — 그 refresh token 은 더는 갱신되지 않고 접근 토큰은 비활성이 된다.
    await kc.auth.logout(refreshed.refreshToken as string)
    const ended = await refusal(kc.auth.refresh(refreshed.refreshToken as string))
    expect(ended).toBeInstanceOf(KeycloakAuthError)
    expect(ended.message).toMatch(/^Token refresh failed: /)
    expect(links(ended)[1]?.code).toBe(SERVER_REFUSED)
    expect((await kc.auth.introspect(refreshed.accessToken)).active).toBe(false)
  })

  it('서버가 서명하지 않은 nonce 를 거부한다', async () => {
    const { request, code } = await login(kc)
    const refused = await refusal(
      kc.auth.exchangeCode(code, REDIRECT_URI, request.codeVerifier, `x${request.nonce}`),
    )
    expect(refused).toBeInstanceOf(KeycloakAuthError)
    // 서버가 아니라 클라이언트가 거부했고, 그 사유는 nonce 다(aud·iss 등 다른 클레임이 아니다).
    expect(links(refused).map((l) => l.code)).not.toContain(SERVER_REFUSED)
    expect(links(refused).at(-1)).toEqual({
      name: 'OperationProcessingError',
      message: 'unexpected ID Token "nonce" claim value',
      code: 'OAUTH_JWT_CLAIM_COMPARISON_FAILED',
    })
    // 그 거부는 서버가 이 코드로 토큰을 **내준 뒤**다 — 코드가 이미 소비돼 맞는 nonce 로도 서버가 거절한다.
    // 토큰 엔드포인트에 가기 전에 거부하는 구현은 여기서 드러난다(Grok 레그 주장 3 — 이 줄 없이 SILENT).
    const replay = await refusal(
      kc.auth.exchangeCode(code, REDIRECT_URI, request.codeVerifier, request.nonce),
    )
    expect(links(replay)[1]?.code).toBe(SERVER_REFUSED)
  })

  it('nonce 클레임이 없는 id_token 은 nonce 를 기대할 때 거부한다', async () => {
    const request = stripNonce(kc.auth.createAuthorizationRequest(REDIRECT_URI))
    // 전제: 서버가 정말 nonce 없이 서명한다(아니면 아래는 부재가 아니라 불일치를 잰다).
    const unchecked = await kc.auth.exchangeCode(
      await browserLogin(request, REDIRECT_URI, ...ALICE),
      REDIRECT_URI,
      request.codeVerifier,
    )
    expect(unchecked.idToken).toBeTruthy()
    expect((await kc.auth.validateIdToken(unchecked.idToken as string)).claims).not.toHaveProperty(
      'nonce',
    )

    const code = await browserLogin(request, REDIRECT_URI, ...ALICE)
    const refused = await refusal(
      kc.auth.exchangeCode(code, REDIRECT_URI, request.codeVerifier, request.nonce),
    )
    expect(refused).toBeInstanceOf(KeycloakAuthError)
    expect(links(refused).map((l) => l.code)).not.toContain(SERVER_REFUSED)
    // 부재 판정 그 자체다 — nonce 클레임 존재 검사(`OAUTH_INVALID_RESPONSE`)이지 다른 클레임의 거부가 아니다.
    expect(links(refused).at(-1)).toEqual({
      name: 'OperationProcessingError',
      message: 'JWT "nonce" (nonce) claim missing',
      code: 'OAUTH_INVALID_RESPONSE',
    })
  })

  /**
   * `expectedAudience` 재정의(리소스 서버)는 액세스 토큰의 몫이다 — id_token `aud` 는 clientId 로 잰다
   * (OIDC Core §2·§3.1.3.7). 예전에는 재정의가 id_token 에도 걸려 Keycloak 의 진짜 id_token(aud=it-web)이
   * `invalid id_token` 으로 거부됐다(go `RefusesAnIDTokenForAnotherAudience` 가 그 거부를 고정했었다).
   */
  it('expectedAudience 를 재정의해도 nonce 교환은 통과하고, 재정의는 액세스 토큰 validate 에만 걸린다', async () => {
    const other = KeycloakClient.create({
      ...webConfig(harness.url),
      expectedAudience: 'not-it-web',
    })
    try {
      const { request, code } = await login(other)
      const tokens = await other.auth.exchangeCode(
        code,
        REDIRECT_URI,
        request.codeVerifier,
        request.nonce,
      )
      // 서버가 서명한 진짜 id_token 이다 — 재정의한 이 클라이언트의 공개 id_token 검증으로 따로 잰다(그 길은 재정의를 쓰지
      // 않는다 — aud 는 clientId 로 잰다).
      const id = await other.auth.validateIdToken(tokens.idToken as string)
      expect(id.audience).toContain('it-web')
      expect(id.audience).not.toContain('not-it-web')
      expect(id.claims['nonce']).toBe(request.nonce)
      expect(id.subject).toBe(aliceId)

      // 재정의는 액세스 토큰 검증에 그대로 걸린다 — 그 토큰은 기본 설정에서는 유효하다(대조군).
      await expect(kc.auth.validate(tokens.accessToken)).resolves.toBeDefined()
      await expect(other.auth.validate(tokens.accessToken)).rejects.toBeInstanceOf(
        KeycloakTokenValidationError,
      )
    } finally {
      await other.close()
    }
  })

  it('재사용한 코드는 거부하고, 그 오류는 코드·verifier·시크릿·토큰을 싣지 않는다', async () => {
    const { request, code } = await login(kc)
    // 로그인 자체(콜백 URL 에 코드가 실린다)는 SDK 의 누출이 아니다 — 여기서부터 잰다.
    const printedBySdk: string[] = []
    const sinks = [
      ...(['log', 'info', 'warn', 'error', 'debug', 'trace'] as const).map((m) =>
        vi.spyOn(console, m),
      ),
      vi.spyOn(process.stdout, 'write'),
      vi.spyOn(process.stderr, 'write'),
    ]
    let tokens
    let reused
    try {
      tokens = await kc.auth.exchangeCode(code, REDIRECT_URI, request.codeVerifier, request.nonce)
      reused = await refusal(
        kc.auth.exchangeCode(code, REDIRECT_URI, request.codeVerifier, request.nonce),
      )
    } finally {
      for (const sink of sinks) {
        // 바이트로 쓴 것은 글자로 되읽는다 — `format` 은 Buffer 를 16진으로 찍어 원문 검색을 빗나간다
        // (Grok 레그 주장 5 — `stdout.write(Buffer)` 누출이 이 변환 없이 SILENT 였다).
        for (const call of sink.mock.calls as unknown[][]) {
          const text = call.map((a) => (a instanceof Uint8Array ? Buffer.from(a).toString() : a))
          printedBySdk.push(format(...text))
        }
        sink.mockRestore()
      }
    }
    expect(reused).toBeInstanceOf(KeycloakAuthError)
    expect(reused.message).toMatch(/^Authorization code exchange failed: /)
    expect(links(reused)[1]?.code).toBe(SERVER_REFUSED)

    const printed = renderings(reused) + printedBySdk.join('\n')
    const secret = WEB_CLIENT_SECRETS['it-web']
    const hidden = [code, request.codeVerifier, secret]
    hidden.push(tokens.accessToken, tokens.refreshToken ?? '', tokens.idToken ?? '')
    // 시크릿이 원문이 아니라 전송 인코딩으로 새는 자리 — `client_secret_basic` 헤더는 `id:secret` 의 base64
    // 다(Grok 레그 주장 5 — 메시지에 실은 base64 누출이 이것 없이 SILENT 였다). 퍼센트 인코딩은 이 값들이
    // 전부 비예약 문자라 원문과 같다.
    for (const plain of [secret, `it-web:${secret}`]) {
      hidden.push(Buffer.from(plain).toString('base64'), Buffer.from(plain).toString('base64url'))
    }
    for (const value of hidden) {
      expect(value.length).toBeGreaterThan(8)
      expect(printed).not.toContain(value)
    }
  })

  /**
   * 등록된 콜백(`http://localhost/it-callback`)의 다른 표기 — 대문자 scheme · 호스트와 기본 포트 — 로도 교환이 끝난다.
   * Keycloak 은 토큰 요청의 redirect_uri 를 인가 요청 때 저장한 문자열과 그대로 비교하고(26.6.9
   * `AuthorizationCodeGrantType`), openid-client 는 토큰 요청에 WHATWG 정규형을 싣는다. 고치기 전에는 인가 요청이 받은
   * 표기 그대로라 두 요청이 갈렸다(등록부 `node-authz-request-redirect-unvalidated`, 단위 실측
   * `test/unit/redirect-uri.test.ts`). 로그인 헬퍼는 서버가 실제로 돌려보낸 콜백(정규형)과 대조한다.
   */
  it('등록된 콜백의 다른 표기로도 교환이 끝난다 — 두 요청이 같은 정규형을 싣는다', async () => {
    const spelled = 'HTTP://LOCALHOST:80/it-callback'
    const request = kc.auth.createAuthorizationRequest(spelled)
    expect(new URL(request.url).searchParams.get('redirect_uri')).toBe(REDIRECT_URI)
    const code = await browserLogin(request, REDIRECT_URI, ...ALICE)
    const tokens = await kc.auth.exchangeCode(code, spelled, request.codeVerifier, request.nonce)
    expect(tokens.accessToken.length).toBeGreaterThan(0)
  })

  /**
   * JWKS 밖 키(HS256)로 서명된 id_token 은 핀을 열어도 거부된다 — `exchangeCode` 가 id_token 을 SDK 검증기에
   * 태우기 때문이다.
   *
   * ⚠️ 이 테스트가 처음 섰을 때 node 는 **둘 다 수락했다.** openid-client v6 는 토큰 엔드포인트에서 직접 받은
   * id_token 의 서명을 `enableNonRepudiationChecks` 없이는 보지 않고(OIDC Core §3.1.3.7 — TLS 로 갈음), alg 도
   * 서버 메타데이터의 `id_token_signing_alg_values_supported`(Keycloak 은 HS256 을 싣는다)로만 거른다.
   * `SECURITY.md` 의 아홉 언어 계약(서명·iss·aud·exp)을 어긴 것이라 `#verifyIdToken` 이 고쳤다.
   *
   * 로그인은 `beforeAll` 에서 한다(거기서의 실패는 스위트를 깨뜨린다 — 헬퍼 state 변이로 실측). 서버가 정말
   * HS256 으로 서명한다는 전제도 SDK 를 거치지 않는 토큰 엔드포인트 호출로 거기서 잰다.
   */
  describe.each([[['RS256']], [['RS256', 'HS256']]])(
    'JWKS 밖 키(HS256)로 서명된 id_token — signatureAlgorithms=%j',
    (algorithms: string[]) => {
      let hs: KeycloakClient
      let pending: { request: AuthorizationRequest; code: string }

      beforeAll(async () => {
        hs = KeycloakClient.create(webConfig(harness.url, 'it-web-hs256', algorithms))
        // 전제: 이 클라이언트의 id_token 은 HS256 이다 — SDK 밖(토큰 엔드포인트 직접)에서 잰다.
        const probe = await login(hs)
        const raw = await fetch(`${harness.url}/realms/it-realm/protocol/openid-connect/token`, {
          method: 'POST',
          body: new URLSearchParams({
            grant_type: 'authorization_code',
            code: probe.code,
            redirect_uri: REDIRECT_URI,
            code_verifier: probe.request.codeVerifier,
            client_id: 'it-web-hs256',
            client_secret: WEB_CLIENT_SECRETS['it-web-hs256'],
          }),
        })
        expect(raw.status).toBe(200)
        const idToken = ((await raw.json()) as { id_token: string }).id_token
        const header = JSON.parse(
          Buffer.from(idToken.split('.')[0] as string, 'base64url').toString(),
        ) as { alg: string }
        expect(header.alg).toBe('HS256')
        // SDK 자신의 강화 검증기는 이 토큰을 거부한다 — 교환 경로만 그것을 안 거친다. 거부는 알고리즘의 것이다(RS256 만이면
        // jose 의 「"alg" … not allowed」, HS256 을 열면 SDK 의 「algorithm not allowed: HS256 …」) — typ 은 서명 검증을 지난
        // 뒤에야 보므로 「not an access token」이 이 자리를 대신 채우지 못한다.
        await expect(hs.auth.validate(idToken)).rejects.toThrow(/alg/)
        pending = await login(hs)
      })

      afterAll(async () => {
        await hs?.close()
      })

      it('교환이 id_token 을 SDK 검증기에서 거부한다', async () => {
        const { request, code } = pending
        // 사유까지 본다 — 코드 만료·invalid_client·전송 오류 같은 엉뚱한 거부는 이 메시지가 아니다.
        const refused = await hs.auth
          .exchangeCode(code, REDIRECT_URI, request.codeVerifier, request.nonce)
          .then(
            () => undefined,
            (e: unknown) => e,
          )
        expect(refused).toBeInstanceOf(KeycloakAuthError)
        expect((refused as Error).message).toBe(
          'Authorization code exchange failed: invalid id_token',
        )
      })
    },
  )
})
