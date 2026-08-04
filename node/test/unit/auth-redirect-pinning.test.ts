/**
 * WBS(2026-07-31 감사) "추가 태스크 — 이미 안전한 경로에 고정(pinning) 테스트" 중 Node
 * `openid-client` 몫이다.
 *
 * 왜 필요한가: 토큰 그랜트는 SDK가 직접 보내지 않는다 — `openid-client`가 보내고, **리다이렉트를
 * 끌 노브가 우리에게 없다**. 그런데 이 경로가 자격증명을 싣는다(`client_secret`이 POST 바디에
 * 있다). 자매 언어에서 실측된 실패 모드가 정확히 이것이다 — Python(requests)·PHP(Guzzle)는
 * 307/308에서 **바디를 보존한 채** 재전송해서 공격자가 고른 경로로 client_secret이 흘렀다
 * (requests의 `rebuild_auth`는 `Authorization` 헤더만 떼어내지 바디는 손대지 않는다).
 *
 * 실측(openid-client 6.8.4): 3xx를 따라가지 않고 `ClientError: unexpected HTTP response status
 * code`로 거부한다. 라이브러리 기본값이 안전하다는 뜻이지만 그건 **우리가 통제하지 않는 성질**이라
 * 상위 버전에서 조용히 바뀔 수 있다 — 그때 이 테스트가 유일한 경보다.
 *
 * ⚠️ 이 파일은 `openid-client`를 **목킹하지 않는다**(auth.test.ts는 목킹한다 — 그쪽은 매핑·예외
 * 변환을 격리 검증하는 것이 목적이라 실제 HTTP 거동을 볼 수 없다). vitest 목은 파일 단위라
 * 별도 파일로 두어야 실제 모듈이 로드된다.
 */
import { describe, it, expect } from 'vitest'
import { createServer, type Server } from 'node:http'
import type { AddressInfo } from 'node:net'
import { AuthClient } from '../../src/auth.js'
import { defineConfig } from '../../src/config.js'

const REALM = 'it'

/** 유효한 discovery 메타데이터를 내주되 토큰 엔드포인트만 302로 돌려보내는 서버. */
function startTrapServer(): Promise<{ server: Server; port: number; paths: string[] }> {
  const paths: string[] = []
  let port = 0
  const server = createServer((req, res) => {
    paths.push(req.url ?? '')
    const origin = `http://127.0.0.1:${port}`
    if (req.url === `/realms/${REALM}/.well-known/openid-configuration`) {
      res.writeHead(200, { 'content-type': 'application/json' })
      res.end(
        JSON.stringify({
          issuer: `${origin}/realms/${REALM}`,
          token_endpoint: `${origin}/realms/${REALM}/protocol/openid-connect/token`,
          authorization_endpoint: `${origin}/realms/${REALM}/protocol/openid-connect/auth`,
          jwks_uri: `${origin}/realms/${REALM}/protocol/openid-connect/certs`,
          introspection_endpoint: `${origin}/realms/${REALM}/protocol/openid-connect/token/introspect`,
          response_types_supported: ['code'],
          grant_types_supported: ['client_credentials', 'authorization_code', 'refresh_token'],
        }),
      )
      return
    }
    if (req.url === `/realms/${REALM}/protocol/openid-connect/token`) {
      res.writeHead(302, { location: `${origin}/moved-token` })
      res.end()
      return
    }
    // 따라갔다면 여기 도달한다 — **성공 응답**을 내줘서 최악의 시나리오(공격자가 고른 경로가
    // 자격증명을 받고, 그 응답이 유효한 토큰으로 받아들여진다)를 그대로 재현한다.
    if (req.url === '/moved-token') {
      res.writeHead(200, { 'content-type': 'application/json' })
      res.end(
        JSON.stringify({
          access_token: 'attacker-controlled',
          token_type: 'Bearer',
          expires_in: 300,
        }),
      )
      return
    }
    res.writeHead(404)
    res.end()
  })
  return new Promise((resolve) => {
    server.listen(0, '127.0.0.1', () => {
      port = (server.address() as AddressInfo).port
      resolve({ server, port, paths })
    })
  })
}

describe('SSRF 고정 — openid-client 기본값이 유일한 방어라 버전 상향을 잠근다', () => {
  it('토큰 엔드포인트의 302를 따라가지 않는다(client_secret이 실린 POST다)', async () => {
    const { server, port, paths } = await startTrapServer()
    try {
      const auth = new AuthClient(
        defineConfig({
          serverUrl: `http://127.0.0.1:${port}`,
          realm: REALM,
          clientId: 'app',
          clientSecret: 'sekret',
        }),
      )

      // 302를 성공으로 오인하면 여기서 'attacker-controlled' 토큰이 반환된다.
      await expect(auth.clientCredentialsToken()).rejects.toThrow()

      // ⚠️ 비공허성 단언 — 이게 없으면 discovery 단계에서 먼저 죽어도 아래 not.toContain이
      // 통과해버려, 실제로는 토큰 요청이 일어난 적조차 없는데 "리다이렉트를 안 따라갔다"고
      // 보고하게 된다. 흐름이 진짜 토큰 엔드포인트까지 갔음을 먼저 못박는다.
      expect(paths).toContain(`/realms/${REALM}/.well-known/openid-configuration`)
      expect(paths).toContain(`/realms/${REALM}/protocol/openid-connect/token`)
      expect(paths).not.toContain('/moved-token')

      // ⚠️ 대조군을 지우지 말 것. 이 하드닝은 openid-client 내부 동작이라 우리가 끌 수 없어
      // "방어를 제거하면 실패하는가"를 변이로 확인할 수단이 없다. 대신 **추종하는 클라이언트는
      // 실제로 /moved-token에 도달함**을 같은 서버로 보여, 위 단언이 프로브 고장(경로 미기록)에
      // 의한 공허한 통과가 아님을 증명한다.
      paths.length = 0
      await fetch(`http://127.0.0.1:${port}/realms/${REALM}/protocol/openid-connect/token`, {
        method: 'POST',
        body: new URLSearchParams({ grant_type: 'client_credentials' }),
      })
      expect(paths).toContain('/moved-token')
    } finally {
      await new Promise<void>((resolve) => server.close(() => resolve()))
    }
  })
})
