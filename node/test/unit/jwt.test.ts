import { describe, it, expect, beforeAll } from 'vitest'
// jose v6는 `KeyLike` 타입 별칭을 제거했다 — 키 타입은 generateKeyPair의 반환에서 추론한다.
import {
  generateKeyPair,
  exportJWK,
  exportSPKI,
  SignJWT,
  createLocalJWKSet,
  type JWTVerifyGetKey,
} from 'jose'
import { JwtValidator, type JwtValidatorOptions } from '../../src/jwt.js'
import { KeycloakTokenValidationError } from '../../src/errors.js'

const ISS = 'https://kc.example.com/realms/test'
const OPTS: JwtValidatorOptions = {
  issuer: ISS,
  audience: 'my-client',
  allowedAlgs: ['RS256'],
  clockSkewSeconds: 30,
  jwksMinRefetchSeconds: 30,
}

describe('JwtValidator (강화 검증)', () => {
  let priv: Awaited<ReturnType<typeof generateKeyPair>>['privateKey']
  let pub: Awaited<ReturnType<typeof generateKeyPair>>['publicKey']
  let keys: JWTVerifyGetKey

  beforeAll(async () => {
    const kp = await generateKeyPair('RS256')
    priv = kp.privateKey
    pub = kp.publicKey
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
    const v = await JwtValidator.forKeySource(keys, OPTS).validate(t)
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
    const v = await JwtValidator.forKeySource(keys, OPTS).validate(t)
    expect(v.audience).toEqual(['my-client', 'realm-management'])
  })

  it('기대 aud 미포함 → KeycloakTokenValidationError', async () => {
    const t = await sign({ sub: 'u', aud: 'other-client' })
    await expect(JwtValidator.forKeySource(keys, OPTS).validate(t)).rejects.toBeInstanceOf(
      KeycloakTokenValidationError,
    )
  })

  it('잘못된 issuer → 거부', async () => {
    const t = await sign({ sub: 'u', aud: 'my-client' }, 'https://evil.example.com/realms/test')
    await expect(JwtValidator.forKeySource(keys, OPTS).validate(t)).rejects.toBeInstanceOf(
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
    await expect(JwtValidator.forKeySource(keys, OPTS).validate(t)).rejects.toBeInstanceOf(
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
    await expect(JwtValidator.forKeySource(keys, OPTS).validate(t)).rejects.toBeInstanceOf(
      KeycloakTokenValidationError,
    )
  })

  it('알고리즘 핀 위반(허용 목록 밖) → 거부', async () => {
    const t = await sign({ sub: 'u', aud: 'my-client' })
    const strict = JwtValidator.forKeySource(keys, { ...OPTS, allowedAlgs: ['ES256'] })
    await expect(strict.validate(t)).rejects.toBeInstanceOf(KeycloakTokenValidationError)
  })

  it('alg=none 미서명 토큰 → 거부(서명 없는 토큰이 통과하지 않는다)', async () => {
    // 손수 조립한다 — jose는 미서명 JWT를 만들어주지 않으므로 SignJWT로는 이 공격을 재현할 수 없다.
    // ⚠️ 이 방어는 우리 alg 핀이 아니라 jose가 제공한다(`jwtVerify`는 `alg:"none"`을 항상 거부하며,
    // 그래서 allowedAlgs에 'none'을 넣어도 통과시킬 수 없다 — 아래에서 그 점까지 못박는다).
    // 테스트의 값은 그 라이브러리 보장을 계약으로 고정하는 데 있다: jose 교체나 상류 동작 변경으로
    // 미서명 토큰이 새면 여기서 깨진다. 나머지 8개 언어의 동형 프로브와 짝을 이룬다.
    const b64u = (o: unknown) => Buffer.from(JSON.stringify(o)).toString('base64url')
    const now = Math.floor(Date.now() / 1000)
    const unsigned = `${b64u({ alg: 'none', kid: 'k1' })}.${b64u({
      sub: 'u',
      aud: 'my-client',
      iss: ISS,
      iat: now,
      exp: now + 300,
    })}.`
    await expect(JwtValidator.forKeySource(keys, OPTS).validate(unsigned)).rejects.toBeInstanceOf(
      KeycloakTokenValidationError,
    )
    // 'none'을 명시적으로 허용해도 뚫리지 않는다 — 설정 실수에 대한 심층방어.
    const permissive = JwtValidator.forKeySource(keys, { ...OPTS, allowedAlgs: ['RS256', 'none'] })
    await expect(permissive.validate(unsigned)).rejects.toBeInstanceOf(KeycloakTokenValidationError)
  })

  it('HS256/RS256 혼동 공격(공개키를 HMAC 비밀로 사용) → 거부', async () => {
    // 고전 공격: 공격자는 공개된 RSA 공개키 텍스트를 HMAC 비밀로 삼아 HS256 토큰을 위조한다.
    // 검증기가 헤더의 alg를 믿고 키를 고르면 "공개키를 아는 사람 = 토큰을 발급할 수 있는 사람"이 된다.
    const pubPem = await exportSPKI(pub)
    const forged = await new SignJWT({ sub: 'attacker', aud: 'my-client' })
      .setProtectedHeader({ alg: 'HS256', kid: 'k1' })
      .setIssuer(ISS)
      .setIssuedAt()
      .setExpirationTime('5m')
      .sign(new TextEncoder().encode(pubPem))
    await expect(JwtValidator.forKeySource(keys, OPTS).validate(forged)).rejects.toBeInstanceOf(
      KeycloakTokenValidationError,
    )
    // alg 핀이 HS256을 허용하도록 잘못 구성되어도 뚫리지 않아야 한다 — 키 소스가 RSA JWKS라
    // HMAC 검증에 쓸 대칭키가 없기 때문이다. 이 두 번째 단언이 없으면 이 테스트는 alg 핀만
    // 확인하는 셈이라 '혼동 공격 방어'라는 이름값을 못 한다.
    const permissive = JwtValidator.forKeySource(keys, { ...OPTS, allowedAlgs: ['RS256', 'HS256'] })
    await expect(permissive.validate(forged)).rejects.toBeInstanceOf(KeycloakTokenValidationError)
  })

  it('forJwksUri — 원격 JWKS 검증기 구성(지연 fetch, 네트워크 호출 없음)', () => {
    const v = JwtValidator.forJwksUri(
      'https://kc.example.com/realms/test/protocol/openid-connect/certs',
      OPTS,
    )
    expect(v).toBeInstanceOf(JwtValidator)
  })
})
