import {
  KeycloakAuthError,
  KeycloakNotFoundError,
  KeycloakTransportError,
  mapHttpError,
} from '../errors.js'
import { isTransportError } from '../transport.js'

/**
 * admin 요청의 Bearer 가 HTTP 헤더에 실릴 수 있는지 **플랫폼 자신에게** 묻는다 — 실을 수 없으면 토큰을 담지 않은
 * SDK 오류로 거부하고, 실을 수 있으면 그대로 돌려준다(값을 고쳐 쓰지 않는다).
 *
 * ⚠️ admin-client 는 요청마다 `new Headers([… ['authorization', `Bearer ${token}`] …])` 를 짓는다
 * (`lib/resources/agent.js` `#requestWithParams`). 토큰에 LF·CR·NUL 이 있으면 undici 가
 * `TypeError: Headers.append: "Bearer <토큰 전체>" is an invalid header value.` 를, U+00FF 를 넘는 문자(짝 없는
 * 서로게이트 · 잘못된 UTF-8 이 풀린 U+FFFD 포함)면 `Cannot convert argument to a ByteString …` 을 던졌고, 원인 없는
 * `TypeError` 라 {@link call} 이 그대로 다시 던졌다 — 앞의 것은 메시지·스택이 토큰을 통째로 인용했다(실측 2026-10-05).
 * 그 오류를 원인으로 감싸면 토큰이 사슬에 남는다(`scrubCause` 는 `SyntaxError` 만 가린다) — 그래서 짓기 **전에**
 * 같은 `Headers` 로 묻고, 실패하면 원인 없이 거부한다.
 *
 * 거르는 것은 플랫폼이 거부하는 것과 **정확히 같다**(규칙을 옮겨 적지 않는다). 플랫폼이 실어 보내는 값 —
 * U+00E9 같은 Latin-1, 앞뒤의 공백·탭·CR·LF(플랫폼이 다듬는다) — 은 지금처럼 보낸다. 길이도 보지 않는다 —
 * 요청 헤더 한도는 서버가 정하고(Keycloak 26.6 은 65,459 바이트 Bearer 를 받는다), 넘으면 서버 응답이나 전송
 * 실패가 이미 SDK 오류다.
 */
export function sendableBearer(token: string): string {
  const probe = new Headers()
  try {
    // `set` 은 admin-client 가 쓰는 초기화(`append`)와 같은 검사를 한다 — 다듬기 · 값 검사 · ByteString 변환.
    probe.set('authorization', `Bearer ${token}`)
  } catch {
    throw new KeycloakAuthError(
      'admin access token cannot be sent: an HTTP header cannot carry it ' +
        '(it holds CR, LF, NUL or a character above U+00FF)',
    )
  }
  return token
}

/**
 * admin-client 호출을 실행하고, 실패를 SDK 예외로 경계 변환한다(§4 계약).
 * admin-client는 HTTP 상태 실패를 `NetworkError`(`.response.status`/`.responseData`)로 던지고,
 * 전송 계층 실패(연결거부/DNS/TLS/타임아웃)는 raw fetch 오류(undici `TypeError: fetch failed` +
 * `cause`, 또는 타임아웃 `AbortError`)로 던진다 — 둘 다 하위 타입을 공개 API로 누출시키지 않는다.
 *
 * HTTP 상태가 있으면 상태별 SDK 예외로, 전송 실패면 KeycloakTransportError로 변환한다.
 * 그 외(전송이 아닌 프로그래밍 오류)는 그대로 재전파한다.
 */
export async function call<T>(fn: () => Promise<T>): Promise<T> {
  try {
    return await fn()
  } catch (err) {
    const status = statusOf(err)
    if (status !== undefined) {
      throw mapHttpError(status, messageOf(err), err)
    }
    if (isTransportError(err)) {
      throw new KeycloakTransportError('admin transport failure', { cause: err })
    }
    throw err
  }
}

/**
 * admin-client의 `findOne`/`findOneByName`류는 404에서 `null`(또는 `undefined`)을 반환한다
 * (선언 타입은 `undefined`지만 런타임은 `null`) — 부재를 SDK {@link KeycloakNotFoundError}로 통일한다.
 */
export function requireFound<T>(value: T | null | undefined, message: string): T {
  if (value === null || value === undefined) {
    throw new KeycloakNotFoundError(message)
  }
  return value
}

function statusOf(err: unknown): number | undefined {
  const status = (err as { response?: { status?: unknown } } | null | undefined)?.response?.status
  return typeof status === 'number' ? status : undefined
}

function messageOf(err: unknown): string {
  const data = (err as { responseData?: unknown } | null | undefined)?.responseData
  if (data !== null && typeof data === 'object') {
    const record = data as Record<string, unknown>
    const message = record['errorMessage'] ?? record['error']
    if (typeof message === 'string') {
      return message
    }
  }
  return err instanceof Error ? err.message : 'admin request failed'
}
