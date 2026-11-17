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

/** 실패해야 하는 검증의 오류 — 성공하면 그것이 곧 실패다. */
async function refusal(call: Promise<unknown>): Promise<Error> {
  const outcome = await call.then(
    () => undefined,
    (e: unknown) => e,
  )
  if (!(outcome instanceof Error)) throw new Error('expected a refusal, got success')
  return outcome
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

  /**
   * Keycloak 의 액세스 토큰 모양 — typ "Bearer"(액세스 검증은 Bearer · DPoP 만 받는다 — 아래 (A) 묶음). typ 자체를 재는
   * 칸은 `sign` 을 쓴다.
   */
  const access = (payload: Record<string, unknown>, iss = ISS, expMinutes = '5m') =>
    sign({ typ: 'Bearer', ...payload }, iss, expMinutes)

  it('정상 RS256 토큰 통과 + subject/audience/issuer/expiresAt/issuedAt 반환', async () => {
    const t = await access({ sub: 'user1', aud: 'my-client' })
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
    const t = await access({ sub: 'u', aud: ['my-client', 'realm-management'] })
    const v = await JwtValidator.forKeySource(keys, OPTS).validate(t)
    expect(v.audience).toEqual(['my-client', 'realm-management'])
  })

  it('기대 aud 미포함 → KeycloakTokenValidationError', async () => {
    const t = await access({ sub: 'u', aud: 'other-client' })
    await expect(JwtValidator.forKeySource(keys, OPTS).validate(t)).rejects.toBeInstanceOf(
      KeycloakTokenValidationError,
    )
  })

  it('잘못된 issuer → 거부', async () => {
    const t = await access({ sub: 'u', aud: 'my-client' }, 'https://evil.example.com/realms/test')
    await expect(JwtValidator.forKeySource(keys, OPTS).validate(t)).rejects.toBeInstanceOf(
      KeycloakTokenValidationError,
    )
  })

  it('만료 토큰(스큐 밖) → 거부', async () => {
    const now = Math.floor(Date.now() / 1000)
    const t = await new SignJWT({ sub: 'u', aud: 'my-client', typ: 'Bearer' })
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
    const t = await new SignJWT({ sub: 'u', aud: 'my-client', typ: 'Bearer' })
      .setProtectedHeader({ alg: 'RS256', kid: 'k1' })
      .setIssuer(ISS)
      .setIssuedAt()
      .sign(priv)
    await expect(JwtValidator.forKeySource(keys, OPTS).validate(t)).rejects.toBeInstanceOf(
      KeycloakTokenValidationError,
    )
  })

  it('알고리즘 핀 위반(허용 목록 밖) → 거부', async () => {
    const t = await access({ sub: 'u', aud: 'my-client' })
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
      typ: 'Bearer',
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
    const forged = await new SignJWT({ sub: 'attacker', aud: 'my-client', typ: 'Bearer' })
      .setProtectedHeader({ alg: 'HS256', kid: 'k1' })
      .setIssuer(ISS)
      .setIssuedAt()
      .setExpirationTime('5m')
      .sign(new TextEncoder().encode(pubPem))
    await expect(JwtValidator.forKeySource(keys, OPTS).validate(forged)).rejects.toBeInstanceOf(
      KeycloakTokenValidationError,
    )
    // alg 핀이 HS256을 허용하도록 잘못 구성되어도 뚫리지 않아야 한다 — 검증기가 키 조회 전에 HS 를
    // 거부한다(등록부 hs-refusal-rests-on-libraries · 키 소스도 RSA JWKS 라 대칭키가 없다). 이 두 번째 단언이 없으면 이 테스트는 alg 핀만
    // 확인하는 셈이라 '혼동 공격 방어'라는 이름값을 못 한다.
    const permissive = JwtValidator.forKeySource(keys, { ...OPTS, allowedAlgs: ['RS256', 'HS256'] })
    await expect(permissive.validate(forged)).rejects.toBeInstanceOf(KeycloakTokenValidationError)
  })

  // 파생 검증기에 주는 토큰은 Keycloak 의 id_token 처럼 typ "ID" 를 싣는다 — 종류 규칙(아래 묶음)이 이 묶음의 판정을 가로채지
  // 않게. 원본(액세스 검증기)에 주는 토큰은 액세스 토큰처럼 typ "Bearer" 다(`access`).
  describe('withAudience — 코드 교환의 id_token 용(aud 만 바뀐다)', () => {
    it('기대 aud 만 바꾸고 원본 검증기는 그대로 둔다', async () => {
      const base = JwtValidator.forKeySource(keys, OPTS)
      const derived = base.withAudience('the-client')
      await expect(
        derived.validate(await sign({ sub: 'u', aud: 'the-client', typ: 'ID' })),
      ).resolves.toMatchObject({ audience: ['the-client'] })
      await expect(
        derived.validate(await sign({ sub: 'u', aud: 'my-client', typ: 'ID' })),
      ).rejects.toBeInstanceOf(KeycloakTokenValidationError)
      // 원본은 파생 뒤에도 자기 audience 를 쓴다 — opts 를 공유 변이하지 않는다.
      await expect(
        base.validate(await access({ sub: 'u', aud: 'my-client' })),
      ).resolves.toBeDefined()
      await expect(
        base.validate(await access({ sub: 'u', aud: 'the-client' })),
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
        new SignJWT({ sub: 'u', aud: 'the-client', typ: 'ID' })
          .setProtectedHeader({ alg: 'RS256', kid: 'k1' })
          .setIssuer(ISS)
          .setIssuedAt(now - 120)
          .setExpirationTime(exp)
          .sign(priv)
      const rejects = async (t: string) =>
        expect(derived.validate(t)).rejects.toBeInstanceOf(KeycloakTokenValidationError)

      await rejects(
        await sign(
          { sub: 'u', aud: 'the-client', typ: 'ID' },
          'https://evil.example.com/realms/test',
        ),
      )
      await rejects(await at(now - 60)) // 스큐(30초) 밖 만료
      await expect(derived.validate(await at(now - 10))).resolves.toBeDefined() // 스큐 안 — 스큐가 살아 있다
      await rejects(
        await new SignJWT({ sub: 'u', aud: 'the-client', typ: 'ID' })
          .setProtectedHeader({ alg: 'RS256', kid: 'k1' })
          .setIssuer(ISS)
          .setIssuedAt()
          .sign(priv),
      ) // exp 없음
      const pinned = JwtValidator.forKeySource(keys, { ...OPTS, allowedAlgs: ['ES256'] })
      await expect(
        pinned
          .withAudience('the-client')
          .validate(await sign({ sub: 'u', aud: 'the-client', typ: 'ID' })),
      ).rejects.toBeInstanceOf(KeycloakTokenValidationError)
    })
  })

  /**
   * (A) 액세스 토큰의 종류 — 페이로드의 `typ` 클레임. Keycloak 은 거기에 토큰의 종류를 적는다(`org.keycloak.util.TokenUtil`,
   * keycloak-client-common-synced 26.0.12: 액세스 토큰은 Bearer · DPoP, 그 밖은 ID · Refresh · Offline · Logout ·
   * Serialized-ID). Keycloak 자신의 리소스 쪽 검사(`TokenVerifier.TokenTypeCheck` 의 `equalsIgnoreCase` ·
   * `DPoPUtil.withDPoPVerifier`)처럼 **허용 목록**이다 — typ 이 ASCII 대소문자를 무시하고 Bearer 나 DPoP 와 같은 문자열일 때만
   * 받는다(`TokenManager.formatTokenType` 은 클라이언트 옵션으로 소문자 "bearer" 를 쓴다). 부재 · 문자열이 아닌 값 · 그 밖의
   * 문자열은 거부다 — typ 이 없는 realm 서명 JWT(JARM 인가 응답, aud = client id)가 기본 설정의 aud 검사까지 지나 액세스
   * 토큰으로 받아들여졌다. 알려진 다섯 종류는 지금의 문구(그 값을 말한다), 나머지는 상수 문구다(토큰이 고른 typ 을 싣지 않는다).
   */
  describe('typ — validate 는 Bearer · DPoP(ASCII 대소문자 무시)만 받는다', () => {
    const NOT_ACCESS = 'not an access token (typ is not Bearer or DPoP)'

    it.each(['Bearer', 'bearer', 'BEARER', 'DPoP', 'dpop', 'DPOP', 'dPoP'])(
      'typ "%s" → 통과(토큰이 실은 값 그대로 돌려준다)',
      async (typ) => {
        const token = await sign({ sub: 'u', aud: 'my-client', typ })
        const validated = await JwtValidator.forKeySource(keys, OPTS).validate(token)
        expect(validated.claims['typ']).toBe(typ)
      },
    )

    it.each(['ID', 'Refresh', 'Offline', 'Logout', 'Serialized-ID'])(
      'typ "%s" → KeycloakTokenValidationError(지금의 문구 — 그 값을 말한다)',
      async (typ) => {
        const token = await sign({ sub: 'u', aud: 'my-client', typ })
        const refused = await refusal(JwtValidator.forKeySource(keys, OPTS).validate(token))
        expect(refused).toBeInstanceOf(KeycloakTokenValidationError)
        // 감싼 「JWT validation failed: …」가 아니라 이 거부이고, 어느 typ 인지 말한다.
        expect(refused.message).toBe(`not an access token (typ "${typ}")`)
      },
    )

    // 허용 목록 밖은 전부 상수 문구다 — 다섯 종류와 대소문자 · 공백만 다른 값도(정확히 같을 때만 지금의 문구다).
    it.each([
      ['없음', undefined],
      ['at+jwt(RFC 9068)', 'at+jwt'],
      ['소문자 id', 'id'],
      ['소문자 logout', 'logout'],
      ['뒤에 공백이 붙은 Bearer', 'Bearer '],
      ['앞에 공백이 붙은 bearer', ' bearer'],
      ['Bearer 접두', 'BearerX'],
      ['빈 문자열', ''],
      ['토큰이 고른 문자열', 'CANARY-TYP-7c2e'],
      ['Bearer 를 담은 배열', ['Bearer']],
      ['숫자', 1],
      ['참거짓', true],
      ['객체', { typ: 'Bearer' }],
      ['null', null],
    ])('typ 이 %s 이면 상수 문구로 거부한다(typ 을 싣지 않는다)', async (_name, typ) => {
      const claims = { sub: 'u', aud: 'my-client' }
      const token = await sign(typ === undefined ? claims : { ...claims, typ })
      const refused = await refusal(JwtValidator.forKeySource(keys, OPTS).validate(token))
      expect(refused).toBeInstanceOf(KeycloakTokenValidationError)
      expect(refused.message).toBe(NOT_ACCESS)
      expect(refused.cause).toBeUndefined()
    })

    // JARM 인가 응답(`AuthorizationResponseToken` — Keycloak 의 `OIDCRedirectUriBuilder`)의 모양: typ 이 없고, iss = realm ·
    // aud = client id · exp 와 code · state 를 싣고, realm 키로 서명된다. 기본 설정(audience = clientId)의 aud 검사를 지난다.
    it('JARM 인가 응답 모양(typ 없음 · code · state · aud = client id)을 상수 문구로 거부한다', async () => {
      const jarm = await sign({
        code: 'c0de-from-the-browser-url',
        state: 'st-1',
        aud: 'my-client',
      })
      const refused = await refusal(JwtValidator.forKeySource(keys, OPTS).validate(jarm))
      expect(refused).toBeInstanceOf(KeycloakTokenValidationError)
      expect(refused.message).toBe(NOT_ACCESS)
    })

    // typ 은 서명 · iss · aud · exp 가 통과한 **뒤에** 본다 — 검증 전 클레임으로 판정하지 않는다.
    it('typ "ID" 를 실은 위조 서명 · 다른 aud · 다른 iss 토큰은 typ 이 아니라 그 검사가 거부한다', async () => {
      const forger = (await generateKeyPair('RS256')).privateKey
      const forged = await new SignJWT({ sub: 'u', aud: 'my-client', typ: 'ID' })
        .setProtectedHeader({ alg: 'RS256', kid: 'k1' })
        .setIssuedAt()
        .setIssuer(ISS)
        .setExpirationTime('5m')
        .sign(forger)
      const tokens = [
        forged,
        await sign({ sub: 'u', aud: 'someone-else', typ: 'ID' }),
        await sign(
          { sub: 'u', aud: 'my-client', typ: 'ID' },
          'https://evil.example.com/realms/test',
        ),
      ]
      for (const token of tokens) {
        const refused = await refusal(JwtValidator.forKeySource(keys, OPTS).validate(token))
        expect(refused).toBeInstanceOf(KeycloakTokenValidationError)
        expect(refused.message).toMatch(/^JWT validation failed: /)
      }
    })

    // (B) 는 id_token 의 규칙이다 — 액세스 토큰의 azp 는 그 토큰을 요청한 클라이언트라 기대 audience 와 다른 것이 정상이다.
    it('azp 규칙은 걸지 않는다 — 다중 aud 에 azp 가 없어도 · 다른 클라이언트여도 · 문자열이 아니어도 받는다', async () => {
      const v = JwtValidator.forKeySource(keys, OPTS)
      await expect(
        v.validate(await access({ sub: 'u', aud: ['my-client', 'other'] })),
      ).resolves.toMatchObject({ audience: ['my-client', 'other'] })
      for (const [aud, azp] of [
        ['my-client', 'frontend'],
        [['my-client', 'other'], 'frontend'],
        [['my-client', 'other'], 42],
      ] as const) {
        await expect(v.validate(await access({ sub: 'u', aud, azp }))).resolves.toMatchObject({
          claims: { azp },
        })
      }
    })
  })

  /**
   * `withAudience` 가 주는 것은 id_token 검증기다(코드 교환과 공개 `AuthClient.validateIdToken` 이 함께 쓴다) — (A) 의 거부
   * 목록 대신 종류를 **허용 목록**으로 본다: payload typ 이 정확히 문자열 "ID" 여야 한다(Keycloak 26.6.9 는 id_token 을 한
   * 곳에서 만들고 늘 "ID" 를 싣는다). 그리고 (B) OIDC Core §3.1.3.7 4·5 를 건다: aud 가 둘 이상이면 azp 가 있어야 하고, azp
   * 가 있으면(JSON null 도 있는 것이다) client id 와 같은 문자열이어야 한다.
   */
  describe('withAudience — id_token 검증기: typ 은 정확히 "ID" · azp 규칙', () => {
    const idTokenValidator = () => JwtValidator.forKeySource(keys, OPTS).withAudience('the-client')
    const NOT_ID_TOKEN = 'not an id_token (typ is not "ID")'

    // 허용 목록 — 부재 · 문자열이 아닌 값 · "ID" 와 (대소문자 · 공백까지) 다른 문자열은 전부 거부다. 문구는 상수다(토큰이
    // 고른 값을 싣지 않는다). azp 는 맞춰 둔다 — 거부를 가르는 것이 종류뿐이게.
    it.each([
      ['typ 없음', undefined],
      ['Bearer', 'Bearer'],
      ['소문자 bearer', 'bearer'],
      ['소문자 id', 'id'],
      ['뒤에 공백이 붙은 ID', 'ID '],
      ['Logout', 'Logout'],
      ['숫자', 1],
      ['null', null],
      ['ID 를 담은 배열', ['ID']],
    ])('typ 이 %s 이면 거부한다(문구는 상수)', async (_name, typ) => {
      const claims = { sub: 'u', aud: 'the-client', azp: 'the-client' }
      const token = await sign(typ === undefined ? claims : { ...claims, typ })
      const refused = await refusal(idTokenValidator().validate(token))
      expect(refused).toBeInstanceOf(KeycloakTokenValidationError)
      expect(refused.message).toBe(NOT_ID_TOKEN)
    })

    it('종류를 azp 보다 먼저 본다 — 종류도 azp 도 틀린 토큰은 종류의 문구다', async () => {
      const token = await sign({ sub: 'u', aud: ['the-client', 'evil'], typ: 'Bearer' })
      const refused = await refusal(idTokenValidator().validate(token))
      expect(refused.message).toBe(NOT_ID_TOKEN)
    })

    it('종류는 서명 · iss · aud · exp 가 통과한 뒤에 본다 — typ 없는 다른 aud 토큰은 aud 의 문구다', async () => {
      const refused = await refusal(
        idTokenValidator().validate(await sign({ sub: 'u', aud: 'someone-else' })),
      )
      expect(refused.message).toBe('JWT validation failed: unexpected "aud" claim value')
    })

    it('typ "ID" 를 받는다 — 같은 토큰을 원본(aud 가 같은 액세스 검증기)은 거부하고, 파생 뒤에도 원본은 그대로다', async () => {
      const token = await sign({ sub: 'u', aud: 'the-client', typ: 'ID', azp: 'the-client' })
      const access = JwtValidator.forKeySource(keys, { ...OPTS, audience: 'the-client' })
      await expect(access.withAudience('the-client').validate(token)).resolves.toMatchObject({
        claims: { typ: 'ID' },
      })
      const refused = await refusal(access.validate(token))
      expect(refused).toBeInstanceOf(KeycloakTokenValidationError)
      expect(refused.message).toBe('not an access token (typ "ID")')
    })

    it.each([
      ['aud 하나 · azp 없음', 'the-client', undefined],
      ['aud 하나 · azp = client', 'the-client', 'the-client'],
      ['aud 둘 · azp = client', ['the-client', 'other'], 'the-client'],
      ['aud 둘(순서 반대) · azp = client', ['other', 'the-client'], 'the-client'],
    ])('%s → 통과', async (_name, aud, azp) => {
      const token = await sign({ sub: 'u', aud, typ: 'ID', ...(azp === undefined ? {} : { azp }) })
      await expect(idTokenValidator().validate(token)).resolves.toMatchObject({ subject: 'u' })
    })

    it.each([
      ['aud 하나 · azp 가 다른 클라이언트', 'the-client', 'evil'],
      ['aud 둘 · azp 없음', ['the-client', 'evil'], undefined],
      ['aud 둘 · azp 가 다른 aud', ['the-client', 'evil'], 'evil'],
      ['azp 가 숫자', 'the-client', 42],
      ['azp 가 client id 를 담은 배열', 'the-client', ['the-client']],
      ['azp 가 JSON null', 'the-client', null],
    ])('%s → 거부(메시지가 azp 를 말한다)', async (_name, aud, azp) => {
      const token = await sign({ sub: 'u', aud, typ: 'ID', ...(azp === undefined ? {} : { azp }) })
      const refused = await refusal(idTokenValidator().validate(token))
      expect(refused).toBeInstanceOf(KeycloakTokenValidationError)
      expect(refused.message).toContain('azp')
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
      const make = (n: number) => access({ sub: 'u', aud: 'my-client', pad: 'a'.repeat(n) })
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
