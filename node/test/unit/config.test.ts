import { describe, it, expect } from 'vitest'
import { inspect } from 'node:util'
import { defineConfig } from '../../src/config.js'
import { KeycloakConfigError } from '../../src/errors.js'

describe('defineConfig', () => {
  it('필수값 누락 → KeycloakConfigError', () => {
    expect(() => defineConfig({ serverUrl: '', realm: 'r', clientId: 'c' })).toThrow(
      KeycloakConfigError,
    )
    expect(() => defineConfig({ serverUrl: 'https://kc', realm: '   ', clientId: 'c' })).toThrow(
      /realm/,
    )
    expect(() => defineConfig({ serverUrl: 'https://kc', realm: 'r', clientId: '' })).toThrow(
      /clientId/,
    )
  })

  // ⚠️ 슬래시 **여러 개**를 함께 고정한다. 구현이 정규식 `/\/+$/`에서 선형 트림으로 바뀌었는데,
  // 단일 슬래시만 검사하면 "하나만 지우는" 구현으로 퇴화해도 통과한다(내부 슬래시 보존도 함께).
  it('serverUrl 끝 슬래시를 전부 제거하되 내부 슬래시는 보존', () => {
    expect(defineConfig({ serverUrl: 'https://kc.example.com////', realm: 'r', clientId: 'c' }).serverUrl)
      .toBe('https://kc.example.com')
    expect(defineConfig({ serverUrl: 'https://kc.example.com/auth//', realm: 'r', clientId: 'c' }).serverUrl)
      .toBe('https://kc.example.com/auth')
    expect(defineConfig({ serverUrl: 'https://kc.example.com', realm: 'r', clientId: 'c' }).serverUrl)
      .toBe('https://kc.example.com')
  })

  it('기본값 채움 + serverUrl 끝 슬래시 제거', () => {
    const c = defineConfig({ serverUrl: 'https://kc.example.com/', realm: 'r', clientId: 'c' })
    expect(c.serverUrl).toBe('https://kc.example.com')
    expect(c.clockSkewSeconds).toBe(30)
    expect(c.connectTimeoutMs).toBe(10_000)
    expect(c.readTimeoutMs).toBe(30_000)
    expect(c.scopes).toEqual([])
    expect(c.clientSecret).toBeUndefined()
    expect(c.signatureAlgorithms).toEqual(['RS256'])
    expect(c.jwksMinRefetchSeconds).toBe(30)
    expect(c.expectedAudience).toBeUndefined()
  })

  it('expectedAudience를 설정하면 그대로 유지한다', () => {
    const c = defineConfig({
      serverUrl: 'https://kc',
      realm: 'r',
      clientId: 'c',
      expectedAudience: 'some-api',
    })
    expect(c.expectedAudience).toBe('some-api')
  })

  it('jwksMinRefetchSeconds를 설정하면 유지하고, 음수는 거부', () => {
    expect(
      defineConfig({
        serverUrl: 'https://kc',
        realm: 'r',
        clientId: 'c',
        jwksMinRefetchSeconds: 60,
      }).jwksMinRefetchSeconds,
    ).toBe(60)
    expect(() =>
      defineConfig({
        serverUrl: 'https://kc',
        realm: 'r',
        clientId: 'c',
        jwksMinRefetchSeconds: -1,
      }),
    ).toThrow(KeycloakConfigError)
  })

  it('signatureAlgorithms를 설정하면 유지하고, 빈 배열은 거부', () => {
    expect(
      defineConfig({
        serverUrl: 'https://kc',
        realm: 'r',
        clientId: 'c',
        signatureAlgorithms: ['ES256', 'RS256'],
      }).signatureAlgorithms,
    ).toEqual(['ES256', 'RS256'])
    expect(() =>
      defineConfig({ serverUrl: 'https://kc', realm: 'r', clientId: 'c', signatureAlgorithms: [] }),
    ).toThrow(KeycloakConfigError)
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

  it('clientSecret은 로깅/직렬화에서 마스킹된다(속성 접근·스프레드는 유지)', () => {
    const c = defineConfig({
      serverUrl: 'https://kc',
      realm: 'r',
      clientId: 'c',
      clientSecret: 'supersecret',
    })
    // 직렬화·inspect는 마스킹 — 원문 미노출
    expect(JSON.stringify(c)).not.toContain('supersecret')
    expect(JSON.stringify(c)).toContain('***')
    expect(inspect(c)).not.toContain('supersecret')
    expect(inspect(c)).toContain('***')
    // 속성 접근과 스프레드는 실제 값을 유지(내부 사용)
    expect(c.clientSecret).toBe('supersecret')
    expect({ ...c }.clientSecret).toBe('supersecret')
  })

  it('clientSecret이 없으면 마스킹 대신 undefined로 직렬화된다', () => {
    const c = defineConfig({ serverUrl: 'https://kc', realm: 'r', clientId: 'c' })
    expect(JSON.stringify(c)).not.toContain('***')
  })
})
