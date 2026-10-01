import { createServer, type Server } from 'node:http'
import type { AddressInfo } from 'node:net'
import { inspect } from 'node:util'
import { afterAll, beforeAll, describe, expect, it } from 'vitest'
import { KeycloakAuthError, KeycloakClient } from '../../src/index.js'
import { MALFORMED_TOKEN_RESPONSES } from './token-responses.js'

// ⚠️ 형식이 틀린 토큰 응답에서 난 오류가 **응답의 토큰을 찍지 않는다** — oauth4webapi 는 그 응답 본문 전체나
// 원문 id_token 을 `cause` 에 싣는다. 실측(2026-09-26, 수정 전): id_token 이 JWT 가 아니면 `console.log(err)`
// 기본 깊이에서 원문 id_token 이, access_token·expires_in·token_type 이 틀리면 깊은 직렬화에서 살아 있는
// access/refresh 토큰이 찍혔다. 정화는 `KeycloakError` 생성자 한 곳이다(`errors.test.ts`).
// 변형 표는 `token-responses.ts` 에 있다 — 적대 경로 행렬이 같은 표를 계급 전체에 붙인다.
const VARIANTS = MALFORMED_TOKEN_RESPONSES

describe('형식이 틀린 토큰 응답의 오류', () => {
  let server: Server
  let origin = ''
  let body: Record<string, unknown> | string = {}

  beforeAll(async () => {
    server = createServer((req, res) => {
      req.on('end', () => {
        const path = new URL(req.url ?? '/', origin).pathname
        res.setHeader('content-type', 'application/json')
        if (path.endsWith('/.well-known/openid-configuration')) {
          const issuer = `${origin}/realms/r`
          res.end(
            JSON.stringify({
              issuer,
              token_endpoint: `${issuer}/protocol/openid-connect/token`,
              jwks_uri: `${issuer}/protocol/openid-connect/certs`,
              response_types_supported: ['code'],
            }),
          )
        } else if (path.endsWith('/token')) {
          res.end(typeof body === 'string' ? body : JSON.stringify(body))
        } else {
          res.statusCode = 404
          res.end('{}')
        }
      })
      req.resume()
    })
    await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve))
    origin = `http://127.0.0.1:${(server.address() as AddressInfo).port}`
  })

  afterAll(() => {
    server.closeAllConnections()
    server.close()
  })

  it.each(Object.entries(VARIANTS))(
    '%s — 기본·깊은 inspect 어디에도 토큰이 없다',
    async (_name, variant) => {
      body = variant
      const kc = await KeycloakClient.create({
        serverUrl: origin,
        realm: 'r',
        clientId: 'c',
        clientSecret: 'S',
      })
      const err = await kc.auth.clientCredentialsToken().then(
        () => undefined,
        (e: unknown) => e,
      )
      // 대조군 — 정말 실패했는가. 성공했다면 아래 단언은 없는 것을 찾으며 통과한다.
      expect(err).toBeInstanceOf(KeycloakAuthError)
      const values = typeof variant === 'string' ? [variant] : Object.values(variant)
      const leaks = values.filter((v): v is string => typeof v === 'string' && v.startsWith('LEAK'))
      expect(leaks.length).toBeGreaterThan(0)
      for (const out of [inspect(err), inspect(err, { depth: Infinity })]) {
        for (const leak of leaks) expect(out).not.toContain(leak)
      }
    },
  )
})
