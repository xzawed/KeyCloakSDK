import { describe, it, expect } from 'vitest'
import { inspect } from 'node:util'
import { tokenSetFromResponse } from '../../src/tokens.js'

describe('TokenSet', () => {
  const t = tokenSetFromResponse(
    {
      access_token: 'SECRETabc',
      token_type: 'Bearer',
      expires_in: 300,
      refresh_token: 'RTvalue',
      id_token: 'IDtokvalue',
      scope: 'openid',
    },
    1_000_000, // issuedAtSeconds (결정론적 expiresAt 검증용)
  )

  it('OIDC 응답(snake_case)을 필드로 매핑', () => {
    expect(t.accessToken).toBe('SECRETabc')
    expect(t.tokenType).toBe('Bearer')
    expect(t.expiresIn).toBe(300)
    expect(t.refreshToken).toBe('RTvalue')
    expect(t.idToken).toBe('IDtokvalue')
    expect(t.scope).toBe('openid')
  })

  it('절대 만료 expiresAt = issuedAt + expiresIn (epoch 초)', () => {
    expect(t.expiresAt).toBe(1_000_300)
  })

  it('isExpired — now+skew가 expiresAt 이상이면 만료', () => {
    expect(t.isExpired(1_000_000, 30)).toBe(false)
    expect(t.isExpired(1_000_280, 30)).toBe(true) // 280+30 >= 300
    // expiresAt 미상이면 보수적으로 만료 처리
    const noExp = tokenSetFromResponse({ access_token: 'x' })
    expect(noExp.expiresAt).toBeUndefined()
    expect(noExp.isExpired(0, 0)).toBe(true)
  })

  it('toString/toJSON/inspect 모두 access/refresh 마스킹 — 원문 미노출', () => {
    for (const rendered of [String(t), JSON.stringify(t), inspect(t)]) {
      expect(rendered).toContain('***')
      expect(rendered).not.toContain('SECRETabc')
      expect(rendered).not.toContain('RTvalue')
    }
  })

  it('최소 응답 — token_type 기본 Bearer, expires_in 문자열 변환, refresh/id/scope undefined', () => {
    const m = tokenSetFromResponse({ access_token: 'x', expires_in: '120' }, 0)
    expect(m.tokenType).toBe('Bearer')
    expect(m.expiresIn).toBe(120)
    expect(m.expiresAt).toBe(120)
    expect(m.refreshToken).toBeUndefined()
    expect(m.idToken).toBeUndefined()
    expect(m.scope).toBeUndefined()
  })

  it('access_token 없으면 throw', () => {
    expect(() => tokenSetFromResponse({ token_type: 'Bearer' })).toThrow()
  })
})
