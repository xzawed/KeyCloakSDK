/**
 * `exchangeCode` 의 id_token **서명** 검증 — 실서버로는 만들 수 없는 거부 경로라 여기서 잰다.
 *
 * 위조 RS256 id_token(JWKS 의 `k1` 과 kid 만 같고 키는 다르다, nonce 는 맞다)은 Keycloak 이 발급할 수 없다.
 * 통합 테스트(`test/integration/code-exchange.it.test.ts`)의 서명 음성은 HS256 토큰뿐이라, RS256 에서만
 * 검증을 건너뛰는 구현은 거기서 초록이다(python 파일럿의 Grok 레그가 찾은 틈) — 그래서 이 파일이 따로 있다.
 *
 * ⚠️ `auth.test.ts` 는 openid-client 를 **목킹**한다 — 그 파일로는 서명도 nonce 도 실제로 검사되지 않는다.
 * 이 파일은 목 없이 진짜 openid-client 를 로컬 가짜 IdP(discovery·token·certs)에 붙인다.
 *
 * ⚠️ 이 파일이 처음 섰을 때 위조 토큰은 **수락됐다** — openid-client v6 는 토큰 엔드포인트가 준 id_token 의
 * 서명을 `enableNonRepudiationChecks` 없이는 보지 않는다(OIDC Core §3.1.3.7). `exchangeCode` 가 nonce 를 받으면
 * id_token 을 SDK `JwtValidator` 에 태워 고쳤다. 같은 가짜 IdP 로 도는 대조군 둘(정상 서명 수락 · nonce 불일치
 * 거부)이 이 파일의 거부가 설정 고장 때문이 아님을 보인다.
 */
import { createServer, type IncomingMessage, type ServerResponse } from 'node:http'
import type { AddressInfo } from 'node:net'
import { afterAll, beforeAll, describe, expect, it } from 'vitest'
import { exportJWK, generateKeyPair, SignJWT, type CryptoKey } from 'jose'
import { KeycloakAuthError, KeycloakClient } from '../../src/index.js'

const NONCE = 'server-nonce'
const CLIENT_ID = 'c'

interface Idp {
  readonly origin: string
  idToken: string
  /** `/certs` 요청 수 — JWKS 저장소가 하나인지 재는 계수기. */
  certsHits: number
  close(): Promise<void>
}

async function startIdp(jwks: unknown): Promise<Idp> {
  const json = (res: ServerResponse, body: unknown): void => {
    res.writeHead(200, { 'content-type': 'application/json' })
    res.end(JSON.stringify(body))
  }
  const route = (req: IncomingMessage, res: ServerResponse): void => {
    const issuer = `${idp.origin}/realms/r`
    const base = `${issuer}/protocol/openid-connect`
    const path = new URL(req.url ?? '/', idp.origin).pathname
    if (path === '/realms/r/.well-known/openid-configuration') {
      return json(res, {
        issuer,
        authorization_endpoint: `${base}/auth`,
        token_endpoint: `${base}/token`,
        jwks_uri: `${base}/certs`,
        response_types_supported: ['code'],
        id_token_signing_alg_values_supported: ['RS256'],
      })
    }
    if (path === '/realms/r/protocol/openid-connect/token') {
      return json(res, {
        access_token: 'access',
        token_type: 'Bearer',
        expires_in: 300,
        refresh_token: 'refresh',
        ...(idp.idToken === '' ? {} : { id_token: idp.idToken }),
      })
    }
    if (path === '/realms/r/protocol/openid-connect/certs') {
      idp.certsHits += 1
      return json(res, jwks)
    }
    res.writeHead(404).end()
  }
  const server = createServer((req, res) => {
    req.on('end', () => route(req, res))
    req.resume()
  })
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve))
  const idp: Idp = {
    origin: `http://127.0.0.1:${(server.address() as AddressInfo).port}`,
    idToken: '',
    certsHits: 0,
    close: () =>
      new Promise<void>((resolve) => {
        server.closeAllConnections()
        server.close(() => resolve())
      }),
  }
  return idp
}

let idp: Idp
let signed: CryptoKey
let forger: CryptoKey

beforeAll(async () => {
  const published = await generateKeyPair('RS256')
  signed = published.privateKey
  forger = (await generateKeyPair('RS256')).privateKey
  const jwk = { ...(await exportJWK(published.publicKey)), kid: 'k1', alg: 'RS256', use: 'sig' }
  idp = await startIdp({ keys: [jwk] })
})

afterAll(async () => {
  await idp.close()
})

/** JWKS 의 `k1` 로 보이는 RS256 id_token — `key` 가 실제 서명 키다. */
function idToken(
  key: CryptoKey,
  nonce: string,
  audience: string | string[] = CLIENT_ID,
): Promise<string> {
  return new SignJWT({ nonce })
    .setProtectedHeader({ alg: 'RS256', kid: 'k1', typ: 'JWT' })
    .setIssuer(`${idp.origin}/realms/r`)
    .setSubject('u1')
    .setAudience(audience)
    .setIssuedAt()
    .setExpirationTime('1m')
    .sign(key)
}

/** JWKS 의 `k1` 로 서명한 액세스 토큰 — `validate` 가 재정의 audience 로 잰다. */
function accessToken(audience: string): Promise<string> {
  return new SignJWT({})
    .setProtectedHeader({ alg: 'RS256', kid: 'k1', typ: 'JWT' })
    .setIssuer(`${idp.origin}/realms/r`)
    .setSubject('u1')
    .setAudience(audience)
    .setIssuedAt()
    .setExpirationTime('1m')
    .sign(signed)
}

