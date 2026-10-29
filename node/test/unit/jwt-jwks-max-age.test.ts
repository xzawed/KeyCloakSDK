/**
 * JWKS 키셋의 수명 — 성공한 조회가 받은 키셋은 그 조회가 끝난 때부터 300 초만 쓴다(아홉 언어 공통, 판정 2026-10-29 ·
 * 등록부 `jwks-cache-lifetime-divergent`). 그 나이에 이르면 캐시는 콜드와 똑같다: 다음 검증이 콜드 적재의 길(같은 실패
 * 백오프)로 다시 받고, 그 조회가 실패하면 검증이 실패한다 — 낡은 키로 물러서지 않는다(T1 정상 만료 · T2 만료 뒤 장애 ·
 * T3 지운 키 · T4 강제 재조회가 나이를 다시 센다). 끝의 시험은 실패 백오프의 jitter 를 실패를 기록할 때 한 번만
 * 뽑는지 본다(등록부 `backoff-jitter-redrawn-per-check`).
 *
 * ⚠️ 시계는 `Date` 만 가짜다 — jose 의 신선도(`fresh`)와 SDK 이음매의 기본 `now` 가 둘 다 `Date.now()` 를 읽는다.
 * HTTP 는 실시계 그대로다. 시각은 리터럴로 적는다 — 상수에서 끌어 쓰면 상수가 바뀔 때 이 시험도 함께 움직인다.
 */
import { describe, it, expect, beforeAll, afterAll, afterEach, vi } from 'vitest'
import { createServer, type Server } from 'node:http'
import type { AddressInfo } from 'node:net'
import { generateKeyPair, exportJWK, SignJWT } from 'jose'
import { JwtValidator, type JwtValidatorOptions } from '../../src/jwt.js'
import { KeycloakTokenValidationError, KeycloakTransportError } from '../../src/errors.js'

const ISS = 'https://kc.example.com/realms/test'

const opts: JwtValidatorOptions = {
  issuer: ISS,
  audience: 'my-client',
  allowedAlgs: ['RS256'],
  clockSkewSeconds: 30,
  jwksMinRefetchSeconds: 30,
}

type Pair = Awaited<ReturnType<typeof generateKeyPair>>

let srv: Server
let uri: string
let status = 200
let served = ''
let certs = 0
let k1: Pair
let k2: Pair
let onlyK1 = ''
let onlyK2 = ''
let bothKeys = ''

beforeAll(async () => {
  k1 = await generateKeyPair('RS256')
  k2 = await generateKeyPair('RS256')
  const jwk = async (pair: Pair, kid: string) => ({
    ...(await exportJWK(pair.publicKey)),
    kid,
    use: 'sig',
    alg: 'RS256',
  })
  onlyK1 = JSON.stringify({ keys: [await jwk(k1, 'k1')] })
  onlyK2 = JSON.stringify({ keys: [await jwk(k2, 'k2')] })
  bothKeys = JSON.stringify({ keys: [await jwk(k1, 'k1'), await jwk(k2, 'k2')] })
  srv = createServer((_req, res) => {
    certs += 1
    if (status !== 200) {
      res.writeHead(status, { 'content-type': 'text/plain' })
      res.end('unavailable')
      return
    }
    res.writeHead(200, { 'content-type': 'application/json' })
    res.end(served)
  })
  await new Promise<void>((resolve) => srv.listen(0, '127.0.0.1', resolve))
  uri = `http://127.0.0.1:${(srv.address() as AddressInfo).port}/certs`
})

afterAll(async () => {
  await new Promise<void>((resolve) => srv.close(() => resolve()))
})

afterEach(() => {
  vi.useRealTimers()
})

/** 검증 시각에 서명한다 — 가짜 시계가 몇 분을 건너도 토큰은 만료되지 않는다. */
const sign = (pair: Pair, kid: string): Promise<string> =>
  new SignJWT({ sub: 'u', aud: 'my-client' })
    .setProtectedHeader({ alg: 'RS256', kid })
    .setIssuer(ISS)
    .setIssuedAt()
    .setExpirationTime('10m')
    .sign(pair.privateKey)

