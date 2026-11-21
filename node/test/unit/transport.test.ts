import { describe, it, expect } from 'vitest'
import { isTransportError, transportInChain } from '../../src/transport.js'

// ⚠️ **이 파일이 없을 때 `TRANSPORT_CODES` 에서 `CERT_HAS_EXPIRED` 를 지워도 107 전부 통과했다**
// (실측 2026-09-10, 변이 프로브 `SILENT`). 호출 자리 테스트(auth·admin 경계)가 이 분류기를
// **구동은 하지만** 치는 팔이 `AbortError` 와 `ECONNREFUSED` **둘뿐**이었고, `src/transport.ts` 는
// 커버리지 게이트에서 제외돼 있어 나머지 15개 코드가 측정되지도 않았다.
//
// ⚠️ TLS 코드가 빠지면 만료·자가서명 인증서 실패가 **전송 오류로 분류되지 않아** 하위 오류가
// 그대로 소비자에게 샌다(§4 경계 계약 위반). 그래서 표로 전수를 친다.
describe('isTransportError — 전송 실패 분류기', () => {
  const transportCodes = [
    'ECONNREFUSED',
    'ECONNRESET',
    'EHOSTUNREACH',
    'ENETUNREACH',
    'EPIPE',
    'ENOTFOUND',
    'EAI_AGAIN',
    'ETIMEDOUT',
    'UND_ERR_CONNECT_TIMEOUT',
    'UND_ERR_HEADERS_TIMEOUT',
    'UND_ERR_SOCKET',
    'CERT_HAS_EXPIRED',
    'DEPTH_ZERO_SELF_SIGNED_CERT',
    'UNABLE_TO_VERIFY_LEAF_SIGNATURE',
    'SELF_SIGNED_CERT_IN_CHAIN',
    'ERR_TLS_CERT_ALTNAME_INVALID',
  ]

  it.each(transportCodes)('직접 code=%s 는 전송 오류다', (code) => {
    expect(isTransportError(Object.assign(new Error('boom'), { code }))).toBe(true)
  })

  it.each(transportCodes)('cause.code=%s 도 전송 오류다', (code) => {
    // undici 는 시스템 오류를 `cause` 에 담아 던진다.
    const err = new Error('outer') as Error & { cause?: unknown }
    err.cause = Object.assign(new Error('inner'), { code })
    expect(isTransportError(err)).toBe(true)
  })

  it.each(['AbortError', 'TimeoutError'])('name=%s 는 전송 오류다', (name) => {
    expect(isTransportError(Object.assign(new Error('t'), { name }))).toBe(true)
  })

  it('cause 있는 TypeError 는 전송 오류다(undici "fetch failed")', () => {
    expect(isTransportError(new TypeError('fetch failed', { cause: new Error('x') }))).toBe(true)
  })

  // ── 음성 케이스 — 이것이 없으면 위 표는 「항상 true 를 돌려준다」와 구분되지 않는다 ──
  it('cause 없는 TypeError 는 전송 오류가 아니다(프로그래밍 버그)', () => {
    expect(isTransportError(new TypeError('bug'))).toBe(false)
  })

  it('알 수 없는 code 는 전송 오류가 아니다', () => {
    expect(isTransportError(Object.assign(new Error('e'), { code: 'ENOENT' }))).toBe(false)
  })

  it.each([null, undefined, 'string', 42, true])('객체가 아니면 전송 오류가 아니다: %s', (v) => {
    expect(isTransportError(v)).toBe(false)
  })

  it('code 가 문자열이 아니면 무시한다', () => {
    expect(isTransportError(Object.assign(new Error('e'), { code: 111 }))).toBe(false)
  })
})

// auth 레인의 계급 판정 — 라이브러리가 fetch 의 오류를 제 오류로 감싸도 사슬 어딘가의 전송 오류를 본다
// (`auth.ts` 의 `failure` · `auth-incomplete-response.test.ts`).
describe('transportInChain — 원인 사슬의 전송 실패', () => {
  // undici 의 모양 — cause 는 Error 다(아래 「a cause that is not an Error」: 평범한 객체 cause 는 데이터다).
  const fetchFailed = new TypeError('fetch failed', {
    cause: Object.assign(new Error('read ECONNRESET'), { code: 'ECONNRESET' }),
  })

  it('맨 앞이 전송 실패면 참', () => {
    expect(transportInChain(fetchFailed)).toBe(true)
  })

  it('감싼 오류의 사슬 안쪽도 본다', () => {
    const wrapped = new Error('something went wrong', {
      cause: new Error('mid', { cause: fetchFailed }),
    })
    expect(transportInChain(wrapped)).toBe(true)
  })

  it('끝까지 온 응답의 해석 실패는 아니다', () => {
    expect(
      transportInChain(new Error('bad', { cause: new SyntaxError('Unexpected token <') })),
    ).toBe(false)
  })

  it('여덟 고리 밖은 보지 않는다', () => {
    let deep: Error = fetchFailed
    for (let i = 0; i < 8; i += 1) deep = new Error(`wrap ${i}`, { cause: deep })
    expect(transportInChain(deep)).toBe(false)
    expect(transportInChain(deep.cause)).toBe(true)
  })

  it.each([null, undefined, 'fetch failed', 42])('객체가 아니면 아니다: %s', (v) => {
    expect(transportInChain(v)).toBe(false)
  })
})

