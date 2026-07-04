import { describe, it, expect } from 'vitest'
import { inspect } from 'node:util'
import { tokenSetFromResponse } from '../../src/tokens.js'

describe('TokenSet', () => {
  const t = tokenSetFromResponse({
    access_token: 'SECRETabc',
    token_type: 'Bearer',
    expires_in: 300,
    refresh_token: 'RTvalue',
    scope: 'openid',
  })

  it('OIDC 응답(snake_case)을 필드로 매핑', () => {
    expect(t.accessToken).toBe('SECRETabc')
    expect(t.tokenType).toBe('Bearer')
    expect(t.expiresIn).toBe(300)
    expect(t.refreshToken).toBe('RTvalue')
    expect(t.scope).toBe('openid')
  })

  it('toString/toJSON/inspect 모두 마스킹 — 원문 미노출', () => {
    expect(String(t)).toContain('***')
    expect(String(t)).not.toContain('SECRETabc')
    expect(JSON.stringify(t)).not.toContain('SECRETabc')
    expect(inspect(t)).not.toContain('SECRETabc')
  })

  it('최소 응답 — token_type 기본 Bearer, expires_in 문자열 변환, refresh/scope undefined', () => {
    const m = tokenSetFromResponse({ access_token: 'x', expires_in: '120' })
    expect(m.tokenType).toBe('Bearer')
    expect(m.expiresIn).toBe(120)
    expect(m.refreshToken).toBeUndefined()
    expect(m.scope).toBeUndefined()
  })

  it('access_token 없으면 throw', () => {
    expect(() => tokenSetFromResponse({ token_type: 'Bearer' })).toThrow()
  })
})
