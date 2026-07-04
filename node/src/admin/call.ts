import { mapHttpError } from '../errors.js'

/**
 * admin-client 호출을 실행하고, 실패 시 HTTP 상태를 SDK 예외로 경계 변환한다(§4 계약).
 * admin-client는 실패를 `NetworkError`(`.response.status`/`.responseData`)로 던진다 — 하위
 * 타입(`jakarta.ws.rs.*`/`NetworkError`)을 공개 API로 누출하지 않기 위해 여기서 변환한다.
 *
 * HTTP 응답 상태가 없는(전송 계층/프로그래밍) 오류는 그대로 재전파한다.
 */
export async function call<T>(fn: () => Promise<T>): Promise<T> {
  try {
    return await fn()
  } catch (err) {
    const status = statusOf(err)
    if (status !== undefined) {
      throw mapHttpError(status, messageOf(err), err)
    }
    throw err
  }
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
