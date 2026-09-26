import { describe, it, expect } from 'vitest'
import { inspect } from 'node:util'
import {
  mapHttpError,
  KeycloakAuthError,
  KeycloakError,
  KeycloakAdminError,
  KeycloakNotFoundError,
  KeycloakConflictError,
  KeycloakForbiddenError,
} from '../../src/errors.js'

describe('mapHttpError', () => {
  it('404 → KeycloakNotFoundError (계급 상속)', () => {
    const e = mapHttpError(404, 'x')
    expect(e).toBeInstanceOf(KeycloakNotFoundError)
    expect(e).toBeInstanceOf(KeycloakAdminError)
    expect(e).toBeInstanceOf(KeycloakError)
  })
  it('409 → Conflict, 403 → Forbidden', () => {
    expect(mapHttpError(409, 'x')).toBeInstanceOf(KeycloakConflictError)
    expect(mapHttpError(403, 'x')).toBeInstanceOf(KeycloakForbiddenError)
  })
  it('기타 상태 → KeycloakAdminError + name 보존 + 상태 포함', () => {
    const e = mapHttpError(500, 'boom')
    expect(e).toBeInstanceOf(KeycloakAdminError)
    expect(e.name).toBe('KeycloakAdminError')
    expect(e.message).toContain('500')
  })
})

// ⚠️ 하위 오류의 cause 사슬은 **이름·메시지·code 만** 남긴다. oauth4webapi 는 형식이 틀린 토큰 응답의 본문
// 전체(살아 있는 access/refresh 토큰)나 원문 id_token 을 `cause` 에 싣고, `console.log(err)` 와 로거의 깊은
// 직렬화가 그 사슬을 따라가 찍었다(실측 2026-09-26). 정화는 생성자 한 곳이라 모든 감싸기 자리를 덮는다.
describe('KeycloakError cause 정화', () => {
  const lower = (): Error => {
    const inner = Object.assign(new Error('Invalid JWT', { cause: 'RAW-ID-TOKEN' }), {
      code: 'OAUTH_INVALID_RESPONSE',
    })
    return Object.assign(
      new Error('invalid response encountered', {
        cause: { body: { access_token: 'RAW-AT', refresh_token: 'RAW-RT' } },
      }),
      { name: 'ClientError', code: 'OAUTH_INVALID_RESPONSE', inner, response: { body: 'RAW-RT' } },
    )
  }

  it('깊이 무제한 inspect 에도 하위 오류가 실은 값이 안 나온다', () => {
    const e = new KeycloakAuthError('grant failed', { cause: lower() })
    const out = inspect(e, { depth: Infinity })
    for (const raw of ['RAW-ID-TOKEN', 'RAW-AT', 'RAW-RT']) expect(out).not.toContain(raw)
  })

  it('사슬의 이름·메시지·code 는 남는다 — 디버깅할 수 있어야 한다', () => {
    const wrapped = Object.assign(new Error('fetch failed', { cause: lower() }), { name: 'TypeError' })
    const cause = new KeycloakAuthError('x', { cause: wrapped }).cause as Error & { code?: string }
    expect(cause.name).toBe('TypeError')
    expect(cause.message).toBe('fetch failed')
    const inner = cause.cause as Error & { code?: string }
    expect([inner.name, inner.message, inner.code]).toEqual([
      'ClientError',
      'invalid response encountered',
      'OAUTH_INVALID_RESPONSE',
    ])
    // 오류가 아닌 cause(문자열·응답 본문 객체)는 떨어진다.
    expect(inner.cause).toBeUndefined()
    expect(Object.keys(inner)).not.toContain('response')
  })

  it('원본 하위 오류 객체는 공개 API 로 새지 않는다(§4) — 사본이다', () => {
    const original = lower()
    expect(new KeycloakAuthError('x', { cause: original }).cause).not.toBe(original)
  })

  it('cause 가 없거나 오류가 아니면 cause 가 없다', () => {
    expect(new KeycloakAuthError('x').cause).toBeUndefined()
    expect(new KeycloakAuthError('x', { cause: 'RAW' }).cause).toBeUndefined()
    expect(inspect(new KeycloakAuthError('x', { cause: 'RAW' }))).not.toContain('RAW')
  })
})
