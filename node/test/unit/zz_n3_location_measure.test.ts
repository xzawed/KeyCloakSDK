// measurement only — not for merge (task n3 · registry admin-created-id-non-ascii-location).
//
// What id does `(await kc.admin()).users.create` return when the 201's Location carries a byte that is not visible ASCII?
// A raw TCP server answers discovery, the token grant and the create with 201 +
// `Location: http://127.0.0.1:<port>/admin/realms/it-realm/users/<id bytes>` for `abc` (control), `ab` 0xE9 `cd` (Latin-1
// obs-text) and `ab` 0xC3 0xA9 `cd` (UTF-8 for U+00E9). Per case: the bytes a raw socket reads off the wire (WIRE), what
// the global fetch (undici) hands back as the header (CLIENT), and what the SDK returns (ID).
//
// Run: N3_OUT=<file> npx vitest run test/unit/zz_n3_location_measure.test.ts
import { createConnection, createServer, type AddressInfo, type Socket } from 'node:net'
import { writeFileSync } from 'node:fs'
import { describe, expect, it } from 'vitest'
import { KeycloakClient } from '../../src/index.js'

const USERS = '/admin/realms/it-realm/users'
const CASES: readonly (readonly [string, Buffer])[] = [
  ['ascii-control', Buffer.from('abc', 'latin1')],
  ['latin1-0xE9', Buffer.from([0x61, 0x62, 0xe9, 0x63, 0x64])],
  ['utf8-0xC3A9', Buffer.from([0x61, 0x62, 0xc3, 0xa9, 0x63, 0x64])],
]

const hex = (b: Buffer): string => [...b].map((x) => x.toString(16).toUpperCase().padStart(2, '0')).join(' ')

/** A JS string with every char outside printable ASCII escaped, then its code points. */
function show(s: string | null | undefined): string {
  if (s === null || s === undefined) return String(s)
  const escaped = [...s]
    .map((c) => {
      const cp = c.codePointAt(0) ?? 0
      return cp >= 0x20 && cp < 0x7f ? c : `\\u${cp.toString(16).toUpperCase().padStart(4, '0')}`
    })
    .join('')
  const cps = [...s].map((c) => `U+${(c.codePointAt(0) ?? 0).toString(16).toUpperCase().padStart(4, '0')}`)
  return `"${escaped}" cps=[${cps.join(',')}]`
}

const tail = (s: string | null): string | null => (s === null ? null : s.slice(s.lastIndexOf('/') + 1))

