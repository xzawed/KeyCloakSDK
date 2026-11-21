/**
 * A member of an OAuth error body named like a field of a transport failure — `code` (`"ECONNRESET"`), `name`
 * (`"TimeoutError"` · `"AbortError"`) or a nested `cause` — leaves the failure what the same body without it is: a
 * `KeycloakAuthError` carrying the OAuth `error` (registry `node-body-code-member-transport`).
 *
 * oauth4webapi's `ResponseBodyError` — and the SDK's own one for a 200 carrying `error` (`fetchTokenEndpointBounded`,
 * #1184) — holds the JSON-parsed body as its `cause`. The classifier (`src/transport.ts`) read `cause.code` of that
 * error and walked into the body as the next link of the cause chain, so the body's members were read as a transport
 * failure's fields. Before the fix (main 4a1ac04f) every member row below was a `KeycloakTransportError` without
 * `oauthError`, while its control was a `KeycloakAuthError` carrying `invalid_grant`.
 *
 * The admin facade is a control that passes before and after: its error body goes to `responseData`, never to `cause`,
 * and `call()` maps a response with a status by that status before it asks whether the failure is a transport one
 * (`src/admin/http.ts` `reject` · `src/admin/call.ts`).
 */
import { createServer, type Server } from 'node:http'
import type { AddressInfo } from 'node:net'
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest'
import {
  ClientCredentialsTokenProvider,
  KeycloakAdminError,
  KeycloakAuthError,
  KeycloakClient,
} from '../../src/index.js'
import { discoveryDocument, tokenResponse } from './fake-idp.js'

// No value a request sends overlaps `invalid_grant`, so the control carries that code (`src/oauth-error-code.ts`).
const SECRET = 'zebrasecretjk'
const VERIFIER = `${'ocelotverifier'.repeat(3)}xx`

interface Answer {
  readonly status: number
  readonly body: string
}

let server: Server
let origin = ''
/** What the token and introspection endpoints answer. */
let token: Answer
/** What every admin path answers. */
let admin: Answer

beforeAll(async () => {
  server = createServer((req, res) => {
    req.on('end', () => {
      const path = new URL(req.url ?? '/', origin).pathname
      const answer: Answer =
        path === '/realms/r/.well-known/openid-configuration'
          ? { status: 200, body: JSON.stringify(discoveryDocument(`${origin}/realms/r`)) }
          : path.startsWith('/admin/')
            ? admin
            : token
      res.writeHead(answer.status, { 'content-type': 'application/json' })
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

beforeEach(() => {
  token = { status: 200, body: tokenResponse('admintoken') }
  admin = { status: 200, body: '[]' }
})

/** Every public call whose failure the auth lane classifies — the provider and admin reach the client-credentials grant. */
const SURFACES: Readonly<Record<string, (kc: KeycloakClient) => Promise<unknown>>> = {
  clientCredentialsToken: (kc) => kc.auth.clientCredentialsToken(),
  provider: (kc) => new ClientCredentialsTokenProvider(kc.auth).getAccessToken(),
  admin: (kc) => kc.admin(),
  refresh: (kc) => kc.auth.refresh('yakrefreshvq'),
  exchangeCode: (kc) =>
    kc.auth.exchangeCode('vulturecodeby', 'https://app.example/cb', VERIFIER, 'the-nonce'),
  introspect: (kc) => kc.auth.introspect('walrustokenpx'),
}
const NAMES = Object.keys(SURFACES)

/** The control's body — a plain OAuth error. */
const CONTROL = { error: 'invalid_grant' }
/** Members named like a transport failure's fields, each beside the control's `error`. */
const MEMBERS: ReadonlyArray<readonly [string, Readonly<Record<string, unknown>>]> = [
  ['code ECONNRESET', { code: 'ECONNRESET' }],
  ['name TimeoutError', { name: 'TimeoutError' }],
  ['name AbortError', { name: 'AbortError' }],
  ['cause.code ECONNRESET', { cause: { code: 'ECONNRESET' } }],
]
const body = (member: Readonly<Record<string, unknown>> = {}): string =>
  JSON.stringify({ ...CONTROL, ...member })

/** The call's failure — any other outcome fails the test. */
async function failing(run: (kc: KeycloakClient) => Promise<unknown>): Promise<Error> {
  const kc = KeycloakClient.create({
    serverUrl: origin,
    realm: 'r',
    clientId: 'app',
    clientSecret: SECRET,
  })
  try {
    await run(kc)
  } catch (e) {
    if (e instanceof Error) return e
    throw new Error(`threw a non-Error ${String(e)}`)
  } finally {
    await kc.close()
  }
  throw new Error('the call did not fail')
}

function surface(name: string): (kc: KeycloakClient) => Promise<unknown> {
  const run = SURFACES[name]
  if (run === undefined) throw new Error(`no surface ${name}`)
  return run
}

/** The surface's failure when the token or introspection endpoint answers `status` with `text`. */
async function authFailure(name: string, status: number, text: string): Promise<Error> {
  token = { status, body: text }
  return failing(surface(name))
}

/** What a consumer tells one failure from another by — its class, message, codes, status and its cause's fields. */
function shape(e: Error): Record<string, unknown> {
  const cause = e.cause instanceof Error ? e.cause : undefined
  return {
    class: e.constructor.name,
    name: e.name,
    message: e.message,
    oauthError: e instanceof KeycloakAuthError ? e.oauthError : undefined,
    status: e instanceof KeycloakAdminError ? e.status : undefined,
    cause:
      cause === undefined
        ? undefined
        : { name: cause.name, message: cause.message, code: (cause as { code?: unknown }).code },
  }
}

// 400 — oauth4webapi's own ResponseBodyError (`checkOAuthBodyError`); 200 — the SDK's (`fetchTokenEndpointBounded`).
describe.each([400, 200])(
  'HTTP %i OAuth error body — a member named like a transport field',
  (status) => {
    it.each(NAMES)(
      '%s — control: {"error":"invalid_grant"} is a KeycloakAuthError carrying invalid_grant',
      async (name) => {
        const e = await authFailure(name, status, body())
        expect(e).toBeInstanceOf(KeycloakAuthError)
        expect((e as KeycloakAuthError).oauthError).toBe('invalid_grant')
        expect(e.message.endsWith(': server responded with an error in the response body')).toBe(
          true,
        )
      },
    )

    const CASES = NAMES.flatMap((name) =>
      MEMBERS.map(([label, member]) => [name, label, member] as const),
    )
    it.each(CASES)(
      '%s — a body member %s: the same failure as the control',
      async (name, _label, member) => {
        const control = await authFailure(name, status, body())
        const got = await authFailure(name, status, body(member))
        expect(shape(got)).toEqual(shape(control))
      },
    )
  },
)

describe('admin facade control — its error body is never a cause, so the status classifies it', () => {
  async function adminFailure(text: string): Promise<Error> {
    admin = { status: 400, body: text }
    return failing(async (kc) => (await kc.admin()).users.get('u1'))
  }

  it.each(MEMBERS)(
    'a 400 admin body with a member %s: the same failure as without it',
    async (_label, member) => {
      const control = await adminFailure(body())
      const got = await adminFailure(body(member))
      expect(control).toBeInstanceOf(KeycloakAdminError)
      expect((control as KeycloakAdminError).status).toBe(400)
      expect(shape(got)).toEqual(shape(control))
    },
  )
})
