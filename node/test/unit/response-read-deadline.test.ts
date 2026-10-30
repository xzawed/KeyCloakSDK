/**
 * Response read deadline — a JWKS response must arrive in full within the configured `readTimeoutMs`, counted from
 * send (`.claude/rules/security.md` · registry `response-read-deadline-divergent`). The validator `AuthClient` builds
 * used jose's own `timeoutDuration` (5,000 ms) instead of the configuration: a trickle that outlasted the configured
 * timeout still validated, and an IdP slower than 5 s failed although the configuration allowed it.
 *
 * Every case goes through `AuthClient` (the SDK-built validator); each builds its own client, so no cache or failure
 * backoff carries over. The body trickles one byte at a time, so a per-read timeout alone would never fire.
 */
import { describe, it, expect, beforeAll, afterAll } from 'vitest'
import { createServer, type Server, type ServerResponse } from 'node:http'
import type { AddressInfo } from 'node:net'
import { generateKeyPair, exportJWK, SignJWT } from 'jose'
import { AuthClient } from '../../src/auth.js'
import { defineConfig } from '../../src/config.js'
import { KeycloakError } from '../../src/errors.js'

type Pair = Awaited<ReturnType<typeof generateKeyPair>>
type Mode = 'healthy' | 'trickle' | 'stall' | 'late'

const TRICKLE_EVERY_MS = 50 // one byte per tick: the body never completes within any deadline here
const LATE_MS = 5_500 // headers and body after this delay — past jose's 5 s

let srv: Server
let base = ''
let mode: Mode = 'healthy'
let pair: Pair
let jwks: Buffer
const open = new Set<ServerResponse>()

beforeAll(async () => {
  pair = await generateKeyPair('RS256')
  const jwk = { ...(await exportJWK(pair.publicKey)), kid: 'k1', use: 'sig', alg: 'RS256' }
  jwks = Buffer.from(JSON.stringify({ keys: [jwk] }))
  srv = createServer((_req, res) => {
    open.add(res)
    res.on('close', () => open.delete(res))
    const head = { 'content-type': 'application/json', 'content-length': String(jwks.length) }
    if (mode === 'late') {
      setTimeout(() => {
        if (res.destroyed) return
        res.writeHead(200, head)
        res.end(jwks)
      }, LATE_MS)
      return
    }
    res.writeHead(200, head)
    if (mode === 'healthy') {
      res.end(jwks)
      return
    }
    if (mode === 'stall') {
      res.write(jwks.subarray(0, 10)) // headers and ten bytes, then nothing
      return
    }
    let i = 0
    const tick = setInterval(() => {
      if (res.destroyed) {
        clearInterval(tick)
        return
      }
      res.write(jwks.subarray(i, i + 1))
      i += 1
      if (i >= jwks.length) {
        clearInterval(tick)
        res.end()
      }
    }, TRICKLE_EVERY_MS)
  })
  await new Promise<void>((resolve) => srv.listen(0, '127.0.0.1', resolve))
  base = `http://127.0.0.1:${(srv.address() as AddressInfo).port}`
})

afterAll(async () => {
  for (const res of open) res.destroy()
  await new Promise<void>((resolve) => srv.close(() => resolve()))
})

const sign = (): Promise<string> =>
  new SignJWT({ sub: 'u', aud: 'my-client' })
    .setProtectedHeader({ alg: 'RS256', kid: 'k1' })
    .setIssuer(`${base}/realms/test`)
    .setIssuedAt()
    .setExpirationTime('10m')
    .sign(pair.privateKey)

/** One validation through a fresh `AuthClient` — its outcome and how long it took. */
async function timed(readTimeoutMs: number): Promise<{ ms: number; error?: unknown }> {
  const token = await sign()
  const auth = new AuthClient(
    defineConfig({ serverUrl: base, realm: 'test', clientId: 'my-client', readTimeoutMs }),
  )
  const t0 = performance.now()
  try {
    await auth.validate(token)
    return { ms: performance.now() - t0 }
  } catch (error) {
    return { ms: performance.now() - t0, error }
  }
}

describe('JWKS response read deadline — the configured readTimeoutMs, not jose 5 s', () => {
  it('a trickled JWKS fails at the configured deadline', async () => {
    mode = 'trickle'
    const r = await timed(1_000)
    expect(r.error).toBeInstanceOf(KeycloakError)
    expect(r.ms).toBeGreaterThanOrEqual(900)
    expect(r.ms).toBeLessThan(3_000)
  }, 15_000)

  it('a stalled JWKS body fails at the configured deadline', async () => {
    mode = 'stall'
    const r = await timed(1_000)
    expect(r.error).toBeInstanceOf(KeycloakError)
    expect(r.ms).toBeGreaterThanOrEqual(900)
    expect(r.ms).toBeLessThan(3_000)
  }, 15_000)

  it('control — an IdP slower than 5 s is accepted when the configured timeout allows it', async () => {
    mode = 'late'
    const r = await timed(8_000)
    expect(r.error).toBeUndefined()
    expect(r.ms).toBeGreaterThanOrEqual(LATE_MS - 100)
  }, 15_000)

  it('control — a healthy JWKS validates', async () => {
    mode = 'healthy'
    expect((await timed(1_000)).error).toBeUndefined()
  })
})
