import { describe, it, expect } from 'vitest'
import { isTransportError } from '../../src/transport.js'

// ⚠️ **이 파일이 없을 때 `TRANSPORT_CODES` 에서 `CERT_HAS_EXPIRED` 를 지워도 107 전부 통과했다**
// (실측 2026-09-10, 변이 프로브 `SILENT`). 호출 자리 테스트(auth·admin 경계)가 이 분류기를
// **구동은 하지만** 치는 팔이 `AbortError` 와 `ECONNREFUSED` **둘뿐**이었고, `src/transport.ts` 는
// 커버리지 게이트에서 제외돼 있어 나머지 15개 코드가 측정되지도 않았다.
//
// ⚠️ TLS 코드가 빠지면 만료·자가서명 인증서 실패가 **전송 오류로 분류되지 않아** 하위 오류가
// 그대로 소비자에게 샌다(§4 경계 계약 위반). 그래서 표로 전수를 친다.
describe('isTransportError — 전송 실패 분류기', () => {
  const transportCodes = [
    'ECONNREFUSED',
    'ECONNRESET',
    'EHOSTUNREACH',
    'ENETUNREACH',
    'EPIPE',
    'ENOTFOUND',
    'EAI_AGAIN',
    'ETIMEDOUT',
    'UND_ERR_CONNECT_TIMEOUT',
    'UND_ERR_HEADERS_TIMEOUT',
    'UND_ERR_SOCKET',
    'CERT_HAS_EXPIRED',
    'DEPTH_ZERO_SELF_SIGNED_CERT',
    'UNABLE_TO_VERIFY_LEAF_SIGNATURE',
    'SELF_SIGNED_CERT_IN_CHAIN',
    'ERR_TLS_CERT_ALTNAME_INVALID',
  ]

  it.each(transportCodes)('직접 code=%s 는 전송 오류다', (code) => {
    expect(isTransportError(Object.assign(new Error('boom'), { code }))).toBe(true)
  })

  it.each(transportCodes)('cause.code=%s 도 전송 오류다', (code) => {
    // undici 는 시스템 오류를 `cause` 에 담아 던진다.
    const err = new Error('outer') as Error & { cause?: unknown }
    err.cause = Object.assign(new Error('inner'), { code })
    expect(isTransportError(err)).toBe(true)
  })

  it.each(['AbortError', 'TimeoutError'])('name=%s 는 전송 오류다', (name) => {
    expect(isTransportError(Object.assign(new Error('t'), { name }))).toBe(true)
  })

  it('cause 있는 TypeError 는 전송 오류다(undici "fetch failed")', () => {
    expect(isTransportError(new TypeError('fetch failed', { cause: new Error('x') }))).toBe(true)
  })

  // ── 음성 케이스 — 이것이 없으면 위 표는 「항상 true 를 돌려준다」와 구분되지 않는다 ──
  it('cause 없는 TypeError 는 전송 오류가 아니다(프로그래밍 버그)', () => {
    expect(isTransportError(new TypeError('bug'))).toBe(false)
  })

  it('알 수 없는 code 는 전송 오류가 아니다', () => {
    expect(isTransportError(Object.assign(new Error('e'), { code: 'ENOENT' }))).toBe(false)
  })

  it.each([null, undefined, 'string', 42, true])('객체가 아니면 전송 오류가 아니다: %s', (v) => {
    expect(isTransportError(v)).toBe(false)
  })

  it('code 가 문자열이 아니면 무시한다', () => {
    expect(isTransportError(Object.assign(new Error('e'), { code: 111 }))).toBe(false)
  })
})
