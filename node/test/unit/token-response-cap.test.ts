/**
 * 토큰·introspection 응답 본문 상한 — 등록부 `token-response-size-unbounded`. 진짜 openid-client·admin-client 를
 * 프로세스 안 가짜 IdP(`fake-idp.ts`)에 붙여 공개 API 로 잰다.
 *
 * 상한 전(실측 2026-10-05 · 6f23931): 쓸 수 있는 토큰 뒤에 JSON 공백 32 MiB 를 붙인 응답을 다섯 레인 —
 * client credentials · refresh · 코드 교환 · admin 의 자기 토큰 부여 · introspection — 이 전부 받아들였고
 * 프로세스 피크가 호출 하나에 +100~123 MB 늘었다(gzip 33 KB 도 같았다).
 *
 * 계약: 본문이 1,048,576 바이트(푼 뒤) 이하면 지금과 똑같고, 1,048,577 바이트 이상이면 그 호출의 기존 SDK 오류
 * (`KeycloakAuthError`)로 실패하며 메시지가 정확하다. admin 은 admin 요청을 보내지 않는다. Keycloak 26.6 이 기본
 * 설정으로 받아들이는 가장 긴 Bearer(65,459 바이트)는 모든 레인에서 통과한다.
 */
import type { ReadableStreamReadResult } from 'node:stream/web'
import { afterAll, afterEach, beforeAll, describe, expect, it, vi } from 'vitest'
import { exportJWK, generateKeyPair, SignJWT, type CryptoKey } from 'jose'
import { KeycloakAuthError, KeycloakClient } from '../../src/index.js'
import {
  discoveryDocument,
  startFakeIdp,
  tokenResponse,
  type FakeIdp,
  type Transfer,
} from './fake-idp.js'

/**
 * 상한 — 소스 상수와 **따로** 적는다. 경계 시험이 상수를 읽으면 상수가 바뀔 때 시험도 함께 움직여 아무것도 잡지
 * 못한다(.NET `TokenResponseCapTests` 와 같은 이유). 상수 값 자체는 `token-response-cap-reader.test.ts` 가 잰다.
 */
const CAP = 1_048_576
/** Keycloak 26.6 이 기본 설정으로 받아들이는 가장 긴 Bearer(실측 2026-10-03, 등록부). */
const KEYCLOAK_MAX_BEARER = 65_459
const NONCE = 'cap-nonce'
const MIB = 1_048_576

let idp: FakeIdp
let signingKey: CryptoKey

beforeAll(async () => {
  idp = await startFakeIdp()
  const pair = await generateKeyPair('RS256')
  signingKey = pair.privateKey
  idp.setJwks({
    keys: [{ ...(await exportJWK(pair.publicKey)), kid: 'k1', alg: 'RS256', use: 'sig' }],
  })
})

afterAll(async () => {
  await idp.close()
})

afterEach(() => {
  vi.restoreAllMocks()
  idp.discovery = undefined
  idp.token = { head: tokenResponse('access') }
  idp.introspect = {
    head: JSON.stringify({ active: true, sub: 'u1', client_id: 'c', username: 'u1' }),
  }
})

function client(): KeycloakClient {
  return KeycloakClient.create({
    serverUrl: idp.origin,
    realm: 'r',
    clientId: 'c',
    clientSecret: 's',
  })
}

function idToken(): Promise<string> {
  return new SignJWT({ nonce: NONCE })
    .setProtectedHeader({ alg: 'RS256', kid: 'k1', typ: 'JWT' })
    .setIssuer(idp.issuer)
    .setSubject('u1')
    .setAudience('c')
    .setIssuedAt()
    .setExpirationTime('5m')
    .sign(signingKey)
}

/** JWT 모양(base64url 세 마디)의 액세스 토큰 — 정확히 `length` 문자. 헤더에 실을 수 있다. */
function bearerOf(length: number): string {
  const signature = 's'.repeat(342)
  const header = 'eyJhbGciOiJSUzI1NiJ9'
  return `${header}.${'p'.repeat(length - header.length - signature.length - 2)}.${signature}`
}

interface Lane {
  /** 실패 메시지의 앞부분 — `${prefix}: response body exceeds 1048576 bytes`. */
  readonly prefix: string
  /** admin 레인이면 실패할 때 admin 요청이 하나도 나가지 않았는지도 본다. */
  readonly admin?: boolean
  /** 이 레인이 읽는 응답에 `total` 바이트 본문을 건다. `accessToken` 은 그 응답이 실을(또는 레인이 보낼) 토큰. */
  arm(accessToken: string, total: number | undefined, transfer: Transfer): Promise<void>
  /** 레인을 부른다. 성공하면 레인이 본 액세스 토큰의 길이를 돌려준다(admin 은 서버가 받은 Bearer 의 길이). */
  run(kc: KeycloakClient, accessToken: string): Promise<number>
}