// A response body is data, not an error: oauth4webapi's `ResponseBodyError` holds the JSON-parsed OAuth error body as
// its `cause` (registry `node-body-code-member-transport` — the public-API rows are `auth-body-member-transport.test.ts`).
// Only a cause that is an `Error` speaks for the transport.
describe('a cause that is not an Error is data, not a transport failure', () => {
  // One of each family — socket, DNS, timeout, undici, TLS — from the exhaustive table above.
  const sampleCodes = ['ECONNRESET', 'ENOTFOUND', 'ETIMEDOUT', 'UND_ERR_SOCKET', 'CERT_HAS_EXPIRED']

  it.each(sampleCodes)(
    'isTransportError — a plain-object cause with code=%s is not one',
    (code) => {
      expect(isTransportError(new Error('outer', { cause: { code } }))).toBe(false)
    },
  )

  it.each([{ code: 'ECONNRESET' }, { name: 'TimeoutError' }, {}, 'ECONNRESET', 42])(
    'isTransportError — a TypeError whose cause is not an Error is not one: %o',
    (cause) => {
      expect(isTransportError(new TypeError('x', { cause }))).toBe(false)
    },
  )

  const responseBodyError = (body: Record<string, unknown>): Error =>
    Object.assign(
      new Error('server responded with an error in the response body', { cause: body }),
      {
        code: 'OAUTH_RESPONSE_BODY_ERROR',
      },
    )
  it.each([
    ['code ECONNRESET', { code: 'ECONNRESET' }],
    ['name TimeoutError', { name: 'TimeoutError' }],
    ['name AbortError', { name: 'AbortError' }],
    ['cause.code ECONNRESET', { cause: { code: 'ECONNRESET' } }],
  ])('an OAuth error body as the cause, with a member %s, is not one', (_label, member) => {
    const err = responseBodyError({ error: 'invalid_grant', ...member })
    expect(isTransportError(err)).toBe(false)
    expect(transportInChain(err)).toBe(false)
  })

  it('transportInChain — a link that is not an Error ends the walk, whatever lies past it', () => {
    const past = new TypeError('fetch failed', {
      cause: Object.assign(new Error('read ECONNRESET'), { code: 'ECONNRESET' }),
    })
    expect(transportInChain(new Error('outer', { cause: { cause: past } }))).toBe(false)
  })

  it('the value given is judged by its own fields as before — a plain object with a transport code is one', () => {
    expect(isTransportError({ code: 'ECONNRESET' })).toBe(true)
    expect(transportInChain({ name: 'TimeoutError' })).toBe(true)
  })
})

