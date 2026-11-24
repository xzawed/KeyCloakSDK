/**
 * `carriedOAuthError` — `KeycloakAuthError.oauthError` 가 IdP 의 OAuth `error` 에서 싣는 것: `[a-z_]{1,64}` 이고 그 요청이
 * 보낸 비어 있지 않은 비밀 어느 것과도 겹치지 않는(어느 쪽도 다른 쪽을 품지 않는) 문자열뿐이다 — 아홉 언어의 한 규칙
 * (`.claude/rules/security.md` 「OAuth error code」, java `OAuthErrorCode.carried` · dotnet `OAuthErrorCode.Carried` 와 같은
 * 표). `oauthErrorOf` 는 openid-client 가 오류 본문에 던지는 `ResponseBodyError`(code `OAUTH_RESPONSE_BODY_ERROR`)의
 * `error` 와, 상태로 거부한 3xx · 5xx 응답(code `OAUTH_RESPONSE_IS_NOT_CONFORM`)에서 SDK 의 fetch 가 남긴 `error` 만 읽는다 —
 * 끝에서 끝까지는 `oauth-error-code-echo.test.ts` 가 잰다.
 */
import { ClientError, ResponseBodyError, WWWAuthenticateChallengeError } from 'openid-client'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { carriedOAuthError, oauthErrorOf } from '../../src/oauth-error-code.js'
import { fetchTokenEndpointBounded } from '../../src/token-response-cap.js'

const C = (code: number): string => String.fromCharCode(code)

describe('carriedOAuthError — 모양 [a-z_]{1,64}', () => {
  it.each([
    ['숫자', 42],
    ['객체', { error: 'invalid_grant' }],
    ['null', null],
    ['undefined', undefined],
    ['배열', ['invalid_grant']],
    ['빈 문자열', ''],
    ['대문자', 'Invalid_grant'],
    ['숫자 글자', 'invalid_grant2'],
    ['공백', 'invalid grant'],
    ['하이픈', 'invalid-grant'],
    ['끝 LF', `invalid_grant${C(0x0a)}`],
    ['NUL', `invalid${C(0x00)}grant`],
    ['DEL', `invalid_grant${C(0x7f)}`],
    ['비 ASCII', `invalid_gr${C(0xe4)}nt`],
    ['65 자', 'a'.repeat(65)],
  ])('%s → undefined', (_name, value) => {
    expect(carriedOAuthError(value, [])).toBeUndefined()
  })

  it.each([
    ['invalid_grant'],
    ['unauthorized_client'],
    ['slow_down'],
    ['_'],
    ['z'],
    ['a'.repeat(64)],
    ['_'.repeat(64)],
  ])('%s → 그대로 싣는다', (value) => {
    expect(carriedOAuthError(value, [])).toBe(value)
  })
})

describe('carriedOAuthError — 보낸 비밀과의 겹침', () => {
  it.each([
    ['겹침 없음', 'invalid_grant', ['s3cret-Value'], 'invalid_grant'],
    ['통째', 'mysecret', ['mysecret'], undefined],
    ['뒤에 덧붙음', 'mysecret_x', ['mysecret'], undefined],
    ['앞에 덧붙음', 'x_mysecret', ['mysecret'], undefined],
    ['앞 조각', 'mysec', ['mysecret'], undefined],
    ['뒤 조각', 'secret', ['mysecret'], undefined],
    ['가운데 조각', 'yse', ['mysecret'], undefined],
    ['둘째 비밀의 조각', 'fresh', ['zzz', 'myrefresh'], undefined],
    ['둘째 비밀을 품음', 'x_myrefresh', ['zzz', 'myrefresh'], undefined],
    ['빈 비밀 · 없는 비밀은 대지 않는다', 'invalid_grant', ['', undefined], 'invalid_grant'],
    ['값 — 비밀이 등록 코드의 조각이면 그 코드를 잃는다', 'invalid_client', ['client'], undefined],
  ] as const)('%s', (_name, value, sent, want) => {
    expect(carriedOAuthError(value, sent)).toBe(want)
  })

  // 아홉 언어가 함께 가진 행 — 겹침은 ASCII 대소문자를 무시하고(비밀을 소문자로 되울리는 IdP · 프록시), 모양은 정확히
  // [a-z_]{1,64} 다. V5 는 U+212A KELVIN SIGN 뒤에 "ey" 를 코드 포인트로 만든다 — 접기는 ASCII 라 아홉이 같은 답을 내고,
  // 비밀의 비 ASCII 글자는 그 글자 그대로 댄다.
  it.each([
    ['V1 소문자로 되울림', 'mysecret', ['MySecret'], undefined],
    ['V2 잘린 소문자 되울림', 'mysec', ['MySecret'], undefined],
    ['V3 덧붙은 소문자 되울림', 'invalid_mysecret_x', ['MySecret'], undefined],
    ['V4 대조군', 'invalid_grant', ['MySecret'], 'invalid_grant'],
    ['V5 접기는 ASCII 만', 'key', [`${String.fromCodePoint(0x212a)}ey`], 'key'],
    ['V6 모양', 'invalid__grant', [], 'invalid__grant'],
    ['V6 모양', '_', [], '_'],
  ] as const)('%s — %s', (_row, value, sent, want) => {
    expect(carriedOAuthError(value, sent)).toBe(want)
  })

  // JS 호출자의 문자열 아닌 값은 문자열로 나간다(`URLSearchParams.set` — 교환의 code) — 나간 그 문자열과 댄다.
  it('문자열이 아닌 비밀은 나간 문자열로 대고, null 은 보내지 않은 것이다', () => {
    expect(carriedOAuthError('vulturecodeby', [['vulturecodeby']])).toBeUndefined()
    expect(carriedOAuthError('undefined', [undefined])).toBe('undefined')
    expect(carriedOAuthError('null', [null])).toBe('null')
  })
})

