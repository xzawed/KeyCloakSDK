import { describe, it, expect, beforeAll } from 'vitest'
import {
  generateKeyPair,
  exportJWK,
  SignJWT,
  createLocalJWKSet,
  type JWTVerifyGetKey,
  type KeyLike,
} from 'jose'
import { JwtValidator, type JwtValidatorOptions } from '../../src/jwt.js'
import { KeycloakTokenValidationError } from '../../src/errors.js'

const ISS = 'https://kc.example.com/realms/test'
const OPTS: JwtValidatorOptions = {
  issuer: ISS,
  audience: 'my-client',
  allowedAlgs: ['RS256'],
  clockSkewSeconds: 30,
}

describe('JwtValidator (강화 검증)', () => {
  let priv: KeyLike
  let keys: JWTVerifyGetKey

  beforeAll(async () => {
    const kp = await generateKeyPair('RS256')
    priv = kp.privateKey
    const jwk = await exportJWK(kp.publicKey)
    keys = createLocalJWKSet({ keys: [{ ...jwk, kid: 'k1', use: 'sig', alg: 'RS256' }] })
  })

  const sign = (payload: Record<string, unknown>, iss = ISS, expMinutes = '5m') =>
    new SignJWT(payload)
      .setProtectedHeader({ alg: 'RS256', kid: 'k1' })
      .setIssuedAt()
      .setIssuer(iss)
      .setExpirationTime(expMinutes)
      .sign(priv)

  it('정상 RS256 토큰 통과 + subject/audience/issuer/expiresAt/issuedAt 반환', async () => {
    const t = await sign({ sub: 'user1', aud: 'my-client' })
    const v = await new JwtValidator(keys, OPTS).validate(t)
    expect(v.subject).toBe('user1')
    expect(v.audience).toEqual(['my-client'])
    expect(v.issuer).toBe(ISS)
    // exp/iat 클레임(epoch 초)을 첫급 필드로 노출한다(Java/Python 동형).
    expect(typeof v.expiresAt).toBe('number')
    expect(typeof v.issuedAt).toBe('number')
    expect(v.expiresAt ?? 0).toBeGreaterThan(v.issuedAt ?? 0)
  })

  it('다중 aud 배열 — 포함검사로 통과', async () => {
    const t = await sign({ sub: 'u', aud: ['my-client', 'realm-management'] })
    const v = await new JwtValidator(keys, OPTS).validate(t)
    expect(v.audience).toEqual(['my-client', 'realm-management'])
  })

  it('기대 aud 미포함 → KeycloakTokenValidationError', async () => {
    const t = await sign({ sub: 'u', aud: 'other-client' })
    await expect(new JwtValidator(keys, OPTS).validate(t)).rejects.toBeInstanceOf(
      KeycloakTokenValidationError,
    )
  })

  it('잘못된 issuer → 거부', async () => {
    const t = await sign({ sub: 'u', aud: 'my-client' }, 'https://evil.example.com/realms/test')
    await expect(new JwtValidator(keys, OPTS).validate(t)).rejects.toBeInstanceOf(
      KeycloakTokenValidationError,
    )
  })

  it('만료 토큰(스큐 밖) → 거부', async () => {
    const now = Math.floor(Date.now() / 1000)
    const t = await new SignJWT({ sub: 'u', aud: 'my-client' })
      .setProtectedHeader({ alg: 'RS256', kid: 'k1' })
      .setIssuer(ISS)
      .setIssuedAt(now - 1000)
      .setExpirationTime(now - 100)
      .sign(priv)
    await expect(new JwtValidator(keys, OPTS).validate(t)).rejects.toBeInstanceOf(
      KeycloakTokenValidationError,
    )
  })

  it('exp 클레임이 없는 토큰 → 거부(무만료 토큰 방지)', async () => {
    // setExpirationTime을 호출하지 않아 exp 클레임이 없는 토큰. jose는 exp가 존재할 때만
    // 만료를 검사하므로, exp 존재를 강제하지 않으면 무만료 토큰이 통과한다(Go/Rust/Python
    // 동형의 심층방어 — Keycloak은 항상 exp를 발급하므로 부재는 위조/오구성 신호다).
    const t = await new SignJWT({ sub: 'u', aud: 'my-client' })
      .setProtectedHeader({ alg: 'RS256', kid: 'k1' })
      .setIssuer(ISS)
      .setIssuedAt()
      .sign(priv)
    await expect(new JwtValidator(keys, OPTS).validate(t)).rejects.toBeInstanceOf(
      KeycloakTokenValidationError,
    )
  })

  it('알고리즘 핀 위반(허용 목록 밖) → 거부', async () => {
    const t = await sign({ sub: 'u', aud: 'my-client' })
    const strict = new JwtValidator(keys, { ...OPTS, allowedAlgs: ['ES256'] })
    await expect(strict.validate(t)).rejects.toBeInstanceOf(KeycloakTokenValidationError)
  })

  it('forJwksUri — 원격 JWKS 검증기 구성(지연 fetch, 네트워크 호출 없음)', () => {
    const v = JwtValidator.forJwksUri(
      'https://kc.example.com/realms/test/protocol/openid-connect/certs',
      OPTS,
    )
    expect(v).toBeInstanceOf(JwtValidator)
  })
})
