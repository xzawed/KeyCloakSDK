import { describe, it, expect } from 'vitest'
import { mask } from '../../src/masking.js'

describe('mask', () => {
  it('완전 불투명 — 입력과 무관하게 ***', () => {
    expect(mask('supersecret')).toBe('***')
    expect(mask('')).toBe('***')
    expect(mask(undefined)).toBe('***')
    expect(mask(null)).toBe('***')
  })
  it('원문을 노출하지 않음(접두 노출 없음)', () => {
    expect(mask('AKIA-secret-1234')).not.toContain('AKIA')
    expect(mask('AKIA-secret-1234')).not.toContain('secret')
  })
})

// createAuthorizationRequest 가 **평범한 객체 리터럴**을 돌려주면 `console.log`(=util.inspect)와
// `JSON.stringify` 가 PKCE codeVerifier 를 원문으로 찍는다. 같은 패키지의 TokenSet 은 세 경로를
// 모두 막는데(toString·toJSON·nodejs.util.inspect.custom) 이 타입만 무보호였다.
// codeVerifier 는 코드 교환의 소유 증명 비밀이다 — 코드를 훔친 공격자가 로그의 verifier 를
// 얻으면 흐름을 완성한다.
describe('AuthorizationRequest 마스킹', () => {
  const build = async () => {
    const { AuthClient } = await import('../../src/auth.js')
    const { defineConfig } = await import('../../src/config.js')
    const cfg = defineConfig({
      serverUrl: 'https://kc.example.com',
      realm: 'demo',
      clientId: 'app',
    })
    return new AuthClient(cfg).createAuthorizationRequest('https://app.example/cb')
  }

  it('util.inspect(=console.log) 가 codeVerifier 를 찍지 않는다', async () => {
    const req = await build()
    const { inspect } = await import('node:util')
    const shown = inspect(req)
    expect(shown).not.toContain(req.codeVerifier)
    expect(shown).toContain('***')
  })

  it('JSON.stringify 가 codeVerifier 를 찍지 않는다', async () => {
    const req = await build()
    const json = JSON.stringify(req)
    expect(json).not.toContain(req.codeVerifier)
  })

  it('String() 이 codeVerifier 를 찍지 않는다', async () => {
    const req = await build()
    expect(String(req)).not.toContain(req.codeVerifier)
  })

  it('값 자체는 그대로 읽힌다 — 마스킹이 API 를 깨지 않는다', async () => {
    const req = await build()
    expect(req.codeVerifier).toMatch(/^[A-Za-z0-9_-]{20,}$/)
    expect(req.url).toContain('code_challenge_method=S256')
    expect(req.state.length).toBeGreaterThan(0)
    expect(req.nonce.length).toBeGreaterThan(0)
  })
})
