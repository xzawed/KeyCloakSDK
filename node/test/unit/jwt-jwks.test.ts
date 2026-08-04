/**
 * JWKS 재조회 rate-limit(`cooldownDuration`)이 실제로 동작하는지 **HTTP 히트 수**로 잠근다.
 *
 * 왜 필요한가: `JwtValidator.forJwksUri`는 jose에 `cooldownDuration`/`cacheMaxAge`를 넘겨
 * 미인증 DoS 증폭(위조 kid를 실은 Bearer 토큰마다 IdP를 때리는 것)을 차단한다. 그런데 이 옵션이
 * 상위 버전에서 이름이 바뀌거나 제거되면 JavaScript는 알 수 없는 프로퍼티를 **조용히 무시**한다 —
 * 타입체크도(테스트는 tsconfig `include`에 없다), 린트도, 나머지 테스트도 그걸 잡지 못한 채
 * 하드닝만 사라진다. 히트 수를 세는 것 외에 이 실패 모드를 감지할 방법이 없다.
 *
 * ⚠️ 두 번째 케이스(대조군)를 **지우지 말 것** — 실제로 회귀를 잡는 쪽은 그쪽이다. 변이 검증
 * 실측: `cooldownDuration`을 개명해 무시되게 만들면 jose가 자체 기본값(30초)으로 폴백하므로
 * 첫 케이스는 그대로 통과한다(우리 설정값도 30초라 구분이 안 된다). cooldown=0을 요구하는
 * 대조군만이 히트 7 → 1로 떨어지며 실패한다. 대조군이 없으면 하드닝 유실이 무사통과한다.
 */
import { describe, it, expect, beforeAll, afterAll } from 'vitest'
import { createServer, type Server } from 'node:http'
import type { AddressInfo } from 'node:net'
import { generateKeyPair, exportJWK, SignJWT } from 'jose'
import { JwtValidator, type JwtValidatorOptions } from '../../src/jwt.js'
import { KeycloakTokenValidationError } from '../../src/errors.js'

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

describe('JWKS 재조회 rate-limit (cooldownDuration 실동작)', () => {
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
