import { KeycloakNotFoundError, KeycloakTransportError, mapHttpError } from '../errors.js'
import { isTransportError } from '../transport.js'

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
