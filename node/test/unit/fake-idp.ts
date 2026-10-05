/**
 * 진짜 openid-client·admin-client 를 붙이는 프로세스 안 가짜 Keycloak realm — discovery·token·introspect·certs·admin.
 * 응답 본문은 **정확한 바이트 수**로 덧댈 수 있다(`head` 뒤에 JSON 공백을 붙여 `total` 바이트를 만든다 — 공백은
 * JSON 값 뒤에 와도 유효하므로 덧댄 본문도 쓸 수 있는 응답이다). 전송은 청크·`Content-Length`·gzip 셋이다.
 *
 * ⚠️ 이 파일은 `*.test.ts` 가 아니다 — 테스트 파일을 import 하면 그 파일의 describe 가 가져온 쪽에서도 등록된다
 * (`token-responses.ts` 와 같은 이유).
 */
import { createServer, type IncomingMessage, type ServerResponse } from 'node:http'
import type { AddressInfo } from 'node:net'
import { gzipSync } from 'node:zlib'

export type Transfer = 'chunked' | 'cl' | 'gzip'

/** 한 엔드포인트가 다음에 돌려줄 응답. `total` 이 있으면 본문은 정확히 그 바이트 수다. */
export interface BodyPlan {
  readonly status?: number
  readonly head: string
  readonly total?: number
  readonly transfer?: Transfer
}

export interface FakeIdp {
  readonly origin: string
  readonly issuer: string
  token: BodyPlan
  introspect: BodyPlan
  /** `undefined` 면 기본 discovery 문서. */
  discovery: BodyPlan | undefined
  admin: BodyPlan
  readonly counts: {
    discovery: number
    token: number
    introspect: number
    admin: number
    certs: number
  }
  /** 마지막으로 받은 값 — admin 의 Authorization 헤더, introspect 의 `token`, 토큰 요청의 `refresh_token`. */
  readonly last: { adminAuthorization?: string; introspectToken?: string; refreshToken?: string }
  /** 마지막으로 보낸 덧댄 본문에서 서버가 실제로 써 보낸 바이트 — 읽기가 끊겼는지를 가른다. */
  bytesWritten: number
  setJwks(jwks: unknown): void
  close(): Promise<void>
}

const PUMP_CHUNK = 65_536

function readForm(req: IncomingMessage): Promise<URLSearchParams> {
  return new Promise((resolve) => {
    const parts: Buffer[] = []
    req.on('data', (d: Buffer) => parts.push(d))
    req.on('end', () => resolve(new URLSearchParams(Buffer.concat(parts).toString('utf8'))))
    req.on('error', () => resolve(new URLSearchParams()))
  })
}