describe('oauthErrorOf — 오류 본문의 `error` 만', () => {
  const bodyError = (error: string, status = 400): ResponseBodyError =>
    new ResponseBodyError('server responded with an error in the response body', {
      cause: { error },
      response: new Response(null, { status }),
    })

  it('openid-client 의 ResponseBodyError 는 본문의 error 를 규칙대로 싣는다', () => {
    expect(oauthErrorOf(bodyError('invalid_grant'), [])).toBe('invalid_grant')
    expect(oauthErrorOf(bodyError('unauthorized_client', 401), ['sekret'])).toBe(
      'unauthorized_client',
    )
    expect(oauthErrorOf(bodyError('mysecret'), ['mysecret'])).toBeUndefined()
    expect(oauthErrorOf(bodyError('Kx7mQ2vT9pLr4WzN8bYc3FhJ6sDa1gE5'), [])).toBeUndefined()
  })

  it('본문을 읽지 않은 오류는 싣지 않는다 — WWW-Authenticate 도전 · 다른 code · 오류가 아닌 값', () => {
    const challenge = new WWWAuthenticateChallengeError('challenge', {
      cause: [{ scheme: 'bearer', parameters: { error: 'invalid_token' } }],
      response: new Response(null, { status: 401 }),
    })
    expect(oauthErrorOf(challenge, [])).toBeUndefined()
    const otherCode = Object.assign(new Error('x'), {
      code: 'OAUTH_RESPONSE_IS_NOT_CONFORM',
      error: 'invalid_grant',
    })
    expect(oauthErrorOf(otherCode, [])).toBeUndefined()
    expect(
      oauthErrorOf(Object.assign(new Error('x'), { error: 'invalid_grant' }), []),
    ).toBeUndefined()
    expect(
      oauthErrorOf({ code: 'OAUTH_RESPONSE_BODY_ERROR', error: 'invalid_grant' }, []),
    ).toBeUndefined()
    expect(oauthErrorOf(undefined, [])).toBeUndefined()
  })
})

// oauth4webapi 는 오류 본문을 4xx 에서만 읽는다 — 3xx · 5xx 는 상태로 읽지 않고 거부하고, openid-client 는 그 응답을 원인으로 단
// `ClientError('unexpected HTTP response status code', { code: OAUTH_RESPONSE_IS_NOT_CONFORM })` 를 던진다. 그 `error` 는 SDK 의
// fetch(`fetchTokenEndpointBounded`)가 4xx 본문과 같은 시험으로 남긴 것이고, 4xx 코드와 같은 규칙을 지난다(등록부
// node-5xx-oauth-error-code-empty).
describe('oauthErrorOf — 상태로 거부된 3xx · 5xx 응답의 `error`', () => {
  afterEach(() => {
    vi.restoreAllMocks()
  })

  const TOKEN_URL = 'https://kc.example.com/realms/r/protocol/openid-connect/token'
  const NOT_CONFORM = 'OAUTH_RESPONSE_IS_NOT_CONFORM'

  /** openid-client 의 그 오류 — 생성자가 `code` 를 받지만 타입 선언에는 없어 덧붙인다. */
  const clientError = (message: string, cause: unknown, code: string): ClientError =>
    Object.assign(new ClientError(message, { cause }), { code })

  /** openid-client 가 `status` 의 토큰 응답에 던지는 오류 — 원인은 SDK 의 fetch 가 돌려준 그 응답이다. */
  async function rejectedByStatus(status: number, body: string): Promise<ClientError> {
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(
      new Response(body, { status, headers: { 'content-type': 'application/json' } }),
    )
    const response = await fetchTokenEndpointBounded(TOKEN_URL, { method: 'POST' })
    return clientError('unexpected HTTP response status code', response, NOT_CONFORM)
  }

  it('본문의 error 를 4xx 코드와 같은 규칙으로 싣는다', async () => {
    const B5 = '{"error":"temporarily_unavailable","error_description":"down"}'
    expect(oauthErrorOf(await rejectedByStatus(503, B5), ['sekret'])).toBe(
      'temporarily_unavailable',
    )
    expect(oauthErrorOf(await rejectedByStatus(500, B5), [])).toBe('temporarily_unavailable')
    expect(oauthErrorOf(await rejectedByStatus(302, B5), [])).toBe('temporarily_unavailable')
    // 되울린 비밀(대소문자 무시) · 코드 모양이 아닌 값은 싣지 않는다.
    expect(oauthErrorOf(await rejectedByStatus(503, '{"error":"mysecret"}'), ['MySecret'])).toBe(
      undefined,
    )
    expect(oauthErrorOf(await rejectedByStatus(503, '{"error":"Down_now"}'), [])).toBeUndefined()
  })

  it('SDK 의 fetch 가 남긴 것이 없으면 싣지 않는다 — 다른 응답 · 다른 code · 원인 없음', async () => {
    const elsewhere = new Response('{"error":"temporarily_unavailable"}', { status: 503 })
    expect(oauthErrorOf(clientError('x', elsewhere, NOT_CONFORM), [])).toBeUndefined()
    const kept = (await rejectedByStatus(503, '{"error":"temporarily_unavailable"}')).cause
    expect(oauthErrorOf(clientError('x', kept, 'OAUTH_RESPONSE_IS_NOT_JSON'), [])).toBeUndefined()
    expect(oauthErrorOf(clientError('x', undefined, NOT_CONFORM), [])).toBeUndefined()
  })
})
