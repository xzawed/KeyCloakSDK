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

beforeAll(async () => {
  // 서버가 내주는 JWKS에는 kid 'served' 하나뿐이다.
  const served = await generateKeyPair('RS256')
  const servedJwk = await exportJWK(served.publicKey)
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
})
