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
 * ⚠️ **알려진 결함(KNOWN DEFECT)**: node 의 `exchangeCode` 는 id_token 서명을 검증하지 않는다 — openid-client v6
 * 는 토큰 엔드포인트가 준 id_token 의 서명을 `enableNonRepudiationChecks` 없이는 보지 않고, SDK 는 그것도
 * 자신의 `JwtValidator` 도 부르지 않는다. 그래서 위조 토큰 케이스는 `it.fails` 다 — 고쳐져 거부가 일어나면
 * 빨개지고, 그때 `.fails` 를 지운다. 같은 가짜 IdP 로 도는 대조군 둘(정상 서명 수락 · nonce 불일치 거부)이
 * 그 `it.fails` 가 설정 고장으로 초록이 되는 것을 막는다.
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
        id_token: idp.idToken,
      })
    }
    if (path === '/realms/r/protocol/openid-connect/certs') return json(res, jwks)
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
function idToken(key: CryptoKey, nonce: string): Promise<string> {
  return new SignJWT({ nonce })
    .setProtectedHeader({ alg: 'RS256', kid: 'k1', typ: 'JWT' })
    .setIssuer(`${idp.origin}/realms/r`)
    .setSubject('u1')
    .setAudience(CLIENT_ID)
    .setIssuedAt()
    .setExpirationTime('1m')
    .sign(key)
}

function exchange(): Promise<unknown> {
  const kc = KeycloakClient.create({
    serverUrl: idp.origin,
    realm: 'r',
    clientId: CLIENT_ID,
    clientSecret: 's',
  })
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

/**
 * 수락됐는가 — `it.fails` 몸통은 **수락될 때만** 실패해야 한다. 거부 사유를 단언하면 전송 오류 같은 엉뚱한
 * 거부가 그 단언을 깨뜨려 `it.fails` 가 초록이 된다(Grok 레그 주장 2 — 죽은 포트로 실측).
 */
function accepted(call: Promise<unknown>): Promise<boolean> {
  return call.then(
    () => true,
    () => false,
  )
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

  it.fails(
    'KNOWN DEFECT: JWKS 밖 키로 서명된 RS256 id_token 은 nonce 가 맞아도 거부한다(현재는 수락)',
    async () => {
      idp.idToken = await idToken(forger, NONCE)
      expect(await accepted(exchange())).toBe(false)
    },
  )
})
