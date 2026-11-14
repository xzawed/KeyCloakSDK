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

// 등록부 node-admin-error-no-status — 여덟 언어의 admin 오류는 상태를 필드로 싣는다(python `status_code` · go
// `StatusCode` · .NET `StatusCode` · php `getStatusCode()` · rust `Other { status }` · ruby `status` · java ·
// kotlin `status`). node 만 없어, 404 · 409 · 403 은 클래스로만, 나머지는 메시지 머리 `HTTP <상태>:` 로만 드러났다.
describe('KeycloakAdminError.status', () => {
  // mapHttpError 의 선언 반환 형은 게시된 그대로 `KeycloakError` 다(api-extractor 가드) — 형은 instanceof 로 좁힌다.
  const admin = (e: KeycloakError): KeycloakAdminError => {
    expect(e).toBeInstanceOf(KeycloakAdminError)
    return e as KeycloakAdminError
  }
  it('mapHttpError 는 상태를 필드로 싣는다 — 하위 클래스 셋과 일반 클래스 모두', () => {
    for (const status of [302, 400, 401, 403, 404, 409, 422, 500, 503]) {
      expect(admin(mapHttpError(status, 'x')).status).toBe(status)
    }
  })
  it('하위 클래스는 제 상태를 스스로 갖는다 — 상태 없이 만들어도', () => {
    expect(new KeycloakNotFoundError('x').status).toBe(404)
    expect(new KeycloakConflictError('x').status).toBe(409)
    expect(new KeycloakForbiddenError('x').status).toBe(403)
  })
  it('일반 클래스는 받은 상태를 싣고, 상태 없이 만들면 undefined 다(소비자의 기존 생성자 호출 호환)', () => {
    expect(new KeycloakAdminError('x', { status: 418 }).status).toBe(418)
    expect(new KeycloakAdminError('x').status).toBeUndefined()
  })
  it('상태를 실어도 cause 정화는 그대로다', () => {
    const e = admin(
      mapHttpError(500, 'boom', new SyntaxError('Unexpected token R in JSON at position 0: RAW')),
    )
    expect(e.status).toBe(500)
    expect((e.cause as Error).message).toBe('invalid JSON (input withheld)')
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
    const wrapped = Object.assign(new Error('fetch failed', { cause: lower() }), {
      name: 'TypeError',
    })
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

// ⚠️ `SyntaxError` 는 **입력을 인용한다** — `JSON.parse` 가 `Unexpected token 'C', "CANARY-RT" is not valid JSON`
// 처럼 본문을(짧으면 전부, 길면 앞 10 자) 메시지와 스택 첫 줄에 싣는다. 토큰 엔드포인트가 200 에 JSON 아닌 본문을
// 주면 그대로 찍혔다(Grok 적대 레그, 재현 2026-09-26). 메시지를 고정 문구로 바꾸고 스택은 옮기지 않는다.
describe('KeycloakError cause 정화 — 입력을 인용하는 SyntaxError', () => {
  it('메시지와 스택 어디에도 인용된 입력이 남지 않는다', () => {
    let parseError: unknown
    try {
      JSON.parse('RAW-BODY-TOKEN')
    } catch (e) {
      parseError = e
    }
    expect(inspect(parseError)).toContain('RAW-BODY') // 대조군 — 원본은 정말 인용한다
    const e = new KeycloakAuthError('x', {
      cause: new Error('parse failed', { cause: parseError }),
    })
    for (const out of [inspect(e), inspect(e, { depth: Infinity })])
      expect(out).not.toContain('RAW-BODY')
    const inner = (e.cause as Error).cause as Error
    expect(inner.name).toBe('SyntaxError')
  })
})