// What Node 22 throws for a transport failure is an Error at every link — the walk reaches it.
describe('the transport failures Node 22 throws', () => {
  it('the undici shape — TypeError("fetch failed") whose cause is an Error with a code', () => {
    const err = new TypeError('fetch failed', {
      cause: Object.assign(new Error('x'), { code: 'ECONNRESET' }),
    })
    expect(isTransportError(err)).toBe(true)
    expect(transportInChain(err)).toBe(true)
  })

  it.each(['AbortError', 'TimeoutError'])('a DOMException %s', (name) => {
    const err = new DOMException('the operation was aborted', name)
    expect(err).toBeInstanceOf(Error)
    expect(isTransportError(err)).toBe(true)
    expect(transportInChain(err)).toBe(true)
  })

  it.each(['AbortError', 'TimeoutError'])(
    "a DOMException %s under openid-client's ClientError (code OAUTH_TIMEOUT · OAUTH_ABORT)",
    (name) => {
      const err = Object.assign(
        new Error('operation timed out', { cause: new DOMException('t', name) }),
        { code: name === 'TimeoutError' ? 'OAUTH_TIMEOUT' : 'OAUTH_ABORT' },
      )
      expect(transportInChain(err)).toBe(true)
    },
  )

  // What fetch rejected with for each local failure (measured Node 22.18.0 · undici 6.21.2): a TypeError with no own
  // `code` — its own properties are cause, message and stack — whose cause is an Error. The TLS row's code is not in
  // TRANSPORT_CODES, so only the TypeError rule makes it transport: that row fails if the rule is dropped, not narrowed.
  const system = (message: string, code: string, syscall: string): Error =>
    Object.assign(new Error(message), { code, syscall })
  const undici = (name: string, message: string, code: string): Error =>
    Object.assign(new Error(message), { name, code })
  it.each([
    [
      'connection refused',
      'fetch failed',
      system('connect ECONNREFUSED 127.0.0.1:55803', 'ECONNREFUSED', 'connect'),
    ],
    [
      'connection refused on both families (localhost)',
      'fetch failed',
      Object.assign(
        new AggregateError(
          [
            system('connect ECONNREFUSED ::1:55803', 'ECONNREFUSED', 'connect'),
            system('connect ECONNREFUSED 127.0.0.1:55803', 'ECONNREFUSED', 'connect'),
          ],
          '',
        ),
        { code: 'ECONNREFUSED' },
      ),
    ],
    [
      'a host that does not resolve',
      'fetch failed',
      undici(
        'ConnectTimeoutError',
        'Connect Timeout Error (attempted address: kcsdk-probe.invalid:80, timeout: 10000ms)',
        'UND_ERR_CONNECT_TIMEOUT',
      ),
    ],
    ['a reset on accept', 'fetch failed', system('read ECONNRESET', 'ECONNRESET', 'read')],
    [
      'a body cut short',
      'terminated',
      undici('SocketError', 'other side closed', 'UND_ERR_SOCKET'),
    ],
    [
      'TLS to a server that does not speak it',
      'fetch failed',
      Object.assign(new Error('SSL routines:ssl3_get_record:wrong version number'), {
        code: 'ERR_SSL_WRONG_VERSION_NUMBER',
      }),
    ],
  ])('undici — %s: TypeError(%j) with the cause measured', (_label, message, cause) => {
    const err = new TypeError(message, { cause })
    expect(Object.hasOwn(err, 'code')).toBe(false)
    expect(isTransportError(err)).toBe(true)
    expect(transportInChain(err)).toBe(true)
  })
})

// A library's parse error is a TypeError too. oauth4webapi's `CodedTypeError(message, code, cause)` always sets its own
// `code` (`ERR_INVALID_ARG_VALUE` · `ERR_INVALID_ARG_TYPE`), and for a part of a JWT that is not base64url it holds the
// decoder's error as its cause — Node 22.18.0 has no `Uint8Array.fromBase64`, so that is atob's InvalidCharacterError
// (registry `node-typeerror-cause-parse-as-transport` — the public-API rows are `auth-id-token-parse-transport.test.ts`).
describe("a TypeError with its own code is a library's error, not undici's fetch failure", () => {
  /** oauth4webapi's `CodedTypeError` (`node_modules/oauth4webapi/build/index.js`). */
  const coded = (code: string, cause: Error): TypeError =>
    Object.assign(new TypeError('The input to be decoded is not correctly encoded.', { cause }), {
      code,
    })
  const invalidCharacter = (): Error =>
    new DOMException('Invalid character', 'InvalidCharacterError')

  it.each(
    ['ERR_INVALID_ARG_VALUE', 'ERR_INVALID_ARG_TYPE'].flatMap((code) => [
      [code, "atob's InvalidCharacterError", invalidCharacter()] as const,
      [code, 'an Error', new Error('x')] as const,
    ]),
  )(
    'code %s with a cause %s — neither isTransportError nor transportInChain',
    (code, _label, cause) => {
      const err = coded(code, cause)
      expect(isTransportError(err)).toBe(false)
      expect(transportInChain(err)).toBe(false)
    },
  )

  it('the chain openid-client throws for an id_token header that is not base64url is not one', () => {
    // ClientError[OAUTH_PARSE_ERROR] > OperationProcessingError[OAUTH_PARSE_ERROR] > TypeError[ERR_INVALID_ARG_VALUE]
    // > InvalidCharacterError — measured on Node 22.18.0 through `refresh`.
    const processing = Object.assign(
      new Error('failed to parse JWT Header body as base64url encoded JSON', {
        cause: coded('ERR_INVALID_ARG_VALUE', invalidCharacter()),
      }),
      { name: 'OperationProcessingError', code: 'OAUTH_PARSE_ERROR' },
    )
    const client = Object.assign(new Error('parsing error occured', { cause: processing }), {
      name: 'ClientError',
      code: 'OAUTH_PARSE_ERROR',
    })
    expect(transportInChain(client)).toBe(false)
  })

  it('a cause with a transport code still makes it one — only the TypeError rule narrows', () => {
    const err = coded(
      'ERR_INVALID_ARG_VALUE',
      Object.assign(new Error('read ECONNRESET'), { code: 'ECONNRESET' }),
    )
    expect(isTransportError(err)).toBe(true)
    expect(transportInChain(err)).toBe(true)
  })
})
