/**
 * JWKS 응답 **바이트 상한** — go·rust·java·kotlin 이 갖고 있었고 php·ruby 는 #466 이 넣었다.
 * node 는 `jose` 에 위임하므로 그동안 **측정되지 않은 채 남아 있었다**.
 *
 * 실측(2026-09-11 · jose 6.2.12 · `node_modules/jose/dist/webapi/jwks/remote.js:10-26`):
 * `fetchJwks` 는 `GET` → status 200 확인 → `response.json()` 이 전부다. `Content-Length`
 * 검사도, 최대 바이트 옵션도, 읽기를 끊는 스트리밍도 **없다**. 유일한 중단은 시간
 * (`AbortSignal.timeout`, 기본 5초)이다. 즉 손상된 IdP 하나가 검증 경로를 메모리로 죽일 수 있다.
 *
 * 이음매는 `createRemoteJWKSet` 의 `[customFetch]`(`dist/types/jwks/remote.d.ts:8,49-50`)이고,
 * **JWKS 전용**이라 토큰·introspect 경로에는 영향이 없다.
 */
import { describe, it, expect, beforeAll, afterAll } from 'vitest'
import { createServer, type Server } from 'node:http'
import type { AddressInfo } from 'node:net'
import { generateKeyPair, exportJWK, SignJWT } from 'jose'
import { JwtValidator, type JwtValidatorOptions, JWKS_MAX_BYTES } from '../../src/jwt.js'

const ISS = 'https://kc.example.com/realms/test'

const baseOpts: Omit<JwtValidatorOptions, 'jwksMinRefetchSeconds'> = {
  issuer: ISS,
  audience: 'my-client',
  allowedAlgs: ['RS256'],
  clockSkewSeconds: 30,
}

let server: Server
let base: string
let signingKey: Awaited<ReturnType<typeof generateKeyPair>>['privateKey']
/** 서버가 실제로 내보낸 바이트 — 「예외를 던졌다」와 「슬러프하지 않았다」를 가른다. */
let bytesWritten = 0

beforeAll(async () => {
  const kp = await generateKeyPair('RS256')
  signingKey = kp.privateKey
  const jwk = await exportJWK(kp.publicKey)
  const keyEntry = { ...jwk, kid: 'k1', use: 'sig', alg: 'RS256' }
  const sane = JSON.stringify({ keys: [keyEntry] })
  // 유효한 JWKS 의 **앞부분** — 뒤에 패딩을 이어 붙여 5MB 로 부풀린다.
  const hugePrefix = `{"keys":[${JSON.stringify(keyEntry)}],"padding":"`

  server = createServer((req, res) => {
    const url = req.url ?? '/'
    if (url.startsWith('/sane')) {
      res.writeHead(200, { 'content-type': 'application/json' })
      res.end(sane)
      return
    }
    // ⚠️ **거대 본문은 「유효한 JWKS」여야 한다.** 쓰레기 바이트를 보내면 상한이 없어도
    // JSON 파싱이 실패해 거부되므로, 「거부됐다」가 상한의 증거가 되지 못한다(첫 판에서
    // 실제로 그랬다 — 상한 없이도 통과했다). 진짜 키를 담고 뒤에 패딩을 붙이면, 상한이
    // 없을 때 검증이 **성공**하므로 거부가 곧 상한의 증거가 된다.
    // ⚠️ `Content-Length` 를 **보내지 않는다**(chunked) — 헤더만 보는 구현은 이것을 놓친다.
    const status = url.startsWith('/huge-500') ? 500 : 200
    res.writeHead(status, { 'content-type': 'application/json' })
    res.write(hugePrefix)
    bytesWritten += hugePrefix.length
    const chunk = 'x'.repeat(8192)
    let sent = 0
    const pump = (): void => {
      while (sent < JWKS_MAX_BYTES * 100) {
        sent += chunk.length
        bytesWritten += chunk.length
        if (!res.write(chunk)) {
          res.once('drain', pump)
          return
        }
      }
      res.end('"}')
    }
    pump()
  })
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve))
  base = `http://127.0.0.1:${(server.address() as AddressInfo).port}`
})

afterAll(async () => {
  await new Promise<void>((resolve) => server.close(() => resolve()))
})

async function token(kid: string): Promise<string> {
  return new SignJWT({ sub: 'u', aud: 'my-client' })
    .setProtectedHeader({ alg: 'RS256', kid })
    .setIssuer(ISS)
    .setIssuedAt()
    .setExpirationTime('5m')
    .sign(signingKey)
}

describe('JWKS 응답 크기 상한', () => {
  it('상한을 넘는 본문은 거부된다', async () => {
    const v = JwtValidator.forJwksUri(`${base}/huge`, { ...baseOpts, jwksMinRefetchSeconds: 30 })
    await expect(v.validate(await token('k1'))).rejects.toThrow()
  })

  /** ⚠️ **대조군을 지우지 말 것** — 위 단언만 두면 「어떤 JWKS 든 거부한다」로도 통과한다. */
  it('대조군 — 상한 아래 본문은 그대로 검증된다', async () => {
    const v = JwtValidator.forJwksUri(`${base}/sane`, { ...baseOpts, jwksMinRefetchSeconds: 30 })
    const out = await v.validate(await token('k1'))
    expect(out.subject).toBe('u')
  })

  /**
   * ⚠️ **예외를 던지는 것만으로는 「슬러프하지 않는다」의 증거가 못 된다** — 다 읽고 나서
   * 길이를 재도 그 단언은 참이다. 서버가 실제로 내보낸 바이트를 세어 읽기가 끊겼음을 본다.
   */
  it('상한을 넘기면 읽기를 끊는다 — 5MB 를 전부 받지 않는다', async () => {
    bytesWritten = 0
    const v = JwtValidator.forJwksUri(`${base}/huge`, { ...baseOpts, jwksMinRefetchSeconds: 30 })
    await expect(v.validate(await token('k1'))).rejects.toThrow()
    expect(bytesWritten).toBeLessThan(JWKS_MAX_BYTES * 100)
  })

  /** ⚠️ 200 만 겨누면 오류 응답의 거대 본문이 그대로 들어온다 — php 가 그 순서였다. */
  it('오류 응답의 거대 본문도 상한에 걸린다', async () => {
    const v = JwtValidator.forJwksUri(`${base}/huge-500`, {
      ...baseOpts,
      jwksMinRefetchSeconds: 30,
    })
    await expect(v.validate(await token('k1'))).rejects.toThrow()
  })

  /** 값은 Nimbus `DEFAULT_HTTP_SIZE_LIMIT` 이고 자매 다섯이 같은 수를 쓴다. */
  it('상한은 51200 이다 (go·rust·php·ruby 동형)', () => {
    expect(JWKS_MAX_BYTES).toBe(51_200)
  })
})
