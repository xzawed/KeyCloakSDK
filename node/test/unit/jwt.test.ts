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

  describe('withAudience — 코드 교환의 id_token 용(aud 만 바뀐다)', () => {
    it('기대 aud 만 바꾸고 원본 검증기는 그대로 둔다', async () => {
      const base = JwtValidator.forKeySource(keys, OPTS)
      const derived = base.withAudience('the-client')
      await expect(
        derived.validate(await sign({ sub: 'u', aud: 'the-client' })),
      ).resolves.toMatchObject({ audience: ['the-client'] })
      await expect(
        derived.validate(await sign({ sub: 'u', aud: 'my-client' })),
      ).rejects.toBeInstanceOf(KeycloakTokenValidationError)
      // 원본은 파생 뒤에도 자기 audience 를 쓴다 — opts 를 공유 변이하지 않는다.
      await expect(base.validate(await sign({ sub: 'u', aud: 'my-client' }))).resolves.toBeDefined()
      await expect(
        base.validate(await sign({ sub: 'u', aud: 'the-client' })),
      ).rejects.toBeInstanceOf(KeycloakTokenValidationError)
    })

    it('키 소스는 같은 객체다 — JWKS 캐시·재조회 제한·백오프를 둘로 나누지 않는다', () => {
      const base = JwtValidator.forJwksUri(
        'https://kc.example.com/realms/test/protocol/openid-connect/certs',
        OPTS,
      )
      const keysOf = (v: JwtValidator): unknown => (v as unknown as { keys: unknown }).keys
      expect(keysOf(base)).toBeTypeOf('function')
      expect(Object.is(keysOf(base.withAudience('the-client')), keysOf(base))).toBe(true)
    })

    it('iss · alg 핀 · exp 필수 · 클록 스큐는 그대로다', async () => {
      const derived = JwtValidator.forKeySource(keys, OPTS).withAudience('the-client')
      const now = Math.floor(Date.now() / 1000)
      const at = (exp: number) =>
        new SignJWT({ sub: 'u', aud: 'the-client' })
          .setProtectedHeader({ alg: 'RS256', kid: 'k1' })
          .setIssuer(ISS)
          .setIssuedAt(now - 120)
          .setExpirationTime(exp)
          .sign(priv)
      const rejects = async (t: string) =>
        expect(derived.validate(t)).rejects.toBeInstanceOf(KeycloakTokenValidationError)

      await rejects(
        await sign({ sub: 'u', aud: 'the-client' }, 'https://evil.example.com/realms/test'),
      )
      await rejects(await at(now - 60)) // 스큐(30초) 밖 만료
      await expect(derived.validate(await at(now - 10))).resolves.toBeDefined() // 스큐 안 — 스큐가 살아 있다
      await rejects(
        await new SignJWT({ sub: 'u', aud: 'the-client' })
          .setProtectedHeader({ alg: 'RS256', kid: 'k1' })
          .setIssuer(ISS)
          .setIssuedAt()
          .sign(priv),
      ) // exp 없음
      const pinned = JwtValidator.forKeySource(keys, { ...OPTS, allowedAlgs: ['ES256'] })
      await expect(
        pinned.withAudience('the-client').validate(await sign({ sub: 'u', aud: 'the-client' })),
      ).rejects.toBeInstanceOf(KeycloakTokenValidationError)
    })
  })

  /**
   * 받는 토큰의 길이 상한(inbound-token-cap) — jose 가 나누고 디코드하기 전, 키를 찾기 전에 거부한다. 상한 상수는
   * export 하지 않으므로(공개 표면) `CAP` 은 `src/jwt.ts` 의 `JWT_MAX_BYTES` 와 같아야 한다. 콜드 원격 검증기의
   * JWKS 요청 0 은 `jwt-jwks.test.ts` 가 잰다.
   */
  describe('받는 토큰의 길이 상한(inbound-token-cap)', () => {
    const CAP = 256_000

    /** `pad` 클레임을 덧대 길이가 [length - 8, length] 인 진짜 서명 토큰(역할이 많은 사용자의 모양). */
    const padded = async (length: number): Promise<string> => {
      const make = (n: number) => sign({ sub: 'u', aud: 'my-client', pad: 'a'.repeat(n) })
      let n = Math.floor((length - (await make(0)).length) * 0.75)
      let token = await make(n)
      while (token.length > length) {
        n -= 1
        token = await make(n)
      }
      expect(token.length).toBeGreaterThan(length - 8)
      return token
    }

    it('T1 — 상한 + 1 의 쓰레기는 디코드 전에 거부한다(디코드가 먼저면 `exceeds` 를 말하지 않는다)', async () => {
      const over = `${'a'.repeat(CAP - 1)}..`
      expect(over.length).toBe(CAP + 1)
      const refused = JwtValidator.forKeySource(keys, OPTS).validate(over)
      await expect(refused).rejects.toBeInstanceOf(KeycloakTokenValidationError)
      await expect(refused).rejects.toThrow('JWT validation failed: token exceeds 256000 bytes')
    })

    it('T2 — 상한 길이의 쓰레기는 상한이 아니라 jose 가 거부한다(`>` 이지 `>=` 가 아니다)', async () => {
      const atCap = `${'a'.repeat(CAP - 2)}..`
      expect(atCap.length).toBe(CAP)
      const refused = await JwtValidator.forKeySource(keys, OPTS)
        .validate(atCap)
        .then(
          () => undefined,
          (e: unknown) => e,
        )
      expect(refused).toBeInstanceOf(KeycloakTokenValidationError)
      expect((refused as Error).message).not.toContain('exceeds')
    })

    it.each([
      ['Keycloak 26.6 기본값이 받는 가장 긴 Bearer', 65_459],
      ['상한', CAP],
    ])('T3 — %s(%i 자)까지 덧댄 진짜 서명 토큰은 통과한다', async (_name, length) => {
      const token = await padded(length)
      await expect(JwtValidator.forKeySource(keys, OPTS).validate(token)).resolves.toMatchObject({
        subject: 'u',
      })
    })

    it('JS 호출자의 문자열 아닌 값 — 검사가 raw TypeError 를 내지 않고, jose 가 받는 Uint8Array 도 잰다', async () => {
      const v = JwtValidator.forKeySource(keys, OPTS)
      await expect(v.validate(undefined as unknown as string)).rejects.toBeInstanceOf(
        KeycloakTokenValidationError,
      )
      await expect(v.validate(new Uint8Array(CAP + 1) as unknown as string)).rejects.toThrow(
        'JWT validation failed: token exceeds 256000 bytes',
      )
    })
  })

  it('forJwksUri — 원격 JWKS 검증기 구성(지연 fetch, 네트워크 호출 없음)', () => {
    const v = JwtValidator.forJwksUri(
      'https://kc.example.com/realms/test/protocol/openid-connect/certs',
      OPTS,
    )
    expect(v).toBeInstanceOf(JwtValidator)
  })
})
