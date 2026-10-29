/**
 * QuickStart — a minimal usage example of `@xzawed/keycloak-sdk` (Node/TypeScript).
 *
 * It needs a real Keycloak server, so this file is not part of the published artifact (`dist`); it is a
 * reference example. To run it, set the environment variables below to real values, link or build the SDK
 * locally (for example `npm run build`, then reference it from a consuming project), and run it with a
 * tsx/TypeScript runtime:
 *
 *   KEYCLOAK_URL=https://kc.example.com KEYCLOAK_REALM=my-realm \
 *   KEYCLOAK_CLIENT_ID=my-client KEYCLOAK_CLIENT_SECRET=*** \
 *   node --experimental-strip-types examples/quickstart.ts
 */
import { KeycloakClient } from '@xzawed/keycloak-sdk'

async function main(): Promise<void> {
  // KeycloakClient.create() builds auth (AuthClient) right away. admin is created lazily on the first admin()
  // call (client-credentials grant — needs clientSecret).
  const client = KeycloakClient.create({
    serverUrl: process.env['KEYCLOAK_URL'] ?? 'https://kc.example.com',
    realm: process.env['KEYCLOAK_REALM'] ?? 'my-realm',
    clientId: process.env['KEYCLOAK_CLIENT_ID'] ?? 'my-client',
    // Load the real value from the environment or a secret manager. The config is masked automatically when logged.
    clientSecret: process.env['KEYCLOAK_CLIENT_SECRET'] ?? 'changeme',
  })

  try {
    // 1) Get a client-credentials token — TokenSet's string form is masked automatically (accessToken=***).
    const token = await client.auth.clientCredentialsToken()
    console.log(`token=${token.toString()}`)

    // 2) Validate the issued token with the self-hardened checks (alg pin · exact iss · aud membership · clock skew).
    const validated = await client.auth.validate(token.accessToken)
    console.log(`subject=${validated.subject} aud=${validated.audience.join(',')}`)

    // 3) Admin API — admin is created lazily at this point. List users (at most 10).
    const admin = await client.admin()
    const users = await admin.users.search(undefined, 0, 10)
    console.log(`users=${users.map((u) => u.username).join(', ')}`)
  } finally {
    // close() releases the admin and auth resources.
    // `await using client = KeycloakClient.create(...)` also cleans up automatically when the scope exits.
    await client.close()
  }
}

main().catch((err: unknown) => {
  console.error(err)
  process.exitCode = 1
})