/** 검증 하나의 답 — 통과면 'ok', 거부면 그 원인의 메시지(`KeycloakError` 가 cause 를 이름·메시지만 남긴 사본으로 바꾼다). */
async function answer(v: JwtValidator, token: string): Promise<string> {
  try {
    await v.validate(token)
    return 'ok'
  } catch (e) {
    expect(e).toBeInstanceOf(KeycloakTokenValidationError)
    const cause = (e as Error).cause
    return cause instanceof Error ? cause.message : String(cause)
  }
}

/** 통과 · 백오프 창 안의 즉시 거부(IdP 없이) · 그 밖의 거부. */
async function outcome(v: JwtValidator, token: string): Promise<'ok' | 'backoff' | 'rejected'> {
  try {
    await v.validate(token)
    return 'ok'
  } catch (e) {
    expect(e).toBeInstanceOf(KeycloakTokenValidationError)
    const cause = (e as Error).cause
    return cause instanceof Error &&
      cause.name === KeycloakTransportError.name &&
      /backing off/.test(cause.message)
      ? 'backoff'
      : 'rejected'
  }
}

/** 캐시를 채운다(콜드 적재 한 번). 돌려준 시각이 그 적재가 끝난 시각이다 — 가짜 시계는 그사이 멈춰 있다. */
async function warm(
  keys: string,
  seams?: { jitter?: () => number },
): Promise<{ v: JwtValidator; t0: number }> {
  vi.useFakeTimers({ toFake: ['Date'] })
  const t0 = Date.now()
  status = 200
  served = keys
  certs = 0
  const v =
    seams === undefined
      ? JwtValidator.forJwksUri(uri, opts)
      : JwtValidator.forJwksUriWithSeams(uri, opts, seams)
  expect(await outcome(v, await sign(k1, 'k1'))).toBe('ok')
  expect(certs).toBe(1)
  return { v, t0 }
}

describe('JWKS 키셋의 수명 300 초 — 그 나이에 이르면 콜드 캐시와 같고, 낡은 키로 물러서지 않는다', () => {
  it('T1 정상 만료 — 299 초에는 조회 없이 통과하고, 301 초에는 정확히 한 번 조회하고 통과한다', async () => {
    const { v, t0 } = await warm(onlyK1)
    vi.setSystemTime(t0 + 299_000)
    expect(await outcome(v, await sign(k1, 'k1'))).toBe('ok')
    expect(certs).toBe(1)
    vi.setSystemTime(t0 + 301_000)
    expect(await outcome(v, await sign(k1, 'k1'))).toBe('ok')
    expect(certs).toBe(2)
    expect(await outcome(v, await sign(k1, 'k1'))).toBe('ok') // 방금 받은 키셋의 나이는 0 이다
    expect(certs).toBe(2)
  })

  it('T2 만료 뒤 장애 — 301 초의 검증은 한 번 조회하고 거부되며, 창 안은 조회 없이 거부되고, 회복 뒤 창이 지나면 한 번 조회하고 통과한다', async () => {
    const { v, t0 } = await warm(onlyK1, { jitter: () => 1 }) // 첫 창이 정확히 0.2 초다
    status = 503
    const t1 = t0 + 301_000
    vi.setSystemTime(t1)
    expect(await outcome(v, await sign(k1, 'k1'))).toBe('rejected') // 캐시된 kid 인데도 거부 — 낡은 키를 쓰지 않는다
    expect(certs).toBe(2)
    for (let i = 0; i < 5; i += 1) {
      expect(await outcome(v, await sign(k1, 'k1'))).toBe('backoff')
    }
    vi.setSystemTime(t1 + 199)
    expect(await outcome(v, await sign(k1, 'k1'))).toBe('backoff')
    expect(certs).toBe(2)
    status = 200 // IdP 가 회복했다
    vi.setSystemTime(t1 + 200)
    expect(await outcome(v, await sign(k1, 'k1'))).toBe('ok')
    expect(certs).toBe(3)
  })

  it('T3 지운 키 — k1·k2 로 적재, IdP 가 이제 k2 만 낸다: 301 초에 k1 토큰은 재조회 뒤 거부되고 k2 토큰은 통과한다', async () => {
    const { v, t0 } = await warm(bothKeys)
    served = onlyK2
    vi.setSystemTime(t0 + 299_000)
    expect(await outcome(v, await sign(k1, 'k1'))).toBe('ok') // 대조 — 수명 안에서는 캐시가 답한다
    expect(certs).toBe(1)
    vi.setSystemTime(t0 + 301_000)
    expect(await outcome(v, await sign(k1, 'k1'))).toBe('rejected')
    expect(certs).toBe(2)
    expect(await outcome(v, await sign(k2, 'k2'))).toBe('ok')
    expect(certs).toBe(2)
  })

  it('T4 강제 재조회가 나이를 다시 센다 — 100 초의 미해결 kid 재조회 뒤 350 초에는 조회가 없다', async () => {
    const { v, t0 } = await warm(onlyK1)
    served = bothKeys // k2 로 회전 — 캐시에 없는 kid 가 강제 재조회를 부른다(30 초 창은 열려 있다)
    vi.setSystemTime(t0 + 100_000)
    expect(await outcome(v, await sign(k2, 'k2'))).toBe('ok')
    expect(certs).toBe(2)
    vi.setSystemTime(t0 + 350_000) // 적재로부터 350 초 · 그 재조회로부터 250 초
    expect(await outcome(v, await sign(k1, 'k1'))).toBe('ok')
    expect(certs).toBe(2)
    vi.setSystemTime(t0 + 401_000) // 그 재조회로부터 301 초 — 다시 센 나이도 300 초에서 끝난다
    expect(await outcome(v, await sign(k1, 'k1'))).toBe('ok')
    expect(certs).toBe(3)
  })
})

