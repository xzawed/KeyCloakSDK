import { describe, it, expect } from 'vitest'
import { defineConfig } from '../../src/config.js'
import { KeycloakConfigError } from '../../src/errors.js'

describe('defineConfig', () => {
  it('필수값 누락 → KeycloakConfigError', () => {
    expect(() => defineConfig({ serverUrl: '', realm: 'r', clientId: 'c' })).toThrow(KeycloakConfigError)
    expect(() => defineConfig({ serverUrl: 'https://kc', realm: '   ', clientId: 'c' })).toThrow(/realm/)
    expect(() => defineConfig({ serverUrl: 'https://kc', realm: 'r', clientId: '' })).toThrow(/clientId/)
  })

  it('기본값 채움 + serverUrl 끝 슬래시 제거', () => {
    const c = defineConfig({ serverUrl: 'https://kc.example.com/', realm: 'r', clientId: 'c' })
    expect(c.serverUrl).toBe('https://kc.example.com')
    expect(c.clockSkewSeconds).toBe(30)
    expect(c.connectTimeoutMs).toBe(10_000)
    expect(c.readTimeoutMs).toBe(30_000)
    expect(c.scopes).toEqual([])
    expect(c.clientSecret).toBeUndefined()
  })

  it('제공한 값은 유지', () => {
    const c = defineConfig({
      serverUrl: 'https://kc',
      realm: 'r',
      clientId: 'c',
      clientSecret: 's',
      scopes: ['profile'],
      clockSkewSeconds: 10,
    })
    expect(c.clientSecret).toBe('s')
    expect(c.scopes).toEqual(['profile'])
    expect(c.clockSkewSeconds).toBe(10)
  })
})
