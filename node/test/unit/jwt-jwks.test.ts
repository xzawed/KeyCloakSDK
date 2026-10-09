/**
 * JWKS 재조회 rate-limit 이 실제로 동작하는지 **HTTP 히트 수**로 잠근다.
 *
 * 왜 필요한가: `JwtValidator.forJwksUri`는 미해결 kid 의 강제 재조회를 `jwksMinRefetchSeconds` 창으로 묶어
 * 미인증 DoS 증폭(위조 kid를 실은 Bearer 토큰마다 IdP를 때리는 것)을 차단한다. 창은 SDK 의 JWKS fetch 이음매가
 * 조회를 **시도할 때** 찍고, jose 의 `cooldownDuration` 은 0 으로 둔다(jose 는 성공에만 찍어 장애 중에는 창이
 * 열린 채다 — 아래 「웜 캐시 + IdP 장애」). 타입체크는 그 옵션의 **개명**을 잡는다 — 우리 쪽 개명은 TS2561,
 * jose 가 타입에서 개명하거나 지우면 TS2353 이다(`npm run typecheck`, 실측 2026-10-09). 잡지 못하는 것은 둘이다 —
 * 우리 줄을 **지우는** 것(선택 옵션이라 타입이 그대로다)과, 이름은 그대로인데 jose 가 런타임에 그 값을 무시하는 것
 * (`remote.js` 만 그렇게 바꿔도 타입체크 0). 둘 다 jose 를 자기 기본 30 초로 돌려보내고, vitest 는 타입을 검사하지
 * 않고 돌리므로 히트 수를 세는 이 시험만 그것을 잡는다(아래 두 시험이 떨어진다 — 둘 다 실측).
 *
 * ⚠️ 두 번째 케이스(대조군)를 **지우지 말 것** — 실제로 회귀를 잡는 쪽은 그쪽이다. 변이 검증 실측: jose 의
 * `cooldownDuration` 을 개명해 무시되게 만들면 jose가 자체 기본값(30초)으로 폴백하므로 첫 케이스는 그대로
 * 통과한다(SDK 창도 30초라 구분이 안 된다). 창 0 을 쓰는 두 시험만 떨어진다 — 대조군(히트 7 → 1, 「expected 1
 * to be greater than 2」)과 빈 키셋 시험(「expected 1 to be greater than 1」). 지우기·개명 둘 다 단위 346 중 이 둘이다.
 */
import { describe, it, expect, beforeAll, afterAll, afterEach, vi } from 'vitest'
import { createServer, type Server } from 'node:http'
import type { AddressInfo } from 'node:net'
import { generateKeyPair, exportJWK, SignJWT } from 'jose'
import { JwtValidator, type JwtValidatorOptions } from '../../src/jwt.js'
import { KeycloakTokenValidationError, KeycloakTransportError } from '../../src/errors.js'

const ISS = 'https://kc.example.com/realms/test'

const baseOpts: Omit<JwtValidatorOptions, 'jwksMinRefetchSeconds'> = {
  issuer: ISS,
  audience: 'my-client',
  allowedAlgs: ['RS256'],
  clockSkewSeconds: 30,
}

let server: Server
let jwksUri: string
let hits = 0
let attackerKey: Awaited<ReturnType<typeof generateKeyPair>>['privateKey']
// 리다이렉트 프로브가 "따라갔다면 검증이 성공해버린다"를 재현하려면 유효한 JWK가 필요하다.
let servedJwkForRedirectProbe: Record<string, unknown>

beforeAll(async () => {
  // 서버가 내주는 JWKS에는 kid 'served' 하나뿐이다.
  const served = await generateKeyPair('RS256')
  const servedJwk = await exportJWK(served.publicKey)
  servedJwkForRedirectProbe = { ...servedJwk, kid: 'served', use: 'sig', alg: 'RS256' }
  const body = JSON.stringify({
    keys: [{ ...servedJwk, kid: 'served', use: 'sig', alg: 'RS256' }],
  })

  // 공격자 토큰은 서버에 없는 kid로 서명한다 → 매 검증마다 kid 미해결 → 재조회 시도를 유발한다.
  attackerKey = (await generateKeyPair('RS256')).privateKey

  server = createServer((_req, res) => {
    hits += 1
    res.writeHead(200, { 'content-type': 'application/json' })
    res.end(body)
  })
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve))
  jwksUri = `http://127.0.0.1:${(server.address() as AddressInfo).port}/certs`
})

afterAll(async () => {
  await new Promise<void>((resolve) => server.close(() => resolve()))
})

async function forgedToken(): Promise<string> {
  return new SignJWT({ sub: 'u', aud: 'my-client' })
    .setProtectedHeader({ alg: 'RS256', kid: 'unresolvable' })
    .setIssuer(ISS)
    .setIssuedAt()
    .setExpirationTime('5m')
    .sign(attackerKey)
}

async function attack(v: JwtValidator, times: number): Promise<void> {
  for (let i = 0; i < times; i += 1) {
    // kid가 해결되지 않으므로 전부 거부되어야 한다. 통과한다면 그 자체가 심각한 결함이다.
    await expect(v.validate(await forgedToken())).rejects.toThrow()
  }
}