export async function startFakeIdp(): Promise<FakeIdp> {
  let jwks: unknown = { keys: [] }

  const send = (res: ServerResponse, plan: BodyPlan): void => {
    const status = plan.status ?? 200
    const head = Buffer.from(plan.head, 'utf8')
    const total = plan.total ?? head.length
    if (total < head.length) throw new Error(`plan total ${total} < head ${head.length}`)
    const transfer = plan.transfer ?? 'cl'
    const headers: Record<string, string> = { 'content-type': 'application/json' }
    idp.bytesWritten = 0
    if (transfer === 'gzip') {
      const wire = gzipSync(Buffer.concat([head, Buffer.alloc(total - head.length, 0x20)]))
      headers['content-encoding'] = 'gzip'
      headers['content-length'] = String(wire.length)
      res.writeHead(status, headers)
      res.end(wire)
      idp.bytesWritten = wire.length
      return
    }
    if (transfer === 'cl') headers['content-length'] = String(total)
    res.writeHead(status, headers)
    res.write(head)
    idp.bytesWritten += head.length
    let left = total - head.length
    const chunk = Buffer.alloc(PUMP_CHUNK, 0x20)
    let closed = false
    res.on('close', () => {
      closed = true
    })
    const pump = (): void => {
      while (left > 0 && !closed) {
        const n = Math.min(left, chunk.length)
        left -= n
        idp.bytesWritten += n
        if (!res.write(n === chunk.length ? chunk : chunk.subarray(0, n))) {
          res.once('drain', pump)
          return
        }
      }
      if (!closed) res.end()
    }
    pump()
  }

  const route = async (req: IncomingMessage, res: ServerResponse): Promise<void> => {
    const path = new URL(req.url ?? '/', idp.origin).pathname
    const oc = '/realms/r/protocol/openid-connect'
    if (path === '/realms/r/.well-known/openid-configuration') {
      idp.counts.discovery += 1
      return send(res, idp.discovery ?? { head: JSON.stringify(discoveryDocument(idp.issuer)) })
    }
    if (path === `${oc}/certs`) {
      idp.counts.certs += 1
      return send(res, { head: JSON.stringify(jwks) })
    }
    if (path === `${oc}/token`) {
      idp.counts.token += 1
      const form = await readForm(req)
      idp.last.refreshToken = form.get('refresh_token') ?? undefined
      return send(res, idp.token)
    }
    if (path === `${oc}/token/introspect`) {
      idp.counts.introspect += 1
      const form = await readForm(req)
      idp.last.introspectToken = form.get('token') ?? undefined
      return send(res, idp.introspect)
    }
    if (path === `${oc}/logout`) {
      await readForm(req)
      res.writeHead(204).end()
      return
    }
    if (path.startsWith('/admin/')) {
      idp.counts.admin += 1
      idp.last.adminAuthorization = req.headers['authorization']
      await readForm(req)
      return send(res, idp.admin)
    }
    res.writeHead(404).end()
  }

  // ⚠️ 헤더 한도를 키운다 — Node 기본(16 KiB)이면 Keycloak 이 받아들이는 65,459 바이트 Bearer 를 이 서버가 먼저
  // 끊는다(실측 `read ECONNRESET`). 128 KiB 를 넘는 헤더는 Node 의 기본 처리(431·끊기)에 맡긴다.
  const server = createServer({ maxHeaderSize: 131_072 }, (req, res) => {
    res.on('error', () => undefined)
    route(req, res).catch(() => {
      if (!res.headersSent) res.writeHead(500)
      res.end()
    })
  })
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve))
  const origin = `http://127.0.0.1:${(server.address() as AddressInfo).port}`
  const idp: FakeIdp = {
    origin,
    issuer: `${origin}/realms/r`,
    token: { head: tokenResponse('access') },
    introspect: {
      head: JSON.stringify({ active: true, sub: 'u1', client_id: 'c', username: 'u1' }),
    },
    discovery: undefined,
    admin: { head: '[]' },
    counts: { discovery: 0, token: 0, introspect: 0, admin: 0, certs: 0 },
    last: {},
    bytesWritten: 0,
    setJwks: (value) => {
      jwks = value
    },
    close: () =>
      new Promise<void>((resolve) => {
        server.closeAllConnections()
        server.close(() => resolve())
      }),
  }
  return idp
}

export function discoveryDocument(issuer: string): Record<string, unknown> {
  const oc = `${issuer}/protocol/openid-connect`
  return {
    issuer,
    authorization_endpoint: `${oc}/auth`,
    token_endpoint: `${oc}/token`,
    introspection_endpoint: `${oc}/token/introspect`,
    end_session_endpoint: `${oc}/logout`,
    jwks_uri: `${oc}/certs`,
    response_types_supported: ['code'],
    id_token_signing_alg_values_supported: ['RS256'],
    authorization_response_iss_parameter_supported: true,
  }
}

/** 토큰 엔드포인트의 200 본문 — `extra` 는 그대로 더한다(id_token 등). */
export function tokenResponse(accessToken: string, extra: Record<string, unknown> = {}): string {
  return JSON.stringify({
    access_token: accessToken,
    token_type: 'Bearer',
    expires_in: 300,
    refresh_token: 'refresh',
    ...extra,
  })
}
