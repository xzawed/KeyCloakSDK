import { describe, expect, it } from 'vitest'
import { call, requireFound } from '../../src/admin/call.js'
import {
  KeycloakNotFoundError,
  KeycloakTransportError,
  KeycloakError,
} from '../../src/errors.js'

// ⚠️ **이 파일이 있는 이유 — `src/admin/**` 커버리지 제외가 순수 로직을 삼켰다.**
// `call.ts` 는 네트워크를 타지 않는다: `call` 은 호출자가 넘긴 `fn` 을 부를 뿐이고,
// `statusOf`·`messageOf`·`requireFound` 는 인자만으로 결정된다. 그런데 파일 전체가
// 제외 안에 있어 분기가 **측정되지 않았고**, 실측(2026-09-15, `scripts/probe.sh --site`):
//   · `statusOf` 의 `typeof status === 'number'` 검사 제거 → **SILENT**
//   · `messageOf` 의 `?? record['error']` 폴백 제거      → **SILENT**
//   · `messageOf` 의 기본 문구 변경                        → **SILENT**
// `src/transport.ts` 가 2026-09-10 에 같은 이유로 제외에서 빠졌다 — 같은 부류의 둘째 자리다.
// ⚠️ `requireFound` 는 이 부류가 **아니다**: 무력화하면 admin 위임 테스트 다섯이 실패한다
//    (실측 `CAUGHT`). 등록부가 「테스트 언급 0」이라 적은 것은 **이름 grep** 이었다.

describe('requireFound — 부재를 NotFound 로 통일한다', () => {
  it('null 과 undefined 만 던진다 — falsy 값은 통과시킨다', () => {
    expect(() => requireFound(null, 'x')).toThrow(KeycloakNotFoundError)
    expect(() => requireFound(undefined, 'x')).toThrow(KeycloakNotFoundError)
    // ⚠️ `0`·`''`·`false` 는 **있는 값**이다. `!value` 로 바꾸면 여기서 떨어진다.
    expect(requireFound(0, 'x')).toBe(0)
    expect(requireFound('', 'x')).toBe('')
    expect(requireFound(false, 'x')).toBe(false)
  })
  it('메시지를 그대로 실어 보낸다', () => {
    expect(() => requireFound(null, '사용자 없음')).toThrow('사용자 없음')
  })
})

// `statusOf` 는 export 되지 않으므로 `call` 을 통해 관찰한다 — 상태가 숫자면 HTTP 매핑,
// 아니면 (전송오류가 아닌 한) 원래 오류가 그대로 재전파된다.
const withResponse = (status: unknown, responseData?: unknown): unknown =>
  Object.assign(new Error('raw'), { response: { status }, responseData })

describe('statusOf — 상태는 **숫자일 때만** 상태다', () => {
  const notNumbers: Array<[string, unknown]> = [
    ['문자열', '404'],
    ['객체', { code: 404 }],
    ['null', null],
    ['undefined', undefined],
    ['불리언', true],
  ]
  for (const [label, status] of notNumbers) {
    it(`${label} 상태는 HTTP 로 매핑하지 않고 원래 오류를 재전파한다`, async () => {
      const raw = withResponse(status)
      await expect(call(() => Promise.reject(raw))).rejects.toBe(raw)
    })
  }
  it('숫자 상태는 SDK 예외로 변환한다', async () => {
    await expect(call(() => Promise.reject(withResponse(404)))).rejects.toBeInstanceOf(KeycloakError)
  })
  it('response 자체가 없으면 재전파한다', async () => {
    const raw = new Error('plain')
    await expect(call(() => Promise.reject(raw))).rejects.toBe(raw)
  })
})

describe('messageOf — 어떤 문구가 소비자에게 가는가', () => {
  const cases: Array<[string, unknown, string]> = [
    ['errorMessage 우선', { errorMessage: '첫째', error: '둘째' }, '첫째'],
    ['errorMessage 가 없으면 error', { error: '둘째' }, '둘째'],
    // ⚠️ `??` 라 **null/undefined 만** 다음 키로 넘어간다. `||` 로 바꾸면 빈 문자열에서 갈린다.
    ['errorMessage 가 null 이면 error', { errorMessage: null, error: '둘째' }, '둘째'],
    ['errorMessage 가 빈 문자열이면 그 빈 문자열', { errorMessage: '', error: '둘째' }, ''],
    // ⚠️ `errorMessage` 가 문자열이 **아니면** `error` 로도 안 간다 — `??` 가 이미 소비했다.
    ['errorMessage 가 숫자면 raw 메시지로 떨어진다', { errorMessage: 7, error: '둘째' }, 'raw'],
    ['responseData 가 없으면 raw 메시지', undefined, 'raw'],
    ['responseData 가 null 이면 raw 메시지', null, 'raw'],
    ['responseData 가 문자열이면 raw 메시지', 'nope', 'raw'],
  ]
  // ⚠️ **정확일치로 대조한다 — 부분문자열은 빈 문자열을 구분하지 못한다.**
  // 처음에 `toThrow(want)` 로 썼다가 `want` 가 `''` 인 행에서 오판했다(실측):
  // 빈 문자열은 `/^$/` 로 해석돼 실제 문구 `'HTTP 500: '` 와 안 맞는다.
  // `mapHttpError` 가 `HTTP <상태>: ` 를 앞에 붙이므로 그것까지 포함해 맞춘다.
  for (const [label, responseData, want] of cases) {
    it(label, async () => {
      const err = await call(() => Promise.reject(withResponse(500, responseData))).then(
        () => null,
        (e: unknown) => e,
      )
      expect((err as Error).message).toBe(`HTTP 500: ${want}`)
    })
  }
  it('Error 가 아닌 것이 던져지면 기본 문구를 쓴다', async () => {
    const raw = { response: { status: 500 } }
    const err = await call(() => Promise.reject(raw)).then(
      () => null,
      (e: unknown) => e,
    )
    expect((err as Error).message).toBe('HTTP 500: admin request failed')
  })
})

describe('call — 경계 변환', () => {
  it('성공은 그대로 돌려준다', async () => {
    await expect(call(() => Promise.resolve(42))).resolves.toBe(42)
  })
  it('전송 실패는 KeycloakTransportError 로 감싼다', async () => {
    const raw = Object.assign(new TypeError('fetch failed'), {
      cause: Object.assign(new Error('boom'), { code: 'ECONNREFUSED' }),
    })
    await expect(call(() => Promise.reject(raw))).rejects.toBeInstanceOf(KeycloakTransportError)
  })
  it('전송도 HTTP 도 아니면 원래 오류를 그대로 던진다', async () => {
    const raw = new RangeError('프로그래밍 오류')
    await expect(call(() => Promise.reject(raw))).rejects.toBe(raw)
  })
})