describe('JWKS 재조회 rate-limit (재조회 창 실동작)', () => {
  it('미해결 kid를 반복 주입해도 IdP 조회는 상한된다', async () => {
    const v = JwtValidator.forJwksUri(jwksUri, { ...baseOpts, jwksMinRefetchSeconds: 30 })

    hits = 0
    const attempts = 12
    await attack(v, attempts)

    expect(hits).toBeGreaterThan(0) // 최초 1회는 조회해야 정상이다
    expect(hits).toBeLessThanOrEqual(2) // cooldown이 무시되면 attempts에 비례해 늘어난다
  })

  it('대조군 — cooldown이 0이면 조회가 상한되지 않는다(프로브가 히트를 센다는 증명)', async () => {
    const v = JwtValidator.forJwksUri(jwksUri, { ...baseOpts, jwksMinRefetchSeconds: 0 })

    hits = 0
    const attempts = 6
    await attack(v, attempts)

    // 이 단언이 실패하면 히트 계측 자체가 고장난 것이고, 위 테스트의 통과는 무의미해진다.
    expect(hits).toBeGreaterThan(2)
  })

  // 동형 최소집합 5번 — 기형 JWKS가 raw 라이브러리 예외가 아니라 SDK 오류 계급으로 나와야 한다.
  // PHP 자매 구현에서 이 클래스가 일반 리뷰를 뚫고 Critical(경계 미변환 예외 누출)로 배포된
  // 전례가 있어 아홉 언어에 같은 프로브를 둔다. Node에는 없었다(감사 실측).
  it('기형 JWKS(base64url 아닌 modulus) → raw 예외가 아니라 KeycloakTokenValidationError', async () => {
    const bad = createServer((_req, res) => {
      res.writeHead(200, { 'content-type': 'application/json' })
      res.end(
        JSON.stringify({
          keys: [
            {
              kty: 'RSA',
              kid: 'served',
              use: 'sig',
              alg: 'RS256',
              n: '!!!not-base64!!!',
              e: 'AQAB',
            },
          ],
        }),
      )
    })
    await new Promise<void>((resolve) => bad.listen(0, '127.0.0.1', resolve))
    try {
      const uri = `http://127.0.0.1:${(bad.address() as AddressInfo).port}/certs`
      const v = JwtValidator.forJwksUri(uri, { ...baseOpts, jwksMinRefetchSeconds: 30 })
      // kid는 서버가 내주는 것과 같게 둔다 — 그래야 "kid 미해결"이 아니라 **키 자체가 기형**인
      // 경로를 타고, 이 테스트가 의도한 실패 모드를 검증한다.
      const token = await new SignJWT({ sub: 'u', aud: 'my-client' })
        .setProtectedHeader({ alg: 'RS256', kid: 'served' })
        .setIssuer(ISS)
        .setIssuedAt()
        .setExpirationTime('5m')
        .sign(attackerKey)

      await expect(v.validate(token)).rejects.toBeInstanceOf(KeycloakTokenValidationError)
    } finally {
      await new Promise<void>((resolve) => bad.close(() => resolve()))
    }
  })

  // WBS(2026-07-31 감사) "추가 태스크 — 이미 안전한 경로에 고정(pinning) 테스트": JWKS 페치는
  // SDK가 직접 하지 않는다. jose 내부의 `createRemoteJWKSet`이 하고, **리다이렉트를 끌 노브가
  // 우리에게 없다** — 즉 여기서는 테스트가 유일한 방어수단이다.
  //
  // 실측(jose 6.2.4): 302를 따라가지 않고 `JOSEError: Expected 200 OK from the JSON Web Key Set
  // HTTP response`로 거부한다. 라이브러리 기본값이 안전하다는 뜻이지만, 그건 **우리가 통제하지
  // 않는 성질**이라 상위 버전에서 조용히 바뀔 수 있다. 바뀌면 예상 밖 3xx가 공격자가 고른
  // 내부 URL을 가리켜도 SDK가 그 응답을 서명키로 받아들이게 된다.
  it('SSRF 고정 — JWKS 302를 따라가지 않는다(jose 기본값이 유일한 방어라 버전 상향을 잠근다)', async () => {
    const paths: string[] = []
    const redirecting = createServer((req, res) => {
      paths.push(req.url ?? '')
      if (req.url?.startsWith('/certs')) {
        res.writeHead(302, {
          location: `http://127.0.0.1:${(redirecting.address() as AddressInfo).port}/internal`,
        })
        res.end()
        return
      }
      // 따라갔다면 여기에 도달한다 — 게다가 **유효한** JWKS를 내줘서, 검증이 성공해버리는
      // 최악의 시나리오(공격자가 고른 출처의 키를 신뢰)를 그대로 재현한다.
      res.writeHead(200, { 'content-type': 'application/json' })
      res.end(JSON.stringify({ keys: [servedJwkForRedirectProbe] }))
    })
    await new Promise<void>((resolve) => redirecting.listen(0, '127.0.0.1', resolve))
    try {
      const uri = `http://127.0.0.1:${(redirecting.address() as AddressInfo).port}/certs`
      const v = JwtValidator.forJwksUri(uri, { ...baseOpts, jwksMinRefetchSeconds: 30 })
      const token = await new SignJWT({ sub: 'u', aud: 'my-client' })
        .setProtectedHeader({ alg: 'RS256', kid: 'served' })
        .setIssuer(ISS)
        .setIssuedAt()
        .setExpirationTime('5m')
        .sign(attackerKey)

      await expect(v.validate(token)).rejects.toBeInstanceOf(KeycloakTokenValidationError)
      // 상태코드 거부만으로는 부족하다 — 리다이렉트 대상에 **요청 자체가 가지 않았음**을 본다.
      expect(paths).not.toContain('/internal')

      // ⚠️ 대조군을 지우지 말 것. 이 하드닝은 jose 내부 동작이라 우리가 끌 수 없고, 따라서
      // 다른 테스트들처럼 "방어를 제거하면 실패하는가"를 변이로 확인할 수단이 없다. 대신
      // **추종하는 클라이언트는 실제로 /internal에 도달함**을 같은 서버로 보여, 위 단언이
      // 프로브 고장(경로 미기록)으로 인한 공허한 통과가 아님을 증명한다. cooldown 테스트가
      // cooldown=0 대조군을 두는 것과 같은 이유다.
      paths.length = 0
      await fetch(uri) // 기본 redirect:'follow'
      expect(paths).toContain('/internal')
    } finally {
      await new Promise<void>((resolve) => redirecting.close(() => resolve()))
    }
  })
})