describe('실패 백오프의 jitter — 실패를 기록할 때 한 번 뽑는다', () => {
  // 뽑을 때마다 0.95 와 0.5 를 번갈아 낸다. 실패를 기록할 때 한 번 뽑으면 첫 창은 0.2 초 × 0.95 = 190 ms 다. 검사마다
  // 뽑으면 둘째 검사가 0.5(창 100 ms)를 받아 150 ms 에 IdP 로 나가고, 같은 실패가 한 번은 거부하고 한 번은 통과시킨다.
  it('실패 하나 뒤 같은 순간의 거듭된 검사는 같은 답이고, 창의 끝이 검사 사이에 움직이지 않는다', async () => {
    let draws = 0
    const jitter = (): number => (draws++ % 2 === 0 ? 0.95 : 0.5)
    vi.useFakeTimers({ toFake: ['Date'] })
    const t = Date.now()
    status = 503
    certs = 0
    const v = JwtValidator.forJwksUriWithSeams(uri, opts, { jitter })
    expect(await outcome(v, await sign(k1, 'k1'))).toBe('rejected') // 실패 1(콜드 캐시)
    expect(certs).toBe(1)
    vi.setSystemTime(t + 150)
    const answers: string[] = []
    for (let i = 0; i < 6; i += 1) {
      answers.push(await answer(v, await sign(k1, 'k1')))
    }
    expect(answers).toEqual(
      Array<string>(6).fill('JWKS fetch backing off after 1 consecutive failures (retry in 0.04s)'),
    )
    expect(certs).toBe(1)
    vi.setSystemTime(t + 189)
    expect(await outcome(v, await sign(k1, 'k1'))).toBe('backoff') // 끝이 당겨지지 않았다
    expect(certs).toBe(1)
    vi.setSystemTime(t + 190)
    expect(await outcome(v, await sign(k1, 'k1'))).toBe('rejected') // 밀리지도 않았다 — 실패 2
    expect(certs).toBe(2)
    expect(draws).toBe(2) // 기록한 실패마다 한 번 — 검사는 뽑지 않는다
  })
})
