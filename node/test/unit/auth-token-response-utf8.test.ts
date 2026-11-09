/**
 * 2xx 토큰 · introspection 응답의 본문은 UTF-8 이어야 한다(RFC 8259 §8.1) — 등록부 `token-response-class-divergent`
 * 판정 D1. 아니면 끝까지 왔지만 쓸 수 없는 응답이라 `KeycloakAuthError` 다.
 *
 * 수정 전(실측 2026-11-10 · main 219a4667): oauth4webapi 가 `response.json()` 으로 읽어(WHATWG `TextDecoder` 의 기본 —
 * 잘못된 바이트를 U+FFFD 로 바꾼다) 세 그랜트와 introspection 이 IdP 가 내지 않은 토큰 · 클레임을 **성공**으로 돌려줬다.
 *
 * 대조군: application/json 의 모르는 charset 은 받아들인다(RFC 8259 §11, 판정 D2). 오류 상태의 본문은 보지 않는다 —
 * 상태가 판정하고, 메시지는 UTF-8 을 탓하지 않는다.
 */
import { createServer, type Server } from 'node:http'
import type { AddressInfo } from 'node:net'
import { afterAll, beforeAll, describe, expect, it } from 'vitest'
import { KeycloakAuthError, KeycloakClient, KeycloakTransportError } from '../../src/index.js'

type Answer = { status: number; type: string; body: Buffer }

const json = 'application/json'
const GOOD_TOKEN = Buffer.from('{"access_token":"a","token_type":"Bearer","expires_in":60}')
const GOOD_INTROSPECTION = Buffer.from('{"active":true,"username":"svc"}')
// 문자열 안의 잘못된 UTF-8 — 바이트를 그대로 싣는다.
const bad = (head: string, tail: string): Buffer =>
  Buffer.concat([Buffer.from(head), Buffer.from([0xff, 0xfe]), Buffer.from(tail)])

let token: Answer = { status: 200, type: json, body: GOOD_TOKEN }
let introspection: Answer = { status: 200, type: json, body: GOOD_INTROSPECTION }
let server: Server
let origin = ''

beforeAll(async () => {
  server = createServer((req, res) => {
    req.on('end', () => {
      const path = new URL(req.url ?? '/', origin).pathname
      if (path.endsWith('/.well-known/openid-configuration')) {
        const issuer = `${origin}/realms/r`
        res.setHeader('content-type', json)
        res.end(
          JSON.stringify({
            issuer,
            token_endpoint: `${issuer}/protocol/openid-connect/token`,
            introspection_endpoint: `${issuer}/protocol/openid-connect/token/introspect`,
            jwks_uri: `${issuer}/protocol/openid-connect/certs`,
            response_types_supported: ['code'],
          }),
        )
        return
      }
      const answer = path.endsWith('/token/introspect') ? introspection : token
      res.statusCode = answer.status
      res.setHeader('content-type', answer.type)
      res.end(answer.body)
    })
    req.resume()
  })
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve))
  origin = `http://127.0.0.1:${(server.address() as AddressInfo).port}`
})

afterAll(async () => {
  await new Promise<void>((resolve) => server.close(() => resolve()))
})

async function outcome(
  run: (kc: KeycloakClient) => Promise<unknown>,
  answers: { token?: Answer; introspection?: Answer },
): Promise<unknown> {
  const kc = KeycloakClient.create({
    serverUrl: origin,
    realm: 'r',
    clientId: 'c',
    clientSecret: 's',
  })
  try {
    token = { status: 200, type: json, body: GOOD_TOKEN }
    introspection = { status: 200, type: json, body: GOOD_INTROSPECTION }
    await kc.auth.clientCredentialsToken() // discovery 를 먼저 끝낸다 — 재는 것은 그 뒤의 요청이다
    token = answers.token ?? token
    introspection = answers.introspection ?? introspection
    return await run(kc)
  } catch (e) {
    return e
  } finally {
    await kc.close()
  }
}

const GRANTS: Array<[string, (kc: KeycloakClient) => Promise<unknown>]> = [
  ['client credentials', (kc) => kc.auth.clientCredentialsToken()],
  ['refresh', (kc) => kc.auth.refresh('r')],
]

describe('2xx 토큰 응답이 UTF-8 이 아니면 KeycloakAuthError', () => {
  it.each(GRANTS)('%s — 토큰 안의 잘못된 바이트', async (_lane, run) => {
    const got = await outcome(run, {
      token: {
        status: 200,
        type: json,
        body: bad('{"access_token":"a', '","token_type":"Bearer","expires_in":60}'),
      },
    })
    expect(got).toBeInstanceOf(KeycloakAuthError)
    expect(got).not.toBeInstanceOf(KeycloakTransportError)
    expect((got as Error).message).toContain('token response is not valid UTF-8')
  })

  it.each(GRANTS)('%s — 토큰 밖의 잘못된 바이트', async (_lane, run) => {
    const got = await outcome(run, {
      token: {
        status: 200,
        type: json,
        body: bad('{"access_token":"a","token_type":"Bearer","expires_in":60,"x":"', '"}'),
      },
    })
    expect(got).toBeInstanceOf(KeycloakAuthError)
    expect((got as Error).message).toContain('token response is not valid UTF-8')
  })

  it.each(GRANTS)('%s — 모르는 charset 은 받아들인다(대조군)', async (_lane, run) => {
    const got = await outcome(run, {
      token: { status: 200, type: `${json}; charset=x-no-such-charset`, body: GOOD_TOKEN },
    })
    expect(got).not.toBeInstanceOf(Error)
  })

  it.each(GRANTS)('%s — 오류 상태의 본문은 상태가 판정한다(대조군)', async (_lane, run) => {
    const got = await outcome(run, {
      token: {
        status: 400,
        type: json,
        body: bad('{"error":"invalid_grant","error_description":"', '"}'),
      },
    })
    expect(got).toBeInstanceOf(KeycloakAuthError)
    expect((got as Error).message).not.toContain('UTF-8')
  })
})

describe('2xx introspection 응답이 UTF-8 이 아니면 KeycloakAuthError', () => {
  it('클레임 안의 잘못된 바이트', async () => {
    const got = await outcome((kc) => kc.auth.introspect('t'), {
      introspection: { status: 200, type: json, body: bad('{"active":true,"username":"s', 'vc"}') },
    })
    expect(got).toBeInstanceOf(KeycloakAuthError)
    expect((got as Error).message).toContain('introspection response is not valid UTF-8')
  })

  it('정상 응답(대조군)', async () => {
    const got = await outcome((kc) => kc.auth.introspect('t'), {})
    expect(got).toMatchObject({ active: true, username: 'svc' })
  })
})