// ⚠️ 여기부터가 **콜드 캐시 + IdP 장애** 축이다. 위 `cooldownDuration` 은 *캐시가 찬 뒤*
// 미해결 kid 재조회만 상한한다 — 캐시가 비어 있으면 jose `getKey` 가 매번 `reload()` 를 부르고,
// 실패한 `reload()` 는 타임스탬프를 남기지 않아 쿨다운에 닿지도 못한다. 실측(2026-09-04):
// 20회 검증 → IdP 요청 **20건**, 7개 언어 동일.
describe('콜드 캐시 + IdP 장애 백오프', () => {
  let down: Server
  let downUri: string
  let downHits = 0

  beforeAll(async () => {
    down = createServer((_req, res) => {
      downHits += 1
      res.writeHead(503, { 'content-type': 'application/json' })
      res.end('{"error":"service unavailable"}')
    })
    await new Promise<void>((resolve) => down.listen(0, '127.0.0.1', resolve))
    downUri = `http://127.0.0.1:${(down.address() as AddressInfo).port}/certs`
  })

  afterAll(async () => {
    await new Promise<void>((resolve) => down.close(() => resolve()))
  })

  // ⚠️ 시계를 **주입**한다. 실시계로 두면 20회 루프(실 크립토 + 실 HTTP)가 base 창(100~200ms)을
  // 넘어 히트가 2가 되는 flake 가 난다 — 실측으로 겪었다. 이 저장소는 벽시계에 매달린 테스트를
  // 이미 결함 부류로 추적한다(`wall-clock-ordering-in-tests`). 실시계에서의 크기는 프로브가
  // 따로 잰다(콜드 캐시 + 503 · 20회 → 요청 1건).
  it('20회 검증이 IdP 요청 1건으로 접힌다', async () => {
    const now = 1_000_000
    const v = JwtValidator.forJwksUriWithSeams(
      downUri,
      { ...baseOpts, jwksMinRefetchSeconds: 30 },
      { now: () => now, jitter: () => 1 },
    )
    downHits = 0
    await attack(v, 20)
    expect(downHits).toBe(1)
  })

  // ⚠️ **이 테스트를 지우지 말 것 — 위 단언은 「한 번 실패하면 영원히 차단」으로도 통과한다.**
  // 그 동작은 원래 결함보다 나쁘다(IdP 가 복구돼도 SDK 가 영영 못 쓴다).
  it('대조군 — 백오프 창이 지나면 다시 IdP 로 나간다', async () => {
    let now = 1_000_000
    const v = JwtValidator.forJwksUriWithSeams(
      downUri,
      { ...baseOpts, jwksMinRefetchSeconds: 30 },
      { now: () => now, jitter: () => 1 },
    )
    downHits = 0

    await expect(v.validate(await forgedToken())).rejects.toThrow()
    expect(downHits).toBe(1)

    // 창 안 — 네트워크로 나가지 않고 즉시 실패한다(sleep 하지 않는다).
    await expect(v.validate(await forgedToken())).rejects.toThrow(/backing off/)
    expect(downHits).toBe(1)

    // 창을 넘기면(상한 5초보다 크게 민다) 다시 나간다.
    now += 10_000
    await expect(v.validate(await forgedToken())).rejects.toThrow()
    expect(downHits).toBe(2)
  })

  // 기본 jitter(`Math.random`)를 실제로 태운다 — `now` 만 고정하면 경과가 0 이라 창은 항상
  // 열려 있고, 그래서 결정적이면서도 기본 경로가 실행된다(주입 jitter 만 쓰면 그 줄이 영영
  // 미실행으로 남는다).
  it('기본 jitter 경로도 창을 연다', async () => {
    const now = 2_000_000
    const v = JwtValidator.forJwksUriWithSeams(
      downUri,
      { ...baseOpts, jwksMinRefetchSeconds: 30 },
      { now: () => now },
    )
    downHits = 0
    await expect(v.validate(await forgedToken())).rejects.toThrow()
    await expect(v.validate(await forgedToken())).rejects.toThrow(/backing off/)
    expect(downHits).toBe(1)
  })

  // ⚠️ 대조군 둘째 — **웜 캐시의 미해결 kid 홍수는 백오프를 올려서는 안 된다.** 그 경로의
  // `JWKSNoMatchingKey` 는 fetch 실패가 아니고, 실패로 세면 위조 kid 홍수가 정상 토큰의
  // 검증까지 막는다(원래 결함보다 나쁜 쪽으로 과잉 수정하는 자리).
  it('대조군 — 정상 IdP 의 위조 kid 홍수는 백오프를 트리거하지 않는다', async () => {
    const v = JwtValidator.forJwksUri(jwksUri, { ...baseOpts, jwksMinRefetchSeconds: 30 })
    hits = 0
    await attack(v, 12)

    // 백오프가 걸렸다면 메시지가 'backing off' 가 된다. 여기서는 그러면 안 된다.
    await expect(v.validate(await forgedToken())).rejects.not.toThrow(/backing off/)
    expect(hits).toBeLessThanOrEqual(2)
  })
})

