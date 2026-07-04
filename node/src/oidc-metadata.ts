import type { KeycloakConfig } from './config.js'

/** Keycloak realm의 OIDC 엔드포인트 URL 집합. */
export interface OidcEndpoints {
  readonly issuer: string
  readonly token: string
  readonly authorization: string
  readonly introspection: string
  readonly endSession: string
  readonly jwks: string
}

/** `{serverUrl}/realms/{realm}` 규약으로 엔드포인트를 조립한다(네트워크 호출 없음). */
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
