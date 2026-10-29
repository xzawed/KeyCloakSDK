import type { KeycloakConfig } from './config.js'

/** The set of OIDC endpoint URLs of a Keycloak realm. */
export interface OidcEndpoints {
  readonly issuer: string
  readonly token: string
  readonly authorization: string
  readonly introspection: string
  readonly endSession: string
  readonly jwks: string
}

/** Assembles the endpoints by the `{serverUrl}/realms/{realm}` convention (no network call). */
export function oidcEndpoints(config: Pick<KeycloakConfig, 'serverUrl' | 'realm'>): OidcEndpoints {
  const issuer = `${config.serverUrl}/realms/${config.realm}`
  const base = `${issuer}/protocol/openid-connect`
  return {
    issuer,
    token: `${base}/token`,
    authorization: `${base}/auth`,
    introspection: `${base}/token/introspect`,
    endSession: `${base}/logout`,
    jwks: `${base}/certs`,
  }
}