const tokenLane = (
  prefix: string,
  run: Lane['run'],
  options: { withIdToken?: boolean; admin?: boolean } = {},
): Lane => ({
  prefix,
  admin: options.admin,
  async arm(accessToken, total, transfer) {
    const withIdToken = options.withIdToken === true
    const extra = withIdToken ? { id_token: await idToken() } : {}
    idp.token = { head: tokenResponse(accessToken, extra), total, transfer }
  },
  run,
})

const LANES: Readonly<Record<string, Lane>> = {
  'client credentials': tokenLane(
    'Client credentials grant failed',
    async (kc) => (await kc.auth.clientCredentialsToken()).accessToken.length,
  ),
  refresh: tokenLane(
    'Token refresh failed',
    async (kc) => (await kc.auth.refresh('refresh')).accessToken.length,
  ),
  'code exchange (nonce — id_token 검증까지)': tokenLane(
    'Authorization code exchange failed',
    async (kc) =>
      (await kc.auth.exchangeCode('code', 'https://app.example/cb', 'verifier', NONCE)).accessToken
        .length,
    { withIdToken: true },
  ),
  'admin 의 자기 토큰 부여': tokenLane(
    'Client credentials grant failed',
    async (kc) => {
      const before = idp.counts.admin
      await (await kc.admin()).realms.list()
      expect(idp.counts.admin).toBe(before + 1)
      return (idp.last.adminAuthorization ?? '').length - 'Bearer '.length
    },
    { admin: true },
  ),
  introspection: {
    prefix: 'Token introspection failed',
    async arm(_accessToken, total, transfer) {
      idp.introspect = {
        head: JSON.stringify({ active: true, sub: 'u1', client_id: 'c', username: 'u1' }),
        total,
        transfer,
      }
    },
    async run(kc, accessToken) {
      const result = await kc.auth.introspect(accessToken)
      expect(result.active).toBe(true)
      return (idp.last.introspectToken ?? '').length
    },
  },
}

const EXCEEDS = `response body exceeds ${CAP} bytes`

async function refusal(call: Promise<unknown>): Promise<Error> {
  const outcome = await call.then(
    () => undefined,
    (e: unknown) => e,
  )
  if (!(outcome instanceof Error)) throw new Error('expected a refusal, got success')
  return outcome
}

describe.each(Object.entries(LANES))('%s', (_name, lane) => {
  it.each<Transfer>(['chunked', 'cl'])(
    '대조군: Keycloak 26.6 의 가장 긴 기본 Bearer(65,459 바이트)가 통과한다 (%s)',
    async (transfer) => {
      const token = bearerOf(KEYCLOAK_MAX_BEARER)
      await lane.arm(token, undefined, transfer)
      expect(await lane.run(client(), token)).toBe(KEYCLOAK_MAX_BEARER)
    },
  )

  it.each<Transfer>(['chunked', 'cl', 'gzip'])(
    '정확히 1,048,576 바이트(푼 뒤) 본문은 지금처럼 통과한다 (%s)',
    async (transfer) => {
      const token = bearerOf(KEYCLOAK_MAX_BEARER)
      await lane.arm(token, CAP, transfer)
      expect(await lane.run(client(), token)).toBe(KEYCLOAK_MAX_BEARER)
    },
  )

  it.each<Transfer>(['chunked', 'cl', 'gzip'])(
    '1,048,577 바이트(푼 뒤) 본문은 KeycloakAuthError 로 실패한다 — 메시지가 정확하다 (%s)',
    async (transfer) => {
      const token = bearerOf(KEYCLOAK_MAX_BEARER)
      await lane.arm(token, CAP + 1, transfer)
      const adminBefore = idp.counts.admin
      const refused = await refusal(lane.run(client(), token))
      expect(refused).toBeInstanceOf(KeycloakAuthError)
      expect(refused.message).toBe(`${lane.prefix}: ${EXCEEDS}`)
      if (lane.admin === true) expect(idp.counts.admin).toBe(adminBefore) // admin 요청은 나가지 않는다
    },
  )

  /**
   * ⚠️ 거부만으로는 「통째로 읽지 않았다」의 증거가 못 된다 — 다 읽고 나서 길이를 재도 거부는 참이다. 둘을 잰다:
   * SDK 가 스트림에서 **청한** 바이트(BYOB 읽기의 view 길이 합)가 cap+1 을 넘지 않고, 서버가 실제로 써 보낸
   * 바이트가 본문 크기보다 훨씬 작다(읽기가 끊겨 전송도 멈췄다).
   */
  it.each([
    [16 * MIB, 'chunked'],
    [32 * MIB, 'chunked'],
    [32 * MIB, 'cl'],
  ] as const)('%d 바이트 본문(%s)은 실패하고 할당이 상한에 묶인다', async (size, transfer) => {
    const token = bearerOf(KEYCLOAK_MAX_BEARER)
    await lane.arm(token, size, transfer)
    // 응답(리더)마다: 받은 바이트와, 청할 때마다 「받은 것 + 이번에 청한 길이」의 최댓값(청한 범위의 끝).
    // discovery 도 같은 길로 읽히므로 리더별로 센다.
    const perReader = new Map<object, { received: number; furthestRequested: number }>()
    const read = ReadableStreamBYOBReader.prototype.read
    vi.spyOn(ReadableStreamBYOBReader.prototype, 'read').mockImplementation(function (
      this: ReadableStreamBYOBReader,
      view: ArrayBufferView,
      ...rest: unknown[]
    ) {
      const seen = perReader.get(this) ?? { received: 0, furthestRequested: 0 }
      perReader.set(this, seen)
      seen.furthestRequested = Math.max(seen.furthestRequested, seen.received + view.byteLength)
      const pending = (
        read as (...a: unknown[]) => Promise<ReadableStreamReadResult<Uint8Array>>
      ).call(this, view, ...rest)
      return pending.then((result) => {
        seen.received += result.value?.byteLength ?? 0
        return result
      })
    } as never)
    const refused = await refusal(lane.run(client(), token))
    expect(refused).toBeInstanceOf(KeycloakAuthError)
    expect(refused.message).toBe(`${lane.prefix}: ${EXCEEDS}`)
    const readers = [...perReader.values()]
    // 판정한 응답은 정확히 cap+1 바이트를 받고 멈췄다 — 그 이상은 청하지도 않았다.
    expect(Math.max(...readers.map((r) => r.received))).toBe(CAP + 1)
    for (const r of readers) expect(r.furthestRequested).toBeLessThanOrEqual(CAP + 1)
    expect(idp.bytesWritten).toBeLessThan(size / 2) // 전송도 본문을 끝까지 보내지 않았다
  })
})

