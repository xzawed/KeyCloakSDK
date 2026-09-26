/**
 * SDK 예외 계급. 하위 라이브러리(openid-client/@keycloak/*)의 에러는 항상 경계에서
 * 이 타입들로 변환되어 공개 API로 새지 않는다(§4 계약).
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

/** 설정 검증 실패(필수값 누락 등). */
export class KeycloakConfigError extends KeycloakError {}
/** 인증(OIDC/OAuth2) 흐름 실패. */
export class KeycloakAuthError extends KeycloakError {}
/** JWT 서명·만료·issuer·audience 검증 실패. */
export class KeycloakTokenValidationError extends KeycloakError {}
/** 관리(Admin) 작업 실패(일반). */
export class KeycloakAdminError extends KeycloakError {}
/** 리소스 없음(HTTP 404). */
export class KeycloakNotFoundError extends KeycloakAdminError {}
/** 충돌(HTTP 409). */
export class KeycloakConflictError extends KeycloakAdminError {}
/** 권한 없음(HTTP 403). */
export class KeycloakForbiddenError extends KeycloakAdminError {}
/** 네트워크·전송 계층 실패. */
export class KeycloakTransportError extends KeycloakError {}

/** HTTP 상태 코드를 SDK 예외로 매핑한다. */
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
