/**
 * SDK exception hierarchy. Errors from the underlying libraries (openid-client/@keycloak/*) are always
 * converted to these types at the boundary and never leak into the public API (§4 contract).
 */
export class KeycloakError extends Error {
  constructor(message: string, options?: { cause?: unknown }) {
    const cause = scrubCause(options?.cause)
    super(message, cause === undefined ? undefined : { cause })
    this.name = new.target.name
  }
}

/**
 * 하위 오류의 cause 사슬을 **이름·메시지·code·스택만** 남긴 사본으로 바꾼다. 오류가 아닌 cause 는 떨어진다.
 *
 * ⚠️ oauth4webapi 는 형식이 틀린 토큰 응답의 **본문 전체**(살아 있는 access/refresh 토큰)나 원문 id_token 을
 * `cause` 에 싣는다 — 원본을 그대로 달면 `console.log(err)` 와 로거의 깊은 직렬화가 그 사슬을 따라가 토큰을
 * 찍었다(실측 2026-09-26). 생성자 한 곳에서 하므로 모든 감싸기 자리를 덮고, 원본 하위 오류 객체도 공개 API 로
 * 새지 않는다(§4). 전송 오류 분류는 감싸기 **전에** 원본으로 끝난다(`isTransportError`).
 */
function scrubCause(cause: unknown, depth = 0): Error | undefined {
  if (!(cause instanceof Error) || depth > 8) return undefined
  const inner = scrubCause((cause as { cause?: unknown }).cause, depth + 1)
  // ⚠️ `SyntaxError` 는 입력을 인용한다 — `JSON.parse` 가 본문을(짧으면 전부, 길면 앞 10 자) 메시지와 스택 첫 줄에
  // 싣는다. 토큰 엔드포인트가 200 에 JSON 아닌 본문을 주면 그대로 찍혔다(재현 2026-09-26). 둘 다 옮기지 않는다.
  const quotesInput = cause instanceof SyntaxError
  const message = quotesInput ? 'invalid JSON (input withheld)' : cause.message
  const copy = new Error(message, inner === undefined ? undefined : { cause: inner })
  copy.name = cause.name
  if (!quotesInput && cause.stack !== undefined) copy.stack = cause.stack
  const code = (cause as { code?: unknown }).code
  if (typeof code === 'string') Object.assign(copy, { code })
  return copy
}

/** Configuration validation failure (a missing required value, etc.). */
export class KeycloakConfigError extends KeycloakError {}
/** Authentication (OIDC/OAuth2) flow failure. */
export class KeycloakAuthError extends KeycloakError {}
/** JWT signature/expiry/issuer/audience validation failure. */
export class KeycloakTokenValidationError extends KeycloakError {}
/** Admin operation failure (general). */
export class KeycloakAdminError extends KeycloakError {}
/** Resource not found (HTTP 404). */
export class KeycloakNotFoundError extends KeycloakAdminError {}
/** Conflict (HTTP 409). */
export class KeycloakConflictError extends KeycloakAdminError {}
/** No permission (HTTP 403). */
export class KeycloakForbiddenError extends KeycloakAdminError {}
/** Network/transport-layer failure. */
export class KeycloakTransportError extends KeycloakError {}

/** Maps an HTTP status code to an SDK exception. */
export function mapHttpError(status: number, message: string, cause?: unknown): KeycloakError {
  switch (status) {
    case 404:
      return new KeycloakNotFoundError(message, { cause })
    case 409:
      return new KeycloakConflictError(message, { cause })
    case 403:
      return new KeycloakForbiddenError(message, { cause })
    default:
      return new KeycloakAdminError(`HTTP ${status}: ${message}`, { cause })
  }
}
