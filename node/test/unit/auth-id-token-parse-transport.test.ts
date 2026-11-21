/**
 * A 200 token response that arrived in full but whose id_token does not parse is a `KeycloakAuthError`, whatever the
 * parse trips on (registry `node-typeerror-cause-parse-as-transport`).
 *
 * oauth4webapi decodes the id_token's header and payload as base64url before it parses them as JSON (`validateJwt`,
 * reached from every grant's token response through `processGenericAccessTokenResponse`). A part that is not base64url
 * throws its `CodedTypeError` (code `ERR_INVALID_ARG_VALUE`) holding the decoder's error as its `cause`, and the
 * classifier (`src/transport.ts`) read that as undici's fetch failure, a `TypeError` whose cause is an `Error`. Before
 * the fix (main 42d8858b) every "not base64url" row below was a `KeycloakTransportError` — chain
 * `ClientError[OAUTH_PARSE_ERROR] > OperationProcessingError[OAUTH_PARSE_ERROR] > TypeError[ERR_INVALID_ARG_VALUE] >
 * InvalidCharacterError` on Node 22.18.0 — while its control, the same part base64url but not JSON, was a
 * `KeycloakAuthError` with the same message.
 */
import { afterAll, beforeAll, describe, expect, it } from 'vitest'
import {
  ClientCredentialsTokenProvider,
  KeycloakAuthError,
  KeycloakClient,
  KeycloakTransportError,
} from '../../src/index.js'
import { startFakeIdp, tokenResponse, type FakeIdp } from './fake-idp.js'

const SECRET = 'zebrasecretjk'
const VERIFIER = `${'ocelotverifier'.repeat(3)}xx`

let idp: FakeIdp

beforeAll(async () => {
  idp = await startFakeIdp()
})

afterAll(async () => {
  await idp.close()
})

/** Every public call that reads a token response — each parses the id_token one carries. */
const SURFACES: ReadonlyArray<
  readonly [name: string, prefix: string, run: (kc: KeycloakClient) => Promise<unknown>]
> = [
  [
    'clientCredentialsToken',
    'Client credentials grant failed',
    (kc) => kc.auth.clientCredentialsToken(),
  ],
  [
    'provider',
    'Client credentials grant failed',
    (kc) => new ClientCredentialsTokenProvider(kc.auth).getAccessToken(),
  ],
  ['admin', 'Client credentials grant failed', (kc) => kc.admin()],
  ['refresh', 'Token refresh failed', (kc) => kc.auth.refresh('yakrefreshvq')],
  [
    'exchangeCode with a nonce',
    'Authorization code exchange failed',
    (kc) => kc.auth.exchangeCode('vulturecodeby', 'https://app.example/cb', VERIFIER, 'the-nonce'),
  ],
  [
    'exchangeCode without a nonce',
    'Authorization code exchange failed',
    (kc) => kc.auth.exchangeCode('vulturecodeby', 'https://app.example/cb', VERIFIER),
  ],
]

const b64u = (text: string): string => Buffer.from(text).toString('base64url')
const HEADER = b64u('{"alg":"RS256"}')
const PAYLOAD = b64u('{}')
const SIGNATURE = b64u('sig')
const NOT_JSON = b64u('not-json')

/** The part · an id_token whose part is not base64url · the control: that part base64url, but not JSON. */
const PARTS: ReadonlyArray<readonly [part: string, undecodable: string, notJson: string]> = [
  ['header', `!!!!.${PAYLOAD}.${SIGNATURE}`, `${NOT_JSON}.${PAYLOAD}.${SIGNATURE}`],
  ['payload', `${HEADER}.!!!!.${SIGNATURE}`, `${HEADER}.${NOT_JSON}.${SIGNATURE}`],
]

/** The call's failure when the token endpoint answers 200 with a usable token beside `idToken` — any other outcome fails. */
async function failure(
  run: (kc: KeycloakClient) => Promise<unknown>,
  idToken: string,
): Promise<Error> {
  idp.token = { head: tokenResponse('access', { id_token: idToken }) }
  const kc = KeycloakClient.create({
    serverUrl: idp.origin,
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

/** The cause chain as `name[code]` — the SDK keeps each link's name and string code. */
function links(e: Error): string[] {
  const out: string[] = []
  for (let link: unknown = e.cause; link instanceof Error; link = link.cause) {
    const code = (link as { code?: unknown }).code
    out.push(typeof code === 'string' ? `${link.name}[${code}]` : link.name)
  }
  return out
}

/** What a consumer tells one failure from another by — its class, message, OAuth code and its cause's fields. */
function shape(e: Error): Record<string, unknown> {
  const cause = e.cause instanceof Error ? e.cause : undefined
  return {
    class: e.constructor.name,
    name: e.name,
    message: e.message,
    oauthError: e instanceof KeycloakAuthError ? e.oauthError : undefined,
    cause:
      cause === undefined
        ? undefined
        : { name: cause.name, message: cause.message, code: (cause as { code?: unknown }).code },
  }
}

describe.each(PARTS)(
  'a 200 token response whose id_token %s does not parse',
  (part, undecodable, notJson) => {
    it.each(SURFACES)(
      `%s — control: a ${part} that is base64url but not JSON is a KeycloakAuthError`,
      async (_name, prefix, run) => {
        const control = await failure(run, notJson)
        expect(links(control)).toContain('SyntaxError')
        expect(control).toBeInstanceOf(KeycloakAuthError)
        expect(control.message).toBe(`${prefix}: parsing error occured`)
        expect((control as KeycloakAuthError).oauthError).toBeUndefined()
      },
    )

    it.each(SURFACES)(
      `%s — a ${part} that is not base64url: the same KeycloakAuthError, not a KeycloakTransportError`,
      async (_name, _prefix, run) => {
        const control = await failure(run, notJson)
        const got = await failure(run, undecodable)
        // The premise — the decoder refused it, so the CodedTypeError is in the chain.
        expect(links(got)).toContain('TypeError[ERR_INVALID_ARG_VALUE]')
        expect(got).not.toBeInstanceOf(KeycloakTransportError)
        expect(got).toBeInstanceOf(KeycloakAuthError)
        expect(shape(got)).toEqual(shape(control))
      },
    )
  },
)