/** 클라이언트마다 JWKS 저장소가 새로 선다(`AuthClient` 생성자). */
function client(expectedAudience?: string): KeycloakClient {
  return KeycloakClient.create({
    serverUrl: idp.origin,
    realm: 'r',
    clientId: CLIENT_ID,
    clientSecret: 's',
    ...(expectedAudience === undefined ? {} : { expectedAudience }),
  })
}

function exchange(kc: KeycloakClient = client()): Promise<unknown> {
  return kc.auth.exchangeCode('code', 'https://app.example/cb', 'verifier', NONCE)
}

async function refusal(call: Promise<unknown>): Promise<Error> {
  const outcome = await call.then(
    () => undefined,
    (e: unknown) => e,
  )
  if (!(outcome instanceof Error)) throw new Error('expected a refusal, got success')
  return outcome
}

function innermost(error: Error): Error {
  let link = error
  while (link.cause instanceof Error) link = link.cause
  return link
}

describe('exchangeCode — 진짜 openid-client 로 id_token 을 잰다', () => {
  it('대조군: JWKS 키로 서명되고 nonce 가 맞는 id_token 은 수락한다', async () => {
    idp.idToken = await idToken(signed, NONCE)
    await expect(exchange()).resolves.toMatchObject({ idToken: idp.idToken })
  })

  it('대조군: nonce 가 틀리면 거부한다(이 설정에서 검사가 실제로 돈다)', async () => {
    idp.idToken = await idToken(signed, `x${NONCE}`)
    const refused = await refusal(exchange())
    expect(refused).toBeInstanceOf(KeycloakAuthError)
    expect(innermost(refused).message).toBe('unexpected ID Token "nonce" claim value')
  })

  it('JWKS 밖 키로 서명된 RS256 id_token 은 nonce 가 맞아도 SDK 검증기에서 거부한다', async () => {
    idp.idToken = await idToken(forger, NONCE)
    const refused = await refusal(exchange())
    expect(refused).toBeInstanceOf(KeycloakAuthError)
    expect(refused.message).toBe('Authorization code exchange failed: invalid id_token')
  })

  it('nonce 를 기대하는데 id_token 이 없으면 거부한다(fail-closed)', async () => {
    idp.idToken = ''
    const refused = await refusal(exchange())
    expect(refused).toBeInstanceOf(KeycloakAuthError)
  })
})

/**
 * `expectedAudience` 재정의 — id_token `aud` 는 clientId 로 검사한다(OIDC Core §2·§3.1.3.7). 재정의는 액세스
 * 토큰의 리소스 서버 제한이다.
 *
 * ⚠️ 거부 사유의 **문구는 고정하지 않는다.** 진짜 openid-client(oauth4webapi)는 aud 에 client_id 가 없는
 * id_token 을 SDK 검증기보다 **먼저** 자기 문구로 거부한다 — 그 층의 거부는 `auth.test.ts`(목) 가 SDK 층만
 * 따로 잰다. 여기서 보는 것은 거부 여부와 SDK 오류 타입이다.
 */
describe('exchangeCode — expectedAudience 재정의(진짜 openid-client)', () => {
  const API = 'some-api'

  it('(A1) 재정의해도 aud=clientId 인 id_token 의 교환은 통과한다', async () => {
    idp.idToken = await idToken(signed, NONCE)
    await expect(exchange(client(API))).resolves.toMatchObject({ idToken: idp.idToken })
  })

  it('(A2) aud 에 clientId 가 없는 id_token 은 거부한다 — aud 가 재정의 값과 같아도', async () => {
    idp.idToken = await idToken(signed, NONCE, API)
    expect(await refusal(exchange(client(API)))).toBeInstanceOf(KeycloakAuthError)
  })

  it('(A4) 재정의 아래에서도 nonce 불일치와 JWKS 밖 서명은 거부한다', async () => {
    idp.idToken = await idToken(signed, `x${NONCE}`)
    const badNonce = await refusal(exchange(client(API)))
    expect(badNonce).toBeInstanceOf(KeycloakAuthError)
    expect(innermost(badNonce).message).toBe('unexpected ID Token "nonce" claim value')

    idp.idToken = await idToken(forger, NONCE)
    const forged = await refusal(exchange(client(API)))
    expect(forged).toBeInstanceOf(KeycloakAuthError)
    expect(forged.message).toBe('Authorization code exchange failed: invalid id_token')
  })

  it('(A3·A5) 교환 뒤 액세스 토큰 validate 는 재정의를 쓰고, JWKS 조회를 늘리지 않는다', async () => {
    idp.idToken = await idToken(signed, NONCE)
    const kc = client(API)
    idp.certsHits = 0
    await exchange(kc)
    expect(idp.certsHits).toBe(1) // 콜드 캐시를 채운 한 번
    await expect(kc.auth.validate(await accessToken(API))).resolves.toMatchObject({
      audience: [API],
    })
    await expect(kc.auth.validate(await accessToken(CLIENT_ID))).rejects.toThrow()
    await exchange(kc)
    // id_token 검증기와 액세스 토큰 검증기가 한 저장소를 쓴다 — 둘째 저장소면 여기가 2 다.
    expect(idp.certsHits).toBe(1)
  })

  it('대조군: 저장소가 둘이면 이 계수기가 그것을 본다(2)', async () => {
    // 위 단언이 공허하지 않다는 증거 — 교환과 validate 가 서로 다른 저장소를 쓰면 /certs 가 두 번 불린다.
    idp.idToken = await idToken(signed, NONCE)
    const exchanger = client(API)
    const validator = client(API)
    idp.certsHits = 0
    await exchange(exchanger)
    await validator.auth.validate(await accessToken(API))
    expect(idp.certsHits).toBe(2)
  })
})
