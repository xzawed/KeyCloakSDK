import { KeycloakNotFoundError, KeycloakTransportError, mapHttpError } from '../errors.js'
import { isTransportError } from '../transport.js'

/**
 * Runs an admin request and converts a failure to an SDK exception at the boundary (§4 contract).
 * The facade's requests (`http.ts`) throw an HTTP status failure in the same shape as admin-client's
 * `NetworkError` (`.response.status`/`.responseData`), and a transport-layer failure (connection
 * refused/DNS/TLS/timeout) as a raw fetch error (undici `TypeError: fetch failed` + `cause`, or a timeout
 * `AbortError`) — neither one leaks an underlying type into the public API.
 *
 * With an HTTP status it converts to the SDK exception for that status; a transport failure becomes
 * KeycloakTransportError. Anything else (a programming error, not a transport one) is rethrown as is.
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
 * admin-client's `findOne`/`findOneByName` family returns `null` (or `undefined`) on a 404
 * (the declared type says `undefined`, but at runtime it is `null`) — this unifies absence as the SDK's
 * {@link KeycloakNotFoundError}.
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