describe('zz n3 location measure (measurement only)', () => {
  it('measures the id a create returns for a non-ASCII Location', async () => {
    const outPath = process.env['N3_OUT']
    expect(outPath, 'set N3_OUT').toBeTruthy()
    const seen: string[] = []
    let location = Buffer.alloc(0)
    let base = ''
    const server = createServer((sock: Socket) => {
      let buf = Buffer.alloc(0)
      sock.on('data', (chunk: Buffer) => {
        buf = Buffer.concat([buf, chunk])
        const end = buf.indexOf('\r\n\r\n')
        if (end < 0) return
        const head = buf.subarray(0, end).toString('latin1').split('\r\n')
        const [method = '', path = ''] = (head[0] ?? '').split(' ')
        const lengthLine = head.find((l) => l.toLowerCase().startsWith('content-length:'))
        const length = lengthLine === undefined ? 0 : Number(lengthLine.split(':')[1])
        if (buf.length < end + 4 + length) return
        seen.push(`${method} ${path}`)
        let answer: Buffer
        if (path.endsWith('/.well-known/openid-configuration')) {
          const issuer = `${base}/realms/it-realm`
          const oc = `${issuer}/protocol/openid-connect`
          const doc = JSON.stringify({
            issuer,
            authorization_endpoint: `${oc}/auth`,
            token_endpoint: `${oc}/token`,
            introspection_endpoint: `${oc}/token/introspect`,
            end_session_endpoint: `${oc}/logout`,
            jwks_uri: `${oc}/certs`,
            response_types_supported: ['code'],
            id_token_signing_alg_values_supported: ['RS256'],
          })
          answer = Buffer.from(
            `HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ${Buffer.byteLength(doc)}\r\nConnection: close\r\n\r\n${doc}`,
            'latin1',
          )
        } else if (path.endsWith('/protocol/openid-connect/token')) {
          const json = '{"access_token":"at-n3","token_type":"Bearer","expires_in":300}'
          answer = Buffer.from(
            `HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ${json.length}\r\nConnection: close\r\n\r\n${json}`,
            'latin1',
          )
        } else if (method === 'POST' && path.replace(/\/$/, '') === USERS) {
          answer = Buffer.concat([
            Buffer.from('HTTP/1.1 201 Created\r\nLocation: ', 'latin1'),
            location,
            Buffer.from('\r\nContent-Length: 0\r\nConnection: close\r\n\r\n', 'latin1'),
          ])
        } else {
          answer = Buffer.from('HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n', 'latin1')
        }
        sock.end(answer)
      })
      sock.on('error', () => undefined)
    })
    await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve))
    const port = (server.address() as AddressInfo).port
    base = `http://127.0.0.1:${port}`

    const out: string[] = [
      `ENV|node=${process.version}|undici=${process.versions['undici'] ?? '?'}|create=(await kc.admin()).users.create`,
      'HEADER|sdk|lane|case|field|value',
    ]
    for (const [name, id] of CASES) {
      const prefix = Buffer.from(`${base}${USERS}/`, 'latin1')
      location = Buffer.concat([prefix, id])

      const raw = await new Promise<Buffer>((resolve, reject) => {
        const chunks: Buffer[] = []
        const c = createConnection({ host: '127.0.0.1', port }, () => {
          c.write(`POST ${USERS} HTTP/1.1\r\nHost: 127.0.0.1:${port}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n`)
        })
        c.on('data', (d: Buffer) => chunks.push(d))
        c.on('end', () => resolve(Buffer.concat(chunks)))
        c.on('error', reject)
      })
      const marker = Buffer.from('\r\nLocation: ', 'latin1')
      const at = raw.indexOf(marker)
      const got = at < 0 ? Buffer.alloc(0) : raw.subarray(at + marker.length, raw.indexOf('\r\n', at + marker.length))
      out.push(
        `WIRE|node|-|${name}|location=<base>/admin/realms/it-realm/users/+[${hex(id)}]|raw_socket_read_equals_sent=${got.equals(location)}|id_bytes_on_wire=${hex(got.subarray(prefix.length))}`,
      )

      try {
        const resp = await fetch(`${base}${USERS}`, { method: 'POST', body: '{}', redirect: 'manual' })
        out.push(
          `CLIENT|node|fetch(undici)|${name}|status=${resp.status}|headers.get('location').after_last_slash=${show(tail(resp.headers.get('location')))}`,
        )
      } catch (e) {
        out.push(`CLIENT|node|fetch(undici)|${name}|threw ${(e as Error).name}: ${(e as Error).message}`)
      }

      seen.length = 0
      let result: string
      const kc = KeycloakClient.create({ serverUrl: base, realm: 'it-realm', clientId: 'it-client', clientSecret: 'dummy-secret' })
      try {
        const admin = await kc.admin()
        result = `Ok(${show(await admin.users.create({ username: 'n3-user' }))})`
      } catch (e) {
        const err = e as Error & { status?: number }
        result = `Err(${err.constructor.name}: ${err.message}${err.status === undefined ? '' : ` status=${err.status}`})`
      } finally {
        await kc.close()
      }
      out.push(`ID|node|(await kc.admin()).users.create|${name}|${result.replaceAll('|', '/').replaceAll(base, '<base>')}|requests=${seen.join(',')}`)
    }
    await new Promise<void>((resolve) => server.close(() => resolve()))
    writeFileSync(outPath as string, `${out.join('\n')}\n`)
    expect(out.filter((l) => l.startsWith('ID|'))).toHaveLength(3)
  })
})