// jose `reload` 는 `fetchJwks` 가 성공한 뒤 `.then` 안에서만 캐시를 대입한다. 200 `{"keys":[]}` 는
// 성공이라 방금 검증된 키셋을 빈 셋으로 덮고, 직전 k1 토큰까지 거절한다. 히트 증가를 잠그지
// 않으면 cooldown 이 재조회를 삼켜 결함이 있어도 아래 통과가 공허해진다.
describe('빈 JWKS 키셋(200)이 좋은 캐시를 덮지 않는다', () => {
  it('미해결 kid 재조회가 200 빈 키셋을 받아도 기존 k1 검증은 유지된다', async () => {
    const pair = await generateKeyPair('RS256')
    const jwk = await exportJWK(pair.publicKey)
    const good = JSON.stringify({
      keys: [{ ...jwk, kid: 'k1', use: 'sig', alg: 'RS256' }],
    })

    let served = good
    let hits = 0
    const srv = createServer((_req, res) => {
      hits += 1
      res.writeHead(200, { 'content-type': 'application/json' })
      res.end(served)
    })
    await new Promise<void>((resolve) => srv.listen(0, '127.0.0.1', resolve))
    try {
      const uri = `http://127.0.0.1:${(srv.address() as AddressInfo).port}/certs`
      const v = JwtValidator.forJwksUri(uri, { ...baseOpts, jwksMinRefetchSeconds: 0 })

      const sign = (kid: string) =>
        new SignJWT({ sub: 'u', aud: 'my-client' })
          .setProtectedHeader({ alg: 'RS256', kid })
          .setIssuer(ISS)
          .setIssuedAt()
          .setExpirationTime('5m')
          .sign(pair.privateKey)

      const k1 = await sign('k1')
      await expect(v.validate(k1)).resolves.toMatchObject({ subject: 'u' })

      served = '{"keys":[]}'
      const hitsBeforeRefetch = hits
      await expect(v.validate(await sign('k2'))).rejects.toBeInstanceOf(
        KeycloakTokenValidationError,
      )
      // ⚠️ 이 단언이 빠지면 재조회가 없었는지를 모르고, 아래 k1 통과는 아무것도 증명하지 못한다.
      expect(hits).toBeGreaterThan(hitsBeforeRefetch)

      await expect(v.validate(k1)).resolves.toMatchObject({ subject: 'u' })
      await expect(v.validate(await sign('k1'))).resolves.toMatchObject({ subject: 'u' })
    } finally {
      await new Promise<void>((resolve) => srv.close(() => resolve()))
    }
  })
})

