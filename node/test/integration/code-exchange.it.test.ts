import { format, inspect } from 'node:util'
import { afterAll, beforeAll, describe, expect, it, vi } from 'vitest'
import {
  KeycloakAuthError,
  KeycloakClient,
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
    // id_token 의 클레임은 SDK 의 강화 검증기(서명·iss·aud·exp)를 통과한 것만 읽는다.
    const id = await kc.auth.validate(tokens.idToken as string)
    expect(id.claims['nonce']).toBe(request.nonce)
    expect(id.subject).toBe(aliceId)

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
    expect((await kc.auth.validate(unchecked.idToken as string)).claims).not.toHaveProperty('nonce')

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
   * ⚠️ **알려진 결함(KNOWN DEFECT) — `exchangeCode` 는 id_token 의 서명을 검증하지 않는다.**
   *
   * `SECURITY.md` 는 nonce 를 넘기면 `exchange*` 가 id_token 을 **서명**·iss·aud·exp 까지 검증한다고 9 언어
   * 전부에 대해 약속한다. node 는 그 검증을 openid-client 에 맡기는데, openid-client v6 는 토큰 엔드포인트에서
   * 직접 받은 id_token 의 서명을 `enableNonRepudiationChecks` 없이는 보지 않는다(`build/index.js` 의
   * `nonRepudiation?.(response)` — SDK 는 그것을 켜지 않는다). alg 도 SDK 의 `signatureAlgorithms` 가 아니라
   * 서버 메타데이터의 `id_token_signing_alg_values_supported` 로만 거른다 — Keycloak 은 거기에 HS256 을 싣는다.
   * 그래서 JWKS 에 없는 HMAC 키로 서명된 id_token 이 **핀이 RS256 인데도** 통과한다(실측: 두 변형 모두 수락).
   *
   * `it.fails` 는 그 결함이 있는 동안 초록이고, 고쳐져 거부가 일어나는 순간 **빨개진다** — 그때 `.fails` 를
   * 지운다. 수락 외의 이유로 초록이 되지 않도록 로그인은 `beforeAll` 에서 하고(거기서의 실패는 스위트를
   * 깨뜨린다 — 헬퍼 state 변이로 실측), 서버가 정말 HS256 으로 서명한다는 전제도 SDK 를 거치지 않는 토큰
   * 엔드포인트 호출로 거기서 잰다. 몸통은 **수락 여부만** 본다(아래 주석).
   */
  describe.each([[['RS256']], [['RS256', 'HS256']]])(
    'KNOWN DEFECT: JWKS 밖 키(HS256)로 서명된 id_token — signatureAlgorithms=%j',
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
        // SDK 자신의 강화 검증기는 이 토큰을 거부한다 — 교환 경로만 그것을 안 거친다.
        await expect(hs.auth.validate(idToken)).rejects.toThrow()
        pending = await login(hs)
      })

      afterAll(async () => {
        await hs?.close()
      })

      it.fails('교환이 id_token 을 거부한다(현재는 수락 — 고쳐지면 .fails 를 지운다)', async () => {
        const { request, code } = pending
        // ⚠️ 이 몸통은 **수락될 때만** 실패해야 한다 — `it.fails` 는 어떤 실패든 초록으로 친다. 거부 사유를
        // 여기서 단언하면 코드 만료·invalid_client·전송 오류 같은 엉뚱한 거부가 그 단언을 깨뜨려 초록이 된다
        // (Grok 레그 주장 2 — 코드를 미리 태워 실측). 사유 단언은 고친 뒤 `.fails` 를 지울 때 더한다.
        const accepted = await hs.auth
          .exchangeCode(code, REDIRECT_URI, request.codeVerifier, request.nonce)
          .then(
            () => true,
            () => false,
          )
        expect(accepted).toBe(false)
      })
    },
  )
})
