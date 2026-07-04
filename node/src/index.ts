// 공개 배럴 — SDK의 공개 API 표면. 하위 라이브러리 타입은 재수출하지 않는다(파사드 뒤 은닉).

// 통합 진입점
export { KeycloakClient } from './client.js'

// 인증 파사드
export { AuthClient, type AuthorizationRequest } from './auth.js'

// 관리 파사드 + 리소스
export {
  AdminClient,
  UsersResource,
  ClientsResource,
  RealmsResource,
  RolesResource,
  GroupsResource,
} from './admin/index.js'

// 설정
export { defineConfig, type KeycloakConfig, type KeycloakConfigInput } from './config.js'

// 예외 계급 + HTTP 매핑
export * from './errors.js'

// 값 타입
export {
  TokenSet,
  tokenSetFromResponse,
  type ValidatedToken,
  type IntrospectionResult,
} from './tokens.js'

// 토큰 공급 SPI
export {
  ClientCredentialsTokenProvider,
  type TokenProvider,
  type TokenSource,
} from './token-provider.js'

// OIDC 엔드포인트 조립 + 강화 JWT 검증기(고급 사용)
export { oidcEndpoints, type OidcEndpoints } from './oidc-metadata.js'
export { JwtValidator, type JwtValidatorOptions } from './jwt.js'