// ⚠️ 여기부터가 **웜 캐시 + IdP 장애** 축이다. 위 콜드 캐시 백오프는 캐시가 찬 뒤를 보지 않는다(규칙 (4) —
// 웜 캐시의 미해결 kid 거부는 fetch 실패가 아니다). 그런데 jose 는 재조회 창(`cooldownDuration`)을 **성공**한
// 조회에만 찍으므로, 캐시가 찬 채 IdP 가 503 이면 위조 kid 토큰마다 IdP 로 나갔다 — 실측(2026-10-05,
// jwks-window.mjs): 위조 kid 5 → /certs 5. 자기 손으로 창을 거는 다섯(python·go·rust·php·ruby)은 결정할 때
// 창을 찍어 장애 중에도 창마다 한 번이다(`.claude/rules/security.md`).
//
// ⚠️ 시계는 `Date` 만 가짜로 돌린다 — jose 의 창 판정(`isFreshFor`)과 SDK 이음매의 기본 `now` 가 둘 다
// `Date.now()` 를 읽는다. HTTP 와 jose 의 5 초 타임아웃은 실시계 그대로다.
describe('웜 캐시 + IdP 장애 — 위조 kid 의 강제 재조회도 창마다 한 번', () => {
  let srv: Server
  let uri: string
  let status = 200
  let certs = 0
  let published: Awaited<ReturnType<typeof generateKeyPair>>
  let forger: Awaited<ReturnType<typeof generateKeyPair>>['privateKey']

  beforeAll(async () => {
    published = await generateKeyPair('RS256')
    forger = (await generateKeyPair('RS256')).privateKey
    const body = JSON.stringify({
      keys: [{ ...(await exportJWK(published.publicKey)), kid: 'k1', use: 'sig', alg: 'RS256' }],
    })
    srv = createServer((_req, res) => {
      certs += 1
      if (status !== 200) {
        res.writeHead(status, { 'content-type': 'text/plain' })
        res.end('unavailable')
        return
      }
      res.writeHead(200, { 'content-type': 'application/json' })
      res.end(body)
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

  const legit = (): Promise<string> =>
    new SignJWT({ sub: 'u', aud: 'my-client' })
      .setProtectedHeader({ alg: 'RS256', kid: 'k1' })
      .setIssuer(ISS)
      .setIssuedAt()
      .setExpirationTime('10m')
      .sign(published.privateKey)

  const forgedKid = (kid: string): Promise<string> =>
    new SignJWT({ sub: 'u', aud: 'my-client' })
      .setProtectedHeader({ alg: 'RS256', kid })
      .setIssuer(ISS)
      .setIssuedAt()
      .setExpirationTime('10m')
      .sign(forger)

  /** 캐시를 채운다(콜드 적재 한 번) — 돌려준 시각이 그 적재의 시각이다. */
  async function warm(): Promise<{ v: JwtValidator; t0: number }> {
    vi.useFakeTimers({ toFake: ['Date'] })
    const t0 = Date.now()
    status = 200
    certs = 0
    const v = JwtValidator.forJwksUri(uri, { ...baseOpts, jwksMinRefetchSeconds: 30 })
    await expect(v.validate(await legit())).resolves.toMatchObject({ subject: 'u' })
    expect(certs).toBe(1)
    return { v, t0 }
  }

  it('장애 중 위조 kid 다섯은 IdP 요청 한 건으로 접히고, 캐시된 kid 는 그대로 통과한다', async () => {
    const { v, t0 } = await warm()
    vi.setSystemTime(t0 + 31_000) // 창이 열린 뒤
    status = 503
    for (let i = 0; i < 5; i += 1) {
      await expect(v.validate(await forgedKid(`forged-${i}`))).rejects.toBeInstanceOf(
        KeycloakTokenValidationError,
      )
    }
    expect(certs).toBe(2) // 콜드 적재 + 이 창의 강제 재조회 한 번(수정 전: 6)
    // ⚠️ 규칙 (4) — 위조 kid 홍수가 정상 토큰을 막으면 원래 결함보다 나쁘다. 캐시된 kid 는 IdP 없이 통과한다.
    await expect(v.validate(await legit())).resolves.toMatchObject({ subject: 'u' })
    expect(certs).toBe(2)
  })

  // ⚠️ **이 대조군을 지우지 말 것 — 위 단언은 「한 번 실패하면 영원히 안 나간다」로도 통과한다.** 그 동작은
  // IdP 가 돌아와도 회전한 키를 영영 못 받는다.
  it('대조군 — 장애가 이어져도 다음 창에서는 다시 한 번 나간다', async () => {
    const { v, t0 } = await warm()
    vi.setSystemTime(t0 + 31_000)
    status = 503
    await expect(v.validate(await forgedKid('forged-a'))).rejects.toThrow()
    expect(certs).toBe(2)
    vi.setSystemTime(t0 + 61_000) // 그 실패한 시도로부터 30 초
    await expect(v.validate(await forgedKid('forged-b'))).rejects.toThrow()
    expect(certs).toBe(3)
  })

  // ⚠️ 만료(cacheMaxAge 600 초) 갱신은 강제 재조회 창에 걸지 않는다. jose 는 만료된 캐시를 갱신하지 못하면 캐시된
  // kid 도 거부하므로, 걸면 직전의 위조 kid 시도 하나 때문에 정상 토큰까지 30 초 막힌다.
  it('만료된 캐시의 갱신은 창에 걸리지 않는다 — 직전에 실패한 강제 재조회가 있어도 정상 토큰이 통과한다', async () => {
    const { v, t0 } = await warm()
    vi.setSystemTime(t0 + 595_000)
    status = 503
    await expect(v.validate(await forgedKid('late'))).rejects.toThrow()
    expect(certs).toBe(2)
    vi.setSystemTime(t0 + 601_000) // 마지막 성공(t0)으로부터 cacheMaxAge 를 넘었다 — 그 시도로부터는 6 초
    status = 200
    await expect(v.validate(await legit())).resolves.toMatchObject({ subject: 'u' })
    expect(certs).toBe(3)
  })

  // 정상 IdP 에서는 지금과 같아야 한다 — 창마다 정확히 한 번(0 초 콜드 적재 · 31 초 · 61 초).
  it('정상 IdP — 위조 kid 의 강제 재조회는 창마다 정확히 한 번이다', async () => {
    const { v, t0 } = await warm()
    const at = async (offsetMs: number, kid: string): Promise<number> => {
      vi.setSystemTime(t0 + offsetMs)
      await expect(v.validate(await forgedKid(kid))).rejects.toThrow()
      return certs
    }
    expect(await at(1_000, 'f1')).toBe(1) // 콜드 적재의 창 안
    expect(await at(31_000, 'f2')).toBe(2)
    expect(await at(45_000, 'f3')).toBe(2)
    expect(await at(60_000, 'f4')).toBe(2)
    expect(await at(61_000, 'f5')).toBe(3)
  })
})

// ⚠️ 여기부터가 **낡은 캐시 + IdP 장애** 축이다. jose 는 `cacheMaxAge`(600 초)가 지난 캐시를 `local` 로 둔 채
// `getKey` 첫머리에서 갱신하고(`remote.js:66`), 그 갱신이 실패하면 캐시된 kid 까지 거부한다. 실패 백오프가 캐시가
// **비어 있을 때만** 셌으므로(`remote.jwks() === undefined`) 낡은 캐시의 갱신 실패는 세지 않았다 — 실측(2026-10-05):
// 601 초 · /certs 503 · 검증 10 회(k1 다섯 · 위조 다섯) → /certs 1 → 11.
//
// ⚠️ 수락 정책은 이 축의 몫이 아니다 — 장애 중 낡은 캐시의 키로 서명된 토큰을 받아 줄지(serve stale)는 아홉이 함께
// 정할 판정이다. 지금처럼 거부한다(아래 단언이 그것도 잠근다).
describe('낡은 캐시(cacheMaxAge 뒤) + IdP 장애 — 실패한 갱신도 백오프한다', () => {
  let srv: Server
  let uri: string
  let status = 200
  let certs = 0
  let jumpTo: number | null = null // 있으면 서버가 답하기 전에 가짜 시계를 여기로 옮긴다(응답을 기다리는 사이 시간이 흐른다)
  let published: Awaited<ReturnType<typeof generateKeyPair>>
  let forger: Awaited<ReturnType<typeof generateKeyPair>>['privateKey']

  beforeAll(async () => {
    published = await generateKeyPair('RS256')
    forger = (await generateKeyPair('RS256')).privateKey
    const body = JSON.stringify({
      keys: [{ ...(await exportJWK(published.publicKey)), kid: 'k1', use: 'sig', alg: 'RS256' }],
    })
    srv = createServer((_req, res) => {
      certs += 1
      if (jumpTo !== null) {
        vi.setSystemTime(jumpTo)
        jumpTo = null
      }
      if (status !== 200) {
        res.writeHead(status, { 'content-type': 'text/plain' })
        res.end('unavailable')
        return
      }
      res.writeHead(200, { 'content-type': 'application/json' })
      res.end(body)
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

  const legit = (): Promise<string> =>
    new SignJWT({ sub: 'u', aud: 'my-client' })
      .setProtectedHeader({ alg: 'RS256', kid: 'k1' })
      .setIssuer(ISS)
      .setIssuedAt()
      .setExpirationTime('10m')
      .sign(published.privateKey)

  const forgedKid = (kid: string): Promise<string> =>
    new SignJWT({ sub: 'u', aud: 'my-client' })
      .setProtectedHeader({ alg: 'RS256', kid })
      .setIssuer(ISS)
      .setIssuedAt()
      .setExpirationTime('10m')
      .sign(forger)

  /**
   * 캐시를 채운다(콜드 적재 한 번). `jitter: () => 1` 을 주면 창이 정확히 0.2 초 × 2^(실패−1) 이다 — 창의 끝을
   * 겨누는 대조군이 쓴다. 시계는 `Date` 만 가짜다(jose 의 `fresh` 와 SDK 의 기본 `now` 가 둘 다 `Date.now()` 를 읽는다).
   */
  async function warm(seams?: {
    now?: () => number
    jitter?: () => number
  }): Promise<{ v: JwtValidator; t0: number }> {
    vi.useFakeTimers({ toFake: ['Date'] })
    const t0 = Date.now()
    status = 200
    certs = 0
    const opts = { ...baseOpts, jwksMinRefetchSeconds: 30 }
    const v =
      seams === undefined
        ? JwtValidator.forJwksUri(uri, opts)
        : JwtValidator.forJwksUriWithSeams(uri, opts, seams)
    await expect(v.validate(await legit())).resolves.toMatchObject({ subject: 'u' })
    expect(certs).toBe(1)
    return { v, t0 }
  }

  /**
   * 검증 하나의 결과 — 통과 · 백오프 창 안의 즉시 거부(IdP 없이) · 그 밖의 거부.
   *
   * ⚠️ `cause` 는 `instanceof` 로 가를 수 없다 — `KeycloakError` 가 cause 를 이름·메시지만 남긴 평범한 `Error` 사본으로
   * 바꾼다(`errors.ts` `scrubCause`). 그래서 이름으로 가른다(처음엔 `instanceof` 로 써서 모든 거부가 'rejected' 였다).
   */
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

  it('갱신 실패 한 번이 창을 연다 — 검증 10 회(k1·위조 번갈아)에 /certs 한 건, 나머지는 IdP 없이 즉시 거부', async () => {
    const { v, t0 } = await warm()
    vi.setSystemTime(t0 + 601_000) // 마지막 성공(t0)으로부터 cacheMaxAge(600 초)를 넘었다
    status = 503
    const seen: string[] = []
    for (let i = 0; i < 10; i += 1) {
      seen.push(await outcome(v, i % 2 === 0 ? await legit() : await forgedKid(`forged-${i}`)))
    }
    // 시계가 멈춰 있으니 열 번 모두 첫 실패의 창(0.2 초 × jitter[0.5, 1)) 안이다 — 장애 중 요청은 정확히 한 건.
    expect(certs).toBe(2) // 적재 + 장애 중 한 번(수정 전: 11 — 검증마다 한 건)
    // 수락은 그대로 — 낡은 캐시 + 장애에서 k1 도 거부된다. 첫 검증만 IdP 의 503 을 받고, 나머지 아홉은 콜드 캐시
    // 백오프와 같은 오류(`KeycloakTransportError` 「backing off」를 감싼 `KeycloakTokenValidationError`)다.
    expect(seen).toEqual(['rejected', ...Array<string>(9).fill('backoff')])
  })

  // ⚠️ 대조군 — 위 단언은 「낡은 캐시는 아예 갱신하지 않는다」로도 통과한다. 정상 IdP 에서는 갱신이 일어나고
  // 정상 토큰이 통과해야 한다. **위조 kid 가 먼저 온다** — 그 검증은 갱신에 성공한 뒤 kid 를 못 찾아 거부되는데,
  // 그것을 실패로 세면(규칙 (4)) 뒤따르는 k1 이 창에 막힌다.
  it('대조군 — IdP 가 정상이면 낡은 캐시는 갱신되고 정상 토큰이 통과한다(갱신을 위조 kid 가 일으켜도)', async () => {
    const { v, t0 } = await warm()
    vi.setSystemTime(t0 + 601_000)
    const seen: string[] = []
    for (let i = 0; i < 10; i += 1) {
      seen.push(await outcome(v, i % 2 === 0 ? await forgedKid(`forged-${i}`) : await legit()))
    }
    expect(certs).toBe(2) // 갱신 한 번 — 뒤따르는 위조 kid 의 강제 재조회는 30 초 창이 막는다
    expect(seen).toEqual(Array.from({ length: 10 }, (_, i) => (i % 2 === 0 ? 'rejected' : 'ok')))
  })

  // ⚠️ 대조군(규칙 (4)) — 신선한 캐시의 미해결 kid 거부는 fetch 실패가 아니다. 그것을 세면 위조 kid 홍수가
  // 백오프를 올려 정상 IdP 에서도 정상 토큰이 막힌다(원래 결함보다 나쁜 과잉 수정).
  it('대조군(규칙 (4)) — 신선한 캐시의 위조 kid 홍수는 백오프를 올리지 않는다: 정상 토큰이 계속 통과한다', async () => {
    const { v, t0 } = await warm()
    vi.setSystemTime(t0 + 31_000) // 30 초 창이 열린 뒤 — 홍수의 첫 위조 kid 가 그 창의 강제 재조회를 쓴다
    const seen: string[] = []
    for (let i = 0; i < 10; i += 1) {
      seen.push(await outcome(v, await forgedKid(`flood-${i}`)))
    }
    expect(seen).toEqual(Array<string>(10).fill('rejected')) // 'backoff' 가 하나라도 있으면 홍수가 창을 연 것이다
    expect(certs).toBe(2)
    await expect(v.validate(await legit())).resolves.toMatchObject({ subject: 'u' })
    expect(certs).toBe(2)
  })

  // ⚠️ 대조군(규칙 (4), 경계) — 실패를 「끝났을 때 신선한 캐시가 없다」만으로 세면, 30 초 창이 IdP 없이 거부한
  // 위조 kid(그때는 신선한 캐시)가 그 결정과 catch 사이에 캐시가 600 초를 넘긴 것만으로 세어진다. 밀리초가 그 사이에
  // 넘어가는 것을 `now` 이음매(창의 결정이 부른다)로 재현한다 — 그 판(PM 후보 그대로)에서는 정상 IdP 의 k1 이
  // 'backoff' 로 거부되고 /certs 는 2 그대로였다(갱신 시도조차 없었다).
  it('대조군(규칙 (4), 경계) — 창이 IdP 없이 거부한 위조 kid 는 그사이 캐시가 낡아도 실패로 세지 않는다', async () => {
    let tick = 0
    const now = (): number => {
      const t = Date.now()
      if (tick !== 0) {
        vi.setSystemTime(t + tick) // 창의 결정(이 호출)과 catch 사이에 밀리초가 넘어간다
        tick = 0
      }
      return t
    }
    const { v, t0 } = await warm({ now, jitter: () => 1 })
    vi.setSystemTime(t0 + 590_000)
    status = 503
    // 실패한 강제 재조회 — 30 초 창을 찍지만 jose 의 캐시 시각(t0)은 그대로다. 성공했다면 경계가 1190 초로 밀린다.
    expect(await outcome(v, await forgedKid('blip'))).toBe('rejected')
    expect(certs).toBe(2)
    status = 200
    vi.setSystemTime(t0 + 599_999) // 캐시는 아직 신선하고, 창은 닫혔다(590 초에 찍힘)
    tick = 1
    expect(await outcome(v, await forgedKid('edge'))).toBe('rejected') // IdP 없이 창이 거부
    expect(certs).toBe(2)
    expect(Date.now()).toBe(t0 + 600_000) // 이음매가 실제로 밀리초를 넘겼다 — 그사이 캐시가 낡았다
    expect(await outcome(v, await legit())).toBe('ok') // 정상 IdP — 갱신하고 통과한다
    expect(certs).toBe(3)
  })

  // ⚠️ 대조군 — 첫 단언은 「한 번 실패하면 영원히 안 나간다」로도 통과한다. 창이 지나면 정확히 한 번 나가고,
  // 장애가 이어지면 창이 두 배가 된다(0.2 → 0.4 초).
  it('대조군 — 창 안에서는 IdP 로 안 나가고, 창이 지나면 정확히 한 번 나간다(장애가 이어지면 창이 두 배)', async () => {
    const { v, t0 } = await warm({ jitter: () => 1 })
    const t1 = t0 + 601_000
    vi.setSystemTime(t1)
    status = 503
    expect(await outcome(v, await legit())).toBe('rejected') // 실패 1 — 창 0.2 초
    expect(certs).toBe(2)
    vi.setSystemTime(t1 + 199)
    expect(await outcome(v, await legit())).toBe('backoff')
    expect(certs).toBe(2)
    vi.setSystemTime(t1 + 200)
    expect(await outcome(v, await legit())).toBe('rejected') // 실패 2 — 창 0.4 초
    expect(certs).toBe(3)
    expect(await outcome(v, await forgedKid('in-window'))).toBe('backoff')
    vi.setSystemTime(t1 + 200 + 399)
    expect(await outcome(v, await legit())).toBe('backoff')
    expect(certs).toBe(3)
    vi.setSystemTime(t1 + 200 + 400)
    expect(await outcome(v, await legit())).toBe('rejected')
    expect(certs).toBe(4)
  })

  // ⚠️ 대조군 — 규칙 (3). 낡은 캐시는 성공한 뒤에도 600 초마다 다시 낡으므로 카운터가 남으면 다음 장애가 처음부터
  // 긴 창으로 시작한다(상한 5 초에 붙은 채).
  it('대조군 — 성공하면 카운터가 돌아간다: 회복 뒤 다시 낡아 실패하면 창은 처음(0.2 초)부터다', async () => {
    const { v, t0 } = await warm({ jitter: () => 1 })
    let t = t0 + 601_000
    vi.setSystemTime(t)
    status = 503
    expect(await outcome(v, await legit())).toBe('rejected') // 실패 1 — 창 0.2 초
    vi.setSystemTime((t += 200))
    expect(await outcome(v, await legit())).toBe('rejected') // 실패 2 — 창 0.4 초
    vi.setSystemTime((t += 400))
    expect(await outcome(v, await legit())).toBe('rejected') // 실패 3 — 창 0.8 초
    vi.setSystemTime(t + 799)
    expect(await outcome(v, await legit())).toBe('backoff') // 카운터가 실제로 3 까지 올랐다
    expect(certs).toBe(4)
    vi.setSystemTime((t += 800))
    status = 200
    expect(await outcome(v, await legit())).toBe('ok') // 회복 — 갱신 성공
    expect(certs).toBe(5)
    vi.setSystemTime((t += 601_000)) // 그 성공으로부터 다시 cacheMaxAge 를 넘었다
    status = 503
    expect(await outcome(v, await legit())).toBe('rejected') // 리셋됐다면 실패 1 — 창 0.2 초
    expect(certs).toBe(6)
    vi.setSystemTime((t += 200))
    expect(await outcome(v, await legit())).toBe('rejected') // 리셋이 없었다면 실패 4 — 창 1.6 초라 'backoff'
    expect(certs).toBe(7)
  })

  // ⚠️ 대조군 — 규칙 (3) 의 「성공」은 **적재의** 성공이다. 회복 갱신을 위조 kid 가 일으키면 그 검증은 kid 를 못 찾아
  // 던지지만 적재는 성공했다. 거기서 카운터가 안 돌아가면 다음 장애의 첫 창이 길어지고(0.2 → 0.4 초), jitter 가
  // 검사마다 다시 뽑히는 탓에 신선한 캐시의 k1 까지 남은 창에 막힐 수 있다(참조 구현 ruby 는 fetch 성공에서 되돌린다).
  it('대조군 — 회복 갱신을 위조 kid 가 일으켜도 카운터가 돌아간다', async () => {
    const { v, t0 } = await warm({ jitter: () => 1 })
    let t = t0 + 601_000
    vi.setSystemTime(t)
    status = 503
    expect(await outcome(v, await legit())).toBe('rejected') // 실패 1 — 창 0.2 초
    vi.setSystemTime((t += 200))
    status = 200
    expect(await outcome(v, await forgedKid('recovery'))).toBe('rejected') // 갱신은 성공, kid 가 없다
    expect(certs).toBe(3)
    vi.setSystemTime((t += 601_000)) // 그 갱신으로부터 다시 cacheMaxAge 를 넘었다
    status = 503
    expect(await outcome(v, await legit())).toBe('rejected') // 되돌아갔다면 실패 1 — 창 0.2 초
    expect(certs).toBe(4)
    vi.setSystemTime((t += 200))
    expect(await outcome(v, await legit())).toBe('rejected') // 안 되돌아갔다면 실패 2 — 창 0.4 초라 'backoff'
    expect(certs).toBe(5)
  })

  // ⚠️ 대조군 — 한 번의 실패는 한 번만 센다. jose 는 동시 갱신을 한 fetch 로 합치고 그 실패를 대기자 모두에게 던진다.
  // 대기자마다 세면 503 한 번이 곧바로 상한(5 초) 창이 된다(참조 구현 ruby 는 mutex 로 fetch 마다 한 번 센다).
  it('대조군 — 동시 검증 열이 한 fetch 의 실패를 나눠 받아도 한 번만 센다', async () => {
    const { v, t0 } = await warm({ jitter: () => 1 })
    const t = t0 + 601_000
    vi.setSystemTime(t)
    status = 503
    const tokens = await Promise.all(Array.from({ length: 10 }, () => legit()))
    const seen = await Promise.all(tokens.map((token) => outcome(v, token)))
    expect(certs).toBe(2) // jose 가 열 검증을 한 fetch 로 합쳤다
    expect(seen).toEqual(Array<string>(10).fill('rejected'))
    vi.setSystemTime(t + 200) // 실패 1 이면 창 0.2 초가 지났다(열로 셌다면 상한 5 초 창 안이다)
    status = 200
    expect(await outcome(v, await legit())).toBe('ok')
    expect(certs).toBe(3)
  })

  // 신선할 때 정한 강제 재조회가 응답을 기다리는 사이 캐시가 600 초를 넘기고 실패해도 그것은 fetch 실패다 — 세지
  // 않으면 다음 검증이 또 IdP 로 나간다(백오프 창 전에 두 건).
  it('신선할 때 나간 강제 재조회가 600 초를 넘겨 실패해도 센다 — 다음 검증은 IdP 로 안 나간다', async () => {
    const { v, t0 } = await warm({ jitter: () => 1 })
    vi.setSystemTime(t0 + 599_990) // 신선하고, 30 초 창은 열려 있다(마지막 시도 t0)
    status = 503
    jumpTo = t0 + 600_010 // 응답을 기다리는 사이 캐시가 낡는다
    expect(await outcome(v, await forgedKid('in-flight'))).toBe('rejected')
    expect(certs).toBe(2)
    expect(Date.now()).toBe(t0 + 600_010) // 서버가 실제로 시계를 넘겼다
    vi.setSystemTime(t0 + 600_020)
    expect(await outcome(v, await legit())).toBe('backoff') // IdP 없이 즉시 거부
    expect(certs).toBe(2)
  })
})
