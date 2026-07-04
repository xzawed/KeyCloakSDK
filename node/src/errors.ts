/**
 * SDK 예외 계급. 하위 라이브러리(openid-client/@keycloak/*)의 에러는 항상 경계에서
 * 이 타입들로 변환되어 공개 API로 새지 않는다(§4 계약).
 */
export class KeycloakError extends Error {
  constructor(message: string, options?: { cause?: unknown }) {
    super(message, options)
    this.name = new.target.name
  }
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