describe('원인 사슬', () => {
  /**
   * 디버깅에는 신호의 이름·메시지가 남고, 신호 **인스턴스**는 공개 API 로 나오지 않는다 — `KeycloakError` 생성자가
   * cause 를 평범한 `Error` 사본으로 바꾼다. `facade-dump.test.ts` 가 `ResponseTooLargeError` 를 면제하는 근거다.
   */
  it('사슬에 신호의 이름과 메시지는 있고 인스턴스는 없다', async () => {
    idp.token = { head: tokenResponse('access'), total: CAP + 1, transfer: 'chunked' }
    const refused = await refusal(client().auth.clientCredentialsToken())
    const chain: Error[] = []
    for (let link = refused.cause; link instanceof Error; link = link.cause) chain.push(link)
    expect(chain.map((e) => `${e.name}: ${e.message}`)).toContain(
      `ResponseTooLargeError: ${EXCEEDS}`,
    )
    expect(chain.some((e) => e.constructor.name === 'ResponseTooLargeError')).toBe(false)
  })
})

describe('admin — 만료 뒤 다시 받는 토큰도 상한 안에서 판정한다', () => {
  it('재발급 응답이 상한을 넘으면 admin 요청 없이 KeycloakAuthError', async () => {
    // expires_in 이 skew(30 초) 이하면 provider 캐시는 곧바로 만료다 — 다음 admin 호출이 토큰을 다시 받는다.
    idp.token = {
      head: JSON.stringify({ access_token: 'first', token_type: 'Bearer', expires_in: 10 }),
    }
    const admin = await client().admin()
    idp.token = {
      head: tokenResponse(bearerOf(KEYCLOAK_MAX_BEARER)),
      total: CAP + 1,
      transfer: 'chunked',
    }
    const before = idp.counts.admin
    const refused = await refusal(admin.realms.list())
    expect(refused).toBeInstanceOf(KeycloakAuthError)
    expect(refused.message).toBe(`Client credentials grant failed: ${EXCEEDS}`)
    expect(idp.counts.admin).toBe(before)
  })
})

/**
 * discovery 도 같은 이음매(`discovery` 옵션의 `[customFetch]`)를 지나므로 같은 상수를 쓴다. 판정: JWKS 상한
 * (51,200)은 JWKS 문서용 Nimbus 값이고 discovery 에 대한 외부 근거가 없다 — realm 의 client scope 가 늘면
 * `scopes_supported` 가 함께 자라는데, discovery 거부는 그 realm 의 모든 auth 호출을 막는다. 1 MiB 는 메모리를
 * 묶는 데 충분하다.
 */
describe('discovery 응답', () => {
  it('정확히 1,048,576 바이트는 통과하고 1,048,577 바이트는 정확한 메시지로 실패한다', async () => {
    const head = JSON.stringify(discoveryDocument(idp.issuer))
    idp.discovery = { head, total: CAP, transfer: 'chunked' }
    await expect(client().auth.clientCredentialsToken()).resolves.toMatchObject({
      accessToken: 'access',
    })
    idp.discovery = { head, total: CAP + 1, transfer: 'chunked' }
    const refused = await refusal(client().auth.clientCredentialsToken())
    expect(refused).toBeInstanceOf(KeycloakAuthError)
    expect(refused.message).toBe(`OIDC discovery failed: ${EXCEEDS}`)
  })
})
