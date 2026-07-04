import { describe, it, expect } from 'vitest'
import { oidcEndpoints } from '../../src/oidc-metadata.js'

describe('oidcEndpoints', () => {
  it('규약대로 엔드포인트 조립', () => {
    const ep = oidcEndpoints({ serverUrl: 'https://kc.example.com', realm: 'myrealm' })
    expect(ep.issuer).toBe('https://kc.example.com/realms/myrealm')
    expect(ep.jwks).toBe('https://kc.example.com/realms/myrealm/protocol/openid-connect/certs')
    expect(ep.token).toBe('https://kc.example.com/realms/myrealm/protocol/openid-connect/token')
    expect(ep.introspection).toBe(
      'https://kc.example.com/realms/myrealm/protocol/openid-connect/token/introspect',
    )
    expect(ep.endSession).toBe('https://kc.example.com/realms/myrealm/protocol/openid-connect/logout')
    expect(ep.authorization).toBe('https://kc.example.com/realms/myrealm/protocol/openid-connect/auth')
  })
})
